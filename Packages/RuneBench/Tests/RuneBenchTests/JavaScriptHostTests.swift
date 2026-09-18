import Foundation
import Testing
@testable import RuneBench
import RuneKernel

// MARK: - JavaScriptCore 执行宿主
//
// ⚠️ 这一组测的重点**不是"能跑 JS"**，而是**边界是否真的成立**：
//    文档对模型的承诺是"沙箱里没有网络与文件系统"，而那必须由测试来守 ——
//    否则某天有人"顺手"注入一个便利 API，承诺就静默失效了（项目记过的 T33）。
//
// ⚠️ 另一条同样重要：**失败分支要说清下一步**。
//    模型看到"执行失败"只会原样再试一次；而"你的代码抛了异常"（宿主仍可用）
//    与"宿主已不可用"（别再用它）要采取的行动完全不同。

@Suite("JS 宿主 —— 基本执行")
struct JavaScriptHostBasicsTests {

    @Test("⭐ console.log 能用（JSContext 默认没有 console，模型却几乎一定会用）")
    func consoleLogWorks() {
        let host = JavaScriptHost()
        let result = host.run("console.log('hello', JSON.stringify({a: 1}));")
        #expect(result.isSuccess, "实际：\(result.modelFacingText)")
        #expect(result.stdout == #"hello {"a":1}"#, "实际输出：\(result.stdout)")
    }

    @Test("⭐ 最后一条表达式的值要作为结果返回")
    func lastExpressionValue() {
        let host = JavaScriptHost()
        let result = host.run("[1,2,3].map(function (x) { return x * 2; }).join(',')")
        #expect(result.isSuccess)
        #expect(result.stdout.isEmpty || !result.stdout.contains("=>"))
        #expect(result.modelFacingText.contains("2,4,6"), "实际：\(result.modelFacingText)")
    }

    @Test("⭐ 抛异常要如实报出，并说明**宿主仍可用**")
    func thrownExceptionIsReported() {
        let host = JavaScriptHost()
        let result = host.run("throw new Error('boom')")
        #expect(!result.isSuccess)
        #expect(result.modelFacingText.contains("boom"), "实际：\(result.modelFacingText)")
        // ⚠️ 模型必须知道"这是我的代码错了"，而不是"沙箱坏了" —— 两者下一步完全不同
        #expect(result.modelFacingText.contains("宿主本身仍可用"), "实际：\(result.modelFacingText)")
        #expect(host.isUsable, "代码抛异常不该让宿主中毒")
    }

    @Test("⚠️ 语法错误也要报出，而不是静默成功")
    func syntaxErrorIsReported() {
        let host = JavaScriptHost()
        let result = host.run("function ( {")
        #expect(!result.isSuccess, "语法错误不能算成功")
    }

    @Test("⚠️ 语句的值是 undefined 时必须照报，不能当成「没有结果」吞掉")
    func undefinedValueIsReported() {
        // ⚠️ 这条是我第一版写错、被测试抓出来的：
        //    我把结果值里的 `"undefined"` 当成"没有值"过滤掉了 ——
        //    于是 `typeof fetch`（结果恰是字符串 "undefined"）在输出里消失，
        //    模型会以为工具没返回任何东西。
        //    「值是 undefined」与「根本没有值」是两件事，必须分开表达。
        let host = JavaScriptHost()
        let result = host.run("var x = 1;")
        #expect(result.isSuccess)
        #expect(result.modelFacingText.contains("undefined"), "实际：\(result.modelFacingText)")
    }

    @Test("⚠️ 真的没有输出时要说清楚，而不是给一片空白")
    func trulyEmptyOutputIsExplicit() {
        let host = JavaScriptHost()
        // 最后一条是语句、且宿主拿不到值的情形：用注释结尾
        let result = host.run("console.log('a'); // 末尾只有注释")
        #expect(result.isSuccess)
        #expect(!result.modelFacingText.isEmpty, "绝不返回空字符串")
        #expect(result.modelFacingText.contains("a"))
    }
}

@Suite("JS 宿主 —— 沙箱边界（承诺必须由测试守住）")
struct JavaScriptHostSandboxTests {

    @Test("⭐⭐ 网络与模块能力必须是 undefined（文档对模型的承诺）")
    func noNetworkOrModuleAPIs() {
        let host = JavaScriptHost()
        for name in ["fetch", "XMLHttpRequest", "require", "setTimeout", "setInterval", "WebSocket", "process"] {
            let result = host.run("typeof \(name)")
            #expect(result.modelFacingText.contains("undefined"),
                    "\(name) 必须不存在，实际：\(result.modelFacingText)")
        }
    }

    @Test("⚠️ 文件系统能力也必须是 undefined")
    func noFileSystemAPIs() {
        let host = JavaScriptHost()
        for name in ["readFile", "writeFile", "fs", "Deno", "Bun"] {
            let result = host.run("typeof \(name)")
            #expect(result.modelFacingText.contains("undefined"), "\(name) 不该存在")
        }
    }

    @Test("⭐⭐ 每次执行都是全新 VM：上一次的全局变量不该被看到")
    func executionsAreIsolated() {
        let host = JavaScriptHost()
        _ = host.run("var leaked = 'secret'")
        let second = host.run("typeof leaked")
        #expect(second.modelFacingText.contains("undefined"),
                "全局变量跨执行泄漏了，实际：\(second.modelFacingText)")
    }
}

@Suite("JS 宿主 —— 配额与超时")
struct JavaScriptHostLimitsTests {

    @Test("⭐⭐ 输出洪水必须被配额挡住（否则内存与上下文都会被冲爆）")
    func outputQuotaIsEnforced() {
        let host = JavaScriptHost()
        let limits = JSLimits(wallClockSeconds: 10, outputBytes: 1024)
        let result = host.run("""
        for (var i = 0; i < 10000; i++) { console.log('xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'); }
        """, limits: limits)
        #expect(!result.isSuccess, "输出超出配额必须报失败")
        #expect(result.outcome == .outputLimitExceeded, "实际：\(result.outcome)")
        #expect(result.modelFacingText.contains("输出超过配额"))
        // ⚠️ 下一步要说清：是"打印太多"，不是"沙箱坏了"
        #expect(result.modelFacingText.contains("减少"), "实际：\(result.modelFacingText)")
    }

    @Test("⭐⭐ 纯死循环无法被中断 —— 宿主必须**如实**报出来并拒绝后续调用")
    func infiniteLoopPoisonsHostHonestly() {
        // ⚠️ 这是平台限制，不是实现偷懒：
        //    JavaScriptCore **没有公开的中断 API**（`JSContextGroupSetExecutionTimeLimit`
        //    既不在公开头文件里、也不在动态库导出符号里），而用私有 API 会撞 App Store 红线。
        //    所以正确做法是：**不假装能强杀**，而是标成中毒 + 如实告诉模型别再用它。
        let host = JavaScriptHost()
        let result = host.run("while (true) {}", limits: JSLimits(wallClockSeconds: 1))
        #expect(result.outcome == .timedOut, "实际：\(result.outcome)")
        #expect(result.modelFacingText.contains("无法中断"), "必须如实说明是平台限制，实际：\(result.modelFacingText)")
        #expect(result.modelFacingText.contains("不要原样重发"), "必须给出下一步，实际：\(result.modelFacingText)")
        // ⚠️ 关键断言：中毒之后**拒绝后续调用**，而不是再挂一个新线程上去。
        //    后者在手机上会表现为 App 越来越卡直到被 jetsam 杀掉（T38）。
        #expect(!host.isUsable, "超时后宿主必须标记为不可用")
        #expect(host.unavailableReason != nil)
        let second = host.run("1 + 1")
        #expect(!second.isSuccess, "中毒后必须拒绝调用")
        #expect(second.modelFacingText.contains("已不可用"), "实际：\(second.modelFacingText)")
    }

    @Test("⭐ 正常脚本在时限内完成，不受影响")
    func normalScriptCompletes() {
        let host = JavaScriptHost()
        let result = host.run("var s = 0; for (var i = 1; i <= 1000; i++) { s += i; } s",
                              limits: JSLimits(wallClockSeconds: 5))
        #expect(result.isSuccess, "实际：\(result.modelFacingText)")
        #expect(result.modelFacingText.contains("500500"))
        #expect(host.isUsable)
    }
}
