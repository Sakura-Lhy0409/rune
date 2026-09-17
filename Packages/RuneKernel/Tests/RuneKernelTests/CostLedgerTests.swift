import Testing
import Foundation
@testable import RuneKernel

// MARK: - 成本账本与熔断（M1-18）
//
// 这一组测的是**用户的钱**。它守的问题很具体：
//
//   在 M1-17 之前，`Config.maxCostMicroUSD` 声明了、有默认值、**从来没被读过**；
//   `Dependencies.costOfRound` 声明了、能注入、**从来没被调用过**；
//   `TurnStatus.pausedBudget` 是一个**永远到不了的状态**；
//   `BudgetWarning` / `TurnPaused` / `TurnResumed` 三个事件**从来没被发出过**。
//
// 也就是说：界面上写着"上限 $0.30"，而那一行代码对行为没有任何影响。
// 这是最坏的一类失败 —— 保护**看起来在**，其实不在。用户只会在账单上发现。

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

/// 记账用的假价格表：一万 token 一微美元，也就是 $1 / 10M token。
/// 用这么小的数是为了让测试里的钱一眼能算出来。
private let oneMicroPer10k: @Sendable (TokenUsage) -> CostBreakdown = { usage in
    let billable = usage.inputTokens + usage.outputTokens
    let micro = billable / 10_000
    return CostBreakdown(usage: usage, microUSD: micro, providerID: "fake", modelID: "fake")
}

/// 一个"永远想再调一次工具"的模型：用来观察"熔断之后它还会不会被叫到"
private func chattyModel(counter: ModelCallCounter) -> @Sendable (TurnState) -> [ModelEvent] {
    { state in
        counter.increment()
        return [
            .toolCallStarted(index: 0, id: "c\(state.round)", name: ToolName.readFile),
            .toolCallArgumentsDelta(index: 0, jsonFragment: #"{"path":"/workspace/notes.md"}"#),
            .usage(TokenUsage(inputTokens: 20_000, outputTokens: 10_000)),
            .finished(reason: .toolCalls),
        ]
    }
}

/// 数模型被调用了几次。**这就是"钱还会不会继续花"的探针。**
private final class ModelCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private func readOnlySpecs() -> [String: ToolSpec] {
    let empty = JSONSchema.object(properties: [:], required: [], additionalProperties: true)
    return [
        ToolName.readFile: ToolSpec(
            name: ToolName.readFile, description: "读文件", inputSchema: empty,
            pathParameters: ["path"],
            riskLevel: .safe, needsApproval: .never, requirements: [.fsRead]
        ),
    ]
}

/// 授权范围：整个 workspace 的读 —— 让这一组测试专心测钱，不要被审批拦住
private func costPolicyContext() -> PolicyEngine.Context {
    let token = CapabilityToken(
        issuedForTurn: UUID(),
        scopes: [.fsRead(VFSPath(mount: .workspace))],
        expiresAt: t0.addingTimeInterval(3600),
        grantedBy: .planApproval,
        reason: "成本熔断测试"
    )
    return PolicyEngine.Context(trustDial: .collaborate, token: token, planApproved: true)
}

private func costDeps(counter: ModelCallCounter,
                      cost: @escaping @Sendable (TokenUsage) -> CostBreakdown = oneMicroPer10k) -> TurnRunner.Dependencies {
    TurnRunner.Dependencies(
        modelEvents: chattyModel(counter: counter),
        executor: StubReader(),
        policy: PolicyEngine(),
        policyContext: costPolicyContext(),
        now: { t0 },
        costOfRound: cost
    )
}

/// 一个只会返回固定内容的读工具
private struct StubReader: ToolExecuting {
    func execute(_ call: ToolCall) throws -> ToolResult {
        .ok(callID: call.id, summary: "notes.md 的内容")
    }
}

private func costConfig(ceiling: Int) -> TurnRunner.Config {
    TurnRunner.Config(maxRounds: 20, maxToolCalls: 40,
                      maxCostMicroUSD: ceiling, toolRegistry: readOnlySpecs())
}

@Suite("成本账本 —— 每一轮都要落账")

struct CostLedgerTests {

    @Test("⭐ 模型报的用量会换算成钱并累加进状态")
    func usageBecomesMoney() {
        let counter = ModelCallCounter()
        var config = costConfig(ceiling: 0)
        config.maxRounds = 3
        let (state, _, _) = TurnRunner.run(TurnState(objective: "读一下 notes"),
                                           deps: costDeps(counter: counter), config: config)

        // 每轮 20k + 10k = 30k token；一万 token 一微美元 → 每轮 3 微美元，三轮 9
        #expect(counter.count == 3, "跑了 3 轮模型")
        #expect(state.spentMicroUSD == 9, "三轮应当记 9 微美元，实际 \(state.spentMicroUSD)")
        #expect(state.usage.inputTokens == 60_000, "用量也要累加（它是账单的另一半）")
        #expect(state.usage.outputTokens == 30_000)
        #expect(state.spentMicroUSD == oneMicroPer10k(state.usage).microUSD,
                "账本必须等于「用量 × 价格」—— 两个数字对不上就是记账出了错")
    }

    @Test("⭐ 每一轮都落成事件（否则崩溃后账本归零，上限就再也拦不住）")
    func everyRoundIsLogged() {
        let counter = ModelCallCounter()
        var config = costConfig(ceiling: 0)
        config.maxRounds = 2
        let (_, events, _) = TurnRunner.run(TurnState(objective: "读一下 notes"),
                                            deps: costDeps(counter: counter), config: config)
        let cost = events.filter { $0.kind == .costRecorded }
        #expect(cost.count == 2, "两轮两笔账")
        // 每一笔都要带上"这一轮多少"与"累计多少"——UI 的实时花费显示靠它
        #expect(cost.map { $0.payload.value(at: ["micro_usd"]) } == [.int(3), .int(3)])
        #expect(cost.map { $0.payload.value(at: ["total_micro_usd"]) } == [.int(3), .int(6)])
    }

    @Test("⭐ 账本能从事件日志**重建**（增量投影 == 全量重放）")
    func ledgerIsRebuildableFromLog() {
        let counter = ModelCallCounter()
        let deps = costDeps(counter: counter)
        var config = costConfig(ceiling: 0)
        config.maxRounds = 3

        var state = TurnState(objective: "读一下 notes")
        var events: [RuntimeEvent] = []
        while state.canAdvance, state.round < 12 {
            let outcome = TurnRunner.step(state, deps: deps, config: config)
            state = outcome.state
            events.append(contentsOf: outcome.newEvents)
        }
        #expect(state.spentMicroUSD > 0)

        // 事件流本身就是一条合法的哈希链（序号与 previousHash 都由运行时维护）
        var log = EventLog(sessionID: state.sessionID, now: { t0 })
        log.loadHistorical(events)
        #expect(log.verify(full: true).isOK, "事件链应当是完整的")

        let projection = EventProjector.project(events, sessionID: state.sessionID)
        let turn = projection.turnList.first { $0.id == state.turnID }
        #expect(turn?.costMicroUSD == state.spentMicroUSD,
                "投影出的钱 \(turn?.costMicroUSD ?? -1) 应当等于状态里的 \(state.spentMicroUSD)")
        #expect(turn?.inputTokens == state.usage.inputTokens)
        #expect(turn?.outputTokens == state.usage.outputTokens)
    }

    @Test("零成本时**不写账**（免得日志里全是 0，把真正的花钱淹没）")
    func zeroCostWritesNothing() {
        let counter = ModelCallCounter()
        let deps = costDeps(counter: counter, cost: { usage in
            CostBreakdown(usage: usage, microUSD: 0, providerID: "mock", modelID: "mock")
        })
        var config = costConfig(ceiling: 0)
        config.maxRounds = 2
        let (state, events, _) = TurnRunner.run(TurnState(objective: "x"), deps: deps, config: config)
        #expect(counter.count == 2, "模型确实被调了两轮")
        #expect(events.filter { $0.kind == .costRecorded }.isEmpty)
        #expect(state.spentMicroUSD == 0)
    }
}

@Suite("成本熔断 —— 上限真的会拦住钱")

struct CostBreakerTests {

    @Test("⭐⭐ 超上限后**模型不再被调用**（这是「熔断」与「账单」的区别）")
    func ceilingStopsTheMoney() {
        let counter = ModelCallCounter()
        // 每轮 3 微美元，上限 7 → 第 3 轮开始前（已花 6 ≤ 7 可以跑，跑完变 9）
        // → 第 4 轮开始前 9 > 7 → 停
        let config = costConfig(ceiling: 7)
        let deps = costDeps(counter: counter)

        let (state, _, _) = TurnRunner.run(TurnState(objective: "一直读下去"), deps: deps, config: config)

        #expect(state.status == .pausedBudget, "应当是「预算暂停」而不是「失败」：实际 \(state.status)")
        #expect(state.spentMicroUSD == 9)
        // ⚠️ 关键断言：模型只被叫了 3 次。若熔断在"烧完之后"才检查，这里会是 4 次 —— 而多出来的那次
        //    是**真的花了钱**的。这条断言就是"停在花钱之前"的证明。
        #expect(counter.count == 3, "熔断后不该再调模型，实际调了 \(counter.count) 次")
    }

    @Test("⭐ 停下时给的是**可执行的选项**，不是一句「超预算了」")
    func stopCarriesActionableOptions() {
        let counter = ModelCallCounter()
        let (state, events, _) = TurnRunner.run(TurnState(objective: "一直读下去"),
                                                deps: costDeps(counter: counter), config: costConfig(ceiling: 7))

        let stop = state.budgetStop
        #expect(stop != nil)
        #expect(stop?.spentMicroUSD == 9)
        #expect(stop?.ceilingMicroUSD == 7)
        #expect(stop?.options.contains { if case .raiseLimit = $0 { return true }; return false } == true)
        #expect(stop?.options.contains { if case .deliverSoFar = $0 { return true }; return false } == true)

        // 金额必须能被用户看懂（整数微美元只在显示时变小数）
        let text = stop?.userFacingText ?? ""
        #expect(text.contains("$0.000009") || text.contains("0.0000"), "要写出花了多少：\(text)")
        #expect(text.contains("上限"))

        // 事件里也要带上数字，否则 UI 只能靠猜
        let exceeded = events.last { $0.kind == .budgetExceeded }
        #expect(exceeded?.payload.value(at: ["spent_micro_usd"]) == .int(9))
        #expect(exceeded?.payload.value(at: ["ceiling_micro_usd"]) == .int(7))
        // 并且**同时**发 turnPaused（这个事件以前从没被发出过）
        #expect(events.contains { $0.kind == .turnPaused })
    }

    @Test("⭐ 快到上限时先提醒一次（判据是「再跑一轮就超」，不是拍脑袋的比例）")
    func warnsWhenOneMoreRoundWouldExceed() {
        let counter = ModelCallCounter()
        // 每轮 3：上限 10 → 花到 9 时，再跑一轮(3)就会超 → 该提醒
        let (state, events, _) = TurnRunner.run(TurnState(objective: "一直读下去"),
                                                deps: costDeps(counter: counter), config: costConfig(ceiling: 10))
        let warnings = events.filter { $0.kind == .budgetWarning }
        #expect(warnings.count == 1, "只提醒一次，实际 \(warnings.count) 次 —— 反复提醒等于没提醒")
        #expect(warnings.first?.payload.value(at: ["reason"]) == .string("再跑一轮就会超过上限"))
        #expect(state.budgetWarningEmitted)
    }

    @Test("⚠️ 上限设成 0 或负数 = **不限**（而不是「一分钱都不许花」）")
    func zeroCeilingMeansUnlimited() {
        let counter = ModelCallCounter()
        let (state, _, _) = TurnRunner.run(TurnState(objective: "读一下"),
                                           deps: costDeps(counter: counter), config: costConfig(ceiling: 0))
        #expect(state.status != .pausedBudget, "0 不该被当成上限 0")
        #expect(state.spentMicroUSD > 0, "钱照花，只是不拦")
    }

    @Test("⚠️ 恰好花到上限**不算超**（用户设 $0.30 就该能用满 $0.30）")
    func exactlyAtCeilingIsAllowed() {
        let counter = ModelCallCounter()
        // 每轮 3，上限 6：第三轮开始前已花 6，不超 → 可以跑；跑完 9 → 第四轮前停
        let (state, _, _) = TurnRunner.run(TurnState(objective: "读一下"),
                                           deps: costDeps(counter: counter), config: costConfig(ceiling: 6))
        #expect(counter.count == 3, "恰好等于上限时那一轮应当照跑，实际调了 \(counter.count) 次")
        #expect(state.spentMicroUSD == 9)
    }

    @Test("⭐⭐ 用户「提高上限」之后能继续，且**卡片不会再弹**（同 T30 那类死循环）")
    func raisingTheLimitResumes() {
        let counter = ModelCallCounter()
        let config = costConfig(ceiling: 7)
        let deps = costDeps(counter: counter)
        let (paused, _, _) = TurnRunner.run(TurnState(objective: "一直读下去"), deps: deps, config: config)
        #expect(paused.status == .pausedBudget)
        let callsBefore = counter.count

        // 用户点"再给一个额度"
        let raised = TurnRunner.raiseBudget(paused, to: 30, deps: deps, config: config)
        #expect(raised.didAdvance)
        #expect(raised.state.status == .reasoning, "应当回到可推进态")
        #expect(raised.state.costCeilingMicroUSD == 30)
        #expect(raised.state.budgetStop == nil)
        #expect(raised.newEvents.contains { $0.kind == .turnResumed })

        // ⚠️ 这条是死循环的回归测试：配置里还是 7，如果上限读的是 config 而不是状态，
        //    下一步会立刻再次判"超预算"，卡片无限弹、按钮看起来是坏的。
        let (again, _, _) = TurnRunner.run(raised.state, deps: deps, config: config)
        #expect(again.spentMicroUSD > paused.spentMicroUSD, "提高上限后必须真的继续花钱")
        #expect(counter.count > callsBefore, "模型必须被继续调用")
        #expect(again.status == .pausedBudget ? (again.spentMicroUSD > 30) : true,
                "若再次停下，只可能是因为**新**上限也超了")
    }

    @Test("⚠️ 提高到一个**没有变大**的上限时，什么也不做（否则按钮像坏的）")
    func raisingToASmallerLimitIsRejected() {
        let counter = ModelCallCounter()
        let config = costConfig(ceiling: 7)
        let deps = costDeps(counter: counter)
        let (paused, _, _) = TurnRunner.run(TurnState(objective: "读一下"), deps: deps, config: config)

        let same = TurnRunner.raiseBudget(paused, to: 7, deps: deps, config: config)
        #expect(!same.didAdvance)
        #expect(same.state.status == .pausedBudget, "状态不能变")
        let smaller = TurnRunner.raiseBudget(paused, to: 1, deps: deps, config: config)
        #expect(!smaller.didAdvance)
    }

    @Test("⚠️ `raiseBudget` 只能从**预算暂停态**进入（不能拿它绕开审批）")
    func raiseBudgetIsNotAGeneralEscapeHatch() {
        let counter = ModelCallCounter()
        let deps = costDeps(counter: counter)
        let config = costConfig(ceiling: 7)
        // 一个正在等审批的 Turn
        let waiting = TurnState(objective: "x", status: .awaitingApproval)
        let outcome = TurnRunner.raiseBudget(waiting, to: 999, deps: deps, config: config)
        #expect(!outcome.didAdvance)
        #expect(outcome.state.status == .awaitingApproval, "审批闸门不能被钱包闸门撬开")
    }

    @Test("⚠️ 崩溃恢复后上限仍然有效（账本在状态里，不在内存里）")
    func ceilingSurvivesRestore() {
        let counter = ModelCallCounter()
        let config = costConfig(ceiling: 7)
        let deps = costDeps(counter: counter)
        let (paused, _, _) = TurnRunner.run(TurnState(objective: "读一下"), deps: deps, config: config)
        #expect(paused.status == .pausedBudget)

        // 模拟"进程重启后从检查点恢复"：状态原样带过来
        var restored = paused
        restored.wasRestored = true
        let (after, _, _) = TurnRunner.run(restored, deps: deps, config: config)
        #expect(after.status == .pausedBudget, "恢复后不能因为「忘了花过钱」而继续跑")
    }
}
