import Foundation
import RuneCore
import RuneKernel
import RuneStore

// 只用于开发验收：只处理临时目录中的合成文件，不读取真实工作区。
//
// ⚠️ 上游抖动（503 "servers overloaded"）在验收里必须**重开一个干净会话重试**：
//    验收工具要证明的是"Rune 在真实模型下能端到端跑通"，而不是"上游此刻恰好不抖"。
//    注意这与运行时内部的重试**不重复**：运行时重试的是同一枪请求（退避 1/2/4 秒，
//    由 ModelClient/RetryPolicy 负责）；这里重试的是**整个验收场景**（新会话、新工作区）。
//    ⚠️ 真失败（模型没改对、审批越界、落盘验链不过）**照样失败**，重试不会把它掩盖掉。
@main struct RuneValidation {
    static func main() async {
        do { try await validate() }
        catch { print("LIVE_VALIDATION_FAILED: \(error.localizedDescription)"); exit(1) }
    }

    /// 上游抖动只重试「整个场景」，且**只对瞬时错误**重试。
    static func validate() async throws {
        guard let secret = ProcessInfo.processInfo.environment["RUNE_LIVE_API_KEY"], !secret.isEmpty else {
            print("缺少 RUNE_LIVE_API_KEY；没有发送请求。")
            return
        }
        let attempts = Int(ProcessInfo.processInfo.environment["RUNE_LIVE_ATTEMPTS"] ?? "4") ?? 4
        var lastError: Error?
        for attempt in 1...max(1, attempts) {
            do {
                try await attemptOnce(secret: secret)
                return
            } catch let failure as TransientUpstream {
                lastError = failure
                let wait = min(5 * attempt, 30)
                print("⚠️ 第 \(attempt) 次遇到上游抖动：\(failure.message)")
                if attempt < attempts { print("   \(wait) 秒后重开一个干净会话重试…"); try await Task.sleep(for: .seconds(wait)) }
            }
            // 真失败（断言不过、模型改错、越界审批）**不重试**，直接抛出
        }
        throw lastError ?? RuntimeFailure("验收未通过")
    }

    /// 只把**上游过载/限流**当作可重试；其余错误一律视为真实失败。
    struct TransientUpstream: Error { let message: String }

    static func attemptOnce(secret: String) async throws {
        let model = ProcessInfo.processInfo.environment["RUNE_LIVE_MODEL"] ?? "gpt-5.5"
        let base = ProcessInfo.processInfo.environment["RUNE_LIVE_BASE_URL"] ?? "https://api.pinaic.com/v1"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rune-live-" + UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "before\n".write(to: workspace.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let store = try RuneEventStore(path: root.appendingPathComponent("events.sqlite").path)
        let provider = ProviderConfig(id: "validation", displayName: "开发验收", protocolFamily: .openAIChat,
                                      baseURL: base, auth: .bearer(keyRef: "live"), models: [ModelDescriptor(id: model)])
        let config = RuntimeConfiguration(sessionID: UUID(), workspaceID: UUID(), workspaceURL: workspace,
            artifactsURL: root.appendingPathComponent("artifacts"), provider: provider, modelID: model, secret: secret,
            maxRounds: 6, maxOutputTokens: 1024)
        let runtime = try AgentRuntime(configuration: config,
            objective: "读取 notes.md，把唯一的 before 改成 after。修改后重新读取确认，只操作这个文件，最后用一句中文报告。", store: store)
        var action = RuntimeAction.proceed
        var final: RuntimeSnapshot?
        for _ in 0..<5 {
            for try await update in runtime.run(action) {
                if case .snapshot(let value) = update { final = value }
            }
            guard let value = final else { throw RuntimeFailure("没有最终状态") }
            print("状态：\(value.state.status.rawValue)，模型轮次：\(value.state.round)，工具次数：\(value.state.toolCallCount)")
            if let approval = value.metadata.approval {
                guard !approval.changes.isEmpty,
                      approval.changes.allSatisfy({ $0.path == "/workspace/notes.md" && $0.after == "after\n" }) else {
                    throw RuntimeFailure("模型请求超出了合成验收文件的预期修改，未批准。")
                }
                action = .approve(callID: approval.call.id)
            } else { break }
        }
        guard let final, final.state.status == .completed else {
            let message = (final?.metadata.failure ?? "任务没有完成").replacingOccurrences(of: secret, with: "[REDACTED]")
            // ⚠️ 只有上游过载/限流才算瞬时；其余（模型改错、工具被拒、预算耗尽）是**真实失败**，
            //    必须让它红，重试只会掩盖真相。
            let transientMarkers = ["overloaded", "temporarily unavailable", "rate limit", "429", "502", "503", "504"]
            if transientMarkers.contains(where: { message.lowercased().contains($0) }) {
                throw TransientUpstream(message: message)
            }
            throw RuntimeFailure(message)
        }
        let content = try String(contentsOf: workspace.appendingPathComponent("notes.md"), encoding: .utf8)
        guard content == "after\n" else { throw RuntimeFailure("真实文件没有成为预期内容") }
        let reopened = try RuneEventStore(path: root.appendingPathComponent("events.sqlite").path)
        guard try reopened.eventLog(sessionID: config.sessionID).verify(full: true).isOK,
              try reopened.loadRuntime(sessionID: config.sessionID)?.state.status == .completed else {
            throw RuntimeFailure("磁盘恢复校验失败")
        }
        print("LIVE_VALIDATION_PASSED：真实模型 → 文件工具 → 审批 → 修改 → 再读 → 事件落盘/重开验链")
        print("验收制品：\(root.path)")
    }
}
