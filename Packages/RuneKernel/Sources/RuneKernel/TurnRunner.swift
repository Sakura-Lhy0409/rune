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
        steerNotes: [String] = []
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
    }

    /// 是否还能继续推进
    public var canAdvance: Bool {
        !status.isTerminal && status != .awaitingApproval && status != .awaitingUser && status != .pausedBudget
    }
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
        /// 工具说明书（用于策略判定与幂等性查询）
        public var toolRegistry: [String: ToolSpec]

        public init(
            maxRounds: Int = 16,
            maxToolCalls: Int = 24,
            maxCostMicroUSD: Int = 300_000,
            maxSelfCorrections: Int = 2,
            toolRegistry: [String: ToolSpec] = [:]
        ) {
            self.maxRounds = maxRounds
            self.maxToolCalls = maxToolCalls
            self.maxCostMicroUSD = maxCostMicroUSD
            self.maxSelfCorrections = maxSelfCorrections
            self.toolRegistry = toolRegistry
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
        /// 终态说明
        public var terminalReason: String?

        public init(
            state: TurnState,
            newEvents: [RuntimeEvent],
            didAdvance: Bool,
            pendingApproval: ApprovalRequest? = nil,
            terminalReason: String? = nil
        ) {
            self.state = state
            self.newEvents = newEvents
            self.didAdvance = didAdvance
            self.pendingApproval = pendingApproval
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
            let callPaths = deps.pathsOfCall(call, spec)
            let callAccess: PathScope.Access =
                spec.requirements.contains(.fsDelete) ? .delete
                : (spec.requirements.contains(.fsWrite) ? .write : .readOnly)

            let decision = evaluatePolicy(
                spec: spec, paths: callPaths, access: callAccess,
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
                    tool: spec, path: callPaths.first, access: callAccess
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
            appendToolResult(&state, call: intent.call, result: result)
            emit(.toolCallFinished, [
                "tool": .string(intent.call.name),
                "status": .string(result.status.rawValue),
                "wave": .int(state.waveIndex),
                "summary": .string(String(result.summary.prefix(300))),
            ])
            record(.toolExecuted, "\(intent.call.name) → \(result.status.rawValue)")

            // ⚠️ **检查点不在这里打**，而是等整个波次结束后统一打一个 —— 见 `takeWaveCheckpoint`。
            //    理由：波内多个调用是同时在飞的，为每个调用各打一个会产出"不对应任何真实状态"的检查点。
            if state.pendingIntents.isEmpty && state.currentWave.isEmpty {
                state.status = .dispatching      // 波次结束，回到派发（由它打检查点并开下一波）
            }
            return StepOutcome(state: state, newEvents: events, didAdvance: true)

        // ---------- 稳定态：不再推进 ----------
        case .awaitingApproval, .awaitingUser, .pausedBudget, .completed, .failed, .interrupted:
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
    public static func approve(_ state: TurnState, deps: Dependencies) -> TurnState {
        var state = state
        guard state.status == .awaitingApproval else { return state }
        state.status = state.queuedCalls.isEmpty ? .dispatching : .dispatching
        return state
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
