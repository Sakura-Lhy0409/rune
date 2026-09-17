import Foundation

/// 事件类型。
///
/// **事件日志是唯一真相源**（docs/12 §1）：会话、检查点、记忆、审计、成本账本全部可从事件重建。
/// 因此新增事件类型是**低风险**的（payload 是 JSON，不改表结构），
/// 但**修改已有事件的语义是高风险**的（会让历史回放与迁移失效）——需同步更新回放夹具。
public enum EventKind: String, Sendable, Codable, Hashable, CaseIterable {
    // 会话
    case sessionCreated = "SessionCreated"
    case sessionTitleSet = "SessionTitleSet"
    case sessionArchived = "SessionArchived"
    case memoryDisabled = "MemoryDisabled"

    // 输入
    case userMessage = "UserMessage"
    case voiceTranscribed = "VoiceTranscribed"
    case shareReceived = "ShareReceived"
    case intentInvoked = "IntentInvoked"
    case cameraCaptured = "CameraCaptured"

    // 计划
    case planProposed = "PlanProposed"
    case planApproved = "PlanApproved"
    case planRevised = "PlanRevised"
    case planStepStatusChanged = "PlanStepStatusChanged"

    // 模型
    case modelCallStarted = "ModelCallStarted"
    case modelCallStreaming = "ModelCallStreaming"
    case modelCallFinished = "ModelCallFinished"
    case modelCallFailed = "ModelCallFailed"
    case modelDegraded = "ModelDegraded"
    case reasoningBlockReceived = "ReasoningBlockReceived"
    case modelSelected = "ModelSelected"

    // 工具
    case toolCallRequested = "ToolCallRequested"
    case toolApprovalRequested = "ToolApprovalRequested"
    case toolApprovalDecided = "ToolApprovalDecided"
    case toolCallStarted = "ToolCallStarted"
    case toolCallFinished = "ToolCallFinished"
    case toolCallFailed = "ToolCallFailed"
    case toolCallDenied = "ToolCallDenied"
    /// 模型自己把上一个错误改好了（**这是我们想展示给用户的信任信号**：它在自己修，不用管）
    case modelSelfCorrected = "ModelSelfCorrected"
    /// 修正机会用尽 / 逐字重复 / 在乱试 → 停下来问用户（docs/04 §4.4）
    case correctionEscalated = "CorrectionEscalated"
    /// 运行时往对话里补了一段引导语（来源标记为 runtimeGuidance，**不是**用户指令）
    case guidanceInjected = "GuidanceInjected"
    /// 用户对「修正失败」做出了选择（继续 / 换方案 / 自己给参数 / 停下）
    case correctionResolved = "CorrectionResolved"
    /// 已出现在对话里、但从未执行的工具调用被补上了结果（**维持协议不变式**）
    case orphanCallsReaped = "OrphanCallsReaped"

    // 沙箱
    case sandboxStarted = "SandboxStarted"
    case sandboxResourceWarning = "SandboxResourceWarning"
    case sandboxKilled = "SandboxKilled"
    case sandboxOutputChunk = "SandboxOutputChunk"

    // 文件
    case fileRead = "FileRead"
    case fileWritten = "FileWritten"
    case fileDeleted = "FileDeleted"
    case fileMoved = "FileMoved"
    case patchApplied = "PatchApplied"
    case patchRejected = "PatchRejected"

    // Git
    case gitCommit = "GitCommit"
    case gitPushAttempted = "GitPushAttempted"
    case gitPushSucceeded = "GitPushSucceeded"
    case gitPushFailed = "GitPushFailed"
    case prCreated = "PRCreated"

    // 检查点
    case checkpointCreated = "CheckpointCreated"
    case checkpointRestored = "CheckpointRestored"
    case turnForked = "TurnForked"

    // 安全
    case capabilityRequested = "CapabilityRequested"
    case capabilityGranted = "CapabilityGranted"
    case capabilityDenied = "CapabilityDenied"
    case egressBlocked = "EgressBlocked"
    case egressAudited = "EgressAudited"
    case injectionSuspected = "InjectionSuspected"
    case humanOnlyZoneTouched = "HumanOnlyZoneTouched"

    // 预算
    case budgetWarning = "BudgetWarning"
    case budgetExceeded = "BudgetExceeded"
    case turnPaused = "TurnPaused"
    case turnResumed = "TurnResumed"

    // 生命周期
    case appForeground = "AppForeground"
    case appBackground = "AppBackground"
    case turnInterrupted = "TurnInterrupted"
    case turnRecovered = "TurnRecovered"
    case offlineDetected = "OfflineDetected"
    case lowPowerEntered = "LowPowerEntered"
    case thermalPressure = "ThermalPressure"

    // 编排
    case subagentSpawned = "SubagentSpawned"
    case subagentFinished = "SubagentFinished"
    case workflowPhaseStarted = "WorkflowPhaseStarted"
    case workflowFinished = "WorkflowFinished"
    case jobStarted = "JobStarted"
    case jobFinished = "JobFinished"
    case jobKilled = "JobKilled"

    // 记忆
    case memoryCandidateCreated = "MemoryCandidateCreated"
    case memoryWritten = "MemoryWritten"
    case memoryRejected = "MemoryRejected"
    case memoryQuarantined = "MemoryQuarantined"

    // 交付
    case artifactCreated = "ArtifactCreated"
    case fileReturned = "FileReturned"
    case notificationSent = "NotificationSent"

    /// 是否属于"安全类事件"（UI 上要有独立的展示与导出，且不可被自动清理）
    public var isSecurityRelevant: Bool {
        switch self {
        case .capabilityDenied, .egressBlocked, .injectionSuspected, .humanOnlyZoneTouched,
             .sandboxKilled, .gitPushAttempted:
            return true
        default:
            return false
        }
    }

    /// 是否应该在 UI 的时间轴上显示为"里程碑"（而不是细节）
    public var isMilestone: Bool {
        switch self {
        case .planApproved, .planRevised, .checkpointCreated, .checkpointRestored,
             .gitCommit, .gitPushSucceeded, .prCreated, .artifactCreated,
             .jobFinished, .subagentFinished, .workflowFinished,
             .correctionEscalated:
            return true
        default:
            return false
        }
    }
}

// MARK: - 事件信封

/// 事件信封。
///
/// `payload` 用 `JSONValue` 而不是强类型，是为了让"新增事件类型"不需要改表结构
/// —— 这是事件溯源在移动端的关键工程优势（schema 演进成本极低）。
/// 强类型访问通过下面的 `Payload` 便捷构造 + 各模块自己的解码器完成。
public struct RuntimeEvent: Sendable, Codable, Hashable, Identifiable {
    /// 全局单调序号（数据库自增），**不是**数组下标
    public let sequence: Int64
    public let id: UUID
    public let sessionID: UUID
    public let turnID: UUID?
    public let goalID: UUID?
    /// 子代理泳道（同一 Turn 内可并行多个子代理）
    public let subagentID: UUID?
    public let kind: EventKind
    public let payload: JSONValue
    /// 该事件内容来源的信任级
    public let originTrust: TrustLevel
    /// 污点标记（传播用）
    public let tainted: Bool
    public let createdAt: Date
    public let previousHash: Data?
    public let hash: Data

    public init(
        sequence: Int64,
        id: UUID = UUID(),
        sessionID: UUID,
        turnID: UUID? = nil,
        goalID: UUID? = nil,
        subagentID: UUID? = nil,
        kind: EventKind,
        payload: JSONValue = .object([:]),
        originTrust: TrustLevel = .toolResultTrusted,
        tainted: Bool = false,
        createdAt: Date = Date(),
        previousHash: Data?
    ) {
        self.sequence = sequence
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.goalID = goalID
        self.subagentID = subagentID
        self.kind = kind
        self.payload = payload
        self.originTrust = originTrust
        self.tainted = tainted || originTrust.isTainted
        self.createdAt = createdAt
        self.previousHash = previousHash
        // 哈希在构造时立即计算 —— 事件一旦创建就不可篡改
        var hasher = SHA256.Streaming()
        if let previousHash { hasher.update(previousHash) }
        hasher.update(Array(id.uuidString.utf8))
        hasher.update(Array(kind.rawValue.utf8))
        hasher.update(SHA256.hash(payload.canonicalString()))
        hasher.update(Array(String(Int(createdAt.timeIntervalSince1970 * 1000)).utf8))
        self.hash = hasher.finalize()
    }

    /// 重新计算哈希并校验（用于检测审计日志被篡改）
    public func verifyHash() -> Bool {
        var hasher = SHA256.Streaming()
        if let previousHash { hasher.update(previousHash) }
        hasher.update(Array(id.uuidString.utf8))
        hasher.update(Array(kind.rawValue.utf8))
        hasher.update(SHA256.hash(payload.canonicalString()))
        hasher.update(Array(String(Int(createdAt.timeIntervalSince1970 * 1000)).utf8))
        return hasher.finalize() == hash
    }

    public var hashHex: String {
        hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 强类型头部（用于 UI 列表，不需要解 payload）

    /// 时间轴上显示的一行标题
    public var displayTitle: String {
        switch kind {
        case .userMessage:        return "收到输入"
        case .planProposed:       return "生成计划"
        case .planApproved:       return "计划已批准"
        case .planRevised:        return "计划已调整"
        case .modelCallStarted:   return "调用模型"
        case .modelCallFinished:  return "模型返回"
        case .modelDegraded:      return "渠道降级"
        case .toolCallStarted:    return "执行工具"
        case .toolCallFinished:   return "工具完成"
        case .toolCallFailed:     return "工具失败"
        case .toolCallDenied:     return "已被拦截"
        case .modelSelfCorrected: return "模型自行修正"
        case .correctionEscalated: return "需要你决定"
        case .correctionResolved: return "已按你的选择继续"
        case .orphanCallsReaped:  return "补记未执行的调用"
        case .patchApplied:       return "应用补丁"
        case .patchRejected:      return "拒绝补丁"
        case .checkpointCreated:  return "创建检查点"
        case .checkpointRestored: return "回滚到检查点"
        case .gitCommit:          return "本地提交"
        case .gitPushSucceeded:   return "已推送"
        case .prCreated:          return "创建 PR"
        case .artifactCreated:    return "生成产物"
        case .egressBlocked:      return "阻止外发"
        case .injectionSuspected: return "疑似提示注入"
        case .budgetExceeded:     return "超出预算"
        case .turnPaused:         return "任务暂停"
        case .turnResumed:        return "任务恢复"
        case .turnRecovered:      return "从检查点恢复"
        case .jobStarted:         return "作业开始"
        case .jobFinished:        return "作业完成"
        case .subagentSpawned:    return "启动子代理"
        case .subagentFinished:   return "子代理完成"
        case .workflowFinished:   return "工作流完成"
        case .memoryWritten:      return "写入记忆"
        case .fileReturned:       return "交付文件"
        default:                  return kind.rawValue
        }
    }
}
