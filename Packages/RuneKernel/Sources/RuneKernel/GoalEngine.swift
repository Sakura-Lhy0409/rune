import Foundation

// MARK: - 目标引擎
//
// Goal 是 Rune 最重要的一条差异化能力（docs/04 §5）：手机上的任务天然会被打断
// （锁屏、来电话、进地铁、上班），Goal 让任务在"被打断的世界"里仍能完成。
//
// 引擎负责四件事：
//   1. **一轮结束后决定下一步**（继续 / 等唤醒 / 停下问人 / 完成 / 熔断）
//   2. **阻塞纪律**：不是随便说一句"我卡住了"就能把任务挂起
//   3. **完成判定**：什么算做完了（否则 Goal 会永远跑下去）
//   4. **移动端条件门禁**：电量、热、网络、预算、僵尸任务防护

public enum GoalEngine {

    // MARK: 运行环境条件

    public enum ThermalLevel: String, Sendable, Comparable, CaseIterable {
        case nominal, fair, serious, critical

        private var rank: Int {
            switch self {
            case .nominal: return 0
            case .fair: return 1
            case .serious: return 2
            case .critical: return 3
            }
        }
        public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rank < rhs.rank }
    }

    /// 一次唤醒时的设备与预算条件
    public struct RuntimeConditions: Sendable, Equatable {
        public var batteryPercent: Int
        public var isCharging: Bool
        public var isLowPowerMode: Bool
        public var isOffline: Bool
        public var thermal: ThermalLevel
        /// 今日还剩多少成本预算（微美元）
        public var remainingCostMicroUSD: Int
        /// 今日还剩多少电量预算（百分点）
        public var remainingBatteryPercent: Int
        /// 用户是否开启了自动续跑
        public var autoContinueEnabled: Bool
        /// 距上次活动过了多少小时（**防僵尸任务半夜自己跑起来**）
        public var hoursSinceLastActivity: Double
        public var isForeground: Bool

        public init(
            batteryPercent: Int = 100,
            isCharging: Bool = false,
            isLowPowerMode: Bool = false,
            isOffline: Bool = false,
            thermal: ThermalLevel = .nominal,
            remainingCostMicroUSD: Int = 1_000_000,
            remainingBatteryPercent: Int = 15,
            autoContinueEnabled: Bool = true,
            hoursSinceLastActivity: Double = 0,
            isForeground: Bool = false
        ) {
            self.batteryPercent = batteryPercent
            self.isCharging = isCharging
            self.isLowPowerMode = isLowPowerMode
            self.isOffline = isOffline
            self.thermal = thermal
            self.remainingCostMicroUSD = remainingCostMicroUSD
            self.remainingBatteryPercent = remainingBatteryPercent
            self.autoContinueEnabled = autoContinueEnabled
            self.hoursSinceLastActivity = hoursSinceLastActivity
            self.isForeground = isForeground
        }

        /// 方便测试与默认值
        public static let `default` = RuntimeConditions()
    }

    /// 唤醒来源
    public enum WakeReason: String, Sendable, Equatable, CaseIterable {
        /// 用户打开 App（不受后台限制）
        case foreground
        /// 静默推送（30 秒、每小时 2-3 条、不保证送达）
        case backgroundPush
        /// BGAppRefreshTask（最多 30 秒）
        case appRefresh
        /// BGProcessingTask（设备空闲、充电时）
        case processingWindow
        /// 用户设定的工作时段
        case scheduledWindow
        /// 用户手动触发
        case userAction

        /// 这类唤醒**能不能花钱**（后台自动续跑默认不许花钱，除非用户预先授权）
        public var isBackgroundAutomatic: Bool {
            switch self {
            case .foreground, .userAction: return false
            case .backgroundPush, .appRefresh, .processingWindow, .scheduledWindow: return true
            }
        }
    }

    // MARK: 一轮的结果

    /// 一轮推进的结果（由运行时填好后交给引擎决策）
    public struct RoundOutcome: Sendable, Equatable {
        public enum Result: String, Sendable, Equatable {
            /// 有实质推进（产出制品 / 推进了步骤）
            case progressed
            /// 没有推进，但也没有遇到障碍（跑偏 / 空转）
            case noProgress
            /// 遇到了具体障碍
            case blocked
            case failed
            /// 达成交付物
            case delivered
            case userAborted
        }

        public var result: Result
        /// 具体障碍（`blocked` 时必填；用于"同一条件连续 3 轮"的判定）
        public var blockingReason: String?
        /// 已经尝试过的办法（标记阻塞时必须列出 ≥3 条）
        public var attemptedFixes: [String]
        /// **需要用户做的那一件事**（标记阻塞时必填，且必须是一件可执行的事）
        public var needsUserTo: String?
        public var evidence: DeliverableEvidence
        public var costMicroUSD: Int
        public var batteryUsedPercent: Int
        public var checkpointID: UUID?

        public init(
            result: Result,
            blockingReason: String? = nil,
            attemptedFixes: [String] = [],
            needsUserTo: String? = nil,
            evidence: DeliverableEvidence = .init(),
            costMicroUSD: Int = 0,
            batteryUsedPercent: Int = 0,
            checkpointID: UUID? = nil
        ) {
            self.result = result
            self.blockingReason = blockingReason
            self.attemptedFixes = attemptedFixes
            self.needsUserTo = needsUserTo
            self.evidence = evidence
            self.costMicroUSD = costMicroUSD
            self.batteryUsedPercent = batteryUsedPercent
            self.checkpointID = checkpointID
        }
    }

    /// 完成判定的证据
    public struct DeliverableEvidence: Sendable, Equatable {
        /// 本轮产出的制品名
        public var producedArtifacts: [String]
        /// 本轮成功的命令（用于 `commandSucceeds`）
        public var succeededCommands: [String]
        public var userConfirmed: Bool
        /// 计划的所有步骤是否都已完成
        public var allStepsDone: Bool
        /// 由模型/端侧对自然语言条件给出的判定（nil = 未判定）
        public var naturalLanguageAssessment: Bool?

        public init(
            producedArtifacts: [String] = [],
            succeededCommands: [String] = [],
            userConfirmed: Bool = false,
            allStepsDone: Bool = false,
            naturalLanguageAssessment: Bool? = nil
        ) {
            self.producedArtifacts = producedArtifacts
            self.succeededCommands = succeededCommands
            self.userConfirmed = userConfirmed
            self.allStepsDone = allStepsDone
            self.naturalLanguageAssessment = naturalLanguageAssessment
        }

        /// 本轮是否"做出来了东西"（用于无进展熔断判定）
        public var hasSomethingToShow: Bool {
            !producedArtifacts.isEmpty || !succeededCommands.isEmpty || allStepsDone || userConfirmed
        }
    }

    // MARK: 决策

    public enum BudgetKind: String, Sendable, Equatable {
        case rounds
        case cost
        case battery
        case thermal
        case lowPower
        case offline
        case zombieProtection
        case autoContinueDisabled
        case noProgress
    }

    public indirect enum Decision: Sendable, Equatable {
        /// 目标达成
        case completed(reason: String)
        /// 立刻再跑一轮
        case continueNow(reason: String)
        /// 先挂起，等下一次唤醒（附带原因与建议的最早时间）
        case waitForWake(reason: String, notBefore: Date?)
        /// 受阻：**必须带上"需要用户做的那一件事"**
        case blocked(reason: String, needsUserTo: String, attempted: [String])
        /// 预算/条件熔断
        case budgetExhausted(kind: BudgetKind, explanation: String)
        /// 空转熔断：没有障碍但也没产出 → 停下来问用户
        case stalled(rounds: Int, explanation: String)
        /// 用户中止
        case aborted(reason: String)
    }

    public struct RoundApplication: Sendable, Equatable {
        public var goal: Goal
        public var decision: Decision
        /// 是否消耗了一轮
        public var consumedRound: Bool

        public init(goal: Goal, decision: Decision, consumedRound: Bool) {
            self.goal = goal
            self.decision = decision
            self.consumedRound = consumedRound
        }
    }

    // MARK: 主入口：应用一轮结果

    /// 把一轮的结果落到 Goal 上，并给出下一步决策。
    ///
    /// **注意调用顺序**：先做条件门禁（`gatedDecision`）还是先应用结果？
    /// 这里是"先应用结果、再判断条件" —— 因为**这一轮已经跑完了**，条件影响的是"下一轮要不要跑"。
    public static func apply(
        outcome: RoundOutcome,
        to goal: Goal,
        conditions: RuntimeConditions,
        nextWake: WakeReason = .foreground,
        now: Date
    ) -> RoundApplication {
        var goal = goal
        var consumedRound = false

        // ---------- 1. 记账 ----------
        if outcome.result != .userAborted {
            goal.roundsUsed += 1
            consumedRound = true
            goal.budget.usedCostMicroUSD += outcome.costMicroUSD
            goal.budget.usedBatteryPercent += outcome.batteryUsedPercent
            if let checkpointID = outcome.checkpointID { goal.lastCheckpointID = checkpointID }
        }

        // ---------- 2. 分派 ----------
        switch outcome.result {
        case .userAborted:
            goal.status = .paused
            goal.clearBlocked()
            return RoundApplication(goal: goal, decision: .aborted(reason: "用户中止了这一轮"), consumedRound: false)

        case .delivered:
            goal.status = .completed
            goal.completedAt = now
            goal.clearBlocked()
            goal.consecutiveNoProgress = 0
            return RoundApplication(
                goal: goal,
                decision: .completed(reason: "达到交付条件：\(goal.deliverableSpec?.detail ?? "已交付")"),
                consumedRound: consumedRound
            )

        case .progressed:
            // 有推进 → 清空两个计数（障碍解除了、也不再空转）
            goal.consecutiveNoProgress = 0
            goal.clearBlocked()

            // 检查交付条件是否已经满足（避免"做完了却还在跑"）
            if let spec = goal.deliverableSpec, isSatisfied(spec, evidence: outcome.evidence) {
                goal.status = .completed
                goal.completedAt = now
                return RoundApplication(
                    goal: goal,
                    decision: .completed(reason: "交付条件已满足：\(spec.detail)"),
                    consumedRound: consumedRound
                )
            }

        case .noProgress:
            goal.consecutiveNoProgress += 1
            // 无进展时不该"清空"阻塞计数——它和阻塞是两回事，但也不该累加阻塞
            if goal.consecutiveNoProgress >= noProgressThreshold {
                goal.status = .paused
                return RoundApplication(
                    goal: goal,
                    decision: .stalled(
                        rounds: goal.consecutiveNoProgress,
                        explanation: """
                        连续 \(goal.consecutiveNoProgress) 轮没有实质进展（没有产出任何文件或结果）。
                        我没有遇到明确的障碍，但也没有推进 —— 继续跑下去只会消耗预算。
                        建议：告诉我更具体的目标，或把它拆成更小的任务。
                        """
                    ),
                    consumedRound: consumedRound
                )
            }

        case .blocked:
            let reason = outcome.blockingReason ?? "未说明的障碍"
            goal.recordBlockedAttempt(reason: reason)

            if goal.canMarkBlocked {
                let attempted = outcome.attemptedFixes
                let needsUserTo = outcome.needsUserTo ?? "（未说明需要你做什么 —— 这本身是个缺陷）"
                goal.status = .blocked
                return RoundApplication(
                    goal: goal,
                    decision: .blocked(reason: reason, needsUserTo: needsUserTo, attempted: attempted),
                    consumedRound: consumedRound
                )
            }
            // 还没到 3 轮 → 不许放弃，再试
            goal.consecutiveNoProgress += 1

        case .failed:
            goal.consecutiveNoProgress += 1
            if goal.consecutiveNoProgress >= noProgressThreshold {
                goal.status = .paused
                return RoundApplication(
                    goal: goal,
                    decision: .stalled(
                        rounds: goal.consecutiveNoProgress,
                        explanation: "连续 \(goal.consecutiveNoProgress) 轮失败，已暂停。已完成的部分都保留着，可以让我换个思路继续。"
                    ),
                    consumedRound: consumedRound
                )
            }
        }

        // ---------- 3. 条件门禁（决定"下一轮现在能不能跑"） ----------
        let gate = gate(goal: goal, conditions: conditions, wake: nextWake)
        if case .allowed = gate {
            return RoundApplication(goal: goal, decision: .continueNow(reason: nextRoundReason(outcome)), consumedRound: consumedRound)
        } else {
            return RoundApplication(goal: goal, decision: gate.toDecision(), consumedRound: consumedRound)
        }
    }

    static func nextRoundReason(_ outcome: RoundOutcome) -> String {
        switch outcome.result {
        case .progressed: return "这一轮有推进，继续下一步"
        case .noProgress: return "这一轮没有实质进展，再试一次（换一个思路）"
        case .blocked: return "障碍尚未达到可标记的门槛，按纪律再试一次"
        case .failed: return "这一轮失败了，再试一次"
        case .delivered, .userAborted: return "无需继续"
        }
    }

    /// 连续无实质进展的熔断门槛（docs/04 §14：连续 3 轮无实质进展 → 暂停并问用户）
    public static let noProgressThreshold = 3

    // MARK: 完成判定

    /// 交付条件是否满足
    public static func isSatisfied(_ spec: DeliverableSpec, evidence: DeliverableEvidence) -> Bool {
        switch spec.kind {
        case .artifactProduced:
            // 宽松匹配：制品名包含 spec.detail 里的关键词即算（detail 是自然语言描述）
            guard !spec.detail.isEmpty else { return !evidence.producedArtifacts.isEmpty }
            let keyword = spec.detail
            return evidence.producedArtifacts.contains { $0.contains(keyword) }
        case .commandSucceeds:
            return evidence.succeededCommands.contains { $0.contains(spec.detail) }
        case .userConfirms:
            return evidence.userConfirmed
        case .allStepsDone:
            return evidence.allStepsDone
        case .naturalLanguageCondition:
            return evidence.naturalLanguageAssessment == true
        }
    }

    // MARK: 条件门禁

    public enum Gate: Sendable, Equatable {
        case allowed
        case denied(BudgetKind, String)

        public var isAllowed: Bool { if case .allowed = self { return true }; return false }

        public func toDecision() -> Decision {
            switch self {
            case .allowed:
                return .continueNow(reason: "条件允许")
            case .denied(let kind, let explanation):
                return .budgetExhausted(kind: kind, explanation: explanation)
            }
        }
    }

    /// 判断"现在能不能再跑一轮"。
    ///
    /// 顺序即优先级：先排除不可协商的（热、僵尸、用户关了开关），再看预算。
    public static func gate(
        goal: Goal,
        conditions: RuntimeConditions,
        wake: WakeReason,
        requiresNetwork: Bool = false
    ) -> Gate {
        if goal.status.isTerminal { return .denied(.rounds, "目标已结束") }

        // 1. 轮次预算
        guard goal.hasRemainingRounds else {
            return .denied(.rounds, "已达到轮次上限（\(goal.roundBudget) 轮）。可以让我再跑几轮，或换个更聚焦的目标。")
        }

        // 2. 热：critical 一律停
        if conditions.thermal >= .critical {
            return .denied(.thermal, "设备过热，已暂停。等它凉下来我会继续。")
        }

        // 3. 僵尸任务防护：**超过 24 小时不自动续跑**
        //    （用户不希望三天前忘了的任务突然开始跑并花钱）
        if wake.isBackgroundAutomatic, conditions.hoursSinceLastActivity > 24 {
            return .denied(.zombieProtection, "距上次活动已超过 24 小时。为了避免「任务自己半夜跑起来」，我不会自动续跑 —— 打开 App 我就继续。")
        }

        // 4. 用户是否允许自动续跑
        if wake.isBackgroundAutomatic, !conditions.autoContinueEnabled {
            return .denied(.autoContinueDisabled, "你关闭了后台自动续跑。打开 App 时我会继续。")
        }

        // 5. 后台自动续跑**默认不许花钱**（docs/10 §6：防止"用户在睡觉，Agent 在烧钱"）
        if wake.isBackgroundAutomatic, conditions.remainingCostMicroUSD <= 0 {
            return .denied(.cost, "今日的后台预算已用完（默认 $0.50/天）。想继续可以在设置里提高额度。")
        }

        // 6. 成本预算：**只拦自动续跑**（docs/04 §14：单日上限触发后"停止自动续跑，只允许用户手动发起"）
        //
        // ⚠️ 这里曾经无条件拦截，是错的：预算上限保护的是"用户不在场时被烧钱"，
        //    而不是"用户就在旁边、点了继续、我们还不让跑"。
        //    真要让用户停，那应该由 UI 明确告知成本、让他自己决定。
        if wake.isBackgroundAutomatic,
           !goal.budget.hasCostRemaining || conditions.remainingCostMicroUSD <= 0 {
            return .denied(.cost, "已达到今日成本上限。已完成的部分都在，明天会自动继续，或现在打开 App 手动继续。")
        }

        // 7. 电量：低于 20% 且没充电 → 停**自动续跑**（前台用户主动发起时放行，但 UI 应提示省电）
        if wake.isBackgroundAutomatic, !conditions.isCharging, conditions.batteryPercent < 20 {
            return .denied(.battery, "电量低于 20%，已暂停后台工作。充电后我会继续。")
        }
        if wake.isBackgroundAutomatic,
           !goal.budget.hasBatteryRemaining || conditions.remainingBatteryPercent <= 0 {
            return .denied(.battery, "已达到今日电量预算。")
        }

        // 8. 低电量模式：只做本地零耗操作 → 自动续跑停
        if conditions.isLowPowerMode, wake.isBackgroundAutomatic {
            return .denied(.lowPower, "低电量模式已开启，暂停后台自动续跑。")
        }

        // 9. 网络
        if requiresNetwork, conditions.isOffline, wake.isBackgroundAutomatic {
            return .denied(.offline, "当前离线，等联网后继续。")
        }

        return .allowed
    }

    // MARK: 创建与清理

    public enum CreationError: Error, Sendable, Equatable {
        case tooManyActiveGoals(Int)
        case emptyObjective

        public var userFacingMessage: String {
            switch self {
            case .tooManyActiveGoals(let n):
                return "已经挂着 \(n) 个进行中的目标了（上限 \(Goal.maxActiveGoals)）。先收掉几个，或把这件事并进现有的目标。"
            case .emptyObjective:
                return "目标不能为空。"
            }
        }
    }

    /// 是否还能新建目标（手机里不能挂着一堆半成品）
    public static func canCreateGoal(existing: [Goal]) -> Bool {
        activeGoals(existing).count < Goal.maxActiveGoals
    }

    public static func activeGoals(_ goals: [Goal]) -> [Goal] {
        goals.filter { $0.status == .active || $0.status == .blocked }
    }

    public static func create(
        objective: String,
        existing: [Goal],
        deliverableSpec: DeliverableSpec? = nil,
        roundBudget: Int = 10,
        budget: GoalBudget = .init(),
        now: Date
    ) throws -> Goal {
        guard !objective.trimmingCharacters(in: .whitespaces).isEmpty else { throw CreationError.emptyObjective }
        let active = activeGoals(existing)
        guard active.count < Goal.maxActiveGoals else { throw CreationError.tooManyActiveGoals(active.count) }
        return Goal(
            objective: objective,
            status: .active,
            roundBudget: roundBudget,
            deliverableSpec: deliverableSpec,
            budget: budget,
            createdAt: now
        )
    }

    /// 目标完成时生成的"成果卡"内容（docs/04 §5：Goal 完成时生成一张成果卡）
    public static func resultCard(for goal: Goal, artifacts: [String], now: Date) -> String {
        let elapsed = now.timeIntervalSince(goal.createdAt)
        let hours = Int(elapsed / 3600)
        let duration = hours >= 1 ? "\(hours) 小时" : "\(Int(elapsed / 60)) 分钟"
        var lines: [String] = []
        lines.append("✅ \(goal.objective)")
        lines.append("")
        lines.append("用了 \(goal.roundsUsed) 轮、\(duration)")
        if goal.budget.usedCostMicroUSD > 0 {
            lines.append(String(format: "花费 $%.3f", Double(goal.budget.usedCostMicroUSD) / 1_000_000))
        }
        if goal.budget.usedBatteryPercent > 0 {
            lines.append("耗电 \(goal.budget.usedBatteryPercent)%")
        }
        if !artifacts.isEmpty {
            lines.append("")
            lines.append("产出：")
            lines.append(contentsOf: artifacts.map { "· \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 供 UI 的进度描述

    public static func progressDescription(_ goal: Goal) -> String {
        switch goal.status {
        case .active:
            return "第 \(goal.roundsUsed + 1)/\(goal.roundBudget) 轮"
        case .blocked:
            return "受阻：\(goal.blockedReason ?? "未说明")"
        case .paused:
            return "已暂停"
        case .completed:
            return "已完成"
        case .abandoned:
            return "已放弃"
        }
    }

    /// 阻塞上报是否合格（**这是纪律的执行点**）
    ///
    /// 不合格的阻塞上报要被驳回，让模型补齐 —— 否则"我卡住了"会变成逃避困难的万能理由。
    public struct BlockedReport: Sendable, Equatable {
        public var reason: String
        public var attemptedFixes: [String]
        public var needsUserTo: String

        public var isAcceptable: Bool {
            !reason.trimmingCharacters(in: .whitespaces).isEmpty
                && attemptedFixes.count >= 3
                && !needsUserTo.trimmingCharacters(in: .whitespaces).isEmpty
        }

        public var rejectionMessage: String? {
            guard !isAcceptable else { return nil }
            var missing: [String] = []
            if reason.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("具体的阻塞条件") }
            if attemptedFixes.count < 3 { missing.append("至少 3 种已尝试的办法（现在只有 \(attemptedFixes.count) 种）") }
            if needsUserTo.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("需要用户做的那一件事") }
            return """
            这份"受阻"报告还缺少：\(missing.joined(separator: "、"))。

            注意：**难度大、不确定、还有活可干 —— 都不算受阻。**
            只有当你确实被一个具体的条件挡住、并且已经试过至少三种办法时，才应该上报受阻。
            如果只是"还没做完"，那就继续做。
            """
        }
    }
}
