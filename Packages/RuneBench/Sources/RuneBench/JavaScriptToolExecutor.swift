import Foundation
import JavaScriptCore
import RuneKernel

// MARK: - `run_javascript` 工具实现
//
// ⚠️ 为什么这个执行器分两次落地（宿主在 C55、接线在 C56）：
//    上一片改了 RuneBench，这一片要同时动 RuneBench 与 RuneCore ——
//    把"实现"与"接线"分开提交，任何一半坏了都能一眼定位是哪一半。
//
// ⚠️ 契约来源是 `ToolRegistry` 里 `run_javascript` 那条 spec：
//      schema   `{ code: string, timeout_sec?: int(1, 600) }`，必填 `code`
//      output   `.artifact(threshold: 16KB)` —— **大输出必须转制品**
//      risk     `.modifying`，`needs: [.exec]`
//    这里不重新定义契约，只实现它。
//
// ⚠️ 超时参数**收窄**到 `JSLimits.wallClockSeconds` 的可用范围：
//    工具 schema 允许 1–600 秒，但手机上一个脚本占 10 分钟是不可接受的
//    （用户在等、电量在掉，而且超时后宿主会中毒）。所以取"用户要求"与
//    "宿主能承受"的较小值，并且**在输出里说明被收窄了** —— 静默收窄会让
//    模型以为是自己的参数没生效，然后反复加大数值。

public struct JavaScriptToolExecutor: ToolExecuting {
    public let host: JavaScriptHost
    public let artifacts: any ArtifactStore
    public let registry: [String: ToolSpec]
    /// 一次执行最多允许的墙钟秒数（工具 schema 允许到 600，这里封顶）
    public let maxWallClockSeconds: Double

    public static let names: Set<String> = [ToolName.runJavaScript]

    public init(host: JavaScriptHost,
                artifacts: any ArtifactStore = InMemoryArtifactStore(),
                registry: [String: ToolSpec] = ToolRegistry.byName,
                maxWallClockSeconds: Double = 60) {
        self.host = host
        self.artifacts = artifacts
        self.registry = registry
        self.maxWallClockSeconds = maxWallClockSeconds
    }

    public func execute(_ call: ToolCall) throws -> ToolResult {
        let args: JSONValue
        do { args = try call.arguments() }
        catch {
            return .failure(callID: call.id, error: ToolError(
                kind: .invalidArguments, modelFacingMessage: "参数不是合法 JSON。"))
        }
        guard call.name == ToolName.runJavaScript else {
            return .failure(callID: call.id, error: ToolError(
                kind: .unknownTool,
                modelFacingMessage: "JavaScriptToolExecutor 不认识工具 `\(call.name)`。"))
        }

        guard let code = args.value(at: ["code"])?.stringValue, !code.isEmpty else {
            return .failure(callID: call.id, error: ToolError(
                kind: .invalidArguments,
                modelFacingMessage: "缺少 `code`（要执行的 JavaScript 源码）。",
                suggestion: "例如 `run_javascript(code: \"console.log(1 + 1)\")`。"))
        }

        // ⚠️ 宿主中毒时**必须拒绝并说清原因**，不能让模型以为"这次是代码写错了"。
        //    不拒绝的话它会反复重试，而每次重试都在一个已经不可用的宿主上 ——
        //    用户看到的是"Agent 卡住了"，真相是平台限制（见 JavaScriptHost 文件头）。
        if let reason = host.unavailableReason {
            return .failure(callID: call.id, error: ToolError(
                kind: .sandboxFailure,
                modelFacingMessage: "JS 宿主当前不可用：\(reason)",
                suggestion: "改用别的工具，或把任务拆成不需要 JS 的步骤；不要原样重发这段代码。"))
        }

        let requested = args.value(at: ["timeout_sec"])?.intValue.map(Double.init)
        let effective = min(requested ?? 5, maxWallClockSeconds)
        let limits = JSLimits(wallClockSeconds: max(1, effective))
        let result = host.run(code, limits: limits)

        var text = result.modelFacingText
        // ⚠️ 收窄超时必须写明：否则模型会以为参数没生效，然后反复加大 timeout_sec
        if let requested, requested > maxWallClockSeconds {
            text += "\n（注意：`timeout_sec` 被收窄为 \(Int(maxWallClockSeconds)) 秒"
                + "上限，你要求的是 \(Int(requested)) 秒。）"
        }
        // ⚠️ 失败要**分开报**：宿主中毒（平台限制，别再用）≠ 代码抛异常（改代码再试）
        if !result.isSuccess {
            let kind: ToolError.Kind = result.outcome == .timedOut ? .sandboxFailure : .other
            return .failure(callID: call.id, error: ToolError(kind: kind, modelFacingMessage: text))
        }
        return deliver(text, call: call)
    }

    /// 按 spec 声明的输出形态决定"内联还是转制品"。
    ///
    /// ⚠️ 与 `LocalToolExecutor.deliver` 是**同一套约定**（`OutputBudget` 来自内核），
    ///    只是那个方法是 `private`。这里不复制它的判断逻辑，只用同一个 `OutputBudget` ——
    ///    所以两边的阈值语义不会分叉。
    /// ⚠️ 漏掉这一步的后果很具体：一次 `console.log` 大对象就能把几 MB 灌进上下文
    ///    （`docs/05 §7` 那条纪律的唯一落点）。
    private func deliver(_ text: String, call: ToolCall) -> ToolResult {
        let budget: OutputBudget
        switch registry[call.name]?.outputShape {
        case .inline(let maxBytes):     budget = OutputBudget(inlineLimit: maxBytes, artifactLimit: 4 * 1024 * 1024)
        case .artifact(let threshold):  budget = OutputBudget(inlineLimit: threshold, artifactLimit: 8 * 1024 * 1024)
        case nil:                       budget = .standard
        }
        switch budget.disposition(byteCount: text.utf8.count) {
        case .inline:
            return .ok(callID: call.id, summary: text)
        case .artifact, .refuse:
            guard let reference = try? artifacts.store(text, suggestedName: "\(call.name).txt", kind: .log) else {
                // 连制品都存不下时**不能假装成功**：给前面一段，并说清只有一段
                let head = budget.preview(text)
                return .ok(callID: call.id,
                           summary: "输出过大（\(OutputBudget.humanBytes(text.utf8.count))）且无法落为制品，只给了前面一段：\n\n\(head)")
            }
            let note = budget.artifactNote(handle: reference.relPath, displayName: "\(call.name) 的输出",
                                           byteCount: text.utf8.count, lineCount: reference.lineCount)
            return ToolResult(callID: call.id, status: .truncated,
                              summary: note + "\n\n预览：\n" + budget.preview(text),
                              artifacts: [reference])
        }
    }
}
