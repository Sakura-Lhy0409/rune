import Testing
import Foundation
@testable import RuneKernel

// MARK: - 沙箱的测试
//
// 这一组守的是 docs/05 §7 那条"手机上最重要的一条工程纪律"，
// 以及 §3.1.1 那条"最重要的安全补偿机制"。
// 两者的共同点是：**做错了不会报错，只会静默地烧钱或静默地放行**。

// MARK: - 输出纪律

@Suite("OutputBudget —— 输出纪律的唯一实现")

struct OutputBudgetTests {

    @Test("⭐ 三档去向：内联 / 制品 / 拒绝")
    func disposition() {
        let budget = OutputBudget(inlineLimit: 8_000, artifactLimit: 2_000_000)
        #expect(budget.disposition(byteCount: 100) == .inline)
        #expect(budget.disposition(byteCount: 8_000) == .inline)
        #expect(budget.disposition(byteCount: 8_001) == .artifact)
        #expect(budget.disposition(byteCount: 2_000_000) == .artifact)
        #expect(budget.disposition(byteCount: 2_000_001) == .refuse)
    }

    @Test("⚠️ 阈值不能倒挂（内联上限大于制品上限 → 配置错误也不能让它越过 refuse）")
    func thresholdsCannotInvert() {
        let budget = OutputBudget(inlineLimit: 100_000, artifactLimit: 1_000)
        #expect(budget.artifactLimit >= budget.inlineLimit)
        #expect(budget.disposition(byteCount: 200_000) == .refuse)
    }

    @Test("⭐ 制品说明必须给全「5W」：多大 / 多少行 / 里面有什么 / 去哪读")
    func artifactNoteAnswersFiveW() {
        let note = OutputBudget.standard.artifactNote(
            handle: "artifacts/ci-0912.txt",
            displayName: "CI 日志",
            byteCount: 3_355_443,
            lineCount: 41_200,
            headline: "首个错误是 test_round_amount 的断言失败"
        )
        #expect(note.contains("3.2MB"))                       // 多大
        #expect(note.contains("41200 行"))                    // 多少行
        #expect(note.contains("test_round_amount"))           // 里面有什么
        #expect(note.contains("read_artifact"))               // 去哪读
        #expect(note.contains("artifacts/ci-0912.txt"))       // 句柄
    }

    @Test("没有摘要时也要给出句柄与读法")
    func artifactNoteWithoutHeadline() {
        let note = OutputBudget.standard.artifactNote(
            handle: "artifacts/x.txt", displayName: "输出", byteCount: 9_000, lineCount: 200
        )
        #expect(!note.contains("摘要：\n"))
        #expect(note.contains("read_artifact"))
    }

    @Test("⭐ 预览保头也保尾（结论通常在最后几行）")
    func previewKeepsHeadAndTail() {
        let text = (1...500).map { "第 \($0) 行" }.joined(separator: "\n")
        let preview = OutputBudget(inlineLimit: 100, artifactLimit: 10_000, previewBytes: 300).preview(text)
        #expect(preview.contains("第 1 行"))
        #expect(preview.contains("第 500 行"))
        #expect(preview.contains("省略"))
        #expect(preview.utf8.count < 500)
    }

    @Test("小输出预览原样返回")
    func previewPassthrough() {
        let text = "很短"
        #expect(OutputBudget.standard.preview(text) == text)
    }

    @Test("人类可读的体积")
    func humanBytes() {
        #expect(OutputBudget.humanBytes(512) == "512B")
        #expect(OutputBudget.humanBytes(2_048) == "2.0KB")
        #expect(OutputBudget.humanBytes(3_355_443) == "3.2MB")
    }
}

// MARK: - 资源限额

@Suite("SandboxLimits —— 超限要说清「该怎么做」")

struct SandboxLimitsTests {

    private func limits() -> SandboxLimits {
        SandboxLimits(wallClockSeconds: 10, cpuSeconds: 5, memoryMB: 256,
                      instructionLimit: 1_000, outputBytes: 1_000, stackDepth: 100)
    }

    @Test("没超就返回 nil")
    func noViolation() {
        let usage = SandboxUsage(wallClockMS: 1_000, cpuMS: 500, peakMemoryMB: 100,
                                 instructions: 500, outputBytes: 100, maxStackDepth: 10)
        #expect(limits().violation(for: usage) == nil)
    }

    @Test("⭐ 内存超限 → 建议分批处理，且不鼓励「换个更大额度重试」")
    func memoryViolation() throws {
        let usage = SandboxUsage(peakMemoryMB: 300)
        let violation = try #require(limits().violation(for: usage))
        #expect(violation.kind == .memoryExceeded)
        #expect(violation.suggestion.contains("分批"))
        #expect(!violation.isRetryableWithBiggerLimit, "内存不够时加大额度通常只是让它更晚崩")
    }

    @Test("⭐ 指令数超限 → 建议换原生工具（而不是加大额度）")
    func instructionViolation() throws {
        let usage = SandboxUsage(instructions: 2_000)
        let violation = try #require(limits().violation(for: usage))
        #expect(violation.kind == .cpuExceeded)
        #expect(violation.suggestion.contains("原生工具"))
        #expect(!violation.isRetryableWithBiggerLimit)
    }

    @Test("栈溢出 → 建议改迭代")
    func stackViolation() throws {
        let violation = try #require(limits().violation(for: SandboxUsage(maxStackDepth: 200)))
        #expect(violation.suggestion.contains("迭代"))
    }

    @Test("CPU 时间超限")
    func cpuViolation() throws {
        let violation = try #require(limits().violation(for: SandboxUsage(cpuMS: 6_000)))
        #expect(violation.kind == .cpuExceeded)
        #expect(violation.suggestion.contains("死循环"))
    }

    @Test("⭐ 墙钟超时 → 建议转后台作业（iOS 上超时会挂起，不是「跑慢一点」）")
    func wallClockViolation() throws {
        let violation = try #require(limits().violation(for: SandboxUsage(wallClockMS: 11_000)))
        #expect(violation.kind == .timedOut)
        #expect(violation.suggestion.contains("start_job"))
        #expect(violation.isRetryableWithBiggerLimit)
    }

    @Test("输出超限 → 建议只输出结论")
    func outputViolation() throws {
        let violation = try #require(limits().violation(for: SandboxUsage(outputBytes: 2_000)))
        #expect(violation.kind == .outputExceeded)
        #expect(violation.suggestion.contains("结论"))
    }

    @Test("⚠️ 判定顺序：内存排在墙钟前面（否则真正的原因会被「超时」藏起来）")
    func orderingPutsRootCauseFirst() throws {
        // 内存打满往往导致疯狂 GC → 最后表现为"墙钟超时"。
        // 先报"超时"的话，模型会去改一个无关的地方。
        let usage = SandboxUsage(wallClockMS: 20_000, peakMemoryMB: 900)
        let violation = try #require(limits().violation(for: usage))
        #expect(violation.kind == .memoryExceeded, "应当先报内存，而不是墙钟")
    }

    @Test("每种超限都给「面向模型的完整文本」（含建议）")
    func modelFacingText() throws {
        let violation = try #require(limits().violation(for: SandboxUsage(peakMemoryMB: 300)))
        let text = violation.modelFacingText
        #expect(text.contains("内存"))
        #expect(text.contains("300MB"))
        #expect(text.contains("256MB"))
        #expect(text.contains("👉"))
    }

    @Test("⭐ 按运行时给不同默认额度（JS 更紧、WASM 用指令数）")
    func perRuntimeDefaults() {
        let js = SandboxLimits.defaults(for: .javascript)
        #expect(js.wallClockSeconds == 30)
        #expect(js.memoryMB == 256)

        let wasm = SandboxLimits.defaults(for: .wasm)
        #expect(wasm.instructionLimit > 0, "WASM 有指令计数器，用指令数做确定性限额")

        let python = SandboxLimits.defaults(for: .python)
        #expect(python.instructionLimit == 0)
        #expect(python.memoryMB >= 256)
    }

    @Test("⭐ 额度必须收敛到设备物理内存之内（否则被限额拦住的不是脚本，是整个 App）")
    func achievableOnDevice() {
        // ⚠️ 上限是物理内存的 **1/4**，不是 3/4：
        //    iOS 的 jetsam 会在 App 占用过多时直接杀进程 ——
        //    那一刻"被拦住"的不是脚本，是整个 App（连同用户没保存的东西）。
        //    剩下的要留给系统、App 本体、UI 与运行时自己。
        #expect(SandboxLimits.memoryCap(onDeviceMemoryMB: 2_048) == 512)
        #expect(SandboxLimits.memoryCap(onDeviceMemoryMB: 4_096) == 1_024)
        #expect(SandboxLimits.memoryCap(onDeviceMemoryMB: 8_192) == 2_048)

        let big = SandboxLimits(memoryMB: 2_048)
        #expect(!big.isAchievable(onDeviceMemoryMB: 4_096), "4GB 机型上给 2GB 沙箱额度 = 等着被系统杀")
        #expect(big.isAchievable(onDeviceMemoryMB: 8_192))

        let small = SandboxLimits(memoryMB: 256)
        #expect(small.isAchievable(onDeviceMemoryMB: 2_048))

        // 极端值要有下限，不能算出 0
        #expect(SandboxLimits.memoryCap(onDeviceMemoryMB: 100) >= 64)
    }
}

// MARK: - 来源分级

@Suite("SandboxPolicy —— 来源分级（最重要的安全补偿机制）")

struct SandboxPolicyTests {

    @Test("用户自写的脚本 → 免批，跑请求的环境")
    func userAuthored() {
        let selection = SandboxPolicy.select(provenance: .userAuthored, runtime: .python)
        #expect(selection.runtime == .python)
        #expect(!selection.requiresApproval)
        #expect(!selection.isTainted)
        #expect(selection.rationale.contains("你自己写的"))
    }

    @Test("内置技能 → 免批（随包分发、已审计）")
    func bundledSkill() {
        let selection = SandboxPolicy.select(provenance: .bundledSkill, runtime: .python)
        #expect(!selection.requiresApproval)
        #expect(!selection.isTainted)
    }

    @Test("⭐ 模型生成的 Python → **降级到 WASM** 且需要确认")
    func modelGeneratedDowngradesToWasm() {
        // 这是设计文档 §3.1.1 的核心：不假装 CPython 沙箱和 WASM 一样强，
        // 而是按来源选择隔离强度。
        let selection = SandboxPolicy.select(provenance: .modelGenerated, runtime: .python)
        #expect(selection.runtime == .wasm)
        #expect(selection.requiresApproval)
        #expect(selection.rationale.contains("模型生成"))
        #expect(selection.rationale.contains("降级"), "要说清做不到时的降级路径")
    }

    @Test("模型生成的 JS → 仍在 JSC 里，但要确认")
    func modelGeneratedJSStaysInJSC() {
        let selection = SandboxPolicy.select(provenance: .modelGenerated, runtime: .javascript)
        #expect(selection.runtime == .javascript)
        #expect(selection.requiresApproval)
    }

    @Test("⭐ 来源不明的脚本 → 需确认 **且打污点**（供应链攻击入口）")
    func unknownFromWorkspaceIsTainted() {
        let selection = SandboxPolicy.select(provenance: .unknownFromWorkspace, runtime: .python)
        #expect(selection.requiresApproval)
        #expect(selection.isTainted)
        #expect(selection.rationale.contains("供应链"))
    }

    @Test("⭐ 从路径推断来源：vendor / node_modules → 来源不明")
    func inferFromPath() {
        for prefix in ["vendor", "node_modules", "third_party", "deps", "site-packages"] {
            let candidate = path("/workspace/\(prefix)/lib/setup.py")
            #expect(SandboxPolicy.inferProvenance(path: candidate) == .unknownFromWorkspace,
                    "\(prefix) 下的脚本应当判为来源不明")
        }
        // 用户自己的源码目录 → 用户自写
        #expect(SandboxPolicy.inferProvenance(path: path("/workspace/src/app.py")) == .userAuthored)
    }

    @Test("本轮刚生成的代码 → 模型生成（优先级最高）")
    func generatedThisTurnWins() {
        let generated = path("/workspace/src/gen.py")
        #expect(SandboxPolicy.inferProvenance(path: generated, wasGeneratedThisTurn: true) == .modelGenerated)
        // 即使它在 vendor 下，本轮生成的也按模型生成处理（更严的那一档）
        let vendored = path("/workspace/vendor/gen.py")
        #expect(SandboxPolicy.inferProvenance(path: vendored, wasGeneratedThisTurn: true) == .modelGenerated)
    }

    @Test("内置技能目录优先于路径推断")
    func bundledSkillFlagWins() {
        #expect(SandboxPolicy.inferProvenance(path: path("/workspace/vendor/x.py"), isBundledSkill: true) == .bundledSkill)
    }

    @Test("⚠️ 路径推断是**保守**的：误判成「来源不明」的代价是一次确认，反过来是静默执行别人的代码")
    func inferenceIsConservative() {
        // 大小写不敏感
        #expect(SandboxPolicy.inferProvenance(path: path("/workspace/Vendor/x.py")) == .unknownFromWorkspace)
        // 未知目录 → 判成用户自写（不是反过来把什么都当可疑）
        #expect(SandboxPolicy.inferProvenance(path: path("/workspace/mystuff/x.py")) == .userAuthored)
    }
}

// MARK: - 取消

@Suite("SandboxCancellation —— 协作式取消")

struct SandboxCancellationTests {

    @Test("未取消时检查通过")
    func notCancelled() throws {
        let token = SandboxCancellation()
        #expect(!token.isCancelled)
        try token.checkCancellation()
    }

    @Test("取消之后检查会抛错，并带上原因")
    func cancelledThrows() {
        let token = SandboxCancellation()
        token.cancel(reason: "用户按了停止")
        #expect(token.isCancelled)
        #expect(throws: SandboxAbort.self) { try token.checkCancellation() }
        #expect(token.cancellationReason == "用户按了停止")
    }

    @Test("⚠️ 取消是幂等的、且第一次的原因被保留（后面的取消不该覆盖掉真实原因）")
    func firstReasonWins() {
        let token = SandboxCancellation()
        token.cancel(reason: "用户按了停止")
        token.cancel(reason: "超时")
        #expect(token.cancellationReason == "用户按了停止")
    }
}

// MARK: - 路由与执行

/// 可编排的沙箱执行器（测试用）
final class ScriptedSandbox: SandboxExecuting, @unchecked Sendable {
    let runtime: SandboxRuntime
    private let lock = NSLock()
    private var queue: [SandboxResult] = []
    private(set) var requests: [SandboxRequest] = []
    private var behavior: ((SandboxRequest, SandboxCancellation) throws -> SandboxResult)?

    init(runtime: SandboxRuntime = .python, results: [SandboxResult] = []) {
        self.runtime = runtime
        self.queue = results
    }

    func enqueue(_ result: SandboxResult) {
        lock.lock(); queue.append(result); lock.unlock()
    }

    func setBehavior(_ behavior: @escaping (SandboxRequest, SandboxCancellation) throws -> SandboxResult) {
        lock.lock(); self.behavior = behavior; lock.unlock()
    }

    func run(_ request: SandboxRequest, cancellation: SandboxCancellation) throws -> SandboxResult {
        lock.lock()
        requests.append(request)
        let behavior = self.behavior
        let next = queue.isEmpty ? nil : queue.removeFirst()
        lock.unlock()
        if let behavior { return try behavior(request, cancellation) }
        return next ?? SandboxResult(stdout: Data("ok\n".utf8))
    }

    var lastRequest: SandboxRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests.last
    }
}

@Suite("SandboxRouter —— 路由、限额、输出纪律集中在一处")

struct SandboxRouterTests {

    private func router(_ executors: [SandboxRuntime: any SandboxExecuting],
                        memory: Int = 4_096) -> SandboxRouter {
        SandboxRouter(executors: executors, deviceMemoryMB: memory)
    }

    @Test("⭐ 模型生成的 Python 会被路由到 WASM 执行器（且说明降级）")
    func modelGeneratedRoutedToWasm() {
        let python = ScriptedSandbox(runtime: .python)
        let wasm = ScriptedSandbox(runtime: .wasm)
        let router = router([.python: python, .wasm: wasm])
        let request = SandboxRequest(runtime: .python, code: "print(1)", provenance: .modelGenerated)

        let routing = router.route(request)
        #expect(routing.selection.runtime == .wasm)
        #expect(routing.wasDowngraded)
        #expect(routing.notes.contains { $0.contains("来源分级") })
        // WASM 的默认额度被套上
        #expect(routing.limits.instructionLimit > 0)

        _ = router.execute(request)
        #expect(wasm.requests.count == 1)
        #expect(python.requests.isEmpty)
    }

    @Test("用户自写的脚本走原环境，不降级")
    func userAuthoredNotDowngraded() {
        let python = ScriptedSandbox(runtime: .python)
        let router = router([.python: python, .wasm: ScriptedSandbox(runtime: .wasm)])
        let request = SandboxRequest(runtime: .python, code: "print(1)", provenance: .userAuthored)
        let routing = router.route(request)
        #expect(routing.selection.runtime == .python)
        #expect(!routing.wasDowngraded)
    }

    @Test("⭐ 内存额度收敛到设备物理内存之内，并如实记下")
    func memoryIsCappedToDevice() {
        let router = router([.python: ScriptedSandbox()], memory: 2_048)
        let request = SandboxRequest(runtime: .python, code: "x",
                                     limits: SandboxLimits(memoryMB: 4_000),
                                     provenance: .userAuthored)
        let routing = router.route(request)
        #expect(routing.limits.memoryMB <= 2_048)
        #expect(routing.notes.contains { $0.contains("收敛") })
    }

    @Test("★ 限额判定在路由层统一做（执行器只上报用量）")
    func violationDetectedAtRouterLevel() {
        let executor = ScriptedSandbox(runtime: .python)
        // 执行器"忘了"判限额，只如实地把用量报上来
        executor.enqueue(SandboxResult(
            stdout: Data("跑了很久\n".utf8),
            usage: SandboxUsage(wallClockMS: 999_000, peakMemoryMB: 100)
        ))
        let router = router([.python: executor])
        let request = SandboxRequest(
            runtime: .python, code: "x",
            limits: SandboxLimits(wallClockSeconds: 5, memoryMB: 512),
            provenance: .userAuthored
        )
        let result = router.execute(request)
        #expect(result.violation?.kind == .timedOut)
        #expect(result.exitCode == 137)
        #expect(!result.succeeded)
    }

    @Test("没有对应执行器 → 127 + 说明（而不是静默成功）")
    func missingExecutor() {
        let router = router([:])
        let result = router.execute(SandboxRequest(runtime: .python, code: "x", provenance: .userAuthored))
        #expect(result.exitCode == 127)
        #expect(String(decoding: result.stderr, as: UTF8.self).contains("没有"))
    }

    @Test("执行器抛取消 → 结果标记为取消（退出码 130）")
    func cancellationPropagates() {
        let executor = ScriptedSandbox(runtime: .python)
        executor.setBehavior { _, _ in throw SandboxAbort.cancelled(reason: "用户停止") }
        let router = router([.python: executor])
        let result = router.execute(SandboxRequest(runtime: .python, code: "x", provenance: .userAuthored))
        #expect(result.wasCancelled)
        #expect(result.exitCode == 130)
    }

    @Test("执行器抛限额 → 结果带上限额信息")
    func limitAbortPropagates() {
        let executor = ScriptedSandbox(runtime: .python)
        let violation = SandboxViolation(kind: .memoryExceeded, measured: "900MB", limit: "256MB",
                                         suggestion: "分批", isRetryableWithBiggerLimit: false)
        executor.setBehavior { _, _ in throw SandboxAbort.limitExceeded(violation) }
        let router = router([.python: executor])
        let result = router.execute(SandboxRequest(runtime: .python, code: "x", provenance: .userAuthored))
        #expect(result.violation?.kind == .memoryExceeded)
        #expect(result.exitCode == 137)
    }

    @Test("执行器抛别的错 → 也要变成结构化结果，不能让异常穿出去")
    func unexpectedErrorIsContained() {
        struct Boom: Error {}
        let executor = ScriptedSandbox(runtime: .python)
        executor.setBehavior { _, _ in throw Boom() }
        let router = router([.python: executor])
        let result = router.execute(SandboxRequest(runtime: .python, code: "x", provenance: .userAuthored))
        #expect(result.exitCode == 1)
        #expect(String(decoding: result.stderr, as: UTF8.self).contains("执行器异常"))
    }

    @Test("⚠️ 模型生成却放行时要留一句提醒（自查用）")
    func modelGeneratedReleaseIsNoted() {
        // 目前 select() 对模型生成一律 requiresApproval，所以这条提醒不该出现
        let router = router([.wasm: ScriptedSandbox(runtime: .wasm)])
        let routing = router.route(SandboxRequest(runtime: .python, code: "x", provenance: .modelGenerated))
        #expect(routing.selection.requiresApproval)
        #expect(!routing.notes.contains { $0.contains("被放行") })
    }
}

// MARK: - 输出纪律的落点

@Suite("SandboxResult.asToolResult —— 所有执行类工具的必经之路")

struct SandboxResultTests {

    private func result(_ text: String, exitCode: Int32 = 0, usage: SandboxUsage = SandboxUsage()) -> SandboxResult {
        SandboxResult(exitCode: exitCode, stdout: Data(text.utf8), usage: usage)
    }

    @Test("小输出直接内联")
    func smallOutputInline() {
        let tool = result("12 passed in 0.31s\n").asToolResult(callID: "c1", budget: .exec)
        #expect(tool.status == .ok)
        #expect(tool.summary.contains("12 passed"))
        #expect(tool.artifacts.isEmpty)
    }

    @Test("⭐ 大输出转制品：摘要 + 句柄 + 预览，全都要有")
    func largeOutputBecomesArtifact() {
        let text = (1...3_000).map { "第 \($0) 行的输出内容" }.joined(separator: "\n")
        let budget = OutputBudget(inlineLimit: 2_000, artifactLimit: 500_000, previewBytes: 500)
        let tool = result(text).asToolResult(callID: "c1", budget: budget,
                                             displayName: "测试输出",
                                             headline: "3 个用例失败")
        #expect(tool.status == .ok)
        #expect(tool.artifacts.count == 1)
        #expect(tool.artifacts[0].displayName == "测试输出")
        #expect(tool.artifacts[0].lineCount == 3_000)
        // 摘要里要有：体积、行数、摘要、怎么读
        #expect(tool.summary.contains("3 个用例失败"))
        #expect(tool.summary.contains("read_artifact"))
        #expect(tool.summary.contains("预览"))
        // ⚠️ 绝不能把全文塞进 summary
        #expect(tool.summary.utf8.count < text.utf8.count / 2)
    }

    @Test("⚠️ 连制品都不该落的大输出 → 拒绝，且建议是「改做法」而不是「再试一次」")
    func oversizedOutputIsRefused() {
        let text = String(repeating: "x", count: 10_000)
        let budget = OutputBudget(inlineLimit: 1_000, artifactLimit: 2_000)
        let tool = result(text).asToolResult(callID: "c1", budget: budget)
        #expect(tool.status == .error)
        let error = tool.error
        #expect(error?.kind == .outputTooLarge)
        #expect(error?.suggestion?.contains("缩小范围") == true)
    }

    @Test("⭐ 限额触发 → error 且带上该怎么做（模型唯一能自救的入口）")
    func violationBecomesActionableError() {
        let violation = SandboxViolation(kind: .timedOut, measured: "11.0s", limit: "10s",
                                         suggestion: "转成后台作业（start_job）",
                                         isRetryableWithBiggerLimit: true)
        var sandbox = result("跑到一半\n")
        sandbox.violation = violation
        let tool = sandbox.asToolResult(callID: "c1", budget: .exec)
        #expect(tool.status == .error)
        #expect(tool.error?.kind == .sandboxFailure)
        #expect(tool.summary.contains("start_job"))
        #expect(tool.summary.contains("跑到一半"), "超限时也要给最后一次输出，否则模型没法判断进度")
    }

    @Test("⚠️ 取消要说明是「被取消」而不是「脚本有问题」")
    func cancellationIsNotAScriptBug() {
        var sandbox = result("")
        sandbox.wasCancelled = true
        let tool = sandbox.asToolResult(callID: "c1", budget: .exec)
        #expect(tool.status == .error)
        #expect(tool.summary.contains("取消"))
        #expect(tool.error?.suggestion?.contains("不是脚本的问题") == true
                || tool.summary.contains("不是脚本的问题"))
    }

    @Test("退出码非 0 → error，并把输出给模型")
    func nonZeroExit() {
        let tool = result("AssertionError: 12.30 != 12.3\n", exitCode: 1).asToolResult(callID: "c1", budget: .exec)
        #expect(tool.status == .error)
        #expect(tool.summary.contains("12.30"))
        #expect(tool.summary.contains("退出码 1"))
    }

    @Test("度量如实带到 ToolResult（UI 要显示耗时与内存）")
    func metricsCarried() {
        let usage = SandboxUsage(wallClockMS: 1_234, cpuMS: 900, peakMemoryMB: 128,
                                 instructions: 42_000, outputBytes: 20)
        let tool = result("ok", usage: usage).asToolResult(callID: "c1", budget: .exec)
        #expect(tool.metrics.wallClockMS == 1_234)
        #expect(tool.metrics.peakMemoryMB == 128)
        #expect(tool.metrics.sandboxInstructions == 42_000)
        #expect(tool.metrics.exitCode == 0)
    }

    @Test("⭐ 所有执行类工具都必须经过它 —— 用一个真实的执行工具验证（run_shell 的输出形态）")
    func execToolsDeclareArtifactShape() {
        // 上一条纪律的守门人：注册表里凡是 .exec 的工具，输出形态都必须是制品
        for spec in ToolRegistry.all where spec.requirements.contains(.exec) {
            guard case .artifact = spec.outputShape else {
                Issue.record("\(spec.name) 是执行类工具，输出形态不是制品 —— 它会绕过输出纪律")
                continue
            }
        }
    }
}



