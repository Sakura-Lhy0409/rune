import Testing
import Foundation
@testable import RuneKernel

// MARK: - 测试夹具：一个内存里的"shop-api"项目
//
// 这个文件承载 **M0 的出口验收**（docs/14 §2）：
//   "在测试壳里，模型能自主完成'修一个简单的失败单测'，并在中途被杀后正确恢复。"
//
// 它刻意用**真实的** `GrepEngine` 与 `Patch` 引擎，而不是 mock —— 否则验收就变成自欺欺人。

/// 内存工作区（测试用；真实实现是 RuneBench 的 VFS）
final class FakeWorkspace: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String]
    /// 每个工具被**实际执行**了多少次（用于断言"没有重复副作用"）
    private(set) var executions: [String: Int] = [:]
    /// 补丁真正改动了文件的次数（重复应用应当为 0）
    private(set) var effectivePatches = 0

    init(files: [String: String]) {
        self.files = files
    }

    func read(_ path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return files[path]
    }

    func write(_ path: String, _ content: String) {
        lock.lock(); defer { lock.unlock() }
        files[path] = content
    }

    func allFiles() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return files
    }

    func recordExecution(_ tool: String) {
        lock.lock(); defer { lock.unlock() }
        executions[tool, default: 0] += 1
    }

    func recordEffectivePatch() {
        lock.lock(); defer { lock.unlock() }
        effectivePatches += 1
    }
}

/// 模拟的工具执行器：把 4 个工具接到内存工作区上。
///
/// ⚠️ 关键设计点在 `apply_patch`：它是**内容幂等**的工具。
/// 三步落盘协议允许在"已执行但事实未落盘"时被打断，恢复时会**重做**——
/// 因此内容幂等工具必须自己判断"目标状态是否已达成"，
/// 否则重做会因为"找不到旧内容"而误报失败。
/// 这条语义是三步协议的**配套要求**，真实实现（RuneTools）也必须遵守。
struct FakeToolExecutor: ToolExecuting {
    let workspace: FakeWorkspace

    func execute(_ call: ToolCall) throws -> ToolResult {
        workspace.recordExecution(call.name)

        switch call.name {
        case ToolName.grepSearch:
            return try runGrep(call)
        case ToolName.readFile:
            return try runRead(call)
        case ToolName.applyPatch:
            return try runPatch(call)
        case ToolName.runTests:
            return runTests(call)
        default:
            return .failure(callID: call.id, error: ToolError(
                kind: .unknownTool, modelFacingMessage: "夹具未实现工具 \(call.name)"
            ))
        }
    }

    private func runGrep(_ call: ToolCall) throws -> ToolResult {
        let args = try call.arguments()
        let pattern = args.value(at: ["pattern"])?.stringValue ?? ""
        let query = GrepQuery(pattern: pattern, maxResults: 20)
        let files = workspace.allFiles()
        let source = GrepFileSource { path, _ in
            guard let text = files[path.description] else { return nil }
            return Data(text.utf8)
        }
        let candidates = files.keys.map {
            GrepCandidate(path: VFSPath.parseOrNil($0) ?? VFSPath(mount: .workspace), byteSize: files[$0]!.utf8.count)
        }
        let result = try GrepEngine.search(query: query, candidates: candidates, source: source)
        return .ok(callID: call.id, summary: result.summary)
    }

    private func runRead(_ call: ToolCall) throws -> ToolResult {
        let args = try call.arguments()
        let path = args.value(at: ["path"])?.stringValue ?? ""
        guard let content = workspace.read(path) else {
            return .failure(callID: call.id, error: ToolError(
                kind: .pathNotFound,
                modelFacingMessage: "文件 \(path) 不存在。",
                suggestion: "先用 glob 或 list_dir 确认路径。"
            ))
        }
        let numbered = content.components(separatedBy: "\n")
            .enumerated().map { "\($0.offset + 1)\t\($0.element)" }.joined(separator: "\n")
        return .ok(callID: call.id, summary: numbered)
    }

    private func runPatch(_ call: ToolCall) throws -> ToolResult {
        let args = try call.arguments()
        let patchText = args.value(at: ["patch"])?.stringValue ?? ""
        let patch = try Patch.parse(patchText)

        // 取出目标文件（本夹具只支持单文件补丁）
        guard let file = patch.files.first else {
            return .failure(callID: call.id, error: ToolError(kind: .invalidArguments, modelFacingMessage: "补丁没有文件段。"))
        }
        let path = file.path.description

        // ⭐ 内容幂等：先判断"目标状态是否已达成"
        //    如果补丁里的新增内容已经存在，就认为是重复执行，直接成功返回（不报"找不到旧内容"）
        if let current = workspace.read(path) {
            let newLines = file.hunks.flatMap { $0.lines.filter(\.isAdd).map(\.text) }
            let allPresent = !newLines.isEmpty && newLines.allSatisfy { current.contains($0) }
            let oldLines = file.hunks.flatMap { $0.lines.filter(\.isRemove).map(\.text) }
            let oldGone = oldLines.allSatisfy { !current.contains($0) }
            if allPresent && oldGone {
                return .ok(callID: call.id, summary: "补丁已经应用过（目标状态已达成），跳过重复应用。")
            }
        }

        let result = try patch.apply { p in workspace.read(p.description) }
        guard let change = result.changes.first, let newContent = change.newContent else {
            return .failure(callID: call.id, error: ToolError(kind: .other, modelFacingMessage: "补丁没有产生改动。"))
        }
        workspace.write(path, newContent)
        workspace.recordEffectivePatch()
        return .ok(callID: call.id, summary: "已修改 \(path)（+\(change.addedCount) −\(change.removedCount)）")
    }

    /// 夹具版"跑测试"：检查 bug 是否已被修掉
    private func runTests(_ call: ToolCall) -> ToolResult {
        let money = workspace.read("/workspace/src/money.py") ?? ""
        if money.contains("currency.exponent") {
            return .ok(callID: call.id, summary: "1 passed in 0.01s")
        }
        return .failure(callID: call.id, error: ToolError(
            kind: .other,
            modelFacingMessage: """
            FAILED tests/test_money.py::test_refund_rounding
              AssertionError: Decimal('10.00') != Decimal('10.005')
            1 failed in 0.02s
            """,
            suggestion: "退款金额在币种转换后没有按币种精度取整。"
        ))
    }
}

// MARK: - 脚本化的"模型"
//
// 回放一个真实会话的模型行为（即 docs/14 §6.2 的 cassette 思路）。
// 关键：**分片**吐工具调用参数，从而真正压到 `ToolCallAssembler`。

private enum ModelScript {

    /// 把一次工具调用拆成多个流式事件（参数分 3 片）
    static func toolCall(index: Int, id: String, name: String, arguments: JSONValue) -> [ModelEvent] {
        let json = arguments.canonicalString()
        let chars = Array(json)
        let third = max(1, chars.count / 3)
        let f1 = String(chars[0..<min(third, chars.count)])
        let f2 = String(chars[min(third, chars.count)..<min(third * 2, chars.count)])
        let f3 = String(chars[min(third * 2, chars.count)...])
        return [
            .toolCallStarted(index: index, id: id, name: name),
            .toolCallArgumentsDelta(index: index, jsonFragment: f1),
            .toolCallArgumentsDelta(index: index, jsonFragment: f2),
            .toolCallArgumentsDelta(index: index, jsonFragment: f3),
            .usage(TokenUsage(inputTokens: 1200, outputTokens: 80)),
            .finished(reason: .toolCalls),
        ]
    }

    /// 一个"修复退款取整"的完整脚本
    static let fixRefundBug: @Sendable (TurnState) -> [ModelEvent] = { state in
        switch state.round {
        case 0:
            return toolCall(index: 0, id: "c1", name: ToolName.grepSearch,
                            arguments: ["pattern": .string("round(")])
        case 1:
            return toolCall(index: 0, id: "c2", name: ToolName.readFile,
                            arguments: ["path": .string("/workspace/src/money.py")])
        case 2:
            let patchText = """
            *** File: /workspace/src/money.py
            @@ def round_amount
            -    return round(amount)
            +    return round(amount, currency.exponent)
            """
            return toolCall(index: 0, id: "c3", name: ToolName.applyPatch,
                            arguments: ["patch": .string(patchText)])
        case 3:
            return toolCall(index: 0, id: "c4", name: ToolName.runTests, arguments: [:])
        default:
            return [
                .textDelta("已修复：`round_amount` 现在按币种精度取整（`currency.exponent`），测试通过。"),
                .usage(TokenUsage(inputTokens: 800, outputTokens: 40)),
                .finished(reason: .stop),
            ]
        }
    }
}

// MARK: - 公共装配

private enum Fixture {
    static let buggyMoney = """
    from decimal import Decimal


    def round_amount(amount, currency):
        amount = Decimal(amount)
        return round(amount)
    """

    static func workspace() -> FakeWorkspace {
        FakeWorkspace(files: [
            "/workspace/src/money.py": buggyMoney,
            "/workspace/src/orders.py": "def refund(order):\n    return 1\n",
            "/workspace/tests/test_money.py": """
            def test_refund_rounding():
                assert round_amount("10.005", USD) == Decimal("10.00")
            """,
        ])
    }

    static func specs() -> [String: ToolSpec] {
        let empty = JSONSchema.object(properties: [:], required: [], additionalProperties: true)
        return [
            ToolName.grepSearch: ToolSpec(
                name: ToolName.grepSearch, description: "搜索内容", inputSchema: empty,
                riskLevel: .safe, needsApproval: .never, requirements: [.fsRead]
            ),
            ToolName.readFile: ToolSpec(
                name: ToolName.readFile, description: "读文件", inputSchema: empty,
                riskLevel: .safe, needsApproval: .never, requirements: [.fsRead]
            ),
            ToolName.applyPatch: ToolSpec(
                name: ToolName.applyPatch, description: "应用补丁", inputSchema: empty,
                concurrency: .serialPerPath, isIdempotent: true,
                riskLevel: .modifying, needsApproval: .perProject, requirements: [.fsWrite]
            ),
            ToolName.runTests: ToolSpec(
                name: ToolName.runTests, description: "跑测试", inputSchema: empty,
                riskLevel: .safe, needsApproval: .never, requirements: [.exec]
            ),
        ]
    }

    static func config() -> TurnRunner.Config {
        TurnRunner.Config(maxRounds: 8, maxToolCalls: 12, toolRegistry: specs())
    }

    /// 授权范围：整个 workspace 的读写 + 执行
    static func policyContext() -> PolicyEngine.Context {
        let token = CapabilityToken(
            issuedForTurn: UUID(),
            scopes: [
                .fsRead(VFSPath(mount: .workspace)),
                .fsWrite(VFSPath(mount: .workspace)),
                .exec(runtime: .python),
            ],
            expiresAt: Date().addingTimeInterval(3600),
            grantedBy: .planApproval,
            reason: "M0 验收：修复退款取整 bug"
        )
        return PolicyEngine.Context(trustDial: .collaborate, token: token, planApproved: true)
    }

    static func deps(_ workspace: FakeWorkspace) -> TurnRunner.Dependencies {
        TurnRunner.Dependencies(
            modelEvents: ModelScript.fixRefundBug,
            executor: FakeToolExecutor(workspace: workspace),
            policy: PolicyEngine(),
            policyContext: policyContext(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    static func initialState() -> TurnState {
        TurnState(objective: "退款测试失败，找一下原因并修好")
    }
}

// MARK: - ✅ M0 出口验收

@Suite("M0 出口验收 —— 模型自主修复失败单测")
struct M0AcceptanceTests {

    @Test("⚠️【核心验收】模型自主完成「读 → 改 → 跑测试」，并把 bug 修好")
    func agentFixesFailingTest() {
        let workspace = Fixture.workspace()
        let (final, events, approval) = TurnRunner.run(
            Fixture.initialState(), deps: Fixture.deps(workspace), config: Fixture.config()
        )

        // 1. 没有卡在需要用户决策的地方
        #expect(approval == nil, "验收场景不该需要审批（计划已批准）")

        // 2. Turn 正常完成
        #expect(final.status == .completed, "Turn 应以 completed 结束，实际 \(final.status)")

        // 3. **bug 真的被修好了**（这是唯一有意义的断言）
        let money = workspace.read("/workspace/src/money.py") ?? ""
        #expect(money.contains("currency.exponent"), "money.py 应该已被修复")

        // 4. 测试真的通过了（由 run_tests 这个工具自己确认）
        let testResults = events.filter { $0.kind == .toolCallFinished }
            .filter { $0.payload.value(at: ["tool"]) == .string(ToolName.runTests) }
        #expect(testResults.count == 1)
        #expect(testResults[0].payload.value(at: ["status"]) == .string("ok"))

        // 5. 工具调用顺序正确（模型确实按"先看后改"的顺序做）
        let toolOrder = events.filter { $0.kind == .toolCallRequested }
            .compactMap { $0.payload.value(at: ["tool"])?.stringValue }
        #expect(toolOrder == [ToolName.grepSearch, ToolName.readFile, ToolName.applyPatch, ToolName.runTests])

        // 6. 产生了检查点（可回滚）
        #expect(events.contains { $0.kind == .checkpointCreated })
        #expect(final.lastCheckpoint != nil)

        // 7. 事件日志是完整且可校验的哈希链
        #expect(events.allSatisfy { $0.verifyHash() })
        for i in 1..<events.count {
            #expect(events[i].previousHash == events[i - 1].hash, "第 \(i) 条事件的前哈希不匹配")
        }

        // 8. 模型轮次与工具调用计数合理
        #expect(final.round == 5)          // 4 轮工具 + 1 轮收尾
        #expect(final.toolCallCount == 4)
    }

    @Test("最终回答里包含结论（不能只有一串工具调用）")
    func finalMessageIsPresent() throws {
        let workspace = Fixture.workspace()
        let (final, _, _) = TurnRunner.run(
            Fixture.initialState(), deps: Fixture.deps(workspace), config: Fixture.config()
        )
        let lastAssistant = final.messages.last { $0.role == .assistant }
        #expect(lastAssistant?.plainText.contains("currency.exponent") == true)
    }

    @Test("⚠️【崩溃一致性】在任意一步被杀，恢复后的最终文件状态必须与不中断完全一致")
    func crashConsistencyAcrossAllCutPoints() {
        // 基线：不中断跑完
        let baselineWorkspace = Fixture.workspace()
        let (baselineState, _, _) = TurnRunner.run(
            Fixture.initialState(), deps: Fixture.deps(baselineWorkspace), config: Fixture.config()
        )
        let baselineFiles = baselineWorkspace.allFiles()
        let baselinePatchCount = baselineWorkspace.effectivePatches

        #expect(baselineState.status == .completed)
        #expect(baselinePatchCount == 1, "基线应当只改了一次文件")

        // 对**每一个可能的切断点**都试一遍（比随机取样更强的覆盖）
        var totalSteps = 0
        for cut in 0..<40 {
            let ws = Fixture.workspace()
            let deps = Fixture.deps(ws)

            // 第一段：跑 cut 步后"被杀"
            let first = TurnRunner.run(Fixture.initialState(), deps: deps, config: Fixture.config(), maxSteps: cut)
            if first.state.status == .completed { totalSteps = max(totalSteps, cut); break }

            // 第二段：进程重启 → 从持久化状态恢复
            // ⚠️ 必须显式置 wasRestored：只有运行时知道"我刚重启过"，
            //    光看状态无法区分"正常流程的下一步"与"崩溃前留下的中间态"
            var restored = first.state
            restored.wasRestored = true
            let second = TurnRunner.run(restored, deps: Fixture.deps(ws), config: Fixture.config())

            #expect(second.state.status == .completed, "在第 \(cut) 步切断后无法恢复到完成（实际 \(second.state.status)）")
            #expect(ws.allFiles() == baselineFiles, "在第 \(cut) 步切断后，最终文件状态与基线不一致")
            // ⚠️ 副作用不得重复：补丁真正改文件的次数必须与基线一致
            #expect(ws.effectivePatches == baselinePatchCount,
                    "在第 \(cut) 步切断后，补丁被重复应用了（\(ws.effectivePatches) 次 vs 基线 \(baselinePatchCount) 次）")
            totalSteps = max(totalSteps, cut)
        }
        #expect(totalSteps > 5, "切断点覆盖不足（只跑了 \(totalSteps) 步）")
    }

    @Test("⚠️【三步协议】在「已写意图、未写事实」时被杀 → 幂等工具被安全重做")
    func crashBetweenIntentAndFact() {
        let ws = Fixture.workspace()
        let deps = Fixture.deps(ws)

        // 跑到"刚写完 apply_patch 的意图、还没执行"这个瞬间
        var state = Fixture.initialState()
        var sawPendingPatch = false
        for _ in 0..<40 {
            let outcome = TurnRunner.step(state, deps: deps, config: Fixture.config())
            state = outcome.state
            if state.status == .executing,
               state.pendingIntents.contains(where: { $0.call.name == ToolName.applyPatch }) {
                sawPendingPatch = true
                break
            }
            if !state.canAdvance { break }
        }
        #expect(sawPendingPatch, "没有捕捉到「意图已写、尚未执行」的中间态")

        // 此刻被杀：文件还没改，但意图已落盘
        let beforeKill = ws.read("/workspace/src/money.py") ?? ""
        #expect(!beforeKill.contains("currency.exponent"), "这个瞬间文件还不该被改")

        // 恢复（模拟进程重启：运行时显式告知"我刚重启过"）
        state.wasRestored = true
        let resumed = TurnRunner.run(state, deps: Fixture.deps(ws), config: Fixture.config())
        #expect(resumed.state.status == .completed)
        #expect((ws.read("/workspace/src/money.py") ?? "").contains("currency.exponent"))
        #expect(ws.effectivePatches == 1, "幂等工具被重做，但不应产生第二次实际改动")

        // 恢复事件要如实说明发生过什么
        let recovery = resumed.events.first { $0.kind == .turnRecovered }
        #expect(recovery != nil, "恢复时必须留下 turnRecovered 事件")
        #expect(recovery?.payload.value(at: ["action"]) == .string("redo"))
        #expect(resumed.state.recoveryNote?.contains("重做") == true)
    }

    @Test("⚠️【非幂等】结果未知时必须问用户，绝不自动重做")
    func nonIdempotentRecoveryAsksUser() {
        let ws = Fixture.workspace()
        // 造一个"非幂等工具执行中途被杀"的状态：git_push 的意图已落盘
        let pushCall = ToolCall(id: "p1", name: ToolName.gitPush, argumentsJSON: Data("{}".utf8))
        var state = Fixture.initialState()
        state.status = .start
        state.wasRestored = true      // 模拟进程重启
        state.pendingIntents = [
            PendingToolIntent(call: pushCall, isIdempotent: false, riskLevel: .dangerous, stepIndex: 3)
        ]

        let outcome = TurnRunner.step(state, deps: Fixture.deps(ws), config: Fixture.config())

        #expect(outcome.state.status == .awaitingApproval)
        #expect(!outcome.didAdvance)
        let approval = outcome.pendingApproval
        #expect(approval != nil)
        #expect(approval?.reason.contains("是否已经生效无法确定") == true)
        #expect(approval?.reason.contains("不可自动重做") == true)
        #expect(approval?.requirement == .showDetails)
        // 不得擅自执行
        #expect(ws.executions[ToolName.gitPush] == nil)
    }

    @Test("预算：模型轮次上限会终止 Turn 并如实说明")
    func roundBudgetStopsTurn() {
        let ws = Fixture.workspace()
        // 一个永远要求工具调用的模型（模拟跑偏）
        let loopDeps = TurnRunner.Dependencies(
            modelEvents: { _ in
                ModelScript.toolCall(index: 0, id: UUID().uuidString, name: ToolName.grepSearch,
                                     arguments: ["pattern": .string("x")])
            },
            executor: FakeToolExecutor(workspace: ws),
            policy: PolicyEngine(),
            policyContext: Fixture.policyContext(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        var config = Fixture.config()
        config.maxRounds = 3

        let (final, events, _) = TurnRunner.run(Fixture.initialState(), deps: loopDeps, config: config)
        #expect(final.status == .failed)
        #expect(events.contains { $0.kind == .budgetExceeded })
    }

    @Test("工具名幻觉：回灌可执行的修正建议，让模型自己改")
    func unknownToolIsSelfCorrectable() {
        let ws = Fixture.workspace()
        let deps = TurnRunner.Dependencies(
            modelEvents: { state in
                state.round == 0
                    ? ModelScript.toolCall(index: 0, id: "x", name: "read_fil", arguments: ["path": .string("/workspace/src/money.py")])
                    : [.textDelta("改用正确工具名。"), .finished(reason: .stop)]
            },
            executor: FakeToolExecutor(workspace: ws),
            policy: PolicyEngine(),
            policyContext: Fixture.policyContext(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let (final, events, _) = TurnRunner.run(Fixture.initialState(), deps: deps, config: Fixture.config())

        #expect(events.contains { $0.kind == .toolCallDenied })
        // 拒绝理由要进入对话历史，模型下一轮才能看到并改
        let toolMessages = final.messages.filter { $0.role == .tool }
        #expect(toolMessages.contains { $0.plainText.isEmpty && $0.blocks.contains { $0.toolResultValue?.status == .error } })
    }

    @Test("⚠️ 能力令牌范围外的路径 → 被策略拦下（证明路径级授权真的生效）")
    func pathOutsideTokenIsDenied() {
        let ws = Fixture.workspace()
        let narrowToken = CapabilityToken(
            issuedForTurn: UUID(),
            scopes: [.fsRead(VFSPath(mount: .workspace, components: ["tests"]))],   // 只授权 tests/
            expiresAt: Date().addingTimeInterval(3600),
            grantedBy: .planApproval, reason: "只读 tests"
        )
        let deps = TurnRunner.Dependencies(
            modelEvents: { state in
                state.round == 0
                    ? ModelScript.toolCall(index: 0, id: "r1", name: ToolName.readFile,
                                           arguments: ["path": .string("/workspace/src/money.py")])
                    : [.textDelta("读不到，我换个方式。"), .finished(reason: .stop)]
            },
            executor: FakeToolExecutor(workspace: ws),
            policy: PolicyEngine(),
            policyContext: PolicyEngine.Context(trustDial: .collaborate, token: narrowToken, planApproved: true),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let (_, events, _) = TurnRunner.run(Fixture.initialState(), deps: deps, config: Fixture.config())

        #expect(events.contains { $0.kind == .capabilityDenied })
        // 真的没有执行
        #expect(ws.executions[ToolName.readFile] == nil)
    }

    @Test("每一步都是可中断的最小单元（步进语义）")
    func stepsAreAtomic() {
        let ws = Fixture.workspace()
        let deps = Fixture.deps(ws)
        var state = Fixture.initialState()

        // 第一步：只应该是"开始"
        let s1 = TurnRunner.step(state, deps: deps, config: Fixture.config())
        state = s1.state
        #expect(state.status == .reasoning)
        #expect(state.steps.count == 1)
        #expect(state.steps[0].kind == .turnStarted)

        // 第二步：一轮模型调用
        let s2 = TurnRunner.step(state, deps: deps, config: Fixture.config())
        state = s2.state
        #expect(state.status == .dispatching)
        #expect(state.queuedCalls.count == 1)

        // 第三步：写意图（**还没有执行**）
        let s3 = TurnRunner.step(state, deps: deps, config: Fixture.config())
        state = s3.state
        #expect(state.status == .executing)
        #expect(state.pendingIntents.count == 1)
        #expect(ws.executions[ToolName.grepSearch] == nil, "写了意图但尚未执行")

        // 第四步：执行并写事实
        let s4 = TurnRunner.step(state, deps: deps, config: Fixture.config())
        #expect(s4.state.pendingIntents.isEmpty)
        #expect(ws.executions[ToolName.grepSearch] == 1)
    }
}

// MARK: - 模型已选定（`modelSelected`）—— 一个被 `default: break` 丢掉的审计

@Suite("modelSelected —— 模型选择必须留下痕迹")
struct ModelSelectedAuditTests {

    /// 造一个"会报自己是谁"的模型脚本（三家解码器都通过 `startIfNeeded` 发 `.started`）。
    private func modelEvents(_ model: String, provider: String) -> @Sendable (TurnState) -> [ModelEvent] {
        { _ in
            [.started(modelID: model, providerID: provider),
             .textDelta("做完了"),
             .finished(reason: .stop)]
        }
    }

    @Test("⭐⭐ 模型报了身份就必须落一条 modelSelected（否则审计里看不到「调的是哪个模型」）")
    func selectionIsRecorded() {
        let ws = Fixture.workspace()
        let deps = TurnRunner.Dependencies(
            modelEvents: modelEvents("gpt-5.5", provider: "pinai"),
            executor: FakeToolExecutor(workspace: ws),
            policy: PolicyEngine(), policyContext: Fixture.policyContext(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) })

        let (_, events, _) = TurnRunner.run(Fixture.initialState(), deps: deps, config: Fixture.config())
        let selected = events.filter { $0.kind == .modelSelected }
        // ⚠️ 判据是**事件真的落了**（不是"有没有发生过某件事"，那是 T63 的假绿套路）
        #expect(!selected.isEmpty, "必须记录选定了哪个模型 —— 多渠道路由是产品第一条承诺")
        #expect(selected.first?.payload.value(at: ["model"])?.stringValue == "gpt-5.5")
        #expect(selected.first?.payload.value(at: ["provider"])?.stringValue == "pinai")
        #expect(selected.first?.payload.value(at: ["round"])?.intValue == 1)
    }

    @Test("⚠️ 模型没报身份时**不该**记一条空模型名（那比不记更糟）")
    func emptyModelIsNotRecorded() {
        let ws = Fixture.workspace()
        let deps = TurnRunner.Dependencies(
            // 服务端有时不回 model 字段 → 解码器发出空串
            modelEvents: modelEvents("", provider: "pinai"),
            executor: FakeToolExecutor(workspace: ws),
            policy: PolicyEngine(), policyContext: Fixture.policyContext(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) })

        let (_, events, _) = TurnRunner.run(Fixture.initialState(), deps: deps, config: Fixture.config())
        // ⚠️ 记一条 `model: ""` 看起来"记录了"，实际什么也没说明，
        //    还会让人以为模型名就是空的 —— 宁可什么都不记。
        #expect(!events.contains { $0.kind == .modelSelected },
                "空模型名不该产生 modelSelected 事件")
    }

    @Test("⚠️ 多轮时每轮都要记一条（不然看不清中途换过什么）")
    func everyRoundIsRecorded() {
        let ws = Fixture.workspace()
        let deps = TurnRunner.Dependencies(
            // ⚠️ 用 `state.round` 而不是闭包外部的计数器：`modelEvents` 是 `@Sendable`，
            //    Swift 6 不允许在里面改捕获的可变变量（那本来就是数据竞争）。
            //    而且按状态决定"该吐什么"正是这个 API 的设计意图（注释里写着）。
            modelEvents: { state in
                // 第一轮要一个工具调用（迫使进第二轮），之后直接结束
                if state.round == 0 {
                    return [.started(modelID: "gpt-5.5", providerID: "pinai")]
                        + ModelScript.toolCall(index: 0, id: "call-1", name: ToolName.grepSearch,
                                               arguments: ["pattern": .string("x")])
                }
                return [.started(modelID: "gpt-5.5", providerID: "pinai"),
                        .textDelta("好了"), .finished(reason: .stop)]
            },
            executor: FakeToolExecutor(workspace: ws),
            policy: PolicyEngine(), policyContext: Fixture.policyContext(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) })

        let (_, events, _) = TurnRunner.run(Fixture.initialState(), deps: deps, config: Fixture.config())
        let rounds = events.filter { $0.kind == .modelSelected }
            .compactMap { $0.payload.value(at: ["round"])?.intValue }
        #expect(rounds.count >= 2, "跑了两轮就该有两条，实际：\(rounds)")
        #expect(rounds == rounds.sorted(), "轮次应当递增：\(rounds)")
    }
}
