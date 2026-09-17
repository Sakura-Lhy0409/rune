import Foundation

// MARK: - 角色与消息

public enum Role: String, Sendable, Codable, Hashable, CaseIterable {
    case system
    case user
    case assistant
    case tool
}

/// 归一化消息。**所有厂商差异在网关层消化**，运行时只见这个类型。
public struct Message: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public var role: Role
    public var blocks: [ContentBlock]
    /// 该消息内容的整体信任级（取块内的最低信任级）
    public var origin: TrustLevel
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        blocks: [ContentBlock],
        origin: TrustLevel,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.origin = origin
        self.createdAt = createdAt
    }

    /// 只有文本块拼接（用于 UI 展示与端侧摘要）
    public var plainText: String {
        blocks.compactMap { block in
            if case .text(let s) = block.kind { return s }
            return nil
        }.joined()
    }
}

// MARK: - 内容块

/// 内容块。这是上下文装配的最小单位。
///
/// ⚠️ 新增 case 时必须同步更新：
///   1. `origin` 的推导逻辑（若新块类型可能承载不可信内容）
///   2. 网关层的序列化（每个 provider 都要能表达或合理丢弃它）
///   3. 上下文的 token 估算
public struct ContentBlock: Sendable, Codable, Hashable {
    public enum Kind: Sendable, Codable, Hashable {
        /// 普通文本
        case text(String)
        /// 图片（引用制品，**不内联 base64** —— 手机内存与请求体积都不允许）
        case image(ref: ArtifactRef, mime: String)
        /// 思考链（各家 thinking / reasoning 归一化到这里）
        case reasoning(text: String, signature: Data?)
        /// 工具调用（模型发出）
        case toolCall(ToolCall)
        /// 工具结果（工具返回）
        case toolResult(ToolResult)
        /// 大输出/生成物的句柄（**制品模式**：上下文里只放句柄与摘要）
        case artifact(ArtifactRef)
    }

    public var kind: Kind
    /// 该块内容的来源信任级
    public var origin: TrustLevel
    /// 污点来源（当 origin 为 untrustedContent 或内容派生自不可信内容时非空）
    public var taint: TaintOrigin?

    public init(kind: Kind, origin: TrustLevel, taint: TaintOrigin? = nil) {
        self.kind = kind
        self.origin = origin
        self.taint = taint
    }

    // MARK: 便捷构造

    public static func text(_ s: String, origin: TrustLevel) -> ContentBlock {
        ContentBlock(kind: .text(s), origin: origin)
    }

    /// 把一段不可信内容包成带边界标记的块（序列化时由网关加上 `<untrusted …>` 包裹）
    public static func untrusted(_ s: String, from origin: TaintOrigin) -> ContentBlock {
        ContentBlock(kind: .text(s), origin: .untrustedContent, taint: origin)
    }

    public var textValue: String? {
        if case .text(let s) = kind { return s }
        return nil
    }

    public var toolCallValue: ToolCall? {
        if case .toolCall(let c) = kind { return c }
        return nil
    }

    public var toolResultValue: ToolResult? {
        if case .toolResult(let r) = kind { return r }
        return nil
    }
}

// MARK: - 制品引用

/// 制品（大输出 / 生成物）的句柄。
///
/// 设计依据（docs/03 §4.2）：**工具结果永不完整回灌上下文**。
/// 大输出落盘为制品，上下文里只放"摘要 + 结构索引 + 句柄"，模型需要更多时用
/// `read_artifact(handle, range)` 主动拉取。这是手机上处理大输出的唯一办法。
public struct ArtifactRef: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    /// 相对 App 容器 artifacts/ 目录的路径
    public let relPath: String
    public let kind: ArtifactKind
    public let displayName: String
    public let mime: String?
    public let byteSize: Int64
    public let lineCount: Int?
    public let sha256: Data?
    /// 端侧或廉价模型生成的摘要
    public var summary: String?
    /// 关键行/结构索引（便于 read_artifact 定位，无需全读）
    public var indexHint: ArtifactIndex?

    public init(
        id: UUID = UUID(),
        relPath: String,
        kind: ArtifactKind,
        displayName: String,
        mime: String? = nil,
        byteSize: Int64,
        lineCount: Int? = nil,
        sha256: Data? = nil,
        summary: String? = nil,
        indexHint: ArtifactIndex? = nil
    ) {
        self.id = id
        self.relPath = relPath
        self.kind = kind
        self.displayName = displayName
        self.mime = mime
        self.byteSize = byteSize
        self.lineCount = lineCount
        self.sha256 = sha256
        self.summary = summary
        self.indexHint = indexHint
    }

    public enum ArtifactKind: String, Sendable, Codable, Hashable, CaseIterable {
        case log, file, image, table, chart, document, diff, report, other
    }

    /// 让模型能"不用全读"就找到重点
    public struct ArtifactIndex: Sendable, Codable, Hashable {
        /// 关键行号（错误行、命中行等）
        public var keyLines: [Int]
        /// 结构大纲（例如日志里的时间戳段、代码里的函数）
        public var outline: [OutlineEntry]

        public init(keyLines: [Int] = [], outline: [OutlineEntry] = []) {
            self.keyLines = keyLines
            self.outline = outline
        }

        public struct OutlineEntry: Sendable, Codable, Hashable {
            public var line: Int
            public var label: String
            public init(line: Int, label: String) {
                self.line = line
                self.label = label
            }
        }
    }
}

// MARK: - 用量与成本

/// token 用量。字段与各家 usage 一一对应，且**区分"缓存命中/写入"**——这是手机上省钱的关键指标。
public struct TokenUsage: Sendable, Codable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// 缓存**读取**命中（各家折扣 0.1× 左右）
    public var cachedInputTokens: Int
    /// 缓存**写入**（Anthropic 语义，1.25×；OpenAI GPT-5.6+ 也是 1.25×）
    public var cacheWriteTokens: Int
    public var reasoningTokens: Int?
    /// 厂商未返回 usage 时为 true（本地 tokenizer 估算，UI 上要显示 ≈）
    public var isEstimated: Bool

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        reasoningTokens: Int? = nil,
        isEstimated: Bool = false
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.isEstimated = isEstimated
    }

    public static let zero = TokenUsage()

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            reasoningTokens: {
                switch (lhs.reasoningTokens, rhs.reasoningTokens) {
                case (nil, nil): return nil
                case (let a?, nil): return a
                case (nil, let b?): return b
                case (let a?, let b?): return a + b
                }
            }(),
            isEstimated: lhs.isEstimated || rhs.isEstimated
        )
    }

    /// 计入计费的输入 token（缓存读取是折扣价，但仍要单独记账）
    public var billableInputTokens: Int {
        max(0, inputTokens - cachedInputTokens + cacheWriteTokens)
    }
}

/// 成本明细。**金额一律用整数微美元**——浮点累加会漂移，而用户对账单很敏感。
public struct CostBreakdown: Sendable, Codable, Hashable {
    public var usage: TokenUsage
    /// 微美元（1 USD = 1_000_000）
    public var microUSD: Int
    /// 因缓存命中省下的钱（正反馈，UI 要展示）
    public var cacheSavingsMicroUSD: Int
    public var providerID: String
    public var modelID: String
    /// 价格表未知时按官方价估算 → UI 显示 ≈
    public var isEstimated: Bool

    public init(
        usage: TokenUsage,
        microUSD: Int,
        cacheSavingsMicroUSD: Int = 0,
        providerID: String,
        modelID: String,
        isEstimated: Bool = false
    ) {
        self.usage = usage
        self.microUSD = microUSD
        self.cacheSavingsMicroUSD = cacheSavingsMicroUSD
        self.providerID = providerID
        self.modelID = modelID
        self.isEstimated = isEstimated
    }

    public static func zero(providerID: String = "", modelID: String = "") -> CostBreakdown {
        CostBreakdown(usage: .zero, microUSD: 0, providerID: providerID, modelID: modelID)
    }

    public static func + (lhs: CostBreakdown, rhs: CostBreakdown) -> CostBreakdown {
        CostBreakdown(
            usage: lhs.usage + rhs.usage,
            microUSD: lhs.microUSD + rhs.microUSD,
            cacheSavingsMicroUSD: lhs.cacheSavingsMicroUSD + rhs.cacheSavingsMicroUSD,
            providerID: lhs.providerID,
            modelID: lhs.modelID,
            isEstimated: lhs.isEstimated || rhs.isEstimated
        )
    }

    /// "≈$0.041" / "$0.041" —— 供 UI 直接使用
    public var displayString: String {
        let dollars = Double(microUSD) / 1_000_000
        let prefix = isEstimated ? "≈$" : "$"
        return prefix + String(format: "%.3f", dollars)
    }
}

// MARK: - 模型事件（归一化流式事件）

/// 模型输出的**归一化流式事件**。
///
/// 设计依据（docs/06 §3）：`AgentRuntime` 里不允许出现任何厂商名称或厂商特有字段。
/// 三处最容易写错的地方（已在 docs/06 §4 记录）：
///   1. 工具调用参数是**分片**的，必须按 index 拼接
///   2. 思考链有 6 种字段形态，回传时必须还原成原厂字段
///   3. 结束信号各家不同（有的发 `[DONE]`，有的不发）
public enum ModelEvent: Sendable, Hashable {
    case started(modelID: String, providerID: String)
    case textDelta(String)
    /// 思考链增量（各家 thinking/reasoning 归一化）
    case reasoningDelta(String)
    /// 思考签名（Anthropic signature / Gemini thoughtSignature / OpenAI encrypted_content）
    case reasoningSignature(Data)
    case toolCallStarted(index: Int, id: String, name: String)
    case toolCallArgumentsDelta(index: Int, jsonFragment: String)
    case toolCallCompleted(index: Int, id: String, name: String, argumentsJSON: Data)
    case usage(TokenUsage)
    case cacheInfo(cachedTokens: Int, writtenTokens: Int)
    case finished(reason: FinishReason)
    case providerError(ProviderError)
}

public enum FinishReason: String, Sendable, Codable, Hashable {
    case stop
    case length
    case toolCalls
    case contentFilter
    case error
    /// 厂商没给结束原因（部分中转站）→ 以"连接正常关闭"兜底
    case unknown
}

/// 模型渠道的可分类错误。分类决定"谁来处理"（docs/03 §7）。
public struct ProviderError: Sendable, Codable, Hashable, Error {
    public enum Kind: String, Sendable, Codable, Hashable {
        /// 限流 / 过载 / 网络抖动 → 可重试或换渠道
        case transient
        /// 鉴权 / 余额 → 需用户动作，**不要重试**
        case configuration
        /// 参数错 / 内容过滤 → 不重试
        case request
        /// 上下文超限 → 触发压缩后重试一次
        case contextOverflow
        /// 流被截断，结果不完整
        case truncated
        case unknown
    }

    public let kind: Kind
    public let providerID: String
    public let statusCode: Int?
    /// 面向开发者的原文（**已脱敏**，不含密钥）
    public let message: String
    /// 面向用户的一句话（中文，可直接显示）
    public let userFacingMessage: String
    /// 厂商给出的退避建议（`Retry-After`）
    public let retryAfterSeconds: Int?

    public init(
        kind: Kind,
        providerID: String,
        statusCode: Int? = nil,
        message: String,
        userFacingMessage: String,
        retryAfterSeconds: Int? = nil
    ) {
        self.kind = kind
        self.providerID = providerID
        self.statusCode = statusCode
        self.message = message
        self.userFacingMessage = userFacingMessage
        self.retryAfterSeconds = retryAfterSeconds
    }

    /// 是否值得重试（**配置类错误绝不重试**——重试只会让用户看到反复失败）
    public var isRetryable: Bool {
        switch kind {
        case .transient, .truncated: return true
        case .contextOverflow: return true   // 压缩后重试一次
        case .configuration, .request, .unknown: return false
        }
    }
}
