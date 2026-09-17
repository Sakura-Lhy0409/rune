import Testing
import Foundation
@testable import RuneKernel

// MARK: - 事件日志的测试
//
// 这一组守两条东西：
//   ① **哈希链真的能发现篡改**（而且要分清"被改了"和"被删了"—— 用户看到这两句话的感受不同）
//   ② **投影与真相一致** —— `docs/12 §1` 说"事件日志是唯一真相源"，
//      那就必须能拿它和 TurnState 对账；对不上说明其中一个在说谎。

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func makeLog(
    count: Int,
    anchorInterval: Int = 1_000,
    store: (any AnchorStore)? = nil
) -> (EventLog, [RuntimeEvent]) {
    let log = EventLog(sessionID: UUID(), anchorInterval: anchorInterval,
                       anchorStore: store, now: { t0 })
    var events: [RuntimeEvent] = []
    for index in 0..<count {
        events.append(log.append(.init(
            kind: .toolCallFinished,
            payload: .object(["tool": .string("read_file"), "status": .string("ok"), "n": .int(index)])
        )))
    }
    return (log, events)
}

// MARK: - 哈希链

@Suite("EventLog —— 追加与哈希链")

struct EventLogTests {

    @Test("序号单调、链首尾相接")
    func appendChains() {
        let (log, _) = makeLog(count: 5)
        let events = log.all
        #expect(events.map(\.sequence) == [1, 2, 3, 4, 5])
        #expect(events.first?.previousHash == nil)
        for (previous, next) in zip(events, events.dropFirst()) {
            #expect(next.previousHash == previous.hash)
        }
    }

    @Test("每条事件自身可校验")
    func selfVerifiable() {
        let (log, _) = makeLog(count: 3)
        for event in log.all { #expect(event.verifyHash()) }
    }

    @Test("⭐ 干净的日志校验通过")
    func verifyClean() {
        let (log, _) = makeLog(count: 10)
        let result = log.verify(full: true)
        #expect(result.isOK)
        #expect(result.checkedCount == 10)
        #expect(result.userFacingText.contains("通过"))
    }

    @Test("空日志也算通过（不是错误）")
    func verifyEmpty() {
        let log = EventLog(sessionID: UUID(), now: { t0 })
        #expect(log.verify().isOK)
    }

    @Test("按 kind / turnID / 序号查询")
    func queries() {
        let turnID = UUID()
        let log = EventLog(sessionID: UUID(), now: { t0 })
        for index in 0..<5 {
            log.append(.init(kind: index % 2 == 0 ? .toolCallFinished : .modelCallFinished,
                             payload: .object([:]), turnID: turnID))
        }
        #expect(log.events(kind: .toolCallFinished).count == 3)
        #expect(log.events(turnID: turnID).count == 5)
        #expect(log.events(after: 3).count == 2)
        #expect(log.count == 5)
        #expect(log.tail?.sequence == 5)
    }
}

// MARK: - 锚点与篡改检测

@Suite("EventLog —— 锚点与篡改检测")

struct EventLogTamperTests {

    @Test("每 N 条打一个锚点，并落到 AnchorStore")
    func anchorsAreCreated() {
        let store = InMemoryAnchorStore()
        let (log, _) = makeLog(count: 10, anchorInterval: 5, store: store)
        #expect(log.allAnchors.map(\.sequence) == [5, 10])
        // ⚠️ 锚点必须存到 Agent 够不到的地方（真实实现走 Keychain；
        //    和事件存在同一个可写位置的话，篡改者可以把两边一起改掉 —— 那校验就是自证清白）
        #expect(store.loadLatest()?.sequence == 10)
    }

    @Test("⭐ 存储层的字节被改 → 报「被改动过」（而不是笼统的失败）")
    func tamperedContentDetected() throws {
        // ⚠️ 这里必须**从 JSON 解码**来构造被篡改的事件，不能直接 new 一个。
        //    因为 `RuntimeEvent` 的字段全是 `let`、哈希在构造时就算好了 ——
        //    也就是说"内容和哈希不一致"这种状态**没法通过 API 造出来**。
        //    而它恰恰是真实世界里最可能发生的那种篡改：有人直接改了数据库里的那行。
        //    所以模拟它的正确方式是"改 JSON 文本，再解码回来"。
        let (log, events) = makeLog(count: 5)
        let encoded = try JSONEncoder().encode(events[2])
        var text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("read_file"), "前提：payload 里应当有工具名可改")
        text = text.replacingOccurrences(of: "read_file", with: "delete_path")
        let tampered = try JSONDecoder().decode(RuntimeEvent.self, from: Data(text.utf8))

        // 前提：内容和哈希确实对不上了
        #expect(!tampered.verifyHash(), "篡改后哈希应当对不上")

        var rebuilt = events
        rebuilt[2] = tampered
        let fresh = EventLog(sessionID: log.sessionID, now: { t0 })
        fresh.loadHistorical(rebuilt)

        let result = fresh.verify(full: true)
        #expect(!result.isOK)
        #expect(result.outcome == .tampered, "实际：\(result.outcome) —— \(result.detail)")
        #expect(result.firstBadSequence == 3)
        #expect(result.userFacingText.contains("被改动过"))
        // 关键：它明确说了"自动续跑已停止"
        #expect(result.userFacingText.contains("自动续跑已停止"))
    }

    @Test("⭐ 连哈希一起重算的篡改 → 在下一条的衔接处露馅")
    func recomputedHashDetectedViaLink() {
        // 对懂行的人来说，重算单条哈希并不难（就是一次 SHA-256）。
        // 但**下一条的 previousHash 指向的是旧哈希** —— 那里会露馅。
        // 这也是为什么"链"比"逐条自校验"强：改一条就得改到尾巴。
        let (log, events) = makeLog(count: 5)
        let rewritten = RuntimeEvent(
            sequence: events[2].sequence, id: events[2].id, sessionID: events[2].sessionID,
            kind: events[2].kind,
            payload: .object(["tool": .string("delete_path"), "status": .string("ok")]),
            createdAt: events[2].createdAt, previousHash: events[2].previousHash
        )
        var rebuilt = events
        rebuilt[2] = rewritten
        let fresh = EventLog(sessionID: log.sessionID, now: { t0 })
        fresh.loadHistorical(rebuilt)

        let result = fresh.verify(full: true)
        #expect(!result.isOK)
        #expect(result.outcome == .brokenLink, "实际：\(result.outcome) —— \(result.detail)")
        #expect(result.firstBadSequence == 4, "露馅的是下一条")
        #expect(result.userFacingText.contains("衔接断了"))
    }
    @Test("⚠️ 锚点只覆盖到某一条时，只验它之后的（手机上不必每次扫全表）")
    func incrementalVerification() {
        let (log, _) = makeLog(count: 12, anchorInterval: 5)
        let result = log.verify(full: false)
        #expect(result.isOK)
        // 最近锚点是第 10 条 → 只验 11、12 两条
        #expect(result.checkedFrom == 11)
        #expect(result.checkedCount == 2)
    }

    @Test("⭐ 锚点正好落在最后一条时不能崩（要验的「之后」是空的）")
    func anchorAtTailDoesNotCrash() {
        // ⚠️ 这条是被一个真实的越界崩逼出来的：
        //    锚点覆盖到最后一条时 `startIndex == events.count`，
        //    而代码里有一处 `events[startIndex]` —— 直接越界。
        let (log, _) = makeLog(count: 10, anchorInterval: 5)
        let result = log.verify(full: false)
        #expect(result.isOK)
        #expect(result.checkedCount == 0)
        #expect(result.detail.contains("锚点已覆盖到最后一条"))
    }

    @Test("⚠️ loadHistorical 只允许在日志为空时用（否则序号会冲突、哈希链会变成胡说）")
    func loadHistoricalOnlyOnce() {
        let (log, events) = makeLog(count: 3)
        log.loadHistorical(events)   // 应当被忽略
        #expect(log.count == 3)
        #expect(log.all.map(\.sequence) == [1, 2, 3])
    }
}

// MARK: - 投影

@Suite("EventProjector —— 投影与真相必须一致")

struct EventProjectorTests {

    private func log(with drafts: [EventLog.Draft]) -> EventLog {
        let log = EventLog(sessionID: UUID(), now: { t0 })
        log.append(contentsOf: drafts)
        return log
    }

    @Test("空日志 → 空投影")
    func emptyProjection() {
        let projection = EventProjector.project([], sessionID: UUID())
        #expect(projection.turns.isEmpty)
        #expect(projection.cost.totalMicroUSD == 0)
        #expect(projection.lastSequence == 0)
    }

    @Test("⭐ 增量投影 == 全量重放（这条一破，缓存视图与真相就分叉了）")
    func incrementalEqualsFullReplay() {
        let sessionID = UUID()
        let turnA = UUID()
        let turnB = UUID()
        let log = EventLog(sessionID: sessionID, now: { t0 })
        log.append(contentsOf: [
            .init(kind: .sessionCreated, payload: .object(["title": .string("修退款")])),
            .init(kind: .userMessage, payload: .object(["objective": .string("修好它")]), turnID: turnA),
            .init(kind: .modelCallFinished, payload: .object(["round": .int(1), "toolCalls": .int(2)]), turnID: turnA),
            .init(kind: .toolCallRequested, payload: .object(["tool": .string("read_file")]), turnID: turnA),
            .init(kind: .toolCallFinished, payload: .object(["tool": .string("read_file"), "status": .string("ok")]), turnID: turnA),
            .init(kind: .toolCallFinished, payload: .object(["tool": .string("read_file"), "status": .string("error")]), turnID: turnA),
            .init(kind: .modelSelfCorrected, payload: .object(["tool": .string("read_file")]), turnID: turnA),
            .init(kind: .artifactCreated, payload: .object(["summary": .string("做完了")]), turnID: turnA),
            .init(kind: .userMessage, payload: .object(["objective": .string("再来一个")]), turnID: turnB),
            .init(kind: .budgetExceeded, payload: .object(["reason": .string("轮次上限")]), turnID: turnB),
        ])

        let all = log.all
        let full = EventProjector.project(all, sessionID: sessionID)

        // 逐条增量应用 → 必须与一次性重放**完全相等**
        var incremental = SessionProjection(sessionID: sessionID)
        for event in all { EventProjector.apply(event, to: &incremental) }
        #expect(incremental == full)
    }

    @Test("⚠️ 同一条事件应用两次不改变结果（崩溃后可能重放一段，不幂等会让计数翻倍）")
    func applyIsIdempotent() {
        let sessionID = UUID()
        let turnID = UUID()
        let log = log(with: [
            .init(kind: .userMessage, payload: .object(["objective": .string("干活")]), turnID: turnID),
        ])
        var projection = SessionProjection(sessionID: sessionID)
        for event in log.all { EventProjector.apply(event, to: &projection) }
        let once = projection

        // 把同一条再喂一遍（模拟恢复时的重放）
        for event in log.all { EventProjector.apply(event, to: &projection) }
        #expect(projection == once)
    }

    @Test("会话标题与归档状态")
    func sessionFields() {
        let log = log(with: [
            .init(kind: .sessionCreated, payload: .object(["title": .string("初始标题")])),
            .init(kind: .sessionTitleSet, payload: .object(["title": .string("改过的标题")])),
            .init(kind: .sessionArchived),
        ])
        let projection = EventProjector.project(log.all, sessionID: log.sessionID)
        #expect(projection.title == "改过的标题")
        #expect(projection.isArchived)
        #expect(projection.createdAt != nil)
    }

    @Test("轮次计数、工具计数与失败计数")
    func turnCounters() {
        let turnID = UUID()
        let log = log(with: [
            .init(kind: .userMessage, payload: .object(["objective": .string("目标")]), turnID: turnID),
            .init(kind: .modelCallFinished, payload: .object(["round": .int(1)]), turnID: turnID),
            .init(kind: .modelCallFinished, payload: .object(["round": .int(2)]), turnID: turnID),
            .init(kind: .toolCallRequested, payload: .object(["tool": .string("read_file")]), turnID: turnID),
            .init(kind: .toolCallFinished, payload: .object(["tool": .string("read_file"), "status": .string("ok")]), turnID: turnID),
            .init(kind: .toolCallFinished, payload: .object(["tool": .string("read_file"), "status": .string("error")]), turnID: turnID),
            .init(kind: .capabilityDenied, payload: .object(["tool": .string("write_file")]), turnID: turnID),
        ])
        let turn = try! #require(EventProjector.project(log.all, sessionID: log.sessionID).turns[turnID])
        #expect(turn.objective == "目标")
        #expect(turn.rounds == 2)
        #expect(turn.toolCalls == 1)
        #expect(turn.failedToolCalls == 1)
        #expect(turn.deniedToolCalls == 1)
    }

    @Test("⭐ 成本账本按提供方/模型分账")
    func costLedger() {
        let turnID = UUID()
        let log = log(with: [
            .init(kind: .modelCallFinished, payload: .object([
                "round": .int(1), "microUSD": .int(1_200), "provider": .string("deepseek"),
                "model": .string("deepseek-chat"), "inputTokens": .int(900), "outputTokens": .int(120),
                "cachedInputTokens": .int(400), "savedMicroUSD": .int(300),
            ]), turnID: turnID),
            .init(kind: .modelCallFinished, payload: .object([
                "round": .int(2), "microUSD": .int(800), "provider": .string("openai"),
                "model": .string("gpt-x"), "inputTokens": .int(500), "outputTokens": .int(60),
            ]), turnID: turnID),
        ])
        let projection = EventProjector.project(log.all, sessionID: log.sessionID)
        #expect(projection.cost.totalMicroUSD == 2_000)
        #expect(projection.cost.byProvider["deepseek"] == 1_200)
        #expect(projection.cost.byProvider["openai"] == 800)
        #expect(projection.cost.inputTokens == 1_400)
        #expect(projection.cost.cachedInputTokens == 400)
        #expect(projection.cost.savedMicroUSD == 300)
        #expect(projection.turns[turnID]?.costMicroUSD == 2_000)
    }

    @Test("安全事件与出口审计被单独收集（用户要能问「它到底往外发了什么」）")
    func securityAndEgress() {
        let log = log(with: [
            .init(kind: .egressAudited, payload: .object([
                "host": .string("api.deepseek.com"), "method": .string("POST"), "bytes": .int(4_200),
            ])),
            .init(kind: .egressBlocked, payload: .object([
                "host": .string("evil.test"), "method": .string("POST"), "bytes": .int(100),
            ])),
            .init(kind: .injectionSuspected, payload: .object(["reason": .string("网页里出现了指令")])),
        ])
        let projection = EventProjector.project(log.all, sessionID: log.sessionID)
        #expect(projection.egress.count == 2)
        #expect(projection.egress[0].host == "api.deepseek.com")
        #expect(projection.egress[1].wasBlocked)
        // 安全类事件不只出口那两条：注入怀疑也要进
        #expect(projection.security.contains { $0.kind == .injectionSuspected })
        #expect(projection.security.contains { $0.kind == .egressBlocked })
    }

    @Test("制品与检查点被记下（UI 要能列出「这次产出了什么、能回到哪里」）")
    func artifactsAndCheckpoints() {
        let turnID = UUID()
        let log = log(with: [
            .init(kind: .artifactCreated, payload: .object([
                "summary": .string("CI 日志"), "handle": .string("artifacts/ci.txt"), "bytes": .int(3_000_000),
            ]), turnID: turnID),
            .init(kind: .checkpointCreated, payload: .object([
                "label": .string("第 1 波完成"), "kind": .string("step"), "restorable": .bool(true),
            ]), turnID: turnID),
        ])
        let projection = EventProjector.project(log.all, sessionID: log.sessionID)
        #expect(projection.artifacts.count == 1)
        #expect(projection.artifacts[0].handle == "artifacts/ci.txt")
        #expect(projection.checkpoints.count == 1)
        #expect(projection.checkpoints[0].label == "第 1 波完成")
        #expect(projection.turns[turnID]?.lastCheckpointSeq == 2)
    }
}

// MARK: - ⭐ 与 TurnState 对账

@Suite("事件日志 × TurnState —— 唯一真相源要对得上")

struct EventLogReconciliationTests {

    @Test("⭐ 把真实 TurnRunner 跑出来的事件投影回来，必须与最终 TurnState 一致")
    func projectionMatchesTurnState() {
        let ws = Scenario.workspace()
        let sessionID = UUID()
        let (final, events, _) = TurnRunner.run(
            TurnState(sessionID: sessionID, objective: "修复失败的金额取整测试"),
            deps: Scenario.deps(ws, context: Scenario.context()),
            config: Scenario.config()
        )
        #expect(final.status == .completed)

        // 把事件灌进日志（真实运行时是边跑边写；这里用 loadHistorical 等价地导入）
        let log = EventLog(sessionID: sessionID, now: { Date() })
        log.loadHistorical(events)
        #expect(log.verify(full: true).isOK)

        let projection = EventProjector.project(log.all, sessionID: sessionID)
        let turn = try! #require(projection.turns[final.turnID])

        // ⚠️ 这几条对不上，就说明"事件日志是唯一真相源"这句话是假的
        #expect(turn.objective == final.objective)
        #expect(turn.rounds == final.round, "投影出的轮次 \(turn.rounds) != TurnState 的 \(final.round)")
        #expect(turn.toolCalls == final.toolCallCount,
                "投影出的工具调用数 \(turn.toolCalls) != TurnState 的 \(final.toolCallCount)")
        #expect(turn.isFinished, "跑完了却被投影成未完成")
        #expect(!turn.hasIrreversibleSideEffect, "这个场景没有对外副作用")

        // 事件条数也要对得上（TurnRunner 只产出事件，不产出别的）
        #expect(projection.lastSequence == Int64(events.count))
    }

    @Test("⭐ 有外部副作用的轮次必须被标出来（恢复流程靠它决定能不能自动重做）")
    func irreversibleSideEffectIsFlagged() {
        let turnID = UUID()
        let log = EventLog(sessionID: UUID(), now: { t0 })
        log.append(.init(kind: .gitPushAttempted, payload: .object(["remote": .string("origin")]), turnID: turnID))
        let projection = EventProjector.project(log.all, sessionID: log.sessionID)
        #expect(projection.turns[turnID]?.hasIrreversibleSideEffect == true)

        // 外发也算
        let other = UUID()
        let log2 = EventLog(sessionID: UUID(), now: { t0 })
        log2.append(.init(kind: .fileReturned, payload: .object(["path": .string("out.pdf")]), turnID: other))
        #expect(EventProjector.project(log2.all, sessionID: log2.sessionID).turns[other]?.hasIrreversibleSideEffect == true)
    }
}

// MARK: - 恢复计划

@Suite("RecoveryPlanner —— 冷启动分诊")

struct RecoveryPlannerTests {

    private func verification(_ ok: Bool) -> ChainVerification {
        ChainVerification(outcome: ok ? .ok : .tampered, checkedFrom: 1, checkedCount: 5,
                          firstBadSequence: ok ? nil : 3,
                          detail: ok ? "通过" : "第 3 条被改动过")
    }

    private func unfinishedTurn(
        _ projection: inout SessionProjection,
        at date: Date,
        sideEffect: Bool = false,
        checkpoint: Int64? = nil
    ) -> UUID {
        let id = UUID()
        projection.turns[id] = TurnProjection(id: id, startedAt: date)
        projection.turnOrder.append(id)
        if sideEffect { projection.turns[id]?.hasIrreversibleSideEffect = true }
        if let checkpoint { projection.turns[id]?.lastCheckpointSeq = checkpoint }
        return id
    }

    @Test("⚠️ 链校验没过 → **什么都不自动做**（基于可能被改过的历史执行动作更糟）")
    func brokenChainStopsEverything() {
        var projection = SessionProjection(sessionID: UUID())
        _ = unfinishedTurn(&projection, at: t0)
        let plan = RecoveryPlanner.plan(projection, verification: verification(false), now: t0)
        #expect(plan.actions.isEmpty)
        #expect(plan.headline.contains("校验未通过"))
        #expect(plan.headline.contains("自动续跑已停止"))
    }

    @Test("没有未完成的东西 → 无事可做")
    func nothingToRecover() {
        let projection = SessionProjection(sessionID: UUID())
        let plan = RecoveryPlanner.plan(projection, verification: verification(true), now: t0)
        #expect(plan.actions.isEmpty)
        #expect(plan.headline.contains("没有需要恢复"))
    }

    @Test("⭐ 可安全重做的轮次 → 从最后一个检查点重放")
    func resumableTurn() {
        var projection = SessionProjection(sessionID: UUID())
        _ = unfinishedTurn(&projection, at: t0.addingTimeInterval(-60), checkpoint: 12)
        let plan = RecoveryPlanner.plan(projection, verification: verification(true), now: t0)
        guard case .replayTurn(_, let from, let reason) = plan.actions.first else {
            Issue.record("应当重放，实际 \(plan.actions)")
            return
        }
        #expect(from == 12)
        #expect(reason.contains("12"))
        #expect(plan.headline.contains("已从检查点恢复"))
    }

    @Test("⭐ 有外部副作用的轮次 → **必须问用户**（重复推送/重复付款是真实损失）")
    func sideEffectNeedsUser() {
        var projection = SessionProjection(sessionID: UUID())
        _ = unfinishedTurn(&projection, at: t0.addingTimeInterval(-60), sideEffect: true)
        let plan = RecoveryPlanner.plan(projection, verification: verification(true), now: t0)
        guard case .askUser(_, let reason) = plan.actions.first else {
            Issue.record("应当问用户，实际 \(plan.actions)")
            return
        }
        #expect(reason.contains("重复"))
        #expect(plan.needsUserAttention)
    }

    @Test("⭐ 僵尸（>24h）→ 标记中断，**不自动续跑**（三天前忘了的任务不该自己跑起来花钱）")
    func zombieIsInterruptedNotResumed() {
        var projection = SessionProjection(sessionID: UUID())
        _ = unfinishedTurn(&projection, at: t0.addingTimeInterval(-72 * 3_600))
        let plan = RecoveryPlanner.plan(projection, verification: verification(true), now: t0)
        guard case .markInterrupted(_, let reason) = plan.actions.first else {
            Issue.record("应当标记中断，实际 \(plan.actions)")
            return
        }
        #expect(reason.contains("72"))
        #expect(reason.contains("不会再自动继续"))
        #expect(!plan.needsUserAttention, "僵尸不需要用户马上处理")
    }

    @Test("⚠️ 副作用 + 僵尸：**先按副作用处理**（安全性优先于「别烦用户」）")
    func sideEffectBeatsZombie() {
        var projection = SessionProjection(sessionID: UUID())
        _ = unfinishedTurn(&projection, at: t0.addingTimeInterval(-72 * 3_600), sideEffect: true)
        let plan = RecoveryPlanner.plan(projection, verification: verification(true), now: t0)
        guard case .askUser = plan.actions.first else {
            Issue.record("有副作用的僵尸也该问用户，实际 \(plan.actions)")
            return
        }
    }

    @Test("活跃目标 → 继续推进")
    func activeGoalResumes() {
        var projection = SessionProjection(sessionID: UUID())
        let goalID = UUID()
        projection.goals[goalID] = GoalRecord(id: goalID, objective: "把覆盖率提到 80%",
                                              status: "active", lastActivityAt: t0.addingTimeInterval(-600))
        let plan = RecoveryPlanner.plan(projection, verification: verification(true), now: t0)
        guard case .resumeGoal(_, let objective, _) = plan.actions.first else {
            Issue.record("应当续跑目标，实际 \(plan.actions)")
            return
        }
        #expect(objective == "把覆盖率提到 80%")
        #expect(plan.headline.contains("已从检查点恢复"))
    }

    @Test("⚠️ 太久没动的目标也不自动续跑")
    func staleGoalIsNotResumed() {
        var projection = SessionProjection(sessionID: UUID())
        let goalID = UUID()
        projection.goals[goalID] = GoalRecord(id: goalID, objective: "老目标", status: "active",
                                              lastActivityAt: t0.addingTimeInterval(-50 * 3_600))
        let plan = RecoveryPlanner.plan(projection, verification: verification(true), now: t0)
        #expect(plan.actions.isEmpty)
        #expect(plan.notes.contains { $0.contains("不自动续跑") })
    }

    @Test("一句话摘要要能把三类都说到")
    func headlineCoversAllCategories() {
        var projection = SessionProjection(sessionID: UUID())
        _ = unfinishedTurn(&projection, at: t0.addingTimeInterval(-60))
        _ = unfinishedTurn(&projection, at: t0.addingTimeInterval(-120), sideEffect: true)
        _ = unfinishedTurn(&projection, at: t0.addingTimeInterval(-72 * 3_600))
        let plan = RecoveryPlanner.plan(projection, verification: verification(true), now: t0)
        #expect(plan.headline.contains("已从检查点恢复"))
        #expect(plan.headline.contains("需要你确认"))
        #expect(plan.headline.contains("太久没动"))
    }
}






