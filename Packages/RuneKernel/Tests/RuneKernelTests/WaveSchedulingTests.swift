import Testing
import Foundation
@testable import RuneKernel

// MARK: - 波次调度的夹具
//
// 这一组测试验证 **M1-3 的核心决策**：
//   * 波次由调度器（M1-1）划分，运行器只负责**边界语义**
//   * **检查点以波次为单位**，而不是每个调用一个（波内调用同时在飞，中间状态从未真实存在）
//   * 一次崩溃可能留下**多个**悬空意图，恢复要按"有没有不可重做的"分流

/// 可记录执行顺序的工作区（用于断言"谁先谁后""有没有重复"）
final class WaveWorkspace: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String]
    private(set) var executionOrder: [String] = []
    private(set) var writes: [String: Int] = [:]

    init(files: [String: String]) { self.files = files }

    func read(_ path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return files[path]
    }

    func write(_ path: String, _ content: String) {
        lock.lock(); defer { lock.unlock() }
        files[path] = content
        writes[path, default: 0] += 1
    }

    func record(_ label: String) {
        lock.lock(); defer { lock.unlock() }
        executionOrder.append(label)
    }

    func allFiles() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return files
    }
}

struct WaveExecutor: ToolExecuting {
    let workspace: WaveWorkspace
    /// 让某个**工具**"执行到一半就崩"（模拟进程被杀）
    let crashOn: String?
    /// 让某个**具体调用**崩溃（用于"波内第 2 个调用挂掉"这类场景）
    let crashOnCallID: String?

    init(workspace: WaveWorkspace, crashOn: String? = nil, crashOnCallID: String? = nil) {
        self.workspace = workspace
        self.crashOn = crashOn
        self.crashOnCallID = crashOnCallID
    }

    struct SimulatedCrash: Error {}

    func execute(_ call: ToolCall) throws -> ToolResult {
        if call.name == crashOn || call.id == crashOnCallID { throw SimulatedCrash() }
        workspace.record(call.name)

        switch call.name {
        case ToolName.readFile:
            let path = (try? call.arguments().value(at: ["path"])?.stringValue) ?? ""
            guard let content = workspace.read(path) else {
                return .failure(callID: call.id, error: ToolError(kind: .pathNotFound, modelFacingMessage: "文件不存在"))
            }
            return .ok(callID: call.id, summary: content)
        case "write_cache":
            let args = try call.arguments()
            let path = args.value(at: ["path"])?.stringValue ?? ""
            workspace.write(path, args.value(at: ["content"])?.stringValue ?? "")
            return .ok(callID: call.id, summary: "已写 \(path)")
        case ToolName.applyPatch:
            let patchText = (try? call.arguments().value(at: ["patch"])?.stringValue) ?? ""
            guard let patch = try? Patch.parse(patchText), let file = patch.files.first else {
                return .failure(callID: call.id, error: ToolError(kind: .invalidArguments, modelFacingMessage: "补丁不合法"))
            }
            let path = file.path.description
            if let current = workspace.read(path) {
                let adds = file.hunks.flatMap { $0.lines.filter(\.isAdd).map(\.text) }
                let removes = file.hunks.flatMap { $0.lines.filter(\.isRemove).map(\.text) }
                if !adds.isEmpty, adds.allSatisfy({ current.contains($0) }), removes.allSatisfy({ !current.contains($0) }) {
                    return .ok(callID: call.id, summary: "已应用过（跳过）")
                }
            }
            guard let applied = try? patch.apply(reader: { p in workspace.read(p.description) }),
                  let change = applied.changes.first, let newContent = change.newContent else {
                return .failure(callID: call.id, error: ToolError(kind: .other, modelFacingMessage: "补丁无法应用"))
            }
            workspace.write(path, newContent)
            return .ok(callID: call.id, summary: "已修改 \(path)")
        default:
            return .ok(callID: call.id, summary: "ok")
        }
    }
}

/// 一轮里产出**多个**工具调用（分片交错，顺便压一遍拼装器）
func multiCallEvents(_ calls: [(id: String, name: String, args: JSONValue)]) -> [ModelEvent] {
    var events: [ModelEvent] = []
    var fragments: [Int: [String]] = [:]

    for (index, call) in calls.enumerated() {
        let json = call.args.canonicalString()
        let chars = Array(json)
        let third = max(1, chars.count / 3)
        fragments[index] = [
            String(chars[0..<min(third, chars.count)]),
            String(chars[min(third, chars.count)..<min(third * 2, chars.count)]),
            String(chars[min(third * 2, chars.count)...]),
        ]
        events.append(.toolCallStarted(index: index, id: call.id, name: call.name))
    }
    // 交错下发分片
    for round in 0..<3 {
        for index in calls.indices {
            events.append(.toolCallArgumentsDelta(index: index, jsonFragment: fragments[index]![round]))
        }
    }
    events.append(.usage(TokenUsage(inputTokens: 500, outputTokens: 50)))
    events.append(.finished(reason: .toolCalls))
    return events
}

private enum WaveFixture {
    static func workspace() -> WaveWorkspace {
        WaveWorkspace(files: [
            "/workspace/src/a.py": "def a():\n    return 1\n",
            "/workspace/src/b.py": "def b():\n    return 2\n",
            "/workspace/src/c.py": "def c():\n    return 3\n",
        ])
    }

    static func specs() -> [String: ToolSpec] {
        let empty = JSONSchema.object(properties: [:], required: [], additionalProperties: true)
        return [
            ToolName.readFile: ToolSpec(
                name: ToolName.readFile, description: "读", inputSchema: empty,
                riskLevel: .safe, needsApproval: .never, requirements: [.fsRead]
            ),
            "write_cache": ToolSpec(
                name: "write_cache", description: "写缓存", inputSchema: empty,
                concurrency: .parallelSafe, riskLevel: .modifying,
                needsApproval: .never, requirements: [.fsWrite]
            ),
            ToolName.applyPatch: ToolSpec(
                name: ToolName.applyPatch, description: "补丁", inputSchema: empty,
                concurrency: .serialPerPath, riskLevel: .modifying,
                needsApproval: .perProject, requirements: [.fsWrite]
            ),
            ToolName.runTests: ToolSpec(
                name: ToolName.runTests, description: "测试", inputSchema: empty,
                riskLevel: .safe, needsApproval: .never, requirements: [.exec]
            ),
            ToolName.gitPush: ToolSpec(
                name: ToolName.gitPush, description: "推送", inputSchema: empty,
                concurrency: .serialPerPath, isIdempotent: false,
                riskLevel: .dangerous, needsApproval: .always, requirements: [.gitWrite]
            ),
        ]
    }

    static func config(maxToolCalls: Int = 24) -> TurnRunner.Config {
        TurnRunner.Config(maxRounds: 6, maxToolCalls: maxToolCalls, toolRegistry: specs())
    }

    /// 授权：整个 workspace（可写）。可选缩小范围以测试多路径判定。
    static func context(narrowTo prefix: String? = nil) -> PolicyEngine.Context {
        let scope = prefix.map { VFSPath(mount: .workspace, components: $0.split(separator: "/").map(String.init)) }
            ?? VFSPath(mount: .workspace)
        let token = CapabilityToken(
            issuedForTurn: UUID(),
            scopes: [.fsRead(scope), .fsWrite(scope), .exec(runtime: .python), .gitWrite(remote: nil)],
            expiresAt: Date().addingTimeInterval(3600),
            grantedBy: .planApproval, reason: "测试"
        )
        return PolicyEngine.Context(trustDial: .collaborate, token: token, planApproved: true)
    }

    static func deps(
        _ workspace: WaveWorkspace,
        script: @escaping @Sendable (TurnState) -> [ModelEvent],
        overrideContext: PolicyEngine.Context? = nil,
        crashOn: String? = nil
    ) -> TurnRunner.Dependencies {
        TurnRunner.Dependencies(
            modelEvents: script,
            executor: WaveExecutor(workspace: workspace, crashOn: crashOn),
            policy: PolicyEngine(),
            policyContext: overrideContext ?? Self.context(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }
}

// MARK: - 波次调度

@Suite("M1-3 波次调度 —— 边界语义")
struct WaveSchedulingTests {

    @Test("一轮里的 3 个只读调用 → 1 个波次、3 个调用（可并行）")
    func readOnlyRoundFormsOneWave() {
        let ws = WaveFixture.workspace()
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            state.round == 0
                ? multiCallEvents([
                    (id: "c1", name: ToolName.readFile, args: ["path": .string("/workspace/src/a.py")]),
                    (id: "c2", name: ToolName.readFile, args: ["path": .string("/workspace/src/b.py")]),
                    (id: "c3", name: ToolName.readFile, args: ["path": .string("/workspace/src/c.py")]),
                ])
                : [.textDelta("读完了。"), .finished(reason: .stop)]
        }
        let (final, events, _) = TurnRunner.run(
            TurnState(objective: "读三个文件"), deps: WaveFixture.deps(ws, script: script), config: WaveFixture.config()
        )

        #expect(final.status == .completed)
        let waveEvents = events.filter { $0.payload.value(at: ["phase"]) == .string("wave") }
        #expect(waveEvents.count == 1, "三个只读调用应该合成 1 个波次")
        #expect(waveEvents[0].payload.value(at: ["size"]) == .int(3))
        #expect(waveEvents[0].payload.value(at: ["parallel"]) == .bool(true))
        #expect(final.toolCallCount == 3)
    }

    @Test("⚠️ 一轮里「跑测试 + 改文件」→ 拆成 2 个波次（防止测试读到半成品）")
    func execAndWriteSplitIntoTwoWaves() {
        let ws = WaveFixture.workspace()
        let patch = """
        *** File: /workspace/src/a.py
        @@
        -    return 1
        +    return 100
        """
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            state.round == 0
                ? multiCallEvents([
                    (id: "t1", name: ToolName.runTests, args: [:]),
                    (id: "p1", name: ToolName.applyPatch, args: ["patch": .string(patch)]),
                ])
                : [.textDelta("done"), .finished(reason: .stop)]
        }
        let (final, events, _) = TurnRunner.run(
            TurnState(objective: "测试与改文件"), deps: WaveFixture.deps(ws, script: script), config: WaveFixture.config()
        )

        #expect(final.status == .completed)
        let waveEvents = events.filter { $0.payload.value(at: ["phase"]) == .string("wave") }
        #expect(waveEvents.count == 2, "执行类与写操作必须分成两波")
        #expect(waveEvents.allSatisfy { $0.payload.value(at: ["size"]) == .int(1) })
    }

    @Test("⚠️【核心决策】多个写调用在同一波 → **只打一个检查点**（不是每个调用一个）")
    func oneCheckpointPerWave() {
        let ws = WaveFixture.workspace()
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            state.round == 0
                ? multiCallEvents([
                    (id: "w1", name: "write_cache", args: ["path": .string("/workspace/cache/1.bin"), "content": .string("1")]),
                    (id: "w2", name: "write_cache", args: ["path": .string("/workspace/cache/2.bin"), "content": .string("2")]),
                    (id: "w3", name: "write_cache", args: ["path": .string("/workspace/cache/3.bin"), "content": .string("3")]),
                ])
                : [.textDelta("done"), .finished(reason: .stop)]
        }
        let (final, events, _) = TurnRunner.run(
            TurnState(objective: "写三个缓存"), deps: WaveFixture.deps(ws, script: script), config: WaveFixture.config()
        )

        #expect(final.status == .completed)
        let checkpoints = events.filter { $0.kind == .checkpointCreated }
        #expect(checkpoints.count == 1, "一波只应产生一个检查点，实际 \(checkpoints.count)")
        // 三个文件都真的被写了
        #expect(ws.read("/workspace/cache/1.bin") == "1")
        #expect(ws.read("/workspace/cache/3.bin") == "3")
        // 检查点标签应体现"这是一波"
        #expect(final.lastCheckpoint?.label.contains("第 1 波") == true)
    }

    @Test("全只读波次不打检查点（没有东西需要回滚）")
    func readOnlyWaveHasNoCheckpoint() {
        let ws = WaveFixture.workspace()
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            state.round == 0
                ? multiCallEvents([
                    (id: "c1", name: ToolName.readFile, args: ["path": .string("/workspace/src/a.py")]),
                    (id: "c2", name: ToolName.readFile, args: ["path": .string("/workspace/src/b.py")]),
                ])
                : [.textDelta("done"), .finished(reason: .stop)]
        }
        let (final, events, _) = TurnRunner.run(
            TurnState(objective: "只读"), deps: WaveFixture.deps(ws, script: script), config: WaveFixture.config()
        )
        #expect(final.status == .completed)
        #expect(!events.contains { $0.kind == .checkpointCreated })
        #expect(final.lastCheckpoint == nil)
    }

    @Test("波内调用按模型给出的顺序逐个写意图（顺序不重排）")
    func wavePreservesOrder() {
        let ws = WaveFixture.workspace()
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            state.round == 0
                ? multiCallEvents([
                    (id: "c1", name: ToolName.readFile, args: ["path": .string("/workspace/src/a.py")]),
                    (id: "c2", name: ToolName.readFile, args: ["path": .string("/workspace/src/b.py")]),
                ])
                : [.textDelta("done"), .finished(reason: .stop)]
        }
        let (_, events, _) = TurnRunner.run(
            TurnState(objective: "顺序"), deps: WaveFixture.deps(ws, script: script), config: WaveFixture.config()
        )
        let requested = events.filter { $0.kind == .toolCallRequested }
            .compactMap { $0.payload.value(at: ["id"])?.stringValue }
        #expect(requested == ["c1", "c2"])
    }

    @Test("事件里带波次信息（供 UI 显示「第 2 批 · 3 个并行中」）")
    func eventsCarryWaveInfo() {
        let ws = WaveFixture.workspace()
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            state.round == 0
                ? multiCallEvents([
                    (id: "c1", name: ToolName.readFile, args: ["path": .string("/workspace/src/a.py")]),
                    (id: "c2", name: ToolName.readFile, args: ["path": .string("/workspace/src/b.py")]),
                ])
                : [.textDelta("done"), .finished(reason: .stop)]
        }
        let (_, events, _) = TurnRunner.run(
            TurnState(objective: "波次信息"), deps: WaveFixture.deps(ws, script: script), config: WaveFixture.config()
        )
        let requested = events.filter { $0.kind == .toolCallRequested }
        #expect(requested.allSatisfy { $0.payload.value(at: ["wave"]) == .int(1) })
        #expect(requested.allSatisfy { $0.payload.value(at: ["waveSize"]) == .int(2) })
    }
}

// MARK: - 多路径授权

@Suite("M1-3 多路径授权 —— 全部路径都要检查")
struct MultiPathPolicyTests {

    @Test("⚠️ 多文件补丁里**第二个**文件越权 → 整次调用被拒（不能只看第一个）")
    func secondPathOutOfScopeDenies() {
        let ws = WaveFixture.workspace()
        // 只授权 /workspace/src/a.py 所在目录…… 这里刻意只授权到 /workspace/src（含 a、b）
        // 要制造越权：补丁改 build/ 下的文件
        let patch = """
        *** File: /workspace/src/a.py
        @@
        -    return 1
        +    return 100
        *** File: /workspace/secret/keys.py
        @@
        +LEAKED = True
        """
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            state.round == 0
                ? multiCallEvents([(id: "p1", name: ToolName.applyPatch, args: ["patch": .string(patch)])])
                : [.textDelta("被拒了"), .finished(reason: .stop)]
        }
        // 只授权 src/ 目录
        let ctx = WaveFixture.context(narrowTo: "src")
        let (_, events, _) = TurnRunner.run(
            TurnState(objective: "越权补丁"), deps: WaveFixture.deps(ws, script: script, overrideContext: ctx),
            config: WaveFixture.config()
        )

        #expect(events.contains { $0.kind == .capabilityDenied }, "第二个文件越权必须导致整次调用被拒")
        // 确实一点都没改
        #expect(ws.read("/workspace/src/a.py")?.contains("return 1") == true)
        #expect(ws.read("/workspace/secret/keys.py") == nil)
    }

    @Test("全部路径都在授权范围内 → 放行")
    func allPathsInScopeAllows() {
        let ws = WaveFixture.workspace()
        let patch = """
        *** File: /workspace/src/a.py
        @@
        -    return 1
        +    return 100
        """
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            state.round == 0
                ? multiCallEvents([(id: "p1", name: ToolName.applyPatch, args: ["patch": .string(patch)])])
                : [.textDelta("done"), .finished(reason: .stop)]
        }
        let (final, _, _) = TurnRunner.run(
            TurnState(objective: "正常补丁"), deps: WaveFixture.deps(ws, script: script), config: WaveFixture.config()
        )
        #expect(final.status == .completed)
        #expect(ws.read("/workspace/src/a.py")?.contains("return 100") == true)
    }
}

// MARK: - 多悬空意图的恢复

@Suite("M1-3 多悬空意图恢复 —— 一次崩溃可能留下整批")
struct MultiIntentRecoveryTests {

    private func twoIntentState(idempotent: (Bool, Bool)) -> TurnState {
        var state = TurnState(objective: "两个写操作")
        state.status = .executing
        state.wasRestored = true
        let c1 = ToolCall(id: "w1", name: "write_cache",
                          argumentsJSON: Data(#"{"path":"/workspace/cache/1.bin","content":"1"}"#.utf8))
        let c2 = ToolCall(id: "w2", name: "write_cache",
                          argumentsJSON: Data(#"{"path":"/workspace/cache/2.bin","content":"2"}"#.utf8))
        state.pendingIntents = [
            PendingToolIntent(call: c1, isIdempotent: idempotent.0, riskLevel: .modifying, stepIndex: 1),
            PendingToolIntent(call: c2, isIdempotent: idempotent.1, riskLevel: .modifying, stepIndex: 2),
        ]
        state.waveCalls = [c1, c2]
        state.waveIndex = 1
        return state
    }

    @Test("⚠️ 全部幂等 → 自动重做全部（一次恢复搞定整批）")
    func allIdempotentRedone() {
        let ws = WaveFixture.workspace()
        let deps = WaveFixture.deps(ws, script: { _ in [.textDelta("done"), .finished(reason: .stop)] })

        let outcome = TurnRunner.step(twoIntentState(idempotent: (true, true)), deps: deps, config: WaveFixture.config())
        #expect(outcome.state.status == .executing)
        #expect(outcome.state.recoveryNote?.contains("已自动重做") == true)

        let recovery = outcome.newEvents.first { $0.kind == .turnRecovered }
        #expect(recovery?.payload.value(at: ["action"]) == .string("redo"))
        #expect(recovery?.payload.value(at: ["count"]) == .int(2))

        // 继续跑完，两个文件都该被写
        let (final, _, _) = TurnRunner.run(outcome.state, deps: deps, config: WaveFixture.config())
        #expect(final.status == .completed)
        #expect(ws.read("/workspace/cache/1.bin") == "1")
        #expect(ws.read("/workspace/cache/2.bin") == "2")
    }

    @Test("⚠️ 其中任一个不可重做 → 整批都要问用户（不能先把能做的做了）")
    func anyNonIdempotentAsksUser() {
        let ws = WaveFixture.workspace()
        let deps = WaveFixture.deps(ws, script: { _ in [.textDelta("done"), .finished(reason: .stop)] })

        let outcome = TurnRunner.step(twoIntentState(idempotent: (true, false)), deps: deps, config: WaveFixture.config())

        #expect(outcome.state.status == .awaitingApproval)
        #expect(!outcome.didAdvance)
        let approval = outcome.pendingApproval
        #expect(approval != nil)
        #expect(approval?.reason.contains("2 个操作") == true)
        #expect(approval?.reason.contains("1 个不可自动重做") == true)
        // **一个都不许执行**
        #expect(ws.read("/workspace/cache/1.bin") == nil)
        #expect(ws.read("/workspace/cache/2.bin") == nil)
    }

    @Test("崩在波内第 2 个调用上 → 第 1 个成功、第 2 个失败，波次仍走完")
    func crashOnSecondCallOfWave() {
        let ws = WaveFixture.workspace()
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            state.round == 0
                ? multiCallEvents([
                    (id: "w1", name: "write_cache", args: ["path": .string("/workspace/cache/1.bin"), "content": .string("1")]),
                    (id: "w2", name: "write_cache", args: ["path": .string("/workspace/cache/2.bin"), "content": .string("2")]),
                ])
                : [.textDelta("done"), .finished(reason: .stop)]
        }
        let deps = TurnRunner.Dependencies(
            modelEvents: script,
            executor: WaveExecutor(workspace: ws, crashOnCallID: "w2"),
            policy: PolicyEngine(),
            policyContext: WaveFixture.context(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let (final, events, _) = TurnRunner.run(
            TurnState(objective: "第 2 个调用崩"), deps: deps, config: WaveFixture.config()
        )

        #expect(final.status == .completed)
        // w1 成功、w2 失败 → 只有 1 个文件被写
        #expect(ws.read("/workspace/cache/1.bin") == "1")
        #expect(ws.read("/workspace/cache/2.bin") == nil)
        // 两个调用都被记入事实（一个 ok 一个 error）—— 三步协议要求"写事实"必须发生
        let finished = events.filter { $0.kind == .toolCallFinished }
        #expect(finished.count == 2)
        #expect(finished.contains { $0.payload.value(at: ["status"]) == .string("error") })
    }

    @Test("恢复时留下的步骤与事件要如实说明发生了什么")
    func recoveryIsAuditable() {
        let ws = WaveFixture.workspace()
        let deps = WaveFixture.deps(ws, script: { _ in [.textDelta("done"), .finished(reason: .stop)] })
        let outcome = TurnRunner.step(twoIntentState(idempotent: (true, true)), deps: deps, config: WaveFixture.config())

        let recoveredSteps = outcome.state.steps.filter { $0.kind == .recovered }
        #expect(recoveredSteps.count == 1)
        #expect(recoveredSteps[0].summary.contains("2 个幂等调用"))
        // 事件也要带上是哪些工具
        let recovery = outcome.newEvents.first { $0.kind == .turnRecovered }
        let tools = recovery?.payload.value(at: ["tools"])?.arrayValue?.compactMap(\.stringValue)
        #expect(tools?.count == 2)
    }
}

// MARK: - 波次下的崩溃一致性（回归 M0 的验收标准）

@Suite("M1-3 波次下的崩溃一致性")
struct WaveCrashConsistencyTests {

    @Test("⚠️ 多调用轮次下，任意切断点恢复后最终状态仍与基线一致")
    func crashConsistencyWithMultiCallRounds() {
        let patch = """
        *** File: /workspace/src/a.py
        @@
        -    return 1
        +    return 100
        """
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            switch state.round {
            case 0:   // 一轮里两个只读
                return multiCallEvents([
                    (id: "r1", name: ToolName.readFile, args: ["path": .string("/workspace/src/a.py")]),
                    (id: "r2", name: ToolName.readFile, args: ["path": .string("/workspace/src/b.py")]),
                ])
            case 1:   // 一轮里两个写（不同路径 → 同一波，可并行）
                return multiCallEvents([
                    (id: "w1", name: "write_cache", args: ["path": .string("/workspace/cache/1.bin"), "content": .string("1")]),
                    (id: "w2", name: "write_cache", args: ["path": .string("/workspace/cache/2.bin"), "content": .string("2")]),
                ])
            case 2:   // 补丁
                return multiCallEvents([(id: "p1", name: ToolName.applyPatch, args: ["patch": .string(patch)])])
            default:
                return [.textDelta("done"), .finished(reason: .stop)]
            }
        }

        // 基线
        let baselineWS = WaveFixture.workspace()
        let (baselineState, _, _) = TurnRunner.run(
            TurnState(objective: "多调用轮次"), deps: WaveFixture.deps(baselineWS, script: script),
            config: WaveFixture.config()
        )
        let baselineFiles = baselineWS.allFiles()
        #expect(baselineState.status == .completed)

        // 遍历每一个切断点
        var reachedCompletion = 0
        for cut in 0..<40 {
            let ws = WaveFixture.workspace()
            let first = TurnRunner.run(
                TurnState(objective: "多调用轮次"), deps: WaveFixture.deps(ws, script: script),
                config: WaveFixture.config(), maxSteps: cut
            )
            if first.state.status == .completed { reachedCompletion = cut; break }

            var restored = first.state
            restored.wasRestored = true
            let second = TurnRunner.run(restored, deps: WaveFixture.deps(ws, script: script), config: WaveFixture.config())

            #expect(second.state.status == .completed, "第 \(cut) 步切断后未能恢复完成")
            #expect(ws.allFiles() == baselineFiles, "第 \(cut) 步切断后最终文件状态与基线不一致")
        }
        #expect(reachedCompletion > 5, "切断点覆盖不足")
    }
}


