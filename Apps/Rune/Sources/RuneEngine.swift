import Foundation
import RuneKernel

// MARK: - 手机上真的跑一遍内核
//
// ⚠️ 这个文件的定位要说清楚：**它不是最终的产品引擎，它是"这条链路通了"的证据。**
//
// 在没有 Mac 的开发环境里（见 docs/16），最贵的失败模式是
// "写了一堆东西，推到 CI，才发现整条链路根本没通"。所以第一个上手机的版本刻意做到最小：
//
//   * **不走网络**（真的模型客户端要等 RuneNet）
//   * **用真的文件系统**：在工作区的 Documents 里建一个演示目录，工具真的读写那里的文件
//   * 走的是**真正的** TurnRunner / ToolRegistry / PolicyEngine / LocalToolExecutor / EventLog
//     —— 也就是内核里那 877 项测试覆盖的同一批代码
//
// 它证明的是：**内核能在 iOS 上构建、能在真机上跑、能真的改设备上的文件、事件日志是真的。**
// 至于"接上真的模型"，那是把 ScriptedModel 换成真实流的适配器 —— 接口已经就位。

/// 演示用的"模型"。
///
/// 它按轮次返回**写死的**工具调用，用来把循环跑通：
/// 找 → 读 → 改 → 复读确认。
/// 真实实现（`RuneGateway`）会把这些 event 从 SSE 流里解出来 ——
/// `TurnRunner` 完全看不出区别，因为它只认 `ModelEvent`。
struct ScriptedModel: Sendable {
    func events(for state: TurnState) -> [ModelEvent] {
        switch state.round {
        case 0:
            return Self.call("c1", ToolName.listDir, ["path": .string("/workspace")])
        case 1:
            return Self.call("c2", ToolName.readFile, ["path": .string("notes.md")])
        case 2:
            return Self.call("c3", ToolName.editFile, [
                "path": .string("notes.md"),
                "old_string": .string("- [ ] 在设备上跑一遍内核"),
                "new_string": .string("- [x] 在设备上跑一遍内核（这一行是 Agent 自己勾上的）"),
            ])
        case 3:
            return Self.call("c4", ToolName.readFile, ["path": .string("notes.md")])
        default:
            return [
                .textDelta("""
                我在设备上跑完了：列目录 → 读 notes.md → 改掉一行 → 复读确认。
                工作区里的文件是真的被改了，你可以到「文件」App 里打开看。
                时间轴上的每一步都来自事件日志，哈希链已校验。
                """),
                .usage(TokenUsage(inputTokens: 640, outputTokens: 128)),
                .finished(reason: .stop),
            ]
        }
    }

    private static func call(_ id: String, _ name: String, _ args: [String: JSONValue]) -> [ModelEvent] {
        let json = JSONValue.object(args).canonicalString()
        return [
            .toolCallStarted(index: 0, id: id, name: name),
            .toolCallArgumentsDelta(index: 0, jsonFragment: json),
            .usage(TokenUsage(inputTokens: 420, outputTokens: 48)),
            .finished(reason: .toolCalls),
        ]
    }
}

// MARK: - 工作区

/// 演示工作区：App 的 Documents 下建一个真实目录，工具真的读写它。
///
/// ⚠️ 这里是**真文件系统**（`FileManagerVFS`），不是内存副本 ——
/// 这样装到手机上之后，"Agent 能改设备上的文件"这件事是被真正验证的，
/// 而不是在一个看起来很像的假象上验证的。
///
/// 真机上真正的工作区会是用户用文件选择器授权的目录（security-scoped bookmark）；
/// Documents 下的演示目录是它的替身，两者走的是同一套 VFS 契约。
enum DemoWorkspace {

    static func url() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let workspace = documents.appendingPathComponent("RuneDemo", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    /// 第一次运行时铺一份演示文件；之后不覆盖用户的改动
    static func seedIfNeeded(_ workspace: URL) {
        let notes = workspace.appendingPathComponent("notes.md")
        guard !FileManager.default.fileExists(atPath: notes.path) else { return }
        let content = """
        # Rune 演示工作区

        这个目录在 App 的 Documents 下，Agent 真的会读写这里的文件。

        ## 待办
        - [ ] 在设备上跑一遍内核

        ## 说明
        点一下「在设备上跑一遍内核」，它会列目录、读这个文件、勾上上面那一行、再读一遍确认。
        跑完之后你可以用「文件」App 打开这个目录，看到那一行真的被改了。
        """
        try? content.write(to: notes, atomically: true, encoding: .utf8)

        let readme = workspace.appendingPathComponent("README.md")
        try? "# 演示项目\n\n这个目录由 Rune 在设备上创建。\n"
            .write(to: readme, atomically: true, encoding: .utf8)
    }
}

// MARK: - 引擎

/// 一次运行的可见结果（UI 直接渲染它）
struct RunReport: Sendable {
    var objective: String
    var finalText: String
    var timeline: [String]
    var files: [String: String]
    var workspacePath: String
    var toolCalls: Int
    var chainOK: Bool
    var statusText: String
}

/// 驱动内核跑一轮。
///
/// ⚠️ 它是**纯同步、无网络**的 —— 这样第一次装到手机上时，
/// 出问题的地方只可能是 SwiftUI 或链接，不会是"某个异步边界没处理对"。
@MainActor
final class RuneEngine: ObservableObject {
    @Published private(set) var report: RunReport?
    @Published private(set) var isRunning = false

    func runDemo() {
        isRunning = true
        defer { isRunning = false }

        let sessionID = UUID()
        let log = EventLog(sessionID: sessionID, anchorInterval: 1_000)

        do {
            let workspace = try DemoWorkspace.url()
            DemoWorkspace.seedIfNeeded(workspace)

            // ⭐ 真文件系统 + 真工具实现（14 个文件/检索工具）
            let vfs = FileManagerVFS(baseURL: workspace)
            let executor = LocalToolExecutor(
                vfs: vfs,
                artifacts: InMemoryArtifactStore(),
                now: { Date() }
            )
            let model = ScriptedModel()

            let deps = TurnRunner.Dependencies(
                modelEvents: { state in model.events(for: state) },
                executor: executor,
                policy: PolicyEngine(),
                // 计划已批准 → 修改类工具不需要逐次确认（docs/05 §8.1 的分工）。
                // 演示里还没有审批 UI，所以走"已批准"这条路；
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
                files: Self.snapshot(of: workspace),
                workspacePath: workspace.path,
                toolCalls: final.toolCallCount,
                chainOK: verification.isOK,
                statusText: verification.isOK
                    ? "\(events.count) 条事件 · 哈希链校验通过"
                    : "⚠️ 事件链校验未通过"
            )
        } catch {
            report = RunReport(
                objective: "在设备上跑一遍内核",
                finalText: "跑不起来：\(error)",
                timeline: [],
                files: [:],
                workspacePath: "",
                toolCalls: 0,
                chainOK: false,
                statusText: "失败"
            )
        }
    }

    /// 读回工作区的实际内容（界面要显示的就是磁盘上真实的样子）
    private static func snapshot(of workspace: URL) -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: workspace, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [:] }
        var result: [String: String] = [:]
        for case let item as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let relative = item.path.dropFirst(workspace.path.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let text = try? String(contentsOf: item, encoding: .utf8) {
                result[relative] = text
            }
        }
        return result
    }

    /// 演示用的策略上下文：整个演示工作区可读可写、已批准计划。
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
