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
    /// 模型本轮提出、尚未处理的工具调用
    public var queuedCalls: [ToolCall]
    /// 意图已落盘、结果未知的调用
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
        /// 从工具参数里取出**受影响的路径**，交给策略引擎做范围判定。
        ///
        /// ⚠️ 不用这个的话，`PolicyEngine` 的路径级检查（能力令牌范围）会形同虚设——
        /// 因为调用里只有 JSON 参数，策略引擎看不到路径。
        public var pathOfCall: @Sendable (ToolCall, ToolSpec) -> VFSPath?

        public init(
            modelEvents: @escaping @Sendable (TurnState) -> [ModelEvent],
            executor: any ToolExecuting = NoopToolExecutor(),
            policy: PolicyEngine = PolicyEngine(),
            policyContext: PolicyEngine.Context = .init(),
            now: @escaping @Sendable () -> Date = { Date() },
            costOfRound: @escaping @Sendable (TokenUsage) -> CostBreakdown = { usage in
                CostBreakdown(usage: usage, microUSD: 0, providerID: "mock", modelID: "mock")
            },
            pathOfCall: @escaping @Sendable (ToolCall, ToolSpec) -> VFSPath? = TurnRunner.defaultPathExtractor
        ) {
            self.modelEvents = modelEvents
            self.executor = executor
            self.policy = policy
            self.policyContext = policyContext
            self.now = now
            self.costOfRound = costOfRound
            self.pathOfCall = pathOfCall
        }
    }

    /// 默认的路径提取：从参数里找常见键名。
    ///
    /// 真实工具应在 `ToolSpec` 里显式声明路径参数名（M1 的事）；这里给出一个够用的默认实现，
    /// 让 M0 的验收就能跑通**路径级授权**。
    public static let defaultPathExtractor: @Sendable (ToolCall, ToolSpec) -> VFSPath? = { call, _ in
        guard let obj = try? call.arguments().objectValue else { return nil }
        for key in ["path", "file", "file_path", "target", "source"] {
            if let raw = obj[key]?.stringValue, let path = VFSPath.parseOrNil(raw) {
                return path
            }
        }
        return nil
    }

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

            if let pending = state.pendingIntents.first {
                if pending.isIdempotent {
                    state.recoveryNote = "任务上次在「\(pending.call.name)」执行中途被打断；该操作可安全重做，已自动重做。"
                    record(.recovered, "恢复：重做幂等调用 \(pending.call.name)")
                    emit(.turnRecovered, ["call": .string(pending.call.name), "action": .string("redo")])
                    state.status = .executing
                    return StepOutcome(state: state, newEvents: events, didAdvance: true)
                } else {
                    // ⚠️ 非幂等：结果未知，**必须问用户**
                    state.status = .awaitingApproval
                    let request = ApprovalRequest(
                        call: pending.call,
                        requirement: .showDetails,
                        reason: """
                        任务上次在「\(pending.call.name)」执行中途被打断，**这一步是否已经生效无法确定**。
                        该操作不可自动重做（可能造成重复副作用，例如重复推送/重复付款）。
                        请选择：重新执行 / 视为已完成 / 回滚到之前的检查点。
                        """,
                        risk: pending.riskLevel
                    )
                    record(.approvalRequested, "恢复：\(pending.call.name) 结果未知，需用户确认")
                    emit(.turnRecovered, ["call": .string(pending.call.name), "action": .string("askUser")])
                    return StepOutcome(state: state, newEvents: events, didAdvance: false, pendingApproval: request)
                }
            }

            // 没有悬空意图 → 只是普通的重启继续
            state.recoveryNote = "已从检查点恢复（没有未完成的工具调用）。"
            record(.recovered, "恢复：从检查点继续")
            emit(.turnRecovered, ["action": .string("continue")])
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
            state.status = .dispatching
            return StepOutcome(state: state, newEvents: events, didAdvance: true)

        // ---------- 派发（写意图 / 拒绝） ----------
        case .dispatching:
            guard !state.queuedCalls.isEmpty else {
                // 队列空了 → 回到模型，让它基于工具结果继续
                state.status = .reasoning
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

            let call = state.queuedCalls.removeFirst()
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
                return StepOutcome(state: state, newEvents: events, didAdvance: true)
            }

            // 从参数里取出路径，让策略引擎能做**范围级**判定（而不是只知道工具名）
            let callPath = deps.pathOfCall(call, spec)
            let callAccess: PathScope.Access =
                spec.requirements.contains(.fsDelete) ? .delete
                : (spec.requirements.contains(.fsWrite) ? .write : .readOnly)

            let invocation = PolicyEngine.Invocation(
                tool: spec,
                path: callPath,
                access: callAccess,
                egressHost: nil,
                runtime: nil,
                nativeAPI: nil,
                gitRemote: nil,
                taint: nil
            )
            let decision = deps.policy.evaluate(invocation, context: deps.policyContext)

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
                return StepOutcome(state: state, newEvents: events, didAdvance: true)

            case .denied(let reason, let suggestion):
                let error = ToolError(kind: .capabilityDenied, modelFacingMessage: reason, suggestion: suggestion)
                appendToolResult(&state, call: call, result: .failure(callID: call.id, error: error))
                emit(.capabilityDenied, ["tool": .string(call.name), "reason": .string(reason)])
                record(.toolDenied, "被拒绝 \(call.name)")
                return StepOutcome(state: state, newEvents: events, didAdvance: true)

            case .requiresApproval(let reason, let risk):
                let requirement = deps.policy.approvalRequirement(for: invocation, context: deps.policyContext)
                // 把调用放回队列头，等用户决定
                state.queuedCalls.insert(call, at: 0)
                state.status = .awaitingApproval
                emit(.toolApprovalRequested, ["tool": .string(call.name), "risk": .string(risk.rawValue)])
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
                ])
                record(.toolIntent, "准备执行 \(call.name)")
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
                "summary": .string(String(result.summary.prefix(300))),
            ])
            record(.toolExecuted, "\(intent.call.name) → \(result.status.rawValue)")

            // 检查点（docs/04 §10.2：**每个成功修改文件的工具调用之后**都要有）
            // 条件：成功的、非只读的调用；或任何产出了制品的调用。
            let shouldCheckpoint = (result.status == .ok && intent.riskLevel != .safe)
                || !result.artifacts.isEmpty
            if shouldCheckpoint {
                let checkpoint = Checkpoint(
                    turnID: state.turnID,
                    stepIndex: state.steps.count,
                    eventSeq: state.eventSequence,
                    label: "\(intent.call.name) 完成",
                    kind: intent.riskLevel.alwaysRequiresHuman ? .preDangerous : .step,
                    isRestorable: intent.isIdempotent,
                    irrecoverableNote: intent.isIdempotent ? nil : "此操作可能产生外部副作用，无法完全回滚",
                    createdAt: deps.now()
                )
                state.lastCheckpoint = checkpoint
                emit(.checkpointCreated, ["label": .string(checkpoint.label), "kind": .string(checkpoint.kind.rawValue)])
            }

            state.status = .dispatching
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
