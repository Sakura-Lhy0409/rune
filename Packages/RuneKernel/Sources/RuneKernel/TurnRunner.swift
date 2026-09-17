import Foundation

// MARK: - Turn 状态
//
// 设计依据（docs/04 §1.1 / docs/10 §2）：
//   * **只有少数几个状态是"稳定可挂起"的**，其余中间态一律幂等重做
//   * 每个有副作用的工具调用必须走**三步落盘协议**：写意图 → 执行 → 写事实
//   * 因此本循环是**步进式**的：一步 = 一件可被验证/可被中断的事
//
// ⚠️ 这个类型会被持久化，字段只能**追加**，不能改语义。

/// Turn 的状态（同时充当步进状态机的"相位"）
public enum TurnStatus: String, Sendable, Codable, Hashable, CaseIterable {
    /// 刚开始，尚未做任何事
    case start
    /// 即将调用模型
    case reasoning
    /// 有工具调用排队，待逐个写"意图"
    case dispatching
    /// 已有"意图"落盘，待执行（**中断后由此恢复**）
    case executing
    /// 等待用户审批（稳定态）
    case awaitingApproval
    /// 等待用户输入（稳定态）
    case awaitingUser
    /// 预算耗尽（稳定态）
    case pausedBudget
    /// 完成
    case completed
    /// 失败
    case failed
    /// 被中断（稳定态）
    case interrupted

    /// 是否可以在这些状态下安全挂起
    public var isStable: Bool {
        switch self {
        case .awaitingApproval, .awaitingUser, .pausedBudget, .completed, .failed, .interrupted:
            return true
        case .start, .reasoning, .dispatching, .executing:
            return false
        }
    }

    public var isTerminal: Bool {
        self == .completed || self == .failed
    }
}

// MARK: - 步骤记录

public struct StepRecord: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case turnStarted
        case modelRound
        case toolIntent
        case toolExecuted
        case toolDenied
        case approvalRequested
        /// 修正机会用尽 → 停下来问用户（docs/04 §4.4）
        case correctionEscalated
        case finalized
        case recovered
    }

    public var index: Int
    public var kind: Kind
    /// 人类可读的一行摘要（时间轴直接显示它）
    public var summary: String

    public init(index: Int, kind: Kind, summary: String) {
        self.index = index
        self.kind = kind
        self.summary = summary
    }
}

// MARK: - 检查点

/// 检查点。**回滚与恢复的锚点。**
///
/// `isRestorable` 的意义（docs/04 §10.3）：如果之后发生了**不可回滚的副作用**（推送、外发、支付），
/// 必须如实标记，不能假装还能回到从前。
public struct Checkpoint: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, Hashable {
        /// 每个成功修改文件的工具调用之后（粒度最细）
        case step
        /// 每个 Turn 的 Finalize（会话级锚点）
        case turn
        /// 用户手动打的标记
        case manual
        /// **危险操作之前（强制）**
        case preDangerous
        /// 计划批准的瞬间（"开始动手"前的干净状态）
        case planApproved
    }

    public var id: UUID
    public var turnID: UUID
    public var stepIndex: Int
    /// 事件日志锚点
    public var eventSeq: Int64
    public var label: String
    public var kind: Kind
    /// 是否可完整回滚
    public var isRestorable: Bool
    /// 不可回滚时的原因（必须展示给用户）
    public var irrecoverableNote: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        turnID: UUID,
        stepIndex: Int,
        eventSeq: Int64,
        label: String,
        kind: Kind,
        isRestorable: Bool = true,
        irrecoverableNote: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.turnID = turnID
        self.stepIndex = stepIndex
        self.eventSeq = eventSeq
        self.label = label
        self.kind = kind
        self.isRestorable = isRestorable
        self.irrecoverableNote = irrecoverableNote
        self.createdAt = createdAt
    }
}

// MARK: - 待执行意图

/// "意图已落盘、结果未知"的一次工具调用。
///
/// 这是三步落盘协议的中间态，也是**崩溃恢复的关键**：
/// 恢复时看到它，说明该工具**可能已经执行过**。
/// 幂等的可以安全重做；非幂等的必须问用户（docs/10 §5.2）。
public struct PendingToolIntent: Sendable, Codable, Hashable {
    public var call: ToolCall
    public var isIdempotent: Bool
    public var riskLevel: ToolSpec.RiskLevel
    /// 意图是在哪一步写下的
    public var stepIndex: Int

    public init(call: ToolCall, isIdempotent: Bool, riskLevel: ToolSpec.RiskLevel, stepIndex: Int) {
        self.call = call
        self.isIdempotent = isIdempotent
        self.riskLevel = riskLevel
        self.stepIndex = stepIndex
    }
}

// MARK: - Turn 状态

/// 一个 Turn 的完整可持久化状态。**它是唯一真相的载体**（事件日志是它的投影来源）。
public struct TurnState: Sendable, Codable, Hashable {
    public var turnID: UUID
    public var sessionID: UUID
    public var objective: String
    public var status: TurnStatus
    /// 已完成的模型轮次（从 1 开始计）
    public var round: Int
    /// 归一化对话历史
    public var messages: [Message]
    /// 本 Turn 已执行的步骤
    public var steps: [StepRecord]
    /// 模型本轮提出、**尚未进入任何波次**的工具调用
    public var queuedCalls: [ToolCall]
    /// 当前波次中**尚未写意图**的调用（写一个就移出一个）
    public var currentWave: [ToolCall]
    /// 当前波次的全部调用（写意图后仍保留，用于"波次是否结束"与检查点判定）
    public var waveCalls: [ToolCall]
    /// 波次序号（从 1 开始；用于事件与 UI 显示"第 N 批"）
    public var waveIndex: Int
    /// 意图已落盘、结果未知的调用（**同一个波次里可能同时有多个**）
    public var pendingIntents: [PendingToolIntent]
    /// 最近一次检查点
    public var lastCheckpoint: Checkpoint?
    /// 已完成（含失败）的工具调用总数
    public var toolCallCount: Int
    public var usage: TokenUsage
    /// 事件序号（单调）
    public var eventSequence: Int64
    /// 事件哈希链尾
    public var lastEventHash: Data?
    /// 上一次被中断时的说明（用于 UI 提示"已从检查点恢复"）
    public var recoveryNote: String?
    /// 该状态是从持久化里**恢复**出来的（进程重启后由运行时置为 true）。
    ///
    /// ⚠️ 为什么需要这个显式标记：光看状态本身**无法区分**
    ///   ① "正常流程中，意图刚写完、下一步就要执行"
    ///   ② "进程刚才崩了，这个意图是崩溃前留下的"
    /// 两者状态一模一样，但处理方式完全不同（②必须发恢复事件、并把非幂等调用交给用户）。
    /// 只有运行时知道"我刚重启过"，所以由它显式告知。
    public var wasRestored: Bool
    /// 用户中途追加的要求（转向）
    public var steerNotes: [String]
    /// 修正性重试的记账（docs/04 §4.4）。
    ///
    /// ⚠️ 为什么它必须**随状态一起持久化**：手机上"一次 Turn 被中途结束"是常态
    /// （切后台、内存回收、用户插话）。不落盘的话，用户切回来之后 Agent 会
    /// 从零开始**烧同一批 token 犯同一个错** —— 而那正是最让人恼火的一种浪费。
    public var corrections: CorrectionLedger
    /// 用户对「修正失败」做出的选择（**待消费**）。
    ///
    /// 由运行时写入，由 `.awaitingUser` 这一步消费并落盘成事件。
    /// 之所以不让运行时直接改状态：用户点的那个按钮会决定往模型上下文里注入什么话，
    /// 那必须和工具调用一样可审计（谁在什么时候决定了什么）。
    public var pendingCorrectionResolution: CorrectionResolution?
    /// **本轮已获批的调用指纹。**
    ///
    /// ⚠️ 没有它就等于**审批路径是个死循环**：`PolicyEngine.approvalRequirement` 是纯函数，
    /// 同一个调用重新派发时算出来的结论完全一样 —— 于是「用户点了允许」之后又弹一次，
    /// 弹到用户放弃为止。端到端场景测试就是这么把这个洞挖出来的。
    ///
    /// ⚠️ 记的是**指纹**（callID + 工具名 + 规范化参数）而不是 callID：
    /// callID 来自厂商，理论上可以被复用。只按 id 记的话，
    /// 一个复用了旧 id 的、参数完全不同的调用会被**自动放行** —— 那是提权。
    public var approvedFingerprints: Set<String>

    public init(
        turnID: UUID = UUID(),
        sessionID: UUID = UUID(),
        objective: String,
        status: TurnStatus = .start,
        round: Int = 0,
        messages: [Message] = [],
        steps: [StepRecord] = [],
        queuedCalls: [ToolCall] = [],
        currentWave: [ToolCall] = [],
        waveCalls: [ToolCall] = [],
        waveIndex: Int = 0,
        pendingIntents: [PendingToolIntent] = [],
        lastCheckpoint: Checkpoint? = nil,
        toolCallCount: Int = 0,
        usage: TokenUsage = .zero,
        eventSequence: Int64 = 0,
        lastEventHash: Data? = nil,
        recoveryNote: String? = nil,
        wasRestored: Bool = false,
        steerNotes: [String] = [],
        corrections: CorrectionLedger = CorrectionLedger(),
        pendingCorrectionResolution: CorrectionResolution? = nil,
        approvedFingerprints: Set<String> = []
    ) {
        self.turnID = turnID
        self.sessionID = sessionID
        self.objective = objective
        self.status = status
        self.round = round
        self.messages = messages
        self.steps = steps
        self.queuedCalls = queuedCalls
        self.currentWave = currentWave
        self.waveCalls = waveCalls
        self.waveIndex = waveIndex
        self.pendingIntents = pendingIntents
        self.lastCheckpoint = lastCheckpoint
        self.toolCallCount = toolCallCount
        self.usage = usage
        self.eventSequence = eventSequence
        self.lastEventHash = lastEventHash
        self.recoveryNote = recoveryNote
        self.wasRestored = wasRestored
        self.steerNotes = steerNotes
        self.corrections = corrections
        self.pendingCorrectionResolution = pendingCorrectionResolution
        self.approvedFingerprints = approvedFingerprints
    }

    /// 是否还能继续推进。
    ///
    /// ⚠️ 定义就是「当前不是稳定态」，而不是把几个状态列出来减掉。
    ///    这里曾经是手写枚举（`!= .awaitingApproval && != .awaitingUser && != .pausedBudget`），
    ///    结果 **`.interrupted` 被漏掉了**：它是稳定态但不是终态，
    ///    于是 `run()` 会对着一个已经中断的 Turn 空转 `maxSteps`（一万次）什么都不做。
    ///    用 `isStable` 定义就不可能有这种漏 —— 新增状态时只需要回答"它稳不稳"这一个问题。
    public var canAdvance: Bool { !status.isStable }
}

// MARK: - 依赖注入

/// 工具执行器。**真正的 IO 在这里**（文件系统、沙箱、网络）。
///
/// ⚠️ 调用前运行时会先写 `ToolCallRequested`（意图落盘），由 `TurnRunner` 负责——
/// 实现方**不要**自己写意图事件，否则会破坏三步协议的原子性。
public protocol ToolExecuting: Sendable {
    func execute(_ call: ToolCall) throws -> ToolResult
}

/// 空执行器（用于只测循环本身）
public struct NoopToolExecutor: ToolExecuting {
    public init() {}
    public func execute(_ call: ToolCall) throws -> ToolResult {
        ToolResult.ok(callID: call.id, summary: "(未实际执行)")
    }
}

// MARK: - 运行器

/// **最小可用的 Turn 循环**（M0 出口标准要求它能跑通"读→改→跑测试"并支持中断恢复）。
///
/// 它是**步进式**的：`step()` 推进恰好一件事，因此：
///   * 任何一步之后进程被杀，都能从持久化的 `TurnState` 接着跑
///   * 测试可以在任意步数停下来（**这就是"崩溃一致性"测试的实现方式**）
///
/// M1 会在此基础上加：规划、审批交互、子代理、Goal 续跑、Workflow。
/// 但**三步落盘协议与幂等恢复的语义在这里就定死了**——那是架构地基，不能后补。
public enum TurnRunner {

    // MARK: 配置

    public struct Config: Sendable {
        /// 单轮最大模型往返（防止无限自我修正）
        public var maxRounds: Int
        /// 单轮最大工具调用数
        public var maxToolCalls: Int
        /// 单轮最大成本（微美元）
        public var maxCostMicroUSD: Int
        /// 同一个工具调用失败后最多自我修正几次
        public var maxSelfCorrections: Int
        /// 连续多少次工具失败（任何一次成功都清零）就认为模型在乱试
        public var maxConsecutiveFailures: Int
        /// 工具说明书（用于策略判定与幂等性查询）
        public var toolRegistry: [String: ToolSpec]

        public init(
            maxRounds: Int = 16,
            maxToolCalls: Int = 24,
            maxCostMicroUSD: Int = 300_000,
            maxSelfCorrections: Int = 2,
            maxConsecutiveFailures: Int = 5,
            toolRegistry: [String: ToolSpec] = [:]
        ) {
            self.maxRounds = maxRounds
            self.maxToolCalls = maxToolCalls
            self.maxCostMicroUSD = maxCostMicroUSD
            self.maxSelfCorrections = maxSelfCorrections
            self.maxConsecutiveFailures = maxConsecutiveFailures
            self.toolRegistry = toolRegistry
        }

        var correctionLimits: Correction.Limits {
            Correction.Limits(
                maxSelfCorrections: maxSelfCorrections,
                maxConsecutiveFailures: maxConsecutiveFailures
            )
        }
    }

    /// 依赖。**全部注入**，因此本类型完全可单测、可回放。
    public struct Dependencies: Sendable {
        /// 产出某一轮的模型事件。测试用脚本回放；生产用真实的流式 provider 适配。
        /// 输入是**当前状态**，因此脚本可以按 round / messages 决定该吐什么。
        public var modelEvents: @Sendable (TurnState) -> [ModelEvent]
        public var executor: any ToolExecuting
        public var policy: PolicyEngine
        public var policyContext: PolicyEngine.Context
        public var now: @Sendable () -> Date
        /// 成本记账（由网关实现；测试可给零成本）
        public var costOfRound: @Sendable (TokenUsage) -> CostBreakdown
        /// 从工具参数里取出**受影响的全部路径**。
        ///
        /// ⚠️ 必须是"全部"而不是"第一个"：
        ///   ① 策略引擎要对**每一个**路径做范围判定——只查第一个会让多文件补丁绕过授权；
        ///   ② 调度器要用全部路径做冲突检测。
        public var pathsOfCall: ToolScheduler.PathExtractor

        public init(
            modelEvents: @escaping @Sendable (TurnState) -> [ModelEvent],
            executor: any ToolExecuting = NoopToolExecutor(),
            policy: PolicyEngine = PolicyEngine(),
            policyContext: PolicyEngine.Context = .init(),
            now: @escaping @Sendable () -> Date = { Date() },
            costOfRound: @escaping @Sendable (TokenUsage) -> CostBreakdown = { usage in
                CostBreakdown(usage: usage, microUSD: 0, providerID: "mock", modelID: "mock")
            },
            pathsOfCall: @escaping ToolScheduler.PathExtractor = ToolScheduler.defaultPaths
        ) {
            self.modelEvents = modelEvents
            self.executor = executor
            self.policy = policy
            self.policyContext = policyContext
            self.now = now
            self.costOfRound = costOfRound
            self.pathsOfCall = pathsOfCall
        }
    }

    /// 默认的路径提取：从参数里找常见键名 + 解析补丁正文（多文件补丁会返回多条）。
    ///
    /// 真实工具应在 `ToolSpec` 里显式声明路径参数名（M2 的事）；这里给出一个够用的默认实现。
    public static let defaultPathExtractor: ToolScheduler.PathExtractor = ToolScheduler.defaultPaths

    /// 推进一件事之后的结果
    public struct StepOutcome: Sendable {
        public var state: TurnState
        public var newEvents: [RuntimeEvent]
        /// 本次是否推进了（false 表示卡住/等待外部输入）
        public var didAdvance: Bool
        /// 需要用户决策时的说明
        public var pendingApproval: ApprovalRequest?
        /// 需要用户对"修正失败"做选择时的说明（**不是审批**：这里是模型改不过来，不是权限问题）
        public var pendingCorrection: Correction.Escalation?
        /// 终态说明
        public var terminalReason: String?

        public init(
            state: TurnState,
            newEvents: [RuntimeEvent],
            didAdvance: Bool,
            pendingApproval: ApprovalRequest? = nil,
            pendingCorrection: Correction.Escalation? = nil,
            terminalReason: String? = nil
        ) {
            self.state = state
            self.newEvents = newEvents
            self.didAdvance = didAdvance
            self.pendingApproval = pendingApproval
            self.pendingCorrection = pendingCorrection
            self.terminalReason = terminalReason
        }
    }

    public struct ApprovalRequest: Sendable, Equatable {
        public var call: ToolCall
        public var requirement: ApprovalRequirement
        public var reason: String
        public var risk: ToolSpec.RiskLevel
    }

    // MARK: 推进一步

    /// 推进**恰好一件事**。
    ///
    /// 这是整个循环唯一的状态迁移入口 —— 保证"任意两步之间被杀都能恢复"。
    public static func step(
        _ state: TurnState,
        deps: Dependencies,
        config: Config
    ) -> StepOutcome {
        var state = state
        var events: [RuntimeEvent] = []

        /// 写事件的唯一入口（自动维护序号与哈希链）
        func emit(_ kind: EventKind, _ payload: JSONValue = .object([:]), trust: TrustLevel = .toolResultTrusted) {
            state.eventSequence += 1
            let event = RuntimeEvent(
                sequence: state.eventSequence,
                sessionID: state.sessionID,
                turnID: state.turnID,
                kind: kind,
                payload: payload,
                originTrust: trust,
                createdAt: deps.now(),
                previousHash: state.lastEventHash
            )
            state.lastEventHash = event.hash
            events.append(event)
        }

        func record(_ kind: StepRecord.Kind, _ summary: String) {
            state.steps.append(StepRecord(index: state.steps.count, kind: kind, summary: summary))
        }

        // ---------- 进程重启后的恢复（**必须在状态分派之前**） ----------
        //
        // 为什么放在这里而不是 `.start` 分支：崩溃时状态可能是 `.executing`（意图已写、执行未完），
        // 光看状态无法与"正常流程的下一步"区分。只有运行时的"我刚重启过"标记能区分它们。
        if state.wasRestored {
            state.wasRestored = false

            // ⚠️ 悬空意图可能**不止一个**：波次调度下，一波里的多个调用会先后写下意图，
            //    因此一次崩溃可能留下整批"已写意图、结果未知"的调用。
            let unknowns = state.pendingIntents
            let nonIdempotent = unknowns.filter { !$0.isIdempotent }

            if !nonIdempotent.isEmpty {
                // 只要有非幂等的，就必须问用户——**不能因为其他的能重做就先把它们做了**，
                // 因为重做会改变工作区，可能让用户无法判断那个不可逆操作到底发生了什么。
                state.status = .awaitingApproval
                let names = nonIdempotent.map { "「\($0.call.name)」" }.joined(separator: "、")
                let request = ApprovalRequest(
                    call: nonIdempotent[0].call,
                    requirement: .showDetails,
                    reason: """
                    任务上次被打断，有 \(unknowns.count) 个操作**是否已经生效无法确定**，其中 \(nonIdempotent.count) 个不可自动重做：\(names)。
                    这些操作可能造成重复副作用（例如重复推送 / 重复付款）。
                    请选择：重新执行 / 视为已完成 / 回滚到之前的检查点。
                    """,
                    risk: nonIdempotent.map(\.riskLevel).max(by: { rank($0) < rank($1) }) ?? .dangerous
                )
                record(.approvalRequested, "恢复：\(nonIdempotent.count) 个不可重做操作结果未知，需用户确认")
                emit(.turnRecovered, [
                    "action": .string("askUser"),
                    "count": .int(nonIdempotent.count),
                    "tools": .array(nonIdempotent.map { .string($0.call.name) }),
                ])
                return StepOutcome(state: state, newEvents: events, didAdvance: false, pendingApproval: request)
            }

            if !unknowns.isEmpty {
                let names = unknowns.map(\.call.name).joined(separator: "、")
                state.recoveryNote = "任务上次在 \(names) 执行中途被打断；这些操作可安全重做，已自动重做。"
                record(.recovered, "恢复：重做 \(unknowns.count) 个幂等调用（\(names)）")
                emit(.turnRecovered, [
                    "action": .string("redo"),
                    "count": .int(unknowns.count),
                    "tools": .array(unknowns.map { .string($0.call.name) }),
                ])
                state.status = .executing
                return StepOutcome(state: state, newEvents: events, didAdvance: true)
            }

            // 没有悬空意图 → 只是普通的重启继续
            // （此时 `currentWave` 里可能还有"尚未写意图"的调用 —— 那些**确定没执行过**，
            //   直接回到派发流程即可，不需要任何确认。）
            state.recoveryNote = "已从检查点恢复（没有结果未知的操作）。"
            record(.recovered, "恢复：从检查点继续")
            emit(.turnRecovered, ["action": .string("continue")])
            if state.status == .executing { state.status = .dispatching }
            return StepOutcome(state: state, newEvents: events, didAdvance: true)
        }

        switch state.status {

        // ---------- 启动 ----------
        case .start:
            record(.turnStarted, "开始：\(state.objective)")
            emit(.userMessage, ["objective": .string(state.objective)], trust: .userInstruction)
            state.status = .reasoning
            return StepOutcome(state: state, newEvents: events, didAdvance: true)

        // ---------- 模型轮次 ----------
        case .reasoning:
            // ---------- ① 先守住协议不变式（**必须在调用模型之前，且无条件执行**） ----------
            //
            // 只要我们要把对话发给模型，历史里每一个 `toolCall` 就必须有对应结果。
            // 把这件事放在 `.reasoning` 入口（而不是散落在各处早返回里）是一个刻意的选择：
            // **`reasoning` 是唯一一处会调用模型的地方**，所以"在它之前修好"就等价于
            // "不可能发出一条不合法的请求" —— 不变式由构造保证，而不是靠每个分支记得处理。
            let reaped = reapOrphanCalls(&state, reason: "上一轮在这里结束了，它没有被执行")
            if reaped > 0 {
                emit(.orphanCallsReaped, ["count": .int(reaped)])
                record(.recovered, "补记了 \(reaped) 个未执行的工具调用（维持协议完整）")
            }

            // ---------- ② 把用户中途转向喂给模型 ----------
            //
            // ⚠️ 这里曾经是个**哑掉的功能**：`steerNotes` 一直被持久化，却从没有人把它送进请求。
            //    用户在 Agent 干活干到一半时说"顺便也改一下文档"，界面上显示了，模型却完全不知道。
            //    转向必须走"运行时引导语"（来源 `.runtimeGuidance`），而不是伪造成用户新消息
            //    —— 前者不能驱动危险动作，后者能。
            if !state.steerNotes.isEmpty {
                let text = state.steerNotes.map { "· \($0)" }.joined(separator: "\n")
                injectGuidance(&state, text: """
                用户在你执行过程中追加了要求（**以它为准**，原有目标里与它冲突的部分作废）：
                \(text)
                请把它并入你接下来的做法，不需要从头再来。
                """, reason: "用户转向")
                state.steerNotes = []
            }

            // 预算检查（在**调用之前**，不是在烧完钱之后）
            if state.round >= config.maxRounds {
                state.status = .failed
                emit(.budgetExceeded, ["reason": .string("模型轮次达上限 \(config.maxRounds)")])
                return StepOutcome(
                    state: state, newEvents: events, didAdvance: true,
                    terminalReason: "模型往返次数达到上限（\(config.maxRounds)），已停止。可以让我继续，或换个更聚焦的目标。"
                )
            }

            let rawEvents = deps.modelEvents(state)

            // 用拼装器处理分片（**这里就复用了 M0-4 的成果**）
            var assembler = ToolCallAssembler()
            var calls: [ToolCall] = []
            var textOut = ""
            var usage = TokenUsage.zero
            var finish: FinishReason = .unknown
            var providerError: ProviderError?

            for event in rawEvents {
                switch event {
                case .textDelta(let t): textOut += t
                case .usage(let u): usage = u
                case .providerError(let e): providerError = e
                case .finished(let r): finish = r
                default: break
                }
                calls.append(contentsOf: assembler.ingest(event).map(\.call))
            }
            calls.append(contentsOf: assembler.flush().map(\.call))

            state.round += 1
            state.usage = state.usage + usage

            if let providerError, !providerError.isRetryable {
                state.status = .failed
                emit(.modelCallFailed, ["message": .string(providerError.userFacingMessage)])
                return StepOutcome(
                    state: state, newEvents: events, didAdvance: true,
                    terminalReason: providerError.userFacingMessage
                )
            }

            // 把模型的文字与工具调用都记进对话历史
            var blocks: [ContentBlock] = []
            if !textOut.isEmpty { blocks.append(.text(textOut, origin: .modelOutput)) }
            for call in calls { blocks.append(ContentBlock(kind: .toolCall(call), origin: .modelOutput)) }
            if !blocks.isEmpty {
                state.messages.append(Message(role: .assistant, blocks: blocks, origin: .modelOutput))
            }
            emit(.modelCallFinished, [
                "round": .int(state.round),
                "toolCalls": .int(calls.count),
                "finish": .string(finish.rawValue),
            ])
            record(.modelRound, "第 \(state.round) 轮：\(calls.isEmpty ? "无工具调用" : "\(calls.count) 个工具调用")")

            if calls.isEmpty {
                state.status = .reasoning
                state.queuedCalls = []
                emit(.artifactCreated, ["summary": .string(textOut.prefix(200).description)])
                state.status = .completed
                return StepOutcome(
                    state: state, newEvents: events, didAdvance: true,
                    terminalReason: textOut.isEmpty ? "模型没有产出内容。" : nil
                )
            }

            state.queuedCalls = calls
            // 新一轮从零开始排队：清掉上一轮残留的波次状态（正常情况下本来就该是空的）
            state.currentWave = []
            state.waveCalls = []
            state.waveIndex = 0
            state.pendingIntents = []
            state.status = .dispatching
            return StepOutcome(state: state, newEvents: events, didAdvance: true)

        // ---------- 派发（写意图 / 拒绝） ----------
        case .dispatching:
            // ---------- 波次管理（**必须在任何早返回之前**） ----------
            //
            // 波次 = "可以并行执行的一批调用"。调度器（M1-1）负责分波，运行器负责**边界语义**：
            //   * 波内调用按顺序**逐个写意图**（每个都是一次独立的崩溃窗口）
            //   * 波**结束后**才打一个检查点 —— 见 `takeWaveCheckpoint`
            //
            // ⚠️ 这里曾经写错过一次：波次管理被放在"队列空就回模型"的早返回**之后**，
            //    结果最后一波完成时直接跳过了检查点。**收尾逻辑不能被早返回挡住。**
            if state.currentWave.isEmpty && state.pendingIntents.isEmpty {
                // 上一波刚结束（`waveCalls` 非空说明确实跑过一波）→ 打波次检查点
                if !state.waveCalls.isEmpty {
                    if let checkpoint = takeWaveCheckpoint(&state, config: config, now: deps.now()) {
                        emit(.checkpointCreated, [
                            "label": .string(checkpoint.label),
                            "kind": .string(checkpoint.kind.rawValue),
                            "wave": .int(state.waveIndex),
                            "restorable": .bool(checkpoint.isRestorable),
                        ])
                    }
                    state.waveCalls = []
                }

                // 队列空了 → 回到模型，让它基于工具结果继续
                guard !state.queuedCalls.isEmpty else {
                    state.status = .reasoning
                    return StepOutcome(state: state, newEvents: events, didAdvance: true)
                }
                let waveDescription = startNextWave(&state, config: config)
                emit(.modelCallStreaming, [      // 复用"流式进行中"作为进度信号；真正的结构在 payload 里
                    "phase": .string("wave"),
                    "wave": .int(state.waveIndex),
                    "size": .int(state.waveCalls.count),
                    "parallel": .bool(waveDescription?.contains("并行") ?? false),
                ])
                record(.toolIntent, "波次 \(state.waveIndex)（\(state.waveCalls.count) 个）：\(waveDescription ?? "")")
            }

            // ⚠️ **有意图还没执行 → 那是 `.executing` 的活，不能去 `currentWave` 取调用。**
            //
            //    这条是被端到端场景测试逼出来的**崩溃**：恢复一个"非幂等调用结果未知"的 Turn 时，
            //    恢复分支把状态置成 `.awaitingApproval`，但那个调用在 `pendingIntents` 里、
            //    **不在** `currentWave` 里。用户点了「重新执行」之后（`approve` → `.dispatching`），
            //    波次管理的条件 `currentWave.isEmpty && pendingIntents.isEmpty` 不成立 → 整块被跳过 →
            //    直接执行 `currentWave.removeFirst()` → **空数组越界，App 崩**。
            //
            //    修法有两层：`approve` 正确地按相位路由（见它的注释），
            //    以及这里加一条**防御分支** —— 状态机必须是全函数，任何状态组合都不能崩。
            if !state.pendingIntents.isEmpty {
                state.status = .executing
                return StepOutcome(state: state, newEvents: events, didAdvance: true)
            }

            if state.toolCallCount >= config.maxToolCalls {
                state.status = .failed
                emit(.budgetExceeded, ["reason": .string("工具调用数达上限 \(config.maxToolCalls)")])
                return StepOutcome(
                    state: state, newEvents: events, didAdvance: true,
                    terminalReason: "工具调用次数达到上限（\(config.maxToolCalls)）。已完成的部分都在，可以让我继续。"
                )
            }

            let call = state.currentWave.removeFirst()
            let spec = config.toolRegistry[call.name]

            // 工具不存在 → 回灌"工具名幻觉"的可执行错误，让模型自己改
            guard let spec else {
                let suggestion = nearestToolName(to: call.name, in: Array(config.toolRegistry.keys))
                let error = ToolError(
                    kind: .unknownTool,
                    modelFacingMessage: "没有名为 `\(call.name)` 的工具。",
                    suggestion: suggestion.map { "你是不是想用 `\($0)`？" },
                    candidates: suggestion.map { [$0] } ?? []
                )
                appendToolResult(&state, call: call, result: .failure(callID: call.id, error: error))
                emit(.toolCallDenied, ["tool": .string(call.name), "reason": .string("unknownTool")])
                record(.toolDenied, "未知工具 \(call.name)")
                if state.currentWave.isEmpty && state.pendingIntents.isEmpty { state.status = .dispatching }
                return StepOutcome(state: state, newEvents: events, didAdvance: true)
            }

            // 取**全部**受影响路径：策略引擎要对每一个做范围判定
            let extraction = deps.pathsOfCall(call, spec)
            let callAccess: PathScope.Access =
                spec.requirements.contains(.fsDelete) ? .delete
                : (spec.requirements.contains(.fsWrite) ? .write : .readOnly)

            // ⚠️ **越出挂载点的路径必须直接拒绝，而不是当成"没有路径参数"。**
            //
            // 这里挡的是两类东西：
            //   ① `/etc/passwd` 这种"绝对但挂载点不认识"的路径 —— 如果按相对路径处理，
            //      它会被悄悄映射成 `/workspace/etc/passwd`，于是**被检查的路径和工具
            //      实际操作的路径不是同一个**（典型的混淆代理漏洞）。
            //   ② 模型想用 `..` 往工作区外走（`VFSPath.resolve` 会钳回来并置 `wasClamped`，
            //      钳制本身是安全的，但我们要如实告诉它，而不是让它以为自己成功了）。
            if !extraction.outsideMounts.isEmpty {
                let list = extraction.outsideMounts.joined(separator: "、")
                let error = ToolError(
                    kind: .capabilityDenied,
                    modelFacingMessage: "这些路径不在任何已授权的挂载点内：\(list)。工作区内的路径请写成相对形式（例如 `src/a.py`）。",
                    suggestion: "改用工作区内的相对路径；如果确实需要处理工作区之外的目录，请先用 set_workspace 向用户申请。"
                )
                appendToolResult(&state, call: call, result: .failure(callID: call.id, error: error))
                emit(.capabilityDenied, ["tool": .string(call.name), "reason": .string("outsideMounts")])
                record(.toolDenied, "路径越出挂载点 \(call.name)：\(list)")
                if state.currentWave.isEmpty && state.pendingIntents.isEmpty { state.status = .dispatching }
                return StepOutcome(state: state, newEvents: events, didAdvance: true)
            }

            // ⚠️ **用户已经批准过这一次调用** → 直接放行。
            //
            //    没有这一步，审批就是**死循环**：`PolicyEngine.approvalRequirement` 是纯函数，
            //    重新派发同一个调用会算出同样的「需要确认」，于是卡片会无限弹下去，
            //    直到用户放弃。端到端场景测试就是这么把这个洞挖出来的。
            //
            //    ⚠️ 只跳过"审批"这一层 —— 越出挂载点的检查在上面**必须**先执行，
            //    否则"曾经批准过一次"会变成永久的越权通行证。
            let alreadyApproved = state.approvedFingerprints.contains(approvalFingerprint(for: call))
            let decision: CapabilityDecision = alreadyApproved
                ? .allowed
                : evaluatePolicy(
                    spec: spec, paths: extraction.paths, access: callAccess,
                    call: call, policy: deps.policy, context: deps.policyContext
                )

            switch decision {
            case .humanOnly(let zone):
                let error = ToolError(
                    kind: .humanOnlyZone,
                    modelFacingMessage: zone.denialReason,
                    suggestion: "请在回复中说明理由，由用户手动处理。"
                )
                appendToolResult(&state, call: call, result: .failure(callID: call.id, error: error))
                emit(.humanOnlyZoneTouched, ["tool": .string(call.name)])
                record(.toolDenied, "人类专属区 \(call.name)")
                if state.currentWave.isEmpty && state.pendingIntents.isEmpty { state.status = .dispatching }
                return StepOutcome(state: state, newEvents: events, didAdvance: true)

            case .denied(let reason, let suggestion):
                let error = ToolError(kind: .capabilityDenied, modelFacingMessage: reason, suggestion: suggestion)
                appendToolResult(&state, call: call, result: .failure(callID: call.id, error: error))
                emit(.capabilityDenied, ["tool": .string(call.name), "reason": .string(reason)])
                record(.toolDenied, "被拒绝 \(call.name)")
                if state.currentWave.isEmpty && state.pendingIntents.isEmpty { state.status = .dispatching }
                return StepOutcome(state: state, newEvents: events, didAdvance: true)

            case .requiresApproval(let reason, let risk):
                let invocation = PolicyEngine.Invocation(
                    tool: spec, path: extraction.paths.first, access: callAccess
                )
                let requirement = deps.policy.approvalRequirement(for: invocation, context: deps.policyContext)
                // 把调用放回**当前波次**队头，等用户决定
                state.currentWave.insert(call, at: 0)
                state.status = .awaitingApproval
                emit(.toolApprovalRequested, [
                    "tool": .string(call.name),
                    "risk": .string(risk.rawValue),
                    "requirement": .string(requirement.rawValue),
                ])
                record(.approvalRequested, "待审批 \(call.name)")
                return StepOutcome(
                    state: state, newEvents: events, didAdvance: false,
                    pendingApproval: ApprovalRequest(call: call, requirement: requirement, reason: reason, risk: risk)
                )

            case .allowed:
                // ⭐ 三步协议第 1 步：**先写意图**
                let intent = PendingToolIntent(
                    call: call,
                    isIdempotent: spec.isIdempotent,
                    riskLevel: spec.riskLevel,
                    stepIndex: state.steps.count
                )
                state.pendingIntents.append(intent)
                state.status = .executing
                emit(.toolCallRequested, [
                    "tool": .string(call.name),
                    "id": .string(call.id),
                    "argsPreview": .string(call.argumentsPreview),
                    "wave": .int(state.waveIndex),
                    "waveSize": .int(state.waveCalls.count),
                ])
                record(.toolIntent, "波次 \(state.waveIndex)：准备执行 \(call.name)")
                return StepOutcome(state: state, newEvents: events, didAdvance: true)
            }

        // ---------- 执行 ----------
        case .executing:
            guard let intent = state.pendingIntents.first else {
                state.status = .dispatching
                return StepOutcome(state: state, newEvents: events, didAdvance: true)
            }

            let result: ToolResult
            do {
                result = try deps.executor.execute(intent.call)
            } catch {
                result = .failure(callID: intent.call.id, error: ToolError(
                    kind: .other,
                    modelFacingMessage: "工具执行时抛出异常：\(error)",
                    suggestion: "请检查参数，或改用其他方式完成这一步。"
                ))
            }

            // ⭐ 三步协议第 3 步：**再写事实**
            state.pendingIntents.removeFirst()
            state.toolCallCount += 1

            // ---------- 修正性重试的记账（docs/04 §4.4） ----------
            //
            // ⚠️ 顺序很关键：**先记账，再落盘结果**。
            //    因为"最后一根稻草"提示要挂进回灌正文（`Correction.delivered`），
            //    而正文**只能写一次** —— 结果一旦进了对话历史，就再也不能补话
            //    （补一条新消息会夹在 assistant 的 tool_call 和 tool_result 之间 = 协议违规）。
            let spec = config.toolRegistry[intent.call.name]
            let decision = state.corrections.record(
                call: intent.call,
                result: result,
                spec: spec,
                limits: config.correctionLimits
            )
            appendToolResult(&state, call: intent.call, result: Correction.delivered(result, decision: decision))

            emit(.toolCallFinished, [
                "tool": .string(intent.call.name),
                "status": .string(result.status.rawValue),
                "wave": .int(state.waveIndex),
                "summary": .string(String(result.summary.prefix(300))),
            ])
            record(.toolExecuted, "\(intent.call.name) → \(result.status.rawValue)")

            // 运行时往上下文里补了话 → 必须在事件日志里留痕（否则回放时会出现"无人说过"的文本）
            if decision.injectsGuidance {
                emit(.guidanceInjected, [
                    "reason": .string("修正性重试"),
                    "tool": .string(intent.call.name),
                ])
            }

            switch decision {
            case .progress(let isRecovery) where isRecovery:
                // 它在自己修 —— 这是**要让用户看见**的信任信号，不是噪音
                emit(.modelSelfCorrected, [
                    "tool": .string(intent.call.name),
                    "total": .int(state.corrections.recoveredCount),
                ])
                record(.recovered, "模型自行改好了 \(intent.call.name)（累计 \(state.corrections.recoveredCount) 次）")

            case .escalate(let escalation):
                // 该停下来问人了。⚠️ 这里**不清理** `pendingIntents` 与 `currentWave`：
                // 那些调用的意图已经落盘，恢复时会正常执行；现在把它们悄悄丢掉才是 bug。
                state.status = .awaitingUser
                emit(.correctionEscalated, [
                    "cause": .string(escalation.cause.rawValue),
                    "tool": .string(escalation.toolName),
                    "failures": .int(escalation.failureCount),
                    "options": .array(escalation.options.map { .string($0.action.rawValue) }),
                ])
                record(.correctionEscalated, "修正失败：\(escalation.headline)")
                return StepOutcome(
                    state: state, newEvents: events, didAdvance: false,
                    pendingCorrection: escalation
                )

            default:
                break
            }

            // ⚠️ **检查点不在这里打**，而是等整个波次结束后统一打一个 —— 见 `takeWaveCheckpoint`。
            //    理由：波内多个调用是同时在飞的，为每个调用各打一个会产出"不对应任何真实状态"的检查点。
            if state.pendingIntents.isEmpty && state.currentWave.isEmpty {
                state.status = .dispatching      // 波次结束，回到派发（由它打检查点并开下一波）
            }
            return StepOutcome(state: state, newEvents: events, didAdvance: true)

        // ---------- 稳定态 ----------
        case .awaitingUser:
            // 「修正失败」的选择是**通过状态机消费**的，而不是由运行时直接改状态。
            //
            // 为什么值得多这一层：用户在卡片上点的那个按钮，会决定"往模型的上下文里注入什么话"。
            // 这属于"影响模型看到什么"的动作，必须和工具调用一样落在事件日志里 ——
            // 否则事后回放这段对话时，会看到一段没人说过、也查不到来源的文本。
            guard let resolution = state.pendingCorrectionResolution else {
                return StepOutcome(state: state, newEvents: events, didAdvance: false)
            }
            state.pendingCorrectionResolution = nil
            let escalation = state.corrections.lastEscalation
            emit(.correctionResolved, [
                "action": .string(resolution.action.rawValue),
                "tool": .string(escalation?.toolName ?? ""),
                "cause": .string(escalation?.cause.rawValue ?? ""),
            ])
            state.corrections.clearEscalation()

            if resolution.action == .stop {
                // ⚠️ 停下也必须维持协议不变式：把没执行的调用补上结果，
                //    否则用户过一会儿说"那继续吧"，会话立刻 400。
                let reaped = reapOrphanCalls(&state, reason: "你选择在这里停下")
                state.corrections.recordAbandon()
                state.status = .interrupted
                record(.finalized, "已按你的选择停下（补记 \(reaped) 个未执行的调用）")
                return StepOutcome(
                    state: state, newEvents: events, didAdvance: true,
                    terminalReason: "已在你的要求下停止。已完成的部分都在，随时可以继续。"
                )
            }

            if let nudge = resolution.nudge, !nudge.isEmpty {
                injectGuidance(&state, text: nudge, reason: "修正失败后的定向提示")
                emit(.guidanceInjected, ["action": .string(resolution.action.rawValue)])
            }
            state.corrections.resetForNewDirection()
            // ⚠️ 回到 `.dispatching` 而不是 `.reasoning`：当前波次里可能还有**已经写好意图**的调用，
            //    那些调用必须被执行完，否则又会被兜底逻辑补成"未执行"，白干一次。
            state.status = .dispatching
            record(.recovered, "按你的选择继续（\(resolution.action.rawValue)）")
            return StepOutcome(state: state, newEvents: events, didAdvance: true)

        case .awaitingApproval, .pausedBudget, .completed, .failed, .interrupted:
            return StepOutcome(state: state, newEvents: events, didAdvance: false)
        }
    }

    // MARK: 连续推进

    /// 连续推进直到终态或需要外部输入。
    ///
    /// `maxSteps` 用于**崩溃一致性测试**：在任意步数停下来，模拟进程被杀。
    @discardableResult
    public static func run(
        _ state: TurnState,
        deps: Dependencies,
        config: Config,
        maxSteps: Int = 10_000
    ) -> (state: TurnState, events: [RuntimeEvent], pendingApproval: ApprovalRequest?) {
        var current = state
        var all: [RuntimeEvent] = []
        var steps = 0
        while current.canAdvance, steps < maxSteps {
            let outcome = step(current, deps: deps, config: config)
            all.append(contentsOf: outcome.newEvents)
            current = outcome.state
            steps += 1
            if let approval = outcome.pendingApproval { return (current, all, approval) }
            if !outcome.didAdvance, !current.canAdvance { break }
        }
        return (current, all, nil)
    }

    /// 用户批准后继续（把 `awaitingApproval` 解开）
    ///
    /// ⚠️ 必须**按"现在到底在等什么"路由到正确的相位**，不能一律回到 `.dispatching`：
    ///
    /// 两类等待的落点完全不同：
    ///   * **权限审批**：调用被放回 `currentWave` 队头 → 回 `.dispatching` 重新写意图；
    ///   * **恢复时"结果未知"的确认**：调用在 `pendingIntents` 里、`currentWave` 是空的
    ///     → 必须回 `.executing`。回到 `.dispatching` 会去空数组里取调用 —— **直接崩**。
    ///
    /// 这个 bug 是端到端场景测试（断电恢复）抓出来的：单元测试从没组合出
    /// "非幂等意图 + 用户批准" 这个状态，所以一路绿灯。
    public static func approve(_ state: TurnState, deps: Dependencies) -> TurnState {
        var state = state
        guard state.status == .awaitingApproval else { return state }
        if state.pendingIntents.isEmpty {
            // 权限审批：把**队头那个**调用记为已批准。
            // 不记的话，重新派发时策略引擎会算出同样的「需要确认」→ 卡片无限弹。
            if let call = state.currentWave.first {
                state.approvedFingerprints.insert(approvalFingerprint(for: call))
            }
            state.status = .dispatching
        } else {
            // 恢复时的「结果未知」确认 → 重新执行那个调用（它已经在 `pendingIntents` 里）
            state.status = .executing
        }
        return state
    }

    /// 审批记忆的指纹：**callID + 工具名 + 规范化参数**。
    ///
    /// ⚠️ 不能只记 callID：它来自厂商，理论上可以被复用。只按 id 记的话，
    /// 一个复用了旧 id、参数完全不同的调用会被**自动放行** —— 那是提权。
    /// 参数走 `canonicalString()`（键序无关），否则同一份参数换个键序就又弹一次卡片。
    static func approvalFingerprint(for call: ToolCall) -> String {
        let args = (try? call.arguments())?.canonicalString() ?? String(decoding: call.argumentsJSON, as: UTF8.self)
        return SHA256.hexDigest("\(call.id)\u{1}\(call.name)\u{1}\(args)")
    }

    // MARK: 协议不变式

    /// 把"已经出现在对话里、但从未执行"的工具调用补上结果，返回补了几个。
    ///
    /// ## 为什么这是**必须有**的，而不是锦上添花
    ///
    /// 三家协议都要求：assistant 消息里的每一个工具调用，都必须在紧随其后的消息里有**对应结果**
    /// （Anthropic 的 `tool_result` / OpenAI 的 `role: tool` / Gemini 的 `functionResponse`）。
    /// 只要漏掉一个，**下一次请求就 400**，而且报错信息通常与真正的原因隔了十万八千里
    /// （"messages: roles must alternate" / "tool_call_id not found"），极难排查。
    ///
    /// 而在手机上，"一次 Turn 没跑完就结束了"根本不是边缘情况，是**主路径**：
    /// 切后台被系统挂起、内存回收、用户插话、预算熔断、审批等待、被上面这条修正熔断…
    /// 每一条早返回路径都可能留下孤儿调用。
    ///
    /// 所以这里不试图在十几个分支里逐个处理（那是必然漏的写法），
    /// 而是**在唯一的模型调用点之前统一兜底** —— 见 `.reasoning` 分支。
    @discardableResult
    static func reapOrphanCalls(_ state: inout TurnState, reason: String) -> Int {
        // ⚠️ 判定依据必须是**对话历史**，而不是 `pendingIntents` / `currentWave` / `queuedCalls`。
        //
        //    这里踩过一次：最初按队列字段来判断，结果"预算熔断 → 用户点继续"这条最常见的路径
        //    完全兜不住 —— 新的一轮只带着 `messages` 历史进来，队列字段是空的，
        //    于是那两个孤儿的 tool_call 永远等不到结果，会话从此一发请求就 400。
        //
        //    历史才是"要发给模型的东西"，所以不变式就该读历史。
        var answered = Set<String>()
        for message in state.messages {
            for block in message.blocks {
                if let result = block.toolResultValue { answered.insert(result.callID) }
            }
        }

        var rebuilt: [Message] = []
        var reaped = 0
        for message in state.messages {
            rebuilt.append(message)
            for block in message.blocks {
                guard let call = block.toolCallValue, !answered.contains(call.id) else { continue }
                // ⚠️ 补记的结果必须**紧跟在那条助手消息之后**，不能统统一股脑追加到历史末尾：
                //    三家协议要求的配对是"相邻"的（OpenAI 的 tool 消息必须紧跟带 tool_calls 的 assistant）。
                let error = ToolError(
                    kind: .other,
                    modelFacingMessage: "这次对 `\(call.name)` 的调用没有执行：\(reason)。",
                    suggestion: "如果这一步仍然需要，请重新发起它；如果不再需要，就直接继续下一步。"
                )
                rebuilt.append(Message(
                    role: .tool,
                    blocks: [ContentBlock(kind: .toolResult(.failure(callID: call.id, error: error)),
                                          origin: .toolResultTrusted)],
                    origin: .toolResultTrusted
                ))
                answered.insert(call.id)
                reaped += 1
            }
        }
        state.messages = rebuilt

        // 队列字段一律清空：它们描述的是"接下来还要做什么"，
        // 而既然我们已经决定回到模型，继续执行旧队列只会绕过模型的判断。
        state.pendingIntents = []
        state.currentWave = []
        state.waveCalls = []
        state.queuedCalls = []
        return reaped
    }

    /// 把一段**运行时引导语**放进对话，返回它所在的消息 id。
    ///
    /// ⚠️ 三条约束同时成立才敢这么做：
    ///   1. **协议合法性**：不能凭空造一个"模型发出的工具调用"（见 `Correction.swift` 文件头）。
    ///      引导只能以文本形式出现；
    ///   2. **权限**：来源是 `.runtimeGuidance`，**不是** `.userInstruction`。
    ///      运行时替模型补充它看不到的事实，不等于替用户下命令 ——
    ///      否则运行时就能伪造用户授权去驱动危险动作；
    ///   3. **顺序**：必须紧跟在工具结果之后、下一轮模型调用之前。
    ///      放晚了模型会把提示对应到错误的对象上，比不给还糟。
    @discardableResult
    static func injectGuidance(_ state: inout TurnState, text: String, reason: String) -> UUID {
        let block = ContentBlock(kind: .text(text), origin: .runtimeGuidance)
        let message = Message(role: .user, blocks: [block], origin: .runtimeGuidance)
        state.messages.append(message)
        return message.id
    }

    /// 用户在"修正失败"卡片上做出选择之后继续。
    ///
    /// ⚠️ 唯一的入口，且**必须走状态机**：它会把选择落成 `CorrectionResolved` 事件，
    /// 并（在选择 `nudge` / `askUser` 时）注入一段来源为 `.runtimeGuidance` 的引导语。
    /// 运行时不要自己去改 `status` —— 那样这段"没人说过的话"就查不到出处了。
    ///
    /// ```swift
    /// let outcome = TurnRunner.resolve(state, .init(action: .changeApproach, nudge: option.nudgeText), deps: deps, config: config)
    /// ```
    public static func resolve(
        _ state: TurnState,
        _ resolution: CorrectionResolution,
        deps: Dependencies,
        config: Config
    ) -> StepOutcome {
        var state = state
        guard state.status == .awaitingUser, state.corrections.needsUserDecision else {
            return StepOutcome(state: state, newEvents: [], didAdvance: false)
        }
        state.pendingCorrectionResolution = resolution
        return step(state, deps: deps, config: config)
    }

    // MARK: 辅助

    /// 从 `queuedCalls` 里取下一波（用 M1-1 的调度器分波），并从队列里移除它们。
    /// 返回一句人类可读的说明（用于步骤记录与事件）。
    @discardableResult
    static func startNextWave(_ state: inout TurnState, config: Config) -> String? {
        let schedule = ToolScheduler.schedule(calls: state.queuedCalls, specs: config.toolRegistry)
        guard let wave = schedule.waves.first, !wave.calls.isEmpty else {
            // 调度器一个都没排上（例如全是未知工具）→ 直接把它们当成一波，走"工具名幻觉"兜底
            let fallback = Array(state.queuedCalls.prefix(1))
            state.queuedCalls.removeFirst(min(1, state.queuedCalls.count))
            state.currentWave = fallback
            state.waveCalls = fallback
            state.waveIndex += 1
            return "无法调度，逐个尝试"
        }

        // 调度器按"并行/串行"分了波；这里取第一波，并从队列里移除它包含的调用
        let waveIDs = Set(wave.calls.map(\.id))
        state.queuedCalls.removeAll { waveIDs.contains($0.id) }
        // 调度器可能把"需审批/未知工具"摘到 deferred 里 —— 那些调用要**放回队列**等下一轮处理
        for deferred in schedule.deferred + schedule.approvalsNeeded where
            !state.currentWave.contains(where: { $0.id == deferred.id }) {
            // 已在队列里的不动；不在的补回队尾（保持"最终会被处理"）
            if !state.queuedCalls.contains(where: { $0.id == deferred.id }) {
                state.queuedCalls.append(deferred)
            }
        }

        state.currentWave = wave.calls
        state.waveCalls = wave.calls
        state.waveIndex += 1
        return wave.reason
    }

    /// **波次检查点**。
    ///
    /// 设计取舍（M1-3 的核心决策）：波内多个调用是**同时在飞**的，
    /// 为每个调用各打一个检查点会产出"不对应任何真实状态"的检查点（时间戳几乎相同，但那些中间状态从未存在过）。
    /// 因此**以波次为单位，在整波结束后打一个**。
    ///
    /// 触发条件（与 docs/04 §10.2 对齐）：
    ///   * 本波里任一调用是非只读的（可能改了东西）→ 打点
    ///   * 或本波里任一调用产出了制品 → 打点
    ///   * 全是只读 → 不打点（只读操作不需要回滚点）
    ///
    /// `isRestorable`：只要本波里有**任何**非幂等调用，这个检查点就不能声称"完全可回滚"
    /// ——因为那一步可能已经产生了外部副作用。
    static func takeWaveCheckpoint(_ state: inout TurnState, config: Config, now: Date) -> Checkpoint? {
        let specs = state.waveCalls.compactMap { config.toolRegistry[$0.name] }
        let isReadOnlyWave = specs.allSatisfy { $0.riskLevel == .safe && !$0.requirements.contains(.fsWrite) }
        guard !isReadOnlyWave else { return nil }

        let hasNonIdempotent = specs.contains { !$0.isIdempotent }
        let hasDangerous = specs.contains { $0.riskLevel.alwaysRequiresHuman }
        let names = state.waveCalls.map(\.name).joined(separator: "、")

        let checkpoint = Checkpoint(
            turnID: state.turnID,
            stepIndex: state.steps.count,
            eventSeq: state.eventSequence,
            label: state.waveCalls.count > 1
                ? "第 \(state.waveIndex) 波完成（\(names)）"
                : "\(names) 完成",
            kind: hasDangerous ? .preDangerous : .step,
            isRestorable: !hasNonIdempotent,
            irrecoverableNote: hasNonIdempotent ? "本波含不可自动重做的操作，可能已产生外部副作用，无法完全回滚" : nil,
            createdAt: now
        )
        state.lastCheckpoint = checkpoint
        return checkpoint
    }

    /// 对一个调用的**全部受影响路径**做策略判定，取**最严格**的结果。
    ///
    /// ⚠️ 只查第一个路径是**错误**的：多文件补丁里只要有一个越权，整次调用就必须被拒。
    static func evaluatePolicy(
        spec: ToolSpec,
        paths: [VFSPath],
        access: PathScope.Access,
        call: ToolCall,
        policy: PolicyEngine,
        context: PolicyEngine.Context
    ) -> CapabilityDecision {
        let targets: [VFSPath?] = paths.isEmpty ? [nil] : paths.map { Optional($0) }
        var worst: CapabilityDecision = .allowed

        for path in targets {
            let decision = policy.evaluate(
                PolicyEngine.Invocation(tool: spec, path: path, access: access),
                context: context
            )
            if rank(decision) > rank(worst) { worst = decision }
            if rank(worst) >= rank(.humanOnly(zone: .policyFile)) { break }  // 已是最严，无需继续
        }
        _ = call
        return worst
    }

    /// 判定结果的严格程度（越大越严格；用于合并多个路径的判定）
    static func rank(_ decision: CapabilityDecision) -> Int {
        switch decision {
        case .allowed: return 0
        case .requiresApproval: return 1
        case .denied: return 2
        case .humanOnly: return 3
        }
    }

    /// 风险等级的严格程度
    static func rank(_ risk: ToolSpec.RiskLevel) -> Int {
        switch risk {
        case .safe: return 0
        case .modifying: return 1
        case .dangerous: return 2
        case .irreversible: return 3
        }
    }

    private static func appendToolResult(_ state: inout TurnState, call: ToolCall, result: ToolResult) {
        let block = ContentBlock(kind: .toolResult(result), origin: .toolResultTrusted)
        state.messages.append(Message(role: .tool, blocks: [block], origin: .toolResultTrusted))
    }

    /// 工具名幻觉的兜底：给出最接近的可用工具名（docs/04 §4.4）
    static func nearestToolName(to name: String, in available: [String]) -> String? {
        var best: (name: String, score: Int)?
        for candidate in available {
            let score = sharedPrefix(name.lowercased(), candidate.lowercased())
            if score > (best?.score ?? 0) { best = (candidate, score) }
        }
        // 相似度太低就不猜（宁可不给建议，也不要给错建议）
        guard let best, best.score >= 4 else { return nil }
        return best.name
    }

    private static func sharedPrefix(_ a: String, _ b: String) -> Int {
        var n = 0
        for (x, y) in zip(a, b) {
            if x == y { n += 1 } else { break }
        }
        return n
    }
}
