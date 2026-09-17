import Testing
import Foundation
@testable import RuneKernel

// MARK: - 目标引擎

@Suite("GoalEngine —— 跨轮推进与阻塞纪律")
struct GoalEngineTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func goal(
        objective: String = "把 API 文档补全",
        rounds: Int = 0,
        roundBudget: Int = 10,
        deliverable: DeliverableSpec? = nil,
        budget: GoalBudget = .init()
    ) -> Goal {
        Goal(
            objective: objective, status: .active, roundBudget: roundBudget,
            roundsUsed: rounds, deliverableSpec: deliverable, budget: budget, createdAt: base
        )
    }

    private func progressed(artifacts: [String] = [], commands: [String] = []) -> GoalEngine.RoundOutcome {
        .init(result: .progressed, evidence: .init(producedArtifacts: artifacts, succeededCommands: commands))
    }

    // MARK: 记账

    @Test("一轮结束会记账（轮次、成本、电量、检查点）")
    func accounting() {
        let checkpoint = UUID()
        let outcome = GoalEngine.RoundOutcome(
            result: .progressed, evidence: .init(producedArtifacts: ["report.md"]),
            costMicroUSD: 45_000, batteryUsedPercent: 2, checkpointID: checkpoint
        )
        let applied = GoalEngine.apply(outcome: outcome, to: goal(), conditions: .default, now: base)

        #expect(applied.consumedRound)
        #expect(applied.goal.roundsUsed == 1)
        #expect(applied.goal.budget.usedCostMicroUSD == 45_000)
        #expect(applied.goal.budget.usedBatteryPercent == 2)
        #expect(applied.goal.lastCheckpointID == checkpoint)
    }

    @Test("用户中止不计入轮次（不是它的错）")
    func userAbortDoesNotConsumeRound() {
        let outcome = GoalEngine.RoundOutcome(result: .userAborted)
        let applied = GoalEngine.apply(outcome: outcome, to: goal(), conditions: .default, now: base)
        #expect(!applied.consumedRound)
        #expect(applied.goal.roundsUsed == 0)
        #expect(applied.goal.status == .paused)
        if case .aborted = applied.decision {} else { Issue.record("应返回 aborted：\(applied.decision)") }
    }

    // MARK: 阻塞纪律

    @Test("⚠️ 一次受阻**不足以**标记阻塞（难度大不等于受阻）")
    func oneBlockedAttemptIsNotEnough() {
        let outcome = GoalEngine.RoundOutcome(
            result: .blocked, blockingReason: "缺少 API key",
            attemptedFixes: ["检查了环境变量", "查了配置文件", "问了用户"], needsUserTo: "提供 API key"
        )
        let applied = GoalEngine.apply(outcome: outcome, to: goal(), conditions: .default, now: base)

        #expect(applied.goal.status == .active, "第一次受阻不该把目标挂起")
        #expect(applied.goal.blockedStreak == 1)
        #expect(!applied.goal.canMarkBlocked)
        if case .continueNow(let reason) = applied.decision {
            #expect(reason.contains("再试一次"))
        } else {
            Issue.record("应继续尝试：\(applied.decision)")
        }
    }

    @Test("⚠️ 同一条件连续 3 轮 → 才允许标记阻塞，并带上「需要用户做的事」")
    func threeConsecutiveSameReasonBlocks() {
        var current = goal()
        var lastDecision: GoalEngine.Decision?
        for _ in 0..<3 {
            let outcome = GoalEngine.RoundOutcome(
                result: .blocked, blockingReason: "缺少 API key",
                attemptedFixes: ["查环境变量", "查配置文件", "问用户"], needsUserTo: "在设置里填入 API key"
            )
            let applied = GoalEngine.apply(outcome: outcome, to: current, conditions: .default, now: base)
            current = applied.goal
            lastDecision = applied.decision
        }

        #expect(current.status == .blocked)
        #expect(current.blockedStreak == 3)
        guard case .blocked(let reason, let needsUserTo, let attempted) = lastDecision else {
            Issue.record("第三次应标记阻塞：\(String(describing: lastDecision))"); return
        }
        #expect(reason == "缺少 API key")
        #expect(needsUserTo == "在设置里填入 API key")
        #expect(attempted.count == 3)
    }

    @Test("⚠️ 障碍变化会重置计数（换措辞凑不满 3 轮）")
    func changingReasonResetsStreak() {
        var current = goal()
        for reason in ["缺 key", "缺 key", "网络不通", "网络不通"] {
            let applied = GoalEngine.apply(
                outcome: .init(result: .blocked, blockingReason: reason, attemptedFixes: ["a", "b", "c"], needsUserTo: "x"),
                to: current, conditions: .default, now: base
            )
            current = applied.goal
        }
        #expect(current.blockedStreak == 2, "最后一次换了理由，计数应重置为 2")
        #expect(current.status == .active)
    }

    @Test("受阻上报的**合格性检查**：缺项会被驳回并说明原因")
    func blockedReportValidation() {
        let bad = GoalEngine.BlockedReport(reason: "太难了", attemptedFixes: ["试了一下"], needsUserTo: "")
        #expect(!bad.isAcceptable)
        let message = bad.rejectionMessage
        #expect(message?.contains("3 种已尝试的办法") == true)
        #expect(message?.contains("需要用户做的那一件事") == true)
        #expect(message?.contains("难度大、不确定、还有活可干") == true)

        let good = GoalEngine.BlockedReport(
            reason: "缺少 API key", attemptedFixes: ["查环境变量", "查配置", "问用户"], needsUserTo: "填 key"
        )
        #expect(good.isAcceptable)
        #expect(good.rejectionMessage == nil)
    }

    // MARK: 无进展熔断

    @Test("⚠️ 连续 3 轮无实质进展 → 暂停并问用户（不是障碍，但同样要停）")
    func stalledAfterConsecutiveNoProgress() {
        var current = goal()
        var decision: GoalEngine.Decision?
        for _ in 0..<3 {
            let applied = GoalEngine.apply(outcome: .init(result: .noProgress), to: current, conditions: .default, now: base)
            current = applied.goal
            decision = applied.decision
        }
        #expect(current.consecutiveNoProgress == 3)
        #expect(current.status == .paused)
        guard case .stalled(let rounds, let explanation) = decision else {
            Issue.record("应返回 stalled：\(String(describing: decision))"); return
        }
        #expect(rounds == 3)
        #expect(explanation.contains("没有实质进展"))
        #expect(explanation.contains("告诉我更具体的目标"))
    }

    @Test("有进展会清空无进展计数")
    func progressResetsStallCounter() {
        var current = goal()
        for _ in 0..<2 {
            current = GoalEngine.apply(outcome: .init(result: .noProgress), to: current, conditions: .default, now: base).goal
        }
        #expect(current.consecutiveNoProgress == 2)
        current = GoalEngine.apply(outcome: progressed(), to: current, conditions: .default, now: base).goal
        #expect(current.consecutiveNoProgress == 0)
    }

    @Test("无进展与受阻是两个独立计数（不要互相污染）")
    func noProgressAndBlockedAreIndependent() {
        var current = goal()
        current = GoalEngine.apply(outcome: .init(result: .noProgress), to: current, conditions: .default, now: base).goal
        #expect(current.consecutiveNoProgress == 1)
        #expect(current.blockedStreak == 0, "无进展不该被算成受阻")
    }

    // MARK: 完成判定

    @Test("交付条件：制品产出（宽松匹配）")
    func deliverableArtifact() {
        let spec = DeliverableSpec(kind: .artifactProduced, detail: "report.md")
        #expect(GoalEngine.isSatisfied(spec, evidence: .init(producedArtifacts: ["/workspace/report.md"])))
        #expect(!GoalEngine.isSatisfied(spec, evidence: .init(producedArtifacts: ["notes.txt"])))
    }

    @Test("交付条件：命令成功 / 用户确认 / 全部步骤完成 / 自然语言判定")
    func deliverableOtherKinds() {
        #expect(GoalEngine.isSatisfied(
            DeliverableSpec(kind: .commandSucceeds, detail: "pytest"),
            evidence: .init(succeededCommands: ["pytest -q"])
        ))
        #expect(GoalEngine.isSatisfied(DeliverableSpec(kind: .userConfirms, detail: ""), evidence: .init(userConfirmed: true)))
        #expect(GoalEngine.isSatisfied(DeliverableSpec(kind: .allStepsDone, detail: ""), evidence: .init(allStepsDone: true)))
        #expect(GoalEngine.isSatisfied(
            DeliverableSpec(kind: .naturalLanguageCondition, detail: "文档完整"),
            evidence: .init(naturalLanguageAssessment: true)
        ))
        // 未判定（nil）不算满足 —— 不能"没检查就当通过"
        #expect(!GoalEngine.isSatisfied(
            DeliverableSpec(kind: .naturalLanguageCondition, detail: "x"),
            evidence: .init(naturalLanguageAssessment: nil)
        ))
    }

    @Test("⚠️ 有进展且交付条件已满足 → 立刻完成（不会「做完了还在跑」）")
    func completesWhenDeliverableMet() {
        let g = goal(deliverable: DeliverableSpec(kind: .commandSucceeds, detail: "pytest"))
        let applied = GoalEngine.apply(
            outcome: .init(result: .progressed, evidence: .init(succeededCommands: ["pytest -q"])),
            to: g, conditions: .default, now: base
        )
        #expect(applied.goal.status == .completed)
        #expect(applied.goal.completedAt == base)
        guard case .completed(let reason) = applied.decision else {
            Issue.record("应完成：\(applied.decision)"); return
        }
        #expect(reason.contains("交付条件已满足"))
    }

    @Test("显式 delivered 也判定完成")
    func explicitDelivered() {
        let applied = GoalEngine.apply(outcome: .init(result: .delivered), to: goal(), conditions: .default, now: base)
        #expect(applied.goal.status == .completed)
    }

    // MARK: 条件门禁

    @Test("⚠️ 热到 critical → 一律停")
    func thermalCriticalStops() {
        let gate = GoalEngine.gate(
            goal: goal(), conditions: .init(thermal: .critical),
            wake: .processingWindow
        )
        #expect(!gate.isAllowed)
        if case .denied(let kind, let explanation) = gate {
            #expect(kind == .thermal)
            #expect(explanation.contains("过热"))
        }
    }

    @Test("⚠️ 僵尸任务防护：距上次活动超过 24 小时，后台不自动续跑")
    func zombieProtection() {
        let gate = GoalEngine.gate(
            goal: goal(),
            conditions: .init(hoursSinceLastActivity: 30),
            wake: .processingWindow
        )
        #expect(!gate.isAllowed)
        if case .denied(let kind, let explanation) = gate {
            #expect(kind == .zombieProtection)
            #expect(explanation.contains("24 小时"))
        }
        // 但用户打开 App 时照常继续（前台不受此限制）
        #expect(GoalEngine.gate(goal: goal(), conditions: .init(hoursSinceLastActivity: 30), wake: .foreground).isAllowed)
    }

    @Test("⚠️ 后台自动续跑默认不许花钱")
    func backgroundDoesNotSpendByDefault() {
        let gate = GoalEngine.gate(
            goal: goal(), conditions: .init(remainingCostMicroUSD: 0), wake: .backgroundPush
        )
        #expect(!gate.isAllowed)
        if case .denied(let kind, _) = gate { #expect(kind == .cost) }
        // 前台的用户主动操作不受此限
        #expect(GoalEngine.gate(goal: goal(), conditions: .init(remainingCostMicroUSD: 0), wake: .userAction).isAllowed)
    }

    @Test("电量低于 20% 且未充电 → 停；充电中则放行")
    func batteryGate() {
        #expect(!GoalEngine.gate(goal: goal(), conditions: .init(batteryPercent: 15, isCharging: false), wake: .processingWindow).isAllowed)
        #expect(GoalEngine.gate(goal: goal(), conditions: .init(batteryPercent: 15, isCharging: true), wake: .processingWindow).isAllowed)
    }

    @Test("低电量模式 / 用户关闭自动续跑 / 离线需网络 → 各自拦住后台续跑")
    func otherGates() {
        if case .denied(let k, _) = GoalEngine.gate(goal: goal(), conditions: .init(isLowPowerMode: true), wake: .appRefresh) {
            #expect(k == .lowPower)
        } else { Issue.record("低电量模式应拦住") }

        if case .denied(let k, _) = GoalEngine.gate(goal: goal(), conditions: .init(autoContinueEnabled: false), wake: .appRefresh) {
            #expect(k == .autoContinueDisabled)
        } else { Issue.record("用户关闭开关应拦住") }

        if case .denied(let k, _) = GoalEngine.gate(
            goal: goal(), conditions: .init(isOffline: true), wake: .appRefresh, requiresNetwork: true
        ) {
            #expect(k == .offline)
        } else { Issue.record("离线应拦住需网络的任务") }

        // 离线但任务不需要网络 → 放行
        #expect(GoalEngine.gate(goal: goal(), conditions: .init(isOffline: true), wake: .appRefresh).isAllowed)
    }

    @Test("轮次预算耗尽 → 停")
    func roundBudgetGate() {
        let gate = GoalEngine.gate(goal: goal(rounds: 10, roundBudget: 10), conditions: .default, wake: .foreground)
        #expect(!gate.isAllowed)
        if case .denied(let kind, let explanation) = gate {
            #expect(kind == .rounds)
            #expect(explanation.contains("10 轮"))
        }
    }

    @Test("目标结束后不再推进")
    func terminalGoalNeverAdvances() {
        var g = goal()
        g.status = .completed
        #expect(!GoalEngine.gate(goal: g, conditions: .default, wake: .foreground).isAllowed)
    }

    @Test("门禁顺序：热 > 僵尸 > 开关 > 成本（先排除不可协商的）")
    func gateOrdering() {
        // 同时有过热与预算耗尽 → 报过热（更不可协商）
        let conditions = GoalEngine.RuntimeConditions(
            thermal: .critical, remainingCostMicroUSD: 0, hoursSinceLastActivity: 100
        )
        if case .denied(let kind, _) = GoalEngine.gate(goal: goal(), conditions: conditions, wake: .processingWindow) {
            #expect(kind == .thermal)
        }
    }

    // MARK: 创建与清理

    @Test("⚠️ 最多 5 个活跃目标（手机里不能挂着一堆半成品）")
    func maxActiveGoals() {
        var existing: [Goal] = []
        for i in 0..<5 {
            existing.append(try! GoalEngine.create(objective: "目标 \(i)", existing: existing, now: base))
        }
        #expect(!GoalEngine.canCreateGoal(existing: existing))
        #expect(throws: GoalEngine.CreationError.self) {
            try GoalEngine.create(objective: "第六个", existing: existing, now: base)
        }
        // 完成的不计入
        existing[0].status = .completed
        #expect(GoalEngine.canCreateGoal(existing: existing))
    }

    @Test("空目标被拒绝")
    func emptyObjectiveRejected() {
        #expect(throws: GoalEngine.CreationError.self) {
            try GoalEngine.create(objective: "   ", existing: [], now: base)
        }
    }

    @Test("成果卡内容完整（Goal 完成时要给用户一张卡）")
    func resultCard() {
        var g = goal()
        g.roundsUsed = 4
        g.budget.usedCostMicroUSD = 123_000
        g.budget.usedBatteryPercent = 6
        g.completedAt = base.addingTimeInterval(7200)
        let card = GoalEngine.resultCard(for: g, artifacts: ["report.md", "chart.png"], now: g.completedAt!)
        #expect(card.contains("把 API 文档补全"))
        #expect(card.contains("4 轮"))
        #expect(card.contains("2 小时"))
        #expect(card.contains("$0.123"))
        #expect(card.contains("耗电 6%"))
        #expect(card.contains("report.md"))
    }

    @Test("进度描述（首页卡片直接用）")
    func progressDescription() {
        #expect(GoalEngine.progressDescription(goal(rounds: 2)) == "第 3/10 轮")
        var blocked = goal()
        blocked.status = .blocked
        blocked.blockedReason = "缺 API key"
        #expect(GoalEngine.progressDescription(blocked).contains("缺 API key"))
    }

    @Test("唤醒来源的语义：哪些属于「后台自动」（决定能不能花钱）")
    func wakeReasonSemantics() {
        #expect(!GoalEngine.WakeReason.foreground.isBackgroundAutomatic)
        #expect(!GoalEngine.WakeReason.userAction.isBackgroundAutomatic)
        #expect(GoalEngine.WakeReason.backgroundPush.isBackgroundAutomatic)
        #expect(GoalEngine.WakeReason.appRefresh.isBackgroundAutomatic)
        #expect(GoalEngine.WakeReason.processingWindow.isBackgroundAutomatic)
        #expect(GoalEngine.WakeReason.scheduledWindow.isBackgroundAutomatic)
    }
}

