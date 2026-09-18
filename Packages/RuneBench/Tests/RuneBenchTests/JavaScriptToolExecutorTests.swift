import Foundation
import Testing
@testable import RuneBench
import RuneKernel

// MARK: - `run_javascript` 工具层
//
// ⚠️ 这一组测的是**模型拿到的那段文本**，不是宿主内部：
//    宿主已经有一组自己的测试（`JavaScriptHostTests`），
//    而"宿主对"不等于"工具对" —— 契约（schema / 输出形态 / 错误分类）是在这一层兑现的。

private func runJS(_ code: String, timeoutSec: Int? = nil,
                   host: JavaScriptHost = JavaScriptHost(),
                   artifacts: any ArtifactStore = InMemoryArtifactStore()) throws -> ToolResult {
    var payload: [String: JSONValue] = ["code": .string(code)]
    if let timeoutSec { payload["timeout_sec"] = .int(timeoutSec) }
    let executor = JavaScriptToolExecutor(host: host, artifacts: artifacts)
    let call = ToolCall(id: "c1", name: ToolName.runJavaScript,
                        argumentsJSON: Data(JSONValue.object(payload).canonicalString().utf8))
    return try executor.execute(call)
}

@Suite("run_javascript —— 基本契约")
struct JavaScriptToolBasicsTests {

    @Test("⭐ 正常脚本：结果进 summary，状态是成功")
    func normalRun() throws {
        let result = try runJS("console.log('hi'); 6 * 7")
        #expect(result.status == .ok, "实际：\(result.summary)")
        #expect(result.summary.contains("hi"))
        #expect(result.summary.contains("42"))
    }

    @Test("⚠️ 缺少 code 要被挡下，并给出可用的写法")
    func missingCodeIsRejected() throws {
        let executor = JavaScriptToolExecutor(host: JavaScriptHost())
        let call = ToolCall(id: "c1", name: ToolName.runJavaScript, argumentsJSON: Data("{}".utf8))
        let result = try executor.execute(call)
        #expect(result.status != .ok)
        #expect(result.summary.contains("code"), "实际：\(result.summary)")
        #expect(result.summary.contains("run_javascript"), "要给可执行示例，实际：\(result.summary)")
    }

    @Test("⚠️ 代码抛异常：状态是失败，但要点明「改代码再试」而不是「沙箱坏了」")
    func thrownErrorIsClassified() throws {
        let result = try runJS("throw new Error('bad code')")
        #expect(result.status != .ok)
        #expect(result.summary.contains("bad code"))
        #expect(result.summary.contains("宿主本身仍可用"), "实际：\(result.summary)")
    }
}

@Suite("run_javascript —— 大输出必须转制品")
struct JavaScriptToolArtifactTests {

    @Test("⭐⭐ 超过 spec 阈值（16KB）的输出必须落成制品，并给句柄")
    func largeOutputBecomesArtifact() throws {
        // ⚠️ 漏掉这一步的后果很具体：一次 `console.log` 大对象就能把几 MB 灌进上下文
        //    （docs/05 §7 那条纪律的唯一落点）。spec 声明的是 `.artifact(threshold: 16KB)`。
        let artifacts = InMemoryArtifactStore()
        let result = try runJS("""
        for (var i = 0; i < 2000; i++) { console.log('line ' + i + ' ' + 'x'.repeat(20)); }
        """, artifacts: artifacts)
        #expect(result.status == .truncated, "大输出应当转制品（状态 truncated），实际：\(result.status)")
        #expect(!result.artifacts.isEmpty, "必须给出制品句柄，否则模型无从读到全文")
        #expect(result.summary.contains("预览") || result.summary.contains("句柄") || result.summary.contains("artifacts"),
                "要说明去哪儿读全文，实际：\(result.summary.prefix(200))")
        // 制品里必须能读回全文
        let reference = try #require(result.artifacts.first)
        let text = try artifacts.readAll(handle: reference.relPath)
        #expect(text?.contains("line 1999") == true, "制品里应当是完整输出")
    }

    @Test("⚠️ 小输出仍要内联（不能一律转制品，那会让模型多跑一趟）")
    func smallOutputStaysInline() throws {
        let result = try runJS("console.log('short')")
        #expect(result.status == .ok)
        #expect(result.artifacts.isEmpty)
        #expect(result.summary.contains("short"))
    }
}

@Suite("run_javascript —— 宿主不可用时的行为")
struct JavaScriptToolUnavailableTests {

    @Test("⭐⭐ 宿主中毒后：拒绝调用、分类正确、且**不要原样重发**")
    func poisonedHostIsRefused() throws {
        let host = JavaScriptHost()
        // 先毒化它（死循环）
        _ = host.run("while (true) {}", limits: JSLimits(wallClockSeconds: 1))
        #expect(!host.isUsable)

        let result = try runJS("1 + 1", host: host)
        #expect(result.status != .ok, "中毒后必须拒绝")
        #expect(result.summary.contains("不可用"), "实际：\(result.summary)")
        #expect(result.summary.contains("不要原样重发"), "要给下一步，实际：\(result.summary)")
    }

    @Test("⚠️ timeout_sec 超过上限时被收窄，而且**要说明被收窄了**")
    func timeoutIsClampedAndExplained() throws {
        // ⚠️ 静默收窄会让模型以为参数没生效，然后反复加大数值 —— 白烧 token。
        let result = try runJS("1 + 1", timeoutSec: 600)
        #expect(result.status == .ok, "实际：\(result.summary)")
        #expect(result.summary.contains("收窄"), "必须说明被收窄，实际：\(result.summary)")
        #expect(result.summary.contains("600"), "要提到用户原本要的值")
    }

    @Test("⭐ 正常范围内的 timeout_sec 不该被提及")
    func normalTimeoutIsSilent() throws {
        let result = try runJS("1 + 1", timeoutSec: 3)
        #expect(result.status == .ok)
        #expect(!result.summary.contains("收窄"), "没被收窄就不该提，实际：\(result.summary)")
    }
}
