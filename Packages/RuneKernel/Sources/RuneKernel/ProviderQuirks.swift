import Foundation

// MARK: - 协议族

/// 模型渠道的协议族。**`AgentRuntime` 里不允许出现厂商名**，但网关需要知道该用哪套适配。
public enum ProtocolFamily: String, Sendable, Codable, Hashable, CaseIterable {
    case openAIChat
    case openAIResponses
    case anthropicMessages
    case geminiGenerate
    case geminiInteractions
    /// Ollama 原生端点返回的是 **NDJSON 而不是 SSE**（见 docs/附录A §1）
    case ollamaNative
    /// 自定义协议（用户用声明式 JSON 描述的非标准端点）
    case custom

    public var displayName: String {
        switch self {
        case .openAIChat: return "OpenAI Chat Completions"
        case .openAIResponses: return "OpenAI Responses"
        case .anthropicMessages: return "Anthropic Messages"
        case .geminiGenerate: return "Gemini generateContent"
        case .geminiInteractions: return "Gemini Interactions"
        case .ollamaNative: return "Ollama 原生（NDJSON）"
        case .custom: return "自定义协议"
        }
    }

    /// 数据流形态（决定用哪个解析器）
    public var streamShape: StreamShape {
        switch self {
        case .ollamaNative: return .ndjson
        case .custom: return .ndjson
        default: return .serverSentEvents
        }
    }

    public enum StreamShape: String, Sendable, Codable, Hashable {
        case serverSentEvents
        case ndjson
    }
}

// MARK: - 差异开关

public enum ToolCallDeltaStyle: String, Sendable, Codable, Hashable {
    /// Chat Completions 风格：按 `index` 分组的 `arguments` 字符串分片；`id`/`name` 只在首个分片出现
    case openAIStandard
    /// Responses 风格：`response.function_call_arguments.delta` 按 `output_index` 分组，`done` 时给全量
    case openAIResponses
    /// Anthropic：`content_block_start` → 多个 `input_json_delta.partial_json` → `stop`
    case anthropicBlocks
    /// Gemini：每个 chunk 给完整的 `functionCall` part（不流式拼装）
    case geminiParts
}

public enum ReasoningField: String, Sendable, Codable, Hashable, CaseIterable {
    case none
    /// Kimi / Z.ai / 百度 / xAI / Fireworks / 阿里 / DeepSeek / MiniMax(开启 split)
    case reasoningContent
    /// Groq（配 `include_reasoning`）、Together（视模型而定）
    case reasoning
    /// MiniMax
    case reasoningDetails
    /// Anthropic `thinking` / `redacted_thinking` 块（含不透明 signature）
    case thinkingBlocks
    /// Gemini `thought` parts（含 `thoughtSignature`）
    case thoughtParts
    /// 未开启 split 的 MiniMax 与部分 Fireworks 模型：内联在 content 里的 `<think>…</think>`
    case inlineThinkTag

    public var displayName: String {
        switch self {
        case .none: return "无思考链"
        case .reasoningContent: return "reasoning_content"
        case .reasoning: return "reasoning"
        case .reasoningDetails: return "reasoning_details"
        case .thinkingBlocks: return "thinking blocks"
        case .thoughtParts: return "thought parts"
        case .inlineThinkTag: return "内联 <think> 标签"
        }
    }
}

/// 思考链的**回传策略**。写错会直接 400（docs/附录A §4.2）。
public enum ReasoningReplayPolicy: String, Sendable, Codable, Hashable {
    /// 不回传（多数 OpenAI 兼容端点）
    case never
    /// 总是原样回传（Anthropic 的 thinking + signature；Gemini 的 thoughtSignature）
    case always
    /// **请求里有 tools 时必须回传**（DeepSeek：否则 400）
    case whenToolsPresent
    /// 无状态场景回传 `encrypted_content`（OpenAI `store:false`）
    case encryptedOnly

    public func shouldReplay(hasTools: Bool) -> Bool {
        switch self {
        case .never: return false
        case .always: return true
        case .whenToolsPresent: return hasTools
        case .encryptedOnly: return true
        }
    }

    public var explanation: String {
        switch self {
        case .never: return "该渠道不需要回传思考链"
        case .always: return "该渠道要求原样回传思考块（含不透明签名），缺了会报错"
        case .whenToolsPresent: return "该渠道在带 tools 的请求里必须回传历史思考链，否则返回 400"
        case .encryptedOnly: return "无状态模式下必须回传加密思考内容"
        }
    }
}

public enum CacheStyle: String, Sendable, Codable, Hashable {
    /// 无缓存
    case none
    /// 自动前缀缓存（OpenAI / DeepSeek / Gemini 隐式 / Groq）—— 只要前缀稳定就命中
    case automatic
    /// **需要显式断点**（Anthropic `cache_control`；OpenAI GPT-5.6+ 也需断点才产生写入）
    case explicitBreakpoints
    /// 隐式前缀（Gemini 2.5+，最小输入有门槛）
    case implicitPrefix
    /// 中转透传（能不能命中看上游，客户端不可控）
    case passThrough

    /// 是否需要我们主动打断点才有折扣
    public var requiresExplicitBreakpoints: Bool { self == .explicitBreakpoints }
}

public enum StreamingUsageStyle: String, Sendable, Codable, Hashable {
    /// 最后一个 chunk 带 usage
    case finalChunk
    /// 独立事件带 usage（Anthropic `message_delta`）
    case separateEvent
    /// **不返回 usage** → 必须本地估算并标注 `isEstimated`
    case absent
}

public enum SystemPlacement: String, Sendable, Codable, Hashable {
    /// 作为 `role: "system"` 消息
    case systemMessage
    /// 顶层参数（Anthropic 的 `system`）
    case topLevelParam
    /// 系统指令字段（Gemini 的 `systemInstruction`）
    case systemInstruction
}

public enum ToolChoiceStyle: String, Sendable, Codable, Hashable {
    case auto
    case required
    case none
    /// 部分端点不支持（发过去会报错）
    case unsupported
}

// MARK: - Quirks

/// 渠道差异的**声明式描述**。
///
/// 设计意图（docs/06 §2）：接入一个从未见过的新渠道，**往往只需要在设置里勾几个开关**，
/// 而不是改代码。这直接决定"支持市面上主流模型"这件事能不能规模化。
public struct ProviderQuirks: Sendable, Codable, Hashable {
    public var toolCallDeltaStyle: ToolCallDeltaStyle
    public var reasoningField: ReasoningField
    public var reasoningReplay: ReasoningReplayPolicy
    /// `max_tokens` / `max_completion_tokens` / `max_output_tokens`
    public var maxTokensField: String
    public var systemPlacement: SystemPlacement
    public var cacheStyle: CacheStyle
    public var streamingUsage: StreamingUsageStyle
    /// 发送前要剔除的字段（某些端点不认识就报错）
    public var unsupportedFields: Set<String>
    /// 某些兼容端点要求 tool 结果消息带 `name`
    public var requiresToolResultName: Bool
    public var toolChoiceStyle: ToolChoiceStyle
    /// 是否支持并行工具调用
    public var supportsParallelToolCalls: Bool
    /// 流式是否发送 `data: [DONE]`（DeepSeek Responses 与部分中转站**不发**）
    public var sendsDoneMarker: Bool

    public init(
        toolCallDeltaStyle: ToolCallDeltaStyle,
        reasoningField: ReasoningField = .none,
        reasoningReplay: ReasoningReplayPolicy = .never,
        maxTokensField: String = "max_tokens",
        systemPlacement: SystemPlacement = .systemMessage,
        cacheStyle: CacheStyle = .none,
        streamingUsage: StreamingUsageStyle = .finalChunk,
        unsupportedFields: Set<String> = [],
        requiresToolResultName: Bool = false,
        toolChoiceStyle: ToolChoiceStyle = .auto,
        supportsParallelToolCalls: Bool = true,
        sendsDoneMarker: Bool = true
    ) {
        self.toolCallDeltaStyle = toolCallDeltaStyle
        self.reasoningField = reasoningField
        self.reasoningReplay = reasoningReplay
        self.maxTokensField = maxTokensField
        self.systemPlacement = systemPlacement
        self.cacheStyle = cacheStyle
        self.streamingUsage = streamingUsage
        self.unsupportedFields = unsupportedFields
        self.requiresToolResultName = requiresToolResultName
        self.toolChoiceStyle = toolChoiceStyle
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.sendsDoneMarker = sendsDoneMarker
    }

    /// "没有额外差异的标准 OpenAI 兼容端点"——覆盖 L2 层绝大多数渠道
    public static let openAICompatible = ProviderQuirks(toolCallDeltaStyle: .openAIStandard)

    public static let openAIResponses = ProviderQuirks(
        toolCallDeltaStyle: .openAIResponses,
        reasoningField: .reasoning,
        reasoningReplay: .encryptedOnly,
        maxTokensField: "max_output_tokens",
        cacheStyle: .explicitBreakpoints,     // GPT-5.6+ 不打点就不产生缓存写入
        streamingUsage: .finalChunk,
        sendsDoneMarker: false
    )

    public static let anthropic = ProviderQuirks(
        toolCallDeltaStyle: .anthropicBlocks,
        reasoningField: .thinkingBlocks,
        reasoningReplay: .always,             // 缺 signature 直接报错
        maxTokensField: "max_tokens",
        systemPlacement: .topLevelParam,
        cacheStyle: .explicitBreakpoints,     // 最多 4 个断点
        streamingUsage: .separateEvent,       // message_delta 带累计 usage
        sendsDoneMarker: false
    )

    /// DeepSeek 的坑：**带 tools 时必须回传历史 reasoning_content，否则 400**
    public static let deepSeek = ProviderQuirks(
        toolCallDeltaStyle: .openAIStandard,
        reasoningField: .reasoningContent,
        reasoningReplay: .whenToolsPresent,
        maxTokensField: "max_tokens",
        cacheStyle: .automatic,               // 全自动磁盘缓存，客户端不可控
        streamingUsage: .finalChunk,
        supportsParallelToolCalls: true
    )

    public static let gemini = ProviderQuirks(
        toolCallDeltaStyle: .geminiParts,
        reasoningField: .thoughtParts,
        reasoningReplay: .always,             // thoughtSignature 必须原样回传
        maxTokensField: "maxOutputTokens",
        systemPlacement: .systemInstruction,
        cacheStyle: .implicitPrefix,
        streamingUsage: .finalChunk,
        sendsDoneMarker: false
    )

    /// 中转站：**假设什么都不能依赖**（docs/附录A §3.5）
    public static let relay = ProviderQuirks(
        toolCallDeltaStyle: .openAIStandard,
        reasoningField: .none,
        reasoningReplay: .never,
        maxTokensField: "max_tokens",
        cacheStyle: .passThrough,
        streamingUsage: .absent,              // 流式常缺 usage → 本地估算
        supportsParallelToolCalls: true,
        sendsDoneMarker: true                 // 但也可能不发；解析器必须容忍缺失
    )

    /// 供 UI 展示的"这个渠道有哪些坑"
    public var notableCaveats: [String] {
        var out: [String] = []
        if reasoningField != .none { out.append("思考链字段：\(reasoningField.displayName)") }
        if reasoningReplay != .never { out.append(reasoningReplay.explanation) }
        if cacheStyle.requiresExplicitBreakpoints { out.append("需要显式缓存断点，否则无缓存折扣") }
        if streamingUsage == .absent { out.append("流式不返回用量，成本显示为估算值") }
        if !sendsDoneMarker { out.append("流式不发送 [DONE] 标记，以连接关闭为结束信号") }
        if !unsupportedFields.isEmpty { out.append("发送前会剔除字段：\(unsupportedFields.sorted().joined(separator: ", "))") }
        if requiresToolResultName { out.append("工具结果消息必须带 name 字段") }
        return out
    }
}

// MARK: - 价格与成本

/// 模型价格（**每百万 token 的微美元**）。
///
/// 为什么全部用整数：浮点累加会漂移，而用户对账单极其敏感。
public struct ModelPrice: Sendable, Codable, Hashable {
    public var inputMicroPerMTok: Int
    public var outputMicroPerMTok: Int
    /// 缓存**读取**单价（通常 0.1×）
    public var cachedInputMicroPerMTok: Int
    /// 缓存**写入**单价（Anthropic 5m = 1.25×，1h = 2×）
    public var cacheWriteMicroPerMTok: Int
    /// 低谷折扣（DeepSeek 低谷 5 折 → 0.5）
    public var offPeakMultiplier: Double?
    /// 长上下文阈值与倍率（OpenAI >272K 时按 2× 输入 / 1.5× 输出）
    public var longContextThreshold: Int?
    public var longContextInputMultiplier: Double?
    public var longContextOutputMultiplier: Double?

    public init(
        inputMicroPerMTok: Int,
        outputMicroPerMTok: Int,
        cachedInputMicroPerMTok: Int? = nil,
        cacheWriteMicroPerMTok: Int? = nil,
        offPeakMultiplier: Double? = nil,
        longContextThreshold: Int? = nil,
        longContextInputMultiplier: Double? = nil,
        longContextOutputMultiplier: Double? = nil
    ) {
        self.inputMicroPerMTok = inputMicroPerMTok
        self.outputMicroPerMTok = outputMicroPerMTok
        // 未显式给出时按业界惯例推导：读 0.1×，写 1.25×
        self.cachedInputMicroPerMTok = cachedInputMicroPerMTok ?? Int(Double(inputMicroPerMTok) * 0.1)
        self.cacheWriteMicroPerMTok = cacheWriteMicroPerMTok ?? Int(Double(inputMicroPerMTok) * 1.25)
        self.offPeakMultiplier = offPeakMultiplier
        self.longContextThreshold = longContextThreshold
        self.longContextInputMultiplier = longContextInputMultiplier
        self.longContextOutputMultiplier = longContextOutputMultiplier
    }
}

public enum CostCalculator {

    /// 计算一次调用的成本。
    ///
    /// 计费口径（与各厂商文档对齐）：
    ///   * **未缓存**输入 = 总输入 − 缓存读取
    ///   * **缓存读取**按 cachedInput 单价
    ///   * **缓存写入**按 cacheWrite 单价（它本身也属于"输入"，但价格是 1.25×）
    ///   * 输出按 output 单价
    public static func cost(
        usage: TokenUsage,
        price: ModelPrice,
        providerID: String,
        modelID: String,
        isOffPeak: Bool = false
    ) -> CostBreakdown {
        let cachedRead = max(0, usage.cachedInputTokens)
        let cacheWrite = max(0, usage.cacheWriteTokens)
        let uncachedInput = max(0, usage.inputTokens - cachedRead)

        var inputMicro = micro(uncachedInput, price.inputMicroPerMTok)
        inputMicro += micro(cachedRead, price.cachedInputMicroPerMTok)
        inputMicro += micro(cacheWrite, price.cacheWriteMicroPerMTok)

        var outputMicro = micro(usage.outputTokens, price.outputMicroPerMTok)

        // 长上下文倍率（按"总输入"判定，与 OpenAI 的 272K 规则一致）
        if let threshold = price.longContextThreshold, usage.inputTokens > threshold {
            if let m = price.longContextInputMultiplier { inputMicro = Int(Double(inputMicro) * m) }
            if let m = price.longContextOutputMultiplier { outputMicro = Int(Double(outputMicro) * m) }
        }

        var total = inputMicro + outputMicro
        if isOffPeak, let multiplier = price.offPeakMultiplier {
            total = Int(Double(total) * multiplier)
        }

        return CostBreakdown(
            usage: usage,
            microUSD: total,
            cacheSavingsMicroUSD: savings(usage: usage, price: price),
            providerID: providerID,
            modelID: modelID,
            isEstimated: usage.isEstimated
        )
    }

    /// 缓存命中省下的钱（**正反馈，UI 要展示给用户看**）
    public static func savings(usage: TokenUsage, price: ModelPrice) -> Int {
        let cachedRead = max(0, usage.cachedInputTokens)
        guard cachedRead > 0 else { return 0 }
        let wouldHaveCost = micro(cachedRead, price.inputMicroPerMTok)
        let actuallyCost = micro(cachedRead, price.cachedInputMicroPerMTok)
        return max(0, wouldHaveCost - actuallyCost)
    }

    /// 溢出安全的微美元计算
    private static func micro(_ tokens: Int, _ perMillion: Int) -> Int {
        guard tokens > 0, perMillion > 0 else { return 0 }
        return Int((Double(tokens) * Double(perMillion)) / 1_000_000.0)
    }
}
