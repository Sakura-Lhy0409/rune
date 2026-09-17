import Testing
import Foundation
@testable import RuneKernel

// MARK: - 端到端场景测试
//
// 前面每个模块都有各自的白盒测试，但**它们凑在一起能不能真的当一个 Agent 用**是另一回事：
// 接口对不对得上、协议不变式在真实的多轮流程里守不守得住、授权是不是真的在生效、
// 上下文装配会不会在某一轮悄悄漏掉目标 —— 这些只有把整条链路串起来跑才看得出来。
//
// 这里跑的是一个真实形状的任务：**修一个失败的测试并提交**。

// MARK: 工作区（模拟 VFS 可写的那部分）

final class ScenarioWorkspace: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String]
    private var testRuns = 0
    private(set) var commits: [String] = []
    private(set) var executedCalls: [String] = []
    private(set) var writes: [String: Int] = [:]

    init(files: [String: String]) { self.files = files }

    /// `/workspace/src/a.py` 与 `src/a.py` 都归一化到 `src/a.py`
    static func normalize(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\\", with: "/")
        if s.hasPrefix("/workspace/") { s = String(s.dropFirst("/workspace/".count)) }
        while s.hasPrefix("./") { s = String(s.dropFirst(2)) }
        return s
    }

    func read(_ path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return files[Self.normalize(path)]
    }

    func write(_ path: String, _ content: String) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.normalize(path)
        files[key] = content
        writes[key, default: 0] += 1
    }

    func snapshot() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return files
    }

    func record(_ call: String) {
        lock.lock(); defer { lock.unlock() }
        executedCalls.append(call)
    }

    func nextTestRun() -> Int {
        lock.lock(); defer { lock.unlock() }
        testRuns += 1
        return testRuns
    }

    func addCommit(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        commits.append(message)
    }

    var callMultiplicity: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return executedCalls.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}

// MARK: 执行器（把工具"实现"到内存工作区上）

struct ScenarioExecutor: ToolExecuting {
    let ws: ScenarioWorkspace
    /// 让第一次 `run_tests` 失败（用于验证修正性重试）
    let failFirstTestRun: Bool
    /// 让 `apply_patch` 的前 N 次返回"参数不合法"（用于验证熔断）
    let corruptPatches: Int

    init(ws: ScenarioWorkspace, failFirstTestRun: Bool = false, corruptPatches: Int = 0) {
        self.ws = ws
        self.failFirstTestRun = failFirstTestRun
        self.corruptPatches = corruptPatches
    }

    private func arg(_ call: ToolCall, _ key: String) -> String {
        (try? call.arguments().value(at: [key])?.stringValue) ?? ""
    }

    func execute(_ call: ToolCall) throws -> ToolResult {
        ws.record(call.name)
        switch call.name {

        case ToolName.grepSearch:
            return .ok(callID: call.id,
                       summary: "src/money.py:12:    return round(amount)\nsrc/money.py:20:    return round(total)")

        case ToolName.readFile:
            let path = arg(call, "path")
            guard let content = ws.read(path) else {
                return .failure(callID: call.id, error: ToolError(
                    kind: .pathNotFound,
                    modelFacingMessage: "文件不存在：\(path)",
                    suggestion: "工作区里名字最接近的是 src/money.py",
                    candidates: ["src/money.py"]
                ))
            }
            return .ok(callID: call.id, summary: content)

        case ToolName.applyPatch:
            let patchText = arg(call, "patch")
            guard let patch = try? Patch.parse(patchText), let file = patch.files.first else {
                return .failure(callID: call.id, error: ToolError(
                    kind: .invalidArguments,
                    modelFacingMessage: "补丁格式不合法（缺少文件段或 hunk）",
                    suggestion: "补丁要以 *** File: 路径 开头",
                    candidates: ["patch"]
                ))
            }
            let path = file.path.description
            guard let current = ws.read(path) else {
                return .failure(callID: call.id, error: ToolError(
                    kind: .pathNotFound,
                    modelFacingMessage: "文件不存在：\(path)",
                    suggestion: "确认路径写对了",
                    candidates: ["src/money.py"]
                ))
            }
            // ⚠️ 幂等性：先检查"目标状态是否已经达成"，而不是无脑再改一遍
            let adds = file.hunks.flatMap { $0.lines.filter(\.isAdd).map(\.text) }
            let removes = file.hunks.flatMap { $0.lines.filter(\.isRemove).map(\.text) }
            if !adds.isEmpty,
               adds.allSatisfy({ current.contains($0) }),
               removes.allSatisfy({ !current.contains($0) }) {
                return .ok(callID: call.id, summary: "补丁已应用过（跳过）")
            }
            guard let applied = try? patch.apply(reader: { ws.read($0.description) }),
                  let change = applied.changes.first, let newContent = change.newContent else {
                return .failure(callID: call.id, error: ToolError(
                    kind: .other,
                    modelFacingMessage: "补丁无法应用（上下文不匹配）",
                    suggestion: "先 read_file 确认当前内容"
                ))
            }
            ws.write(path, newContent)
            return .ok(callID: call.id, summary: "已修改 \(path)")

        case ToolName.runTests:
            let run = ws.nextTestRun()
            if failFirstTestRun, run == 1 {
                return .failure(callID: call.id, error: ToolError(
                    kind: .invalidArguments,
                    modelFacingMessage: "1 failed：test_round_amount —— 期望 Decimal('12.30')，实际 Decimal('12.3')",
                    suggestion: "金额应当按币种精度取整（保留 2 位）",
                    candidates: ["subject", "expected"]
                ))
            }
            return .ok(callID: call.id, summary: "12 passed in 0.31s")

        case ToolName.gitCommit:
            ws.addCommit(arg(call, "message"))
            return .ok(callID: call.id, summary: "已提交")

        default:
            return .ok(callID: call.id, summary: "ok")
        }
    }
}

// MARK: 场景夹具

enum Scenario {

    static func workspace() -> ScenarioWorkspace {
        ScenarioWorkspace(files: [
            "src/money.py": """
            def round_amount(amount):
                # BUG: 没有按币种精度取整
                return round(amount)

            def total(items):
                return round(sum(items))
            """,
            "tests/test_money.py": """
            def test_round_amount():
                assert round_amount(Decimal("12.295")) == Decimal("12.30")
            """,
            "CHANGELOG.md": "# 变更日志\n",
        ])
    }

    static let patch = """
    *** File: src/money.py
    @@
    -    return round(amount)
    +    return round(amount, amount.as_tuple().exponent if hasattr(amount, "as_tuple") else 2)
    """

    /// 一个真实形状的六轮对话
    static func script(rounds: Int = 6) -> @Sendable (TurnState) -> [ModelEvent] {
        { state in
            switch state.round {
            case 0:
                return oneCall("c1", ToolName.grepSearch,
                               .object(["pattern": .string("round("), "path": .string("src")]))
            case 1:
                return oneCall("c2", ToolName.readFile, .object(["path": .string("src/money.py")]))
            case 2:
                return oneCall("c3", ToolName.applyPatch, .object(["patch": .string(patch)]))
            case 3:
                return oneCall("c4", ToolName.runTests, .object(["filter": .string("test_money")]))
            case 4:
                return oneCall("c5", ToolName.gitCommit,
                               .object(["message": .string("fix: 金额按币种精度取整")]))
            default:
                return []
            }
        }
    }

    /// 计划已批准 → 修改类工具不需要逐次确认（docs/05 §8.1 的分工）
    static func context(writeUpTo: String = "") -> PolicyEngine.Context {
        let writeScope = writeUpTo.isEmpty
            ? VFSPath(mount: .workspace)
            : VFSPath(mount: .workspace, components: writeUpTo.split(separator: "/").map(String.init))
        let token = CapabilityToken(
            issuedForTurn: UUID(),
            scopes: [
                .fsRead(VFSPath(mount: .workspace)),
                .fsWrite(writeScope),
                .exec(runtime: .python),
                .gitWrite(remote: nil),
            ],
            expiresAt: Date().addingTimeInterval(3600),
            grantedBy: .planApproval,
            reason: "端到端场景测试"
        )
        return PolicyEngine.Context(trustDial: .collaborate, token: token, planApproved: true)
    }

    static func config() -> TurnRunner.Config {
        TurnRunner.Config(
            maxRounds: 10, maxToolCalls: 24, maxSelfCorrections: 2,
            toolRegistry: ToolRegistry.byName
        )
    }

    static func deps(
        _ ws: ScenarioWorkspace,
        context: PolicyEngine.Context,
        failFirstTestRun: Bool = false,
        script: @escaping @Sendable (TurnState) -> [ModelEvent] = Scenario.script()
    ) -> TurnRunner.Dependencies {
        TurnRunner.Dependencies(
            modelEvents: script,
            executor: ScenarioExecutor(ws: ws, failFirstTestRun: failFirstTestRun),
            policy: PolicyEngine(),
            policyContext: context,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            pathsOfCall: ToolScheduler.defaultPaths
        )
    }

    /// 每一轮都装配一次上下文（模拟真实运行时的做法）
    static func contextItems(
        for state: TurnState,
        catalog: ContextItem?,
        skills: SkillRegistry
    ) -> [ContextItem] {
        var items: [ContextItem] = [
            ContextItem(id: "objective", block: .systemLayer1,
                        text: "当前目标：\(state.objective)",
                        trust: .userInstruction, relevance: 1.0, recency: 1.0,
                        pinnedRole: .objective)
        ]
        if let catalog { items.append(catalog) }

        // 最近一次失败的 tool result —— **必须进上下文**，否则模型会重走已经失败的路
        let results = state.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }
        if let failure = results.last(where: { $0.status != .ok }) {
            items.append(ContextItem(
                id: "last-failure", block: .history,
                text: "最近一次失败：\(failure.summary)",
                relevance: 1.0, recency: 1.0, pinnedRole: .lastFailure
            ))
        }

        // 最近几轮的工具结果（越新越靠前）
        for (index, result) in results.suffix(6).enumerated() {
            items.append(ContextItem(
                id: "result-\(index)", block: .toolResult,
                text: result.summary,
                relevance: 0.7,
                recency: Double(index) / 6.0 + 0.3,
                artifactHandle: result.artifacts.first?.relPath
            ))
        }

        // 对话文本（历史）
        for (index, message) in state.messages.enumerated() {
            guard message.role == .user || message.role == .assistant else { continue }
            let text = message.plainText
            guard !text.isEmpty else { continue }
            items.append(ContextItem(
                id: "msg-\(index)", block: .history, text: text,
                trust: message.origin,
                relevance: 0.5,
                recency: Double(index) / Double(max(1, state.messages.count))
            ))
        }
        _ = skills
        return items
    }
}

/// 像真实运行时那样跑到结束：遇到审批就批准，直到稳定态。
///
/// ⚠️ 不能直接用 `TurnRunner.run`：它在**第一次**遇到审批时就返回。
///    真实运行时会弹卡片、用户点一下、然后接着跑。测试要模拟这个循环，
///    否则「恢复时的结果未知确认」这条路径会被整个跳过 —— 而崩溃正是藏在它后面。
@discardableResult
func runToCompletion(
    _ state: TurnState,
    deps: TurnRunner.Dependencies,
    config: TurnRunner.Config,
    maxApprovals: Int = 8
) -> (state: TurnState, events: [RuntimeEvent], pendingApproval: TurnRunner.ApprovalRequest?) {
    var current = state
    var events: [RuntimeEvent] = []
    var approvals = 0
    while true {
        let (next, newEvents, approval) = TurnRunner.run(current, deps: deps, config: config)
        events.append(contentsOf: newEvents)
        current = next
        guard let approval else { return (current, events, nil) }
        approvals += 1
        if approvals > maxApprovals { return (current, events, approval) }
        current = TurnRunner.approve(current, deps: deps)
    }
}

/// 线程安全地收集每一轮装配的结果
final class AssemblyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(round: Int, assembly: Assembly)] = []
    func append(round: Int, _ assembly: Assembly) { lock.lock(); entries.append((round, assembly)); lock.unlock() }
    var all: [(round: Int, assembly: Assembly)] { lock.lock(); defer { lock.unlock() }; return entries }
}

// MARK: - 主场景

@Suite("端到端场景 —— 修一个失败的测试并提交")

struct EndToEndScenarioTests {

    @Test("⭐ 完整跑通：定位 → 读 → 补丁 → 跑测试 → 提交，并全程维持协议不变式")
    func happyPath() {
        let ws = Scenario.workspace()
        let before = ws.snapshot()
        let (final, events, approval) = TurnRunner.run(
            TurnState(objective: "修复失败的金额取整测试"),
            deps: Scenario.deps(ws, context: Scenario.context()),
            config: Scenario.config()
        )

        #expect(approval == nil)
        #expect(final.status == .completed)

        // 工具真的按顺序用了
        #expect(ws.executedCalls == [
            ToolName.grepSearch, ToolName.readFile, ToolName.applyPatch,
            ToolName.runTests, ToolName.gitCommit,
        ])
        // 文件真的改了，别的文件没被碰
        #expect(ws.snapshot()["src/money.py"] != before["src/money.py"])
        #expect(ws.snapshot()["CHANGELOG.md"] == before["CHANGELOG.md"])
        #expect(ws.commits == ["fix: 金额按币种精度取整"])

        // ⚠️ 协议不变式：每个 tool_call 都有且仅有一个配对结果
        let callIDs = final.messages.flatMap { $0.blocks.compactMap(\.toolCallValue) }.map(\.id)
        let resultIDs = final.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }.map(\.callID)
        #expect(Set(callIDs) == Set(resultIDs))
        #expect(callIDs.count == resultIDs.count)

        // 事件哈希链完整可校验（审计可回溯）
        #expect(events.count > 10)
        for event in events { #expect(event.verifyHash()) }
        // 链是首尾相接的
        for (previous, next) in zip(events, events.dropFirst()) {
            #expect(next.previousHash == previous.hash)
        }
    }

    @Test("⭐ 每一轮装配出来的上下文都通过自检（缺目标/缺最近失败都会被抓到）")
    func contextPassesSelfCheckEveryRound() {
        let ws = Scenario.workspace()
        let skills = SkillRegistry(skills: SkillLibrary.builtin)
        let log = AssemblyLog()

        let base = Scenario.deps(ws, context: Scenario.context())
        let deps = TurnRunner.Dependencies(
            modelEvents: { state in
                let assembly = ContextAssembler.assemble(
                    items: Scenario.contextItems(for: state, catalog: skills.catalogItem(query: "测试 失败"), skills: skills),
                    budget: ContextBudget(window: 32_000)
                )
                log.append(round: state.round, assembly)
                return Scenario.script()(state)
            },
            executor: base.executor,
            policy: base.policy,
            policyContext: base.policyContext,
            now: base.now,
            pathsOfCall: base.pathsOfCall
        )

        let (final, _, _) = TurnRunner.run(
            TurnState(objective: "修复失败的金额取整测试"), deps: deps, config: Scenario.config()
        )
        #expect(final.status == .completed)

        let assemblies = log.all
        #expect(assemblies.count >= 3, "应当装配了多轮，实际 \(assemblies.count)")
        for (round, assembly) in assemblies {
            for check in assembly.selfChecks where !check.passed {
                Issue.record("第 \(round) 轮的上下文自检失败：\(check.kind.rawValue) —— \(check.detail)")
            }
            // 技能目录必须在，且落在系统层 2
            #expect(assembly.blocks.contains { $0.id == "skill-catalog" })
        }
    }

    @Test("⭐ 系统层字节在整轮里完全稳定（Prompt Cache 能命中的前提）")
    func cacheablePrefixIsStable() {
        let ws = Scenario.workspace()
        let skills = SkillRegistry(skills: SkillLibrary.builtin)
        let log = AssemblyLog()

        let base = Scenario.deps(ws, context: Scenario.context())
        let deps = TurnRunner.Dependencies(
            modelEvents: { state in
                let assembly = ContextAssembler.assemble(
                    items: Scenario.contextItems(for: state, catalog: skills.catalogItem(), skills: skills),
                    budget: ContextBudget(window: 32_000)
                )
                log.append(round: state.round, assembly)
                return Scenario.script()(state)
            },
            executor: base.executor, policy: base.policy, policyContext: base.policyContext,
            now: base.now, pathsOfCall: base.pathsOfCall
        )
        _ = TurnRunner.run(TurnState(objective: "修复失败的金额取整测试"), deps: deps, config: Scenario.config())

        let prefixes = log.all.map { entry in
            entry.assembly.blocks
                .filter { $0.block == .systemLayer1 || $0.block == .systemLayer2 }
                .map(\.text)
        }
        #expect(prefixes.count >= 3)
        for prefix in prefixes.dropFirst() {
            #expect(prefix == prefixes[0], "系统层字节变了 —— Prompt Cache 会全部失效")
        }
    }

    @Test("⭐ 测试失败后模型自己改好：记一次「自行修正」，最终仍然跑通")
    func selfCorrectionWorksEndToEnd() {
        let ws = Scenario.workspace()
        // 让第一次 run_tests 失败（可修正错误），模型的下一轮会重新跑
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            switch state.round {
            case 0:  return oneCall("c1", ToolName.readFile, .object(["path": .string("src/money.py")]))
            case 1:  return oneCall("c2", ToolName.applyPatch, .object(["patch": .string(Scenario.patch)]))
            case 2, 3:
                return oneCall("t\(state.round)", ToolName.runTests, .object(["filter": .string("test_money")]))
            default: return []
            }
        }
        let (final, events, _) = TurnRunner.run(
            TurnState(objective: "修好它"),
            deps: Scenario.deps(ws, context: Scenario.context(), failFirstTestRun: true, script: script),
            config: Scenario.config()
        )

        #expect(final.status == .completed)
        #expect(final.corrections.recoveredCount == 1, "第一次测试失败后重跑成功，应当记一次自行修正")
        #expect(events.contains { $0.kind == .modelSelfCorrected })
        // 跑了两次测试
        #expect(ws.callMultiplicity[ToolName.runTests] == 2)
        // ⚠️ 补丁只实际改了一次（幂等检查生效）
        #expect(ws.writes["src/money.py"] == 1)
    }

    @Test("⚠️ 写到授权范围之外 → 被拒，且**整个任务仍然能继续**（模型会绕路）")
    func outOfScopeWriteIsDeniedAndTurnSurvives() {
        let ws = Scenario.workspace()
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            switch state.round {
            case 0:
                // 只授权了 src，它却想改 tests —— 必须被拒
                return oneCall("bad", ToolName.writeFile,
                               .object(["path": .string("tests/test_money.py"), "content": .string("改成永远通过")]))
            case 1:
                return oneCall("good", ToolName.readFile, .object(["path": .string("src/money.py")]))
            default:
                return []
            }
        }
        let (final, _, _) = TurnRunner.run(
            TurnState(objective: "修好它"),
            deps: Scenario.deps(ws, context: Scenario.context(writeUpTo: "src"), script: script),
            config: Scenario.config()
        )

        // 被拒的是那一次调用，不是整个任务
        let results = final.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }
        let denied = results.first { $0.callID == "bad" }
        #expect(denied?.status == .denied || denied?.status == .error)
        #expect(denied?.summary.contains("授权") == true || denied?.summary.contains("范围") == true
                || denied?.summary.contains("允许") == true)
        // 测试文件一个字都没被改
        #expect(ws.snapshot()["tests/test_money.py"]?.contains("永远通过") == false)
        // 它随后做了正确的事
        #expect(ws.executedCalls.contains(ToolName.readFile))
    }

    @Test("⭐ 补丁参数一直不合法 → 停下来问用户，而不是把预算烧完")
    func repeatedBadPatchEscalates() {
        let ws = Scenario.workspace()
        // ⚠️ 必须发**解析不了**的补丁才会得到 `.invalidArguments`（可修正）。
        //    发「格式对但锚点找不到」的补丁会得到 `.other`（不可修正）→ 不计数 → 会一直跑到预算上限。
        //    而且每次正文要不同，否则会先命中「逐字重复」熔断而不是「机会用尽」。
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            guard state.round < 8 else { return [] }
            return oneCall("p\(state.round)", ToolName.applyPatch,
                           .object(["patch": .string("这不是一个合法补丁（第 \(state.round) 次尝试）")]))
        }
        var state = TurnState(objective: "改文件")
        let deps = Scenario.deps(ws, context: Scenario.context(), script: script)
        let config = Scenario.config()

        var escalation: Correction.Escalation?
        for _ in 0..<20 {
            let outcome = TurnRunner.step(state, deps: deps, config: config)
            state = outcome.state
            if let pending = outcome.pendingCorrection { escalation = pending }
            if !state.canAdvance { break }
        }

        #expect(escalation?.cause == .correctionsExhausted)
        #expect(state.status == .awaitingUser)
        // 只跑了 3 次就停下（maxToolCalls 是 24）
        #expect(state.toolCallCount == 3)
        // 每个方案都成立：有出口
        let actions = Set(escalation?.options.map(\.action) ?? [])
        #expect(actions.contains(.changeApproach))
        #expect(actions.contains(.stop))
        // ⚠️ 即使在这种情况下，协议不变式仍然成立
        let callIDs = state.messages.flatMap { $0.blocks.compactMap(\.toolCallValue) }.map(\.id)
        let resultIDs = state.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }.map(\.callID)
        #expect(Set(callIDs) == Set(resultIDs))
    }

    @Test("⚠️【崩溃一致性】在任意一步被杀，恢复后的工作区必须与不中断完全一致")
    func crashAtEveryStepIsConsistent() {
        // 基线
        let baselineWS = Scenario.workspace()
        let (baseline, _, _) = TurnRunner.run(
            TurnState(objective: "修复失败的金额取整测试"),
            deps: Scenario.deps(baselineWS, context: Scenario.context()),
            config: Scenario.config()
        )
        #expect(baseline.status == .completed)
        let expected = baselineWS.snapshot()

        var cutPoints = 0
        for cut in 0..<24 {
            let ws = Scenario.workspace()
            let (partial, _, _) = TurnRunner.run(
                TurnState(objective: "修复失败的金额取整测试"),
                deps: Scenario.deps(ws, context: Scenario.context()),
                config: Scenario.config(),
                maxSteps: cut
            )
            var restored = partial
            restored.wasRestored = true
            // ⚠️ 恢复时可能弹出「上次有个不可重做的操作，结果未知」的确认 ——
            //    那**是正确行为**（重复提交是真实副作用），要像真实运行时那样处理它。
            let runDeps = Scenario.deps(ws, context: Scenario.context())
            let (final, _, _) = runToCompletion(restored, deps: runDeps, config: Scenario.config())
            cutPoints += 1

            // ① 工作区最终状态与基线完全一致
            #expect(ws.snapshot() == expected, "第 \(cut) 步切断后工作区与基线不一致")
            // ② 协议不变式仍然成立
            let callIDs = final.messages.flatMap { $0.blocks.compactMap(\.toolCallValue) }.map(\.id)
            let resultIDs = final.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }.map(\.callID)
            #expect(Set(callIDs) == Set(resultIDs), "第 \(cut) 步切断后出现没有结果的工具调用")
            #expect(callIDs.count == resultIDs.count, "第 \(cut) 步切断后出现重复结果")
            // ③ 最终仍然是完成态
            #expect(final.status == .completed, "第 \(cut) 步切断后没能跑到完成")
        }
        #expect(cutPoints == 24)
    }

    @Test("⚠️ 没有计划批准时，修改类工具会停下来等确认，批准后继续")
    func approvalGateWorks() {
        let ws = Scenario.workspace()
        var context = Scenario.context()
        context.planApproved = false          // 没有批量授权 → apply_patch 需要点一次

        var state = TurnState(objective: "修好它")
        let deps = Scenario.deps(ws, context: context)
        let config = Scenario.config()

        var approvals: [TurnRunner.ApprovalRequest] = []
        for _ in 0..<200 {
            let outcome = TurnRunner.step(state, deps: deps, config: config)
            state = outcome.state
            if let pending = outcome.pendingApproval {
                approvals.append(pending)
                state = TurnRunner.approve(state, deps: deps)
            }
            if !state.canAdvance { break }
        }

        // 两个"修改类"工具各要一次确认（没有计划批准就没有批量授权）
        #expect(approvals.map(\.call.name) == [ToolName.applyPatch, ToolName.gitCommit],
                "实际弹了：\(approvals.map(\.call.name))")
        // 审批请求必须是「人看得懂」的：有理由、有风险级
        for approval in approvals {
            #expect(!approval.reason.isEmpty, "\(approval.call.name) 的审批理由为空")
            #expect(approval.risk == .modifying)
        }
        #expect(state.status == .completed)
        #expect(ws.commits.count == 1)
    }

    @Test("⚠️ 不允许「批准一次 = 永久放行」：换个参数的同类调用要重新确认")
    func approvalIsScopedToTheExactCall() {
        let ws = Scenario.workspace()
        var context = Scenario.context()
        context.planApproved = false
        let deps = Scenario.deps(ws, context: context)
        let config = Scenario.config()

        // 用 `apply_patch`（`.perProject` + 修改类）：未批准计划时它一定需要确认。
        // 注意不要用 `write_file` —— 它刻意标了 `.never`（作用域才是它的防线，见 docs/05 §8.1）。
        func pendingState(id: String, patch: String) -> TurnState {
            var state = TurnState(objective: "打补丁")
            state.status = .dispatching
            state.currentWave = [ToolCall(id: id, name: ToolName.applyPatch,
                                         argumentsJSON: Data(#"{"patch":"\#(patch)"}"#.utf8))]
            return state
        }

        // 第一次：应当弹确认，批准后指纹被记下
        var firstOutcome = TurnRunner.step(
            pendingState(id: "same-id", patch: "*** File: src/a.py\n@@\n-x\n+y"),
            deps: deps, config: config
        )
        #expect(firstOutcome.pendingApproval?.call.name == ToolName.applyPatch)
        var first = TurnRunner.approve(firstOutcome.state, deps: deps)
        #expect(first.approvedFingerprints.count == 1)
        #expect(first.status == .dispatching)

        // 同一个 callID、但补丁内容不同 → 指纹不同 → **必须重新确认**
        var second = TurnState(objective: "打补丁")
        second.status = .dispatching
        second.approvedFingerprints = first.approvedFingerprints
        second.currentWave = [ToolCall(id: "same-id", name: ToolName.applyPatch,
                                      argumentsJSON: Data(#"{"patch":"*** File: src/b.py\n@@\n-x\n+z"}"#.utf8))]
        let secondOutcome = TurnRunner.step(second, deps: deps, config: config)
        #expect(secondOutcome.pendingApproval != nil, "复用旧 id 的不同调用被自动放行了 —— 那是提权")
        #expect(secondOutcome.state.approvedFingerprints.count == 1)

        // 同一个 callID、同一份补丁（只是键序不同）→ 指纹相同 → 不用再问
        var third = TurnState(objective: "打补丁")
        third.status = .dispatching
        third.approvedFingerprints = first.approvedFingerprints
        third.currentWave = [ToolCall(id: "same-id", name: ToolName.applyPatch,
                                     argumentsJSON: Data(#"{"patch":"*** File: src/a.py\n@@\n-x\n+y"}"#.utf8))]
        let thirdOutcome = TurnRunner.step(third, deps: deps, config: config)
        #expect(thirdOutcome.pendingApproval == nil, "同一份调用不该被问两遍（否则是死循环）")
        #expect(thirdOutcome.state.status == .executing)
    }
}

// MARK: - 上下文装配在真实状态上的表现

@Suite("端到端 —— 装配器从真实 TurnState 取素材")

struct AssemblerIntegrationTests {

    @Test("⭐ 有失败记录时，它必须进上下文（否则模型会重走已经失败的路）")
    func lastFailureIsInjected() {
        var state = TurnState(objective: "修好它")
        let failed = ToolResult.failure(callID: "c1", error: ToolError(
            kind: .other, modelFacingMessage: "补丁上下文不匹配，第 3 个 hunk 找不到锚点"
        ))
        state.messages.append(Message(
            role: .tool,
            blocks: [ContentBlock(kind: .toolResult(failed), origin: .toolResultTrusted)],
            origin: .toolResultTrusted
        ))

        let items = Scenario.contextItems(for: state, catalog: nil, skills: SkillRegistry(skills: []))
        let assembly = ContextAssembler.assemble(items: items, budget: ContextBudget(window: 8_000))

        #expect(assembly.passed)
        #expect(assembly.blocks.contains { $0.pinnedRole == .lastFailure })
        #expect(assembly.renderedText.contains("hunk"))
    }

    @Test("没有失败记录时不硬塞（有条件必进）")
    func noFailureNoInjection() {
        let state = TurnState(objective: "什么都没做")
        let items = Scenario.contextItems(for: state, catalog: nil, skills: SkillRegistry(skills: []))
        let assembly = ContextAssembler.assemble(items: items, budget: ContextBudget(window: 8_000))
        #expect(assembly.passed)
        #expect(!assembly.blocks.contains { $0.pinnedRole == .lastFailure })
    }

    @Test("窗口很紧时仍然先保住「当前目标」")
    func objectiveSurvivesTightBudget() {
        var state = TurnState(objective: "修复失败的金额取整测试")
        for i in 0..<40 {
            state.messages.append(Message(
                role: .tool,
                blocks: [ContentBlock(
                    kind: .toolResult(.ok(callID: "c\(i)", summary: String(repeating: "很长很长的工具输出。", count: 40))),
                    origin: .toolResultTrusted
                )],
                origin: .toolResultTrusted
            ))
        }
        let items = Scenario.contextItems(for: state, catalog: nil, skills: SkillRegistry(skills: []))
        let assembly = ContextAssembler.assemble(items: items, budget: ContextBudget(window: 6_000))

        #expect(assembly.blocks.contains { $0.pinnedRole == .objective })
        #expect(!assembly.dropped.isEmpty, "窗口这么紧，应当有东西被丢掉")
        // 丢的必须是可丢的，不是必进项
        #expect(!assembly.dropped.contains { $0.id == "objective" })
    }
}





