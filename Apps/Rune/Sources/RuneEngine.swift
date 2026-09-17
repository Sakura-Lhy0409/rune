import Foundation
import RuneKernel

// MARK: - 手机上真的跑一遍内核
//
// ⚠️ 这个文件的定位要说清楚：**它不是最终的产品引擎，它是"这条链路通了"的证据。**
//
// 在没有 Mac 的开发环境里（见 docs/16），最贵的失败模式是
// "写了一堆东西，推到 CI，才发现整条链路根本没通"。所以第一个上手机的版本刻意做到最小：
//
//   * 不走网络（真的模型客户端要等 RuneNet，那是下一步）
//   * 用**内存文件系统**（真的 VFS 要等 RuneBench）
//   * 但走的是**真正的** TurnRunner / ToolRegistry / PolicyEngine / EventLog ——
//     也就是内核里那 822 项测试覆盖的同一批代码
//
// 它证明的是：**内核能在 iOS 上构建、能在真机上跑、事件日志是真的**。
// 至于"接上真的模型"，那是把 MockProvider 换成真实流的适配器 —— 接口已经就位。

/// 演示用的"模型"。
///
/// 它按轮次返回**写死的**工具调用，用来把循环跑通：
/// 列目录 → 读文件 → 改文件 → 报告完成。
/// 真实实现（`RuneGateway`）会把这些 event 从 SSE 流里解出来 ——
/// `TurnRunner` 完全看不出区别，因为它只认 `ModelEvent`。
struct ScriptedModel: Sendable {
    func events(for state: TurnState) -> [ModelEvent] {
        switch state.round {
        case 0:
            return Self.call("c1", ToolName.listDir, ["path": .string("/workspace")])
        case 1:
            return Self.call("c2", ToolName.readFile, ["path": .string("/workspace/README.md")])
        case 2:
            return Self.call("c3", ToolName.writeFile, [
                "path": .string("/workspace/NOTES.md"),
                "content": .string("# 由 Rune 生成\n\n这个文件是 Agent 在设备上自己写出来的。\n"),
            ])
        default:
            return [
                .textDelta("我在设备上跑完了：列目录 → 读 README → 写出 NOTES.md。\n事件日志里能看到每一步。"),
                .usage(TokenUsage(inputTokens: 420, outputTokens: 64)),
                .finished(reason: .stop),
            ]
        }
    }

    private static func call(_ id: String, _ name: String, _ args: [String: JSONValue]) -> [ModelEvent] {
        let json = JSONValue.object(args).canonicalString()
        return [
            .toolCallStarted(index: 0, id: id, name: name),
            .toolCallArgumentsDelta(index: 0, jsonFragment: json),
            .usage(TokenUsage(inputTokens: 320, outputTokens: 40)),
            .finished(reason: .toolCalls),
        ]
    }
}

/// 把工具真正"实现"到内存文件系统上。
///
/// 这是 `ToolExecuting` 的一个最小实现 —— 真实的那份（`RuneTools`）会把
/// 每个工具接到 `RuneBench` 的 VFS 与原生命令表上；**契约是一样的**。
struct DemoExecutor: ToolExecuting {
    let files: FileBox

    func execute(_ call: ToolCall) throws -> ToolResult {
        let args = (try? call.arguments()) ?? .object([:])
        let path = args.value(at: ["path"])?.stringValue ?? "/workspace"

        switch call.name {
        case ToolName.listDir:
            let names = files.paths().sorted()
            return .ok(callID: call.id, summary: names.isEmpty ? "（空目录）" : names.joined(separator: "\n"))

        case ToolName.readFile:
            guard let content = files.read(path) else {
                return .failure(callID: call.id, error: ToolError(
                    kind: .pathNotFound,
                    modelFacingMessage: "文件不存在：\(path)",
                    suggestion: "用 list_dir 看看目录里有什么。",
                    candidates: files.paths()
                ))
            }
            return .ok(callID: call.id, summary: content)

        case ToolName.writeFile:
            let content = args.value(at: ["content"])?.stringValue ?? ""
            files.write(path, content)
            return .ok(callID: call.id, summary: "已写入 \(path)（\(content.utf8.count) 字节）")

        default:
            return .ok(callID: call.id, summary: "（演示执行器没有实现 \(call.name)）")
        }
    }
}

/// 一个极小的文件存储。真实项目里这里是 `RuneBench` 的 VFS。
final class FileBox: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String]

    init(_ files: [String: String]) { self.files = files }

    func read(_ path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return files[path]
    }

    func write(_ path: String, _ content: String) {
        lock.lock(); files[path] = content; lock.unlock()
    }

    func paths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(files.keys)
    }
}

// MARK: - 引擎

/// 一次运行的可见结果（UI 直接渲染它）
struct RunReport: Sendable {
    var objective: String
    var finalText: String
    var timeline: [String]
    var files: [String: String]
    var costMicroUSD: Int
    var toolCalls: Int
    var chainOK: Bool
    var statusText: String
}

/// 驱动内核跑一轮。
///
/// ⚠️ 注意它是**纯同步、无网络、无持久化**的 —— 这样第一次装到手机上时，
/// 出问题的地方只可能是 SwiftUI 或链接，不会是"某个异步边界没处理对"。
@MainActor
final class RuneEngine: ObservableObject {
    @Published private(set) var report: RunReport?
    @Published private(set) var isRunning = false

    func runDemo() {
        isRunning = true
        defer { isRunning = false }

        let box = FileBox([
            "/workspace/README.md": "# 演示项目\n\n这是一个跑在 iPhone 上的 Agent 的工作区。\n",
            "/workspace/src/main.py": "print('hello')\n",
        ])
        let model = ScriptedModel()
        let sessionID = UUID()
        let log = EventLog(sessionID: sessionID, anchorInterval: 1_000)

        let deps = TurnRunner.Dependencies(
            modelEvents: { state in model.events(for: state) },
            executor: DemoExecutor(files: box),
            policy: PolicyEngine(),
            // 计划已批准 → 修改类工具不需要逐次确认（docs/05 §8.1 的分工）。
            // 演示里没有审批 UI，所以这里走"已批准"这条路；
            // 真实的审批交互要等 RuneUI 的第二版。
            policyContext: Self.demoContext(),
            now: { Date() },
            pathsOfCall: ToolScheduler.defaultPaths
        )
        let config = TurnRunner.Config(
            maxRounds: 8, maxToolCalls: 12,
            toolRegistry: ToolRegistry.byName
        )

        let (final, events, _) = TurnRunner.run(
            TurnState(sessionID: sessionID, objective: "在设备上跑一遍内核"),
            deps: deps, config: config
        )

        // 把这次运行的事件写进日志，然后**从日志校验哈希链** ——
        // 这是"事件日志是唯一真相源"这句话在设备上的第一次实证。
        for event in events {
            log.append(.init(
                kind: event.kind, payload: event.payload,
                turnID: event.turnID, goalID: event.goalID,
                subagentID: event.subagentID,
                originTrust: event.originTrust, tainted: event.tainted
            ))
        }
        let verification = log.verify()

        let finalText = final.messages
            .last { $0.role == .assistant }?
            .plainText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "（模型没有产出文字，但有 \(events.count) 条事件）"

        report = RunReport(
            objective: final.objective,
            finalText: finalText,
            timeline: events.compactMap { event in
                let detail = event.payload.value(at: ["tool"])?.stringValue
                    ?? event.payload.value(at: ["summary"])?.stringValue
                    ?? event.payload.value(at: ["reason"])?.stringValue
                    ?? ""
                return detail.isEmpty
                    ? event.displayTitle
                    : "\(event.displayTitle) · \(detail.prefix(60))"
            },
            files: box.paths().sorted().reduce(into: [:]) { result, path in
                result[path] = box.read(path) ?? ""
            },
            costMicroUSD: 0,
            toolCalls: final.toolCallCount,
            chainOK: verification.isOK,
            statusText: verification.isOK
                ? "\(events.count) 条事件 · 哈希链校验通过"
                : "⚠️ 事件链校验未通过"
        )
    }

    /// 演示用的策略上下文：整个工作区可写、已批准计划。
    private static func demoContext() -> PolicyEngine.Context {
        let scope = VFSPath(mount: .workspace)
        let token = CapabilityToken(
            issuedForTurn: UUID(),
            scopes: [.fsRead(scope), .fsWrite(scope)],
            expiresAt: Date().addingTimeInterval(3_600),
            grantedBy: .planApproval,
            reason: "设备演示"
        )
        return PolicyEngine.Context(trustDial: .collaborate, token: token, planApproved: true)
    }
}
