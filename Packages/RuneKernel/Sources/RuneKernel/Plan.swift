import Foundation

// MARK: - 计划

/// 计划。**不是一段散文，而是结构化数据**（可勾选、可比较、可回滚）—— 见 docs/04 §3.1。
///
/// 两个杀手级细节：
///   1. `steps[].toolHints` 用于**提前批量申请权限**（手机上一次弹一个审批是灾难）
///   2. `estimatedCost` 在批准前就展示（"这一步大约花 $0.03、2 分钟"）
///      —— 桌面 Agent 几乎都不给，用户因此不敢放手
public struct Plan: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    /// 修订号。计划可以被修正（PlanRevised 事件），但**目标不改**——改目标等于新建 Goal。
    public var revision: Int
    public var goalSummary: String
    /// 我假设了什么（用户可纠正）
    public var assumptions: [String]
    public var steps: [PlanStep]
    public var risks: [RiskNote]
    public var estimatedCost: CostEstimate
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        revision: Int = 1,
        goalSummary: String,
        assumptions: [String] = [],
        steps: [PlanStep],
        risks: [RiskNote] = [],
        estimatedCost: CostEstimate = .init(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.revision = revision
        self.goalSummary = goalSummary
        self.assumptions = assumptions
        self.steps = steps
        self.risks = risks
        self.estimatedCost = estimatedCost
        self.createdAt = createdAt
    }

    /// 计划里声明的全部工具（用于一次性批量申请权限）
    public var requiredTools: Set<String> {
        Set(steps.flatMap(\.toolHints))
    }

    public var progress: (done: Int, total: Int) {
        (steps.filter { $0.status == .done }.count, steps.count)
    }

    /// 是否发生了"重大偏离"（需要暂停并请求用户确认）
    ///
    /// 规则（docs/04 §3.2）：改目标、增加危险网络副作用、成本超预估 150% → 必须确认；
    /// 换一个等价的读操作、跳过可选验证 → 自动继续但留痕。
    public func requiresUserConfirmation(
        comparedTo original: Plan,
        actualCostMicroUSD: Int
    ) -> (needed: Bool, reason: String?) {
        if goalSummary != original.goalSummary {
            return (true, "目标描述发生了变化：\n原：\(original.goalSummary)\n新：\(goalSummary)")
        }
        let originalRisky = Set(original.risks.filter { $0.isIrreversibleOrNetwork }.map(\.summary))
        let newRisky = risks.filter { $0.isIrreversibleOrNetwork && !originalRisky.contains($0.summary) }
        if !newRisky.isEmpty {
            return (true, "新增了危险步骤：\(newRisky.map(\.summary).joined(separator: "；"))")
        }
        if original.estimatedCost.microUSD > 0,
           actualCostMicroUSD > original.estimatedCost.microUSD * 3 / 2 {
            return (true, "实际花费 \(actualCostMicroUSD) 微美元，超过预估的 150%")
        }
        return (false, nil)
    }
}

public struct PlanStep: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public var title: String
    public var kind: StepKind
    /// 预计用到哪些工具（**用于提前批量申请权限**）
    public var toolHints: [String]
    /// 预计会触碰哪些路径（**批量授权的精确范围**）。
    ///
    /// ⚠️ 没有它就只能退化成"把整个工作区都授权给它"——那是最粗的一种授权。
    /// 有了它，用户看到的是"这一步只会写 `/workspace/src/**`"，而不是"允许它随便写"。
    public var pathHints: [VFSPath]
    public var status: StepStatus
    public var checkpointID: UUID?
    /// 该步骤产出的制品
    public var artifacts: [UUID]

    public init(
        id: UUID = UUID(),
        title: String,
        kind: StepKind,
        toolHints: [String] = [],
        pathHints: [VFSPath] = [],
        status: StepStatus = .pending,
        checkpointID: UUID? = nil,
        artifacts: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.toolHints = toolHints
        self.pathHints = pathHints
        self.status = status
        self.checkpointID = checkpointID
        self.artifacts = artifacts
    }

    public enum StepKind: String, Sendable, Codable, Hashable, CaseIterable {
        case read
        case analyze
        case write
        case execute
        case network
        case verify
        case deliver

        public var displayName: String {
            switch self {
            case .read: return "读取"
            case .analyze: return "分析"
            case .write: return "修改"
            case .execute: return "执行"
            case .network: return "联网"
            case .verify: return "验证"
            case .deliver: return "交付"
            }
        }

        /// 这类步骤是否"可能会改变世界"（决定是否必须走审批）
        public var isSideEffecting: Bool {
            switch self {
            case .read, .analyze, .verify: return false
            case .write, .execute, .network, .deliver: return true
            }
        }
    }

    public enum StepStatus: String, Sendable, Codable, Hashable, CaseIterable {
        case pending
        case running
        case done
        case skipped
        case failed
        /// 被修正过（保留痕迹，不假装原计划就是如此）
        case amended

        public var isTerminal: Bool {
            switch self {
            case .pending, .running: return false
            case .done, .skipped, .failed, .amended: return true
            }
        }

        public var displayName: String {
            switch self {
            case .pending: return "待做"
            case .running: return "进行中"
            case .done: return "完成"
            case .skipped: return "已跳过"
            case .failed: return "失败"
            case .amended: return "已调整"
            }
        }
    }
}

public struct RiskNote: Sendable, Codable, Hashable {
    public var summary: String
    public var severity: ToolSpec.RiskLevel
    /// 是否可撤销（**必须展示给用户**——"能不能撤销"是用户敢不敢点允许的核心依据）
    public var isReversible: Bool
    public var isIrreversibleOrNetwork: Bool

    public init(summary: String, severity: ToolSpec.RiskLevel, isReversible: Bool, isIrreversibleOrNetwork: Bool = false) {
        self.summary = summary
        self.severity = severity
        self.isReversible = isReversible
        self.isIrreversibleOrNetwork = isIrreversibleOrNetwork
    }
}

public struct CostEstimate: Sendable, Codable, Hashable {
    /// 微美元
    public var microUSD: Int
    /// 预计秒数
    public var estimatedSeconds: Int

    public init(microUSD: Int = 0, estimatedSeconds: Int = 0) {
        self.microUSD = microUSD
        self.estimatedSeconds = estimatedSeconds
    }

    public var displayString: String {
        let dollars = Double(microUSD) / 1_000_000
        let time: String
        if estimatedSeconds < 60 {
            time = "\(estimatedSeconds) 秒"
        } else {
            time = "\(Int(round(Double(estimatedSeconds) / 60))) 分钟"
        }
        return String(format: "约 $%.2f · %@", dollars, time)
    }
}

// MARK: - 目标（Goal）

/// 目标：**跨轮持续推进**的长期任务。
///
/// 这是 Rune 最重要的一条差异化能力（docs/04 §5）：手机上的任务天然会被打断
/// （锁屏、来电话、进地铁、上班），Goal 让任务在"被打断的世界"里仍能完成。
public struct Goal: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    /// **不可变**目标（改目标 = 新建 Goal）
    public let objective: String
    public var status: GoalStatus
    /// 自动续跑轮次上限
    public var roundBudget: Int
    public var roundsUsed: Int
    /// 阻塞原因。**只有同一具体条件连续 ≥3 轮才允许写**（难度大/不确定/还有活可干都不算阻塞）
    public var blockedReason: String?
    /// 连续同因轮次计数（防止模型轻易放弃）
    public var blockedStreak: Int
    /// **连续无实质进展**的轮次计数。
    ///
    /// 与 `blockedStreak` 是两件事：
    ///   * `blockedStreak` = "我遇到了同一个障碍"
    ///   * `consecutiveNoProgress` = "我没有障碍，但也没做出任何东西"（跑偏 / 空转）
    /// 后者同样需要熔断 —— 否则 Agent 会一直"在忙"，烧钱烧电却什么都没产出。
    public var consecutiveNoProgress: Int
    /// 什么算"完成"
    public var deliverableSpec: DeliverableSpec?
    public var budget: GoalBudget
    public var lastCheckpointID: UUID?
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        objective: String,
        status: GoalStatus = .active,
        roundBudget: Int = 10,
        roundsUsed: Int = 0,
        blockedReason: String? = nil,
        blockedStreak: Int = 0,
        consecutiveNoProgress: Int = 0,
        deliverableSpec: DeliverableSpec? = nil,
        budget: GoalBudget = .init(),
        lastCheckpointID: UUID? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.objective = objective
        self.status = status
        self.roundBudget = roundBudget
        self.roundsUsed = roundsUsed
        self.blockedReason = blockedReason
        self.blockedStreak = blockedStreak
        self.consecutiveNoProgress = consecutiveNoProgress
        self.deliverableSpec = deliverableSpec
        self.budget = budget
        self.lastCheckpointID = lastCheckpointID
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    public enum GoalStatus: String, Sendable, Codable, Hashable, CaseIterable {
        case active
        case paused
        case completed
        case blocked
        case abandoned

        public var displayName: String {
            switch self {
            case .active: return "进行中"
            case .paused: return "已暂停"
            case .completed: return "已完成"
            case .blocked: return "受阻"
            case .abandoned: return "已放弃"
            }
        }

        public var isTerminal: Bool {
            self == .completed || self == .abandoned
        }
    }

    /// 可以被标记为"阻塞"的最小连续轮次。
    ///
    /// 这条规则来自 DSH 的实践（docs/02 §4.1 H1）：**模型倾向于过早放弃**，
    /// 强制它必须真的试过 3 轮同一障碍才允许上报阻塞。
    public static let blockedStreakThreshold = 3

    /// 是否允许标记为阻塞
    public var canMarkBlocked: Bool {
        blockedStreak >= Self.blockedStreakThreshold
    }

    /// 记录一次"同一原因"的失败。原因变了则计数重置。
    public mutating func recordBlockedAttempt(reason: String) {
        if blockedReason == reason {
            blockedStreak += 1
        } else {
            blockedReason = reason
            blockedStreak = 1
        }
    }

    public mutating func clearBlocked() {
        blockedReason = nil
        blockedStreak = 0
    }

    /// 是否还有续跑预算
    public var hasRemainingRounds: Bool { roundsUsed < roundBudget }

    /// 移动端专属约束：单机最多同时挂 5 个 Goal（避免"手机里挂着一堆半成品"）
    public static let maxActiveGoals = 5
}

/// 什么算"完成"。没有这个，Goal 会永远跑下去。
public struct DeliverableSpec: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        /// 产出某个文件/制品
        case artifactProduced
        /// 某个命令返回成功（例如测试全绿）
        case commandSucceeds
        /// 用户确认
        case userConfirms
        /// 所有计划步骤完成
        case allStepsDone
        /// 自定义条件（自然语言，由端侧/主模型判定）
        case naturalLanguageCondition
    }

    public var kind: Kind
    /// 描述（例如"pytest 全部通过"、"生成 report.md"）
    public var detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }
}

/// Goal 的预算（时间/成本/电量）
public struct GoalBudget: Sendable, Codable, Hashable {
    /// 单日成本上限（微美元），默认 $1.00
    public var dailyCostMicroUSD: Int
    /// 单日电量预算（百分点），默认 15%
    public var dailyBatteryPercent: Int
    public var usedCostMicroUSD: Int
    public var usedBatteryPercent: Int

    public init(
        dailyCostMicroUSD: Int = 1_000_000,
        dailyBatteryPercent: Int = 15,
        usedCostMicroUSD: Int = 0,
        usedBatteryPercent: Int = 0
    ) {
        self.dailyCostMicroUSD = dailyCostMicroUSD
        self.dailyBatteryPercent = dailyBatteryPercent
        self.usedCostMicroUSD = usedCostMicroUSD
        self.usedBatteryPercent = usedBatteryPercent
    }

    public var hasCostRemaining: Bool { usedCostMicroUSD < dailyCostMicroUSD }
    public var hasBatteryRemaining: Bool { usedBatteryPercent < dailyBatteryPercent }
    public var allowsAnotherRound: Bool { hasCostRemaining && hasBatteryRemaining }
}
