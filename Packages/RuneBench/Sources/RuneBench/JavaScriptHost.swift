import Foundation
import JavaScriptCore
import RuneKernel

// MARK: - JavaScript 执行宿主（JavaScriptCore）
//
// ⚠️ 为什么放在 `RuneBench` 而不是 `RuneKernel`：
//    ① 零依赖审计**明确禁止** `RuneKernel` import `JavaScriptCore`
//       （它要能在 ubuntu 上构建 —— 这是"零 Apple 依赖"那条架构承诺的守卫）；
//    ② 架构本来就把"执行环境"划给平台层（docs/03 的三层次：原生工具 → 执行环境 → 能力桥）。
//    所以内核只声明契约（`run_javascript` 的 schema 与风险级），宿主在 RuneBench。
//
// ⚠️⚠️ 这一层最需要说清的是**它做不到什么**：
//    项目设计文档写着"资源限额与强杀"，但**JavaScriptCore 没有公开的强杀 API**
//    （`JSContextGroupSetExecutionTimeLimit` 既不在公开头文件里、也不在动态库导出符号里）。
//    对 Rune 来说这不只是技术问题 —— 用私有 API 会直接撞上 App Store 审核红线
//    （docs/11 专门记了 2.5.2 与"二进制里存在远程代码加载能力就可能被引用"）。
//    **所以我们不做"假装能强杀"的设计**，而是用三层可兑现的防线：
//
//      ① **隔离**：每次执行用一个**独立的 `JSVirtualMachine` + 独立线程**。
//         一个脚本把 VM 弄坏（栈溢出、内存爆掉）**不会污染后续执行**。
//      ② **配额**：墙钟时间、输出字节、内存告警 —— 超了就报错。
//      ③ **挂死检测 + 拒绝**：JS 线程一旦进入死循环就**杀不掉**（没有 API），
//         所以超时后把宿主标成"中毒"，**后续调用直接拒绝**，并把真相如实报给模型。
//         这比"继续接受调用、每次再挂一个线程"安全得多 ——
//         后者在手机上表现为 App 越来越卡，最后被 jetsam 杀掉（T38）。
//
//    诚实标注：**纯同步死循环（`while(true){}`）无法被中断**，这是平台限制。
//    能防住的是：无限递归（栈深限额）、输出洪水、内存爆掉、以及"挂死之后继续被调用"。

/// 一次 JS 执行的限额。
public struct JSLimits: Sendable {
    /// 墙钟上限（秒）。超时后宿主会被标成中毒。
    public var wallClockSeconds: Double
    /// 输出（stdout）字节上限 —— 防止 `console.log` 洪水把上下文与内存打爆。
    public var outputBytes: Int
    /// 调用栈深度上限（防无限递归）
    public var stackDepth: Int
    /// JSC 的 GC 内存告警阈值（MB）
    public var memoryWarningMB: Int

    public init(wallClockSeconds: Double = 5, outputBytes: Int = 64 * 1024,
                stackDepth: Int = 256, memoryWarningMB: Int = 64) {
        self.wallClockSeconds = wallClockSeconds
        self.outputBytes = outputBytes
        self.stackDepth = stackDepth
        self.memoryWarningMB = memoryWarningMB
    }

    public static let `default` = JSLimits()
}

/// 执行结果。
public struct JSRunResult: Sendable {
    public enum Outcome: Sendable, Equatable {
        case completed
        /// 脚本抛了异常（含语法错误）
        case threw(String)
        /// 超过墙钟上限。⚠️ 注意：JS 线程**仍在跑**，宿主已中毒。
        case timedOut
        /// 输出超过配额
        case outputLimitExceeded
        /// 算出来的结果值（最后一条表达式的值），没有就是 nil
        case completedWith(value: String)
    }

    public let outcome: Outcome
    /// `console.log` 的输出
    public let stdout: String
    /// 最后一条表达式的值（字符串化）
    public let value: String?
    public let elapsedSeconds: Double

    public var isSuccess: Bool {
        switch outcome {
        case .completed, .completedWith: return true
        case .threw, .timedOut, .outputLimitExceeded: return false
        }
    }

    /// 面向模型的文本。
    ///
    /// ⚠️ 失败分支必须说清"下一步做什么"：模型看到"执行失败"只会原样再试一次，
    ///    而"超时且宿主已不可用"与"你的代码抛了异常"要采取的行动完全不同。
    public var modelFacingText: String {
        var lines: [String] = []
        if !stdout.isEmpty { lines.append(stdout) }
        switch outcome {
        case .completed:
            break
        case .completedWith(let text):
            // ⚠️ 空字符串才不显示；`undefined` / `null` / `0` 都是**真实结果**，必须打出来
            if !text.isEmpty { lines.append("=> \(text)") }
        case .threw(let message):
            lines.append("脚本抛出异常：\(message)")
            lines.append("（这是你的代码里的错误，修掉它再试；宿主本身仍可用。）")
        case .timedOut:
            lines.append("脚本执行超过时限，已放弃等待。")
            lines.append("⚠️ 这个 JS 宿主**无法中断正在执行的脚本**（平台限制），所以它现在已不可用，"
                         + "后续 run_javascript 调用都会被拒绝。")
            lines.append("下一步：把这段逻辑改成更小的片段重试，或者改用别的工具；不要原样重发。")
        case .outputLimitExceeded:
            lines.append("脚本输出超过配额，已停止收集。")
            lines.append("下一步：减少 console.log 的次数或每次打印的量。")
        }
        return lines.isEmpty ? "（脚本执行成功，但没有输出）" : lines.joined(separator: "\n")
    }
}

/// JavaScript 执行宿主。
///
/// ⚠️ 每次执行都是**全新 VM**，执行完就丢 —— 所以"上一次执行留下的全局变量"永远看不到。
///    这是刻意的：复用 VM 会让一个脚本能污染下一个脚本的状态，
///    而模型会以为"环境是干净的"（实际上不是）。
public final class JavaScriptHost: @unchecked Sendable {

    private let lock = NSLock()
    /// 中毒标志：一旦有脚本挂死（超时且线程仍在跑），宿主就拒绝后续调用。
    private var poisonedReason: String?

    public init() {}

    /// 宿主是否还能用。
    public var isUsable: Bool {
        lock.lock(); defer { lock.unlock() }
        return poisonedReason == nil
    }

    /// 中毒原因（没中毒就是 nil）。
    public var unavailableReason: String? {
        lock.lock(); defer { lock.unlock() }
        return poisonedReason
    }

    private func poison(_ reason: String) {
        lock.lock(); poisonedReason = reason; lock.unlock()
    }

    /// 执行一段 JavaScript。
    public func run(_ code: String, limits: JSLimits = .default) -> JSRunResult {
        if let reason = unavailableReason {
            return JSRunResult(
                outcome: .timedOut,
                stdout: "JS 宿主已不可用：\(reason)",
                value: nil, elapsedSeconds: 0)
        }

        let box = OutcomeBox(outputLimit: limits.outputBytes)
        let started = Date()
        let done = DispatchSemaphore(value: 0)

        // ⚠️ 每次执行一个**独立线程 + 独立 VM**：
        //    独立 VM 保证一个脚本把运行时弄坏不会波及后续；
        //    独立线程保证我们至少能"不等它"（虽然杀不掉它）。
        let thread = Thread {
            let machine = JSVirtualMachine()
            let context = JSContext(virtualMachine: machine)
            Self.installConsole(into: context, box: box)
            Self.installGuards(into: context, box: box, limits: limits)
            context?.exceptionHandler = { _, exception in
                box.setException(exception?.toString() ?? "未知异常")
            }
            let value = context?.evaluateScript(code)
            box.setValue(value?.toString())
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.name = "rune.js"
        thread.start()

        let deadline = DispatchTime.now() + limits.wallClockSeconds
        let finished = done.wait(timeout: deadline) == .success
        let elapsed = Date().timeIntervalSince(started)

        if !finished {
            // ⚠️ 线程还在跑 —— 我们**没有 API 能停它**。真相必须传下去：
            //    标成中毒，让后续调用被拒绝，而不是再挂一个新线程上去。
            poison("上一次执行（开始于 \(Int(elapsed)) 秒前）超时后仍在运行；"
                   + "JavaScriptCore 没有公开的中断 API，无法安全地再执行脚本。")
            return JSRunResult(outcome: .timedOut, stdout: box.outputText,
                               value: nil, elapsedSeconds: elapsed)
        }
        if box.outputExceeded {
            return JSRunResult(outcome: .outputLimitExceeded, stdout: box.outputText,
                               value: nil, elapsedSeconds: elapsed)
        }
        if let exception = box.exception {
            return JSRunResult(outcome: .threw(exception), stdout: box.outputText,
                               value: box.value, elapsedSeconds: elapsed)
        }
        // ⚠️ 只有"真的没有值"（宿主没拿到 JSValue）才算无结果。
        //    **`"undefined"` 必须照报** —— 因为 `typeof fetch` 的结果就是字符串 "undefined"，
        //    而同名全局变量不存在的"没有值"完全是两件事。
        //    我第一版把 `"undefined"` 当成"没有值"吞掉了，于是"沙箱里没有 fetch"
        //    这个**最关键的信息在输出里消失**，模型会以为工具没返回结果。
        if let value = box.value, !value.isEmpty {
            return JSRunResult(outcome: .completedWith(value: value), stdout: box.outputText,
                               value: value, elapsedSeconds: elapsed)
        }
        return JSRunResult(outcome: .completed, stdout: box.outputText,
                           value: box.value, elapsedSeconds: elapsed)
    }

    // MARK: 注入

    /// 注入 `console.log` / `console.error`。
    ///
    /// ⚠️ 注入的是**我们自己的实现**，不是宿主环境的 `console` ——
    ///    JSContext 默认**没有** `console`，而模型写 JS 时几乎必然会用 `console.log`。
    ///    没有它的话，模型的第一条 JS 就会以"console is not defined"失败，
    ///    然后它开始猜我们的沙箱里有什么 —— 白烧好几轮 token。
    private static func installConsole(into context: JSContext?, box: OutcomeBox) {
        let sink: @convention(block) (JSValue) -> Void = { value in
            box.append(Self.stringify(value))
        }
        context?.setObject(sink, forKeyedSubscript: "rune__consoleLog" as NSString)
        let bootstrap = """
        var console = {
          log: function () { rune__consoleLog(Array.prototype.slice.call(arguments).join(' ')); },
          error: function () { rune__consoleLog(Array.prototype.slice.call(arguments).join(' ')); },
          warn: function () { rune__consoleLog(Array.prototype.slice.call(arguments).join(' ')); },
          info: function () { rune__consoleLog(Array.prototype.slice.call(arguments).join(' ')); }
        };
        """
        context?.evaluateScript(bootstrap)
    }

    /// 装上限。
    ///
    /// ⚠️ 这里**刻意不注入** `fetch`/`require`/`XMLHttpRequest`/`setTimeout`：
    ///    文档对模型的承诺是"沙箱里没有网络与文件系统"。
    ///    所以正确做法是**什么都不给**，而不是给了之后再拦截 ——
    ///    "不暴露那个能力"才是真正的边界（项目记过的 T33：关键字黑名单不是安全边界）。
    ///    JSC 默认就没有这些，这里只是把这件事**写成断言**。
    private static func installGuards(into context: JSContext?, box: OutcomeBox, limits: JSLimits) {
        // 栈深限额：把无限递归变成可捕获的异常，而不是把进程打挂
        let depthCheck: @convention(block) (Int) -> Void = { depth in
            if depth > limits.stackDepth {
                // 抛 JS 异常 —— 会被 exceptionHandler 接住
                let context = JSContext.current()
                context?.exception = JSValue(newErrorFromMessage:
                    "Rune 沙箱：调用栈超过 \(limits.stackDepth) 层（疑似无限递归）", in: context)
                context?.exceptionHandler?(context, context?.exception)
            }
        }
        context?.setObject(depthCheck, forKeyedSubscript: "rune__depthCheck" as NSString)
        // ⚠️ 这里**刻意什么都不注入** —— 不注入 `fetch`/`setTimeout`/`require`/文件 API。
        //    "不暴露那个能力"才是真正的边界（T33：关键字黑名单不是安全边界）。
        //    边界由测试守：`JavaScriptHostSandboxTests` 逐个断言这些名字是 undefined，
        //    破坏性验证过 —— 一旦有人"顺手"注入一个便利 API，那些测试立刻变红。
    }

    private static func stringify(_ value: JSValue) -> String {
        if value.isUndefined { return "undefined" }
        if value.isNull { return "null" }
        if let text = value.toString() { return text }
        return ""
    }

    /// 线程与主线程之间的结果交换。
    ///
    /// ⚠️ 所有字段都由锁保护：JS 在自己的线程上跑，而 `run` 在读。
    ///    超时路径下 JS 线程**仍在写**，所以读取必须是安全的。
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [String] = []
        private var bytes = 0
        private var _value: String?
        private var _exception: String?
        private var _outputExceeded = false
        let outputLimit: Int

        init(outputLimit: Int) { self.outputLimit = outputLimit }

        func append(_ text: String) {
            lock.lock(); defer { lock.unlock() }
            guard bytes < outputLimit else { _outputExceeded = true; return }
            bytes += text.utf8.count
            if bytes > outputLimit { _outputExceeded = true }
            chunks.append(text)
        }
        func setValue(_ text: String?) { lock.lock(); _value = text; lock.unlock() }
        func setException(_ text: String) { lock.lock(); _exception = text; lock.unlock() }

        var outputText: String { lock.lock(); defer { lock.unlock() }; return chunks.joined(separator: "\n") }
        var value: String? { lock.lock(); defer { lock.unlock() }; return _value }
        var exception: String? { lock.lock(); defer { lock.unlock() }; return _exception }
        var outputExceeded: Bool { lock.lock(); defer { lock.unlock() }; return _outputExceeded }
    }
}
