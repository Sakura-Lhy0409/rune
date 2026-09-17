import Foundation

// MARK: - 系统提示的分层
//
// 设计依据（docs/04 §13 / docs/06 §7.3）：系统提示不是一整块，而是**按稳定性分层**。
// 层 1+2 在同一个会话内保持**字节级不变**，这是 Prompt Caching 生效的前提
// （能省 60–90% 输入成本）。任何"时间戳/随机 id/当前 todo"都必须放在层 3 之后。

/// 系统提示的一个分层块。
public struct SystemBlock: Sendable, Codable, Hashable, Identifiable {
    public enum Layer: Int, Sendable, Codable, Hashable, CaseIterable, Comparable {
        /// 身份与契约：Rune 是什么、输出契约、诚实性约束、危险动作清单
        case identity = 1
        /// 项目稳定层：项目指令 + 工作区结构 + 技能目录 + 信任档
        case projectStable = 2
        /// 会话易变层：当前目标、todo、最近工具结果、记忆命中
        case sessionVolatile = 3

        public static func < (lhs: Layer, rhs: Layer) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: UUID
    public var layer: Layer
    public var label: String
    public var text: String

    public init(id: UUID = UUID(), layer: Layer, label: String, text: String) {
        self.id = id
        self.layer = layer
        self.label = label
        self.text = text
    }

    /// **只有层 1、2 值得作为缓存断点**——层 3 每轮都变，断在它上面只会浪费断点额度
    public var isCacheCandidate: Bool { layer <= .projectStable }
}

// MARK: - 工具选择

public enum ToolChoice: Sendable, Codable, Hashable {
    case auto
    case required
    case none
    case specific(String)

    /// 转成 OpenAI 风格的字面量；`specific` 需要厂商特定的对象形式，由适配器处理
    public var openAIStyleValue: JSONValue {
        switch self {
        case .auto: return .string("auto")
        case .required: return .string("required")
        case .none: return .string("none")
        case .specific(let name): return .object(["type": .string("function"), "name": .string(name)])
        }
    }

    public var isForcedTool: Bool {
        if case .specific = self { return true }
        return false
    }
}

// MARK: - 推理档位

public enum ReasoningEffort: String, Sendable, Codable, Hashable, CaseIterable {
    case none
    case low
    case medium
    case high
    /// 部分厂商有更高的档（OpenAI Astra 的 xhigh/max；DeepSeek 的 max）
    case xhigh
    case max

    /// 各厂商档位不一致，需要**映射**而不是直传（docs/附录A §2.6）
    ///
    /// 已知映射：DeepSeek 的 `minimal→low`、`medium→high`、`xhigh→high`、`ultra→max`；
    /// 千帆 v2 的 `low`/`medium` 会**塌缩为 `high`**。
    ///
    /// ⚠️ 等价距离时**优先向"更强"的方向取值**：
    ///   ① 宁可多想不可少想（推理质量优先）；
    ///   ② 与已知厂商的实际行为一致（千帆把 medium 塌缩到 high，而不是 low）。
    public func mapped(toSupported supported: Set<ReasoningEffort>, fallback: ReasoningEffort = .medium) -> ReasoningEffort {
        if supported.contains(self) { return self }
        let order: [ReasoningEffort] = [.max, .xhigh, .high, .medium, .low, .none]
        guard let myIndex = order.firstIndex(of: self) else { return fallback }
        // 先向上找（更强），再向下找（更省）
        for candidate in order[..<myIndex].reversed() where supported.contains(candidate) {
            return candidate
        }
        for candidate in order[(myIndex + 1)...] where supported.contains(candidate) {
            return candidate
        }
        return fallback
    }
}

public enum ReasoningRequest: Sendable, Codable, Hashable {
    /// 关闭思考链
    case off
    case effort(ReasoningEffort)
    /// token 预算（仅部分厂商支持；Anthropic 4.7+ 已弃用该形式）
    case budget(Int)

    public var effortValue: ReasoningEffort? {
        if case .effort(let e) = self { return e }
        return nil
    }
}

// MARK: - 归一化请求

/// **归一化**的模型请求。
///
/// ⚠️ 这里**不允许出现任何厂商特有的字段名**（docs/06 §1 的铁律）。
/// 所有差异由 `ProtocolAdapter` 在序列化时消化。
public struct ChatRequest: Sendable {
    /// 系统提示分层（按 layer 升序）
    public var systemBlocks: [SystemBlock]
    public var messages: [Message]
    public var tools: [ToolSpec]
    public var toolChoice: ToolChoice
    public var maxOutputTokens: Int
    public var temperature: Double?
    public var reasoning: ReasoningRequest?
    public var stopSequences: [String]
    public var stream: Bool
    /// 是否要求厂商在流式响应里返回用量（不支持的渠道会忽略）
    public var includeUsage: Bool

    public init(
        systemBlocks: [SystemBlock] = [],
        messages: [Message],
        tools: [ToolSpec] = [],
        toolChoice: ToolChoice = .auto,
        maxOutputTokens: Int = 8192,
        temperature: Double? = nil,
        reasoning: ReasoningRequest? = nil,
        stopSequences: [String] = [],
        stream: Bool = true,
        includeUsage: Bool = true
    ) {
        self.systemBlocks = systemBlocks.sorted { $0.layer < $1.layer }
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.reasoning = reasoning
        self.stopSequences = stopSequences
        self.stream = stream
        self.includeUsage = includeUsage
    }

    /// 拼接后的系统提示文本（供不支持分层的厂商使用）
    public var flattenedSystemText: String {
        systemBlocks.map(\.text).joined(separator: "\n\n")
    }

    /// 请求指纹的输入（用于"同一 Turn 内相同请求直接复用响应"）—— 见 docs/06 §8.3
    public func fingerprintBody() -> Data {
        var parts: [String] = []
        parts.append(flattenedSystemText)
        for m in messages { parts.append(m.role.rawValue + ":" + m.plainText) }
        for t in tools.sorted(by: { $0.name < $1.name }) {
            parts.append(t.name + "|" + t.inputSchema.jsonSchemaValue().canonicalString())
        }
        parts.append("max:\(maxOutputTokens)")
        parts.append("reasoning:\(String(describing: reasoning))")
        return Data(parts.joined(separator: "\n").utf8)
    }
}

// MARK: - 缓存断点规划

/// 缓存断点规划器。
///
/// 各厂商的缓存机制差异（docs/06 §7.2）：
///   * **Anthropic**：显式 `cache_control`，**最多 4 个断点**，且 1h 断点必须排在 5m 之前
///   * **OpenAI GPT-5.6+**：也是显式断点（`prompt_cache_breakpoint`），**不打点就不产生缓存写入**
///   * **OpenAI 早期 / DeepSeek / Gemini 隐式 / Groq**：自动前缀缓存 → 只需保证层 1+2 字节稳定
///   * **中转站**：透传，客户端不可控
public enum CachePlanner {

    public static let anthropicMaxBreakpoints = 4

    /// 需要打缓存断点的系统块下标（按 layer 升序）
    ///
    /// 策略：**只断在层 1 与层 2 的最后一个块上**——层 3 每轮都变，断在它上面只会浪费额度。
    /// 工具定义也算一个断点（它在 Anthropic 里是独立的一段）。
    public static func breakpoints(for request: ChatRequest, quirks: ProviderQuirks) -> Set<Int> {
        guard quirks.cacheStyle.requiresExplicitBreakpoints else { return [] }

        let systemIndices = request.systemBlocks.enumerated()
            .filter { $0.element.isCacheCandidate }
            .map(\.offset)
        guard !systemIndices.isEmpty else { return [] }

        // 留一个额度给工具定义（如果工具很多，它比系统提示更值得缓存）
        let budget = max(1, anthropicMaxBreakpoints - (request.tools.isEmpty ? 0 : 1))

        // 按层取每层的**最后一个**块（前缀越长命中越多）
        var chosen: [Int] = []
        let byLayer = Dictionary(grouping: systemIndices) { request.systemBlocks[$0].layer }
        for layer in SystemBlock.Layer.allCases where layer <= .projectStable {
            if let last = byLayer[layer]?.max() { chosen.append(last) }
        }
        return Set(chosen.sorted().suffix(budget))
    }

    /// 是否需要把工具定义也标为缓存断点
    public static func cacheTools(_ request: ChatRequest, quirks: ProviderQuirks) -> Bool {
        quirks.cacheStyle.requiresExplicitBreakpoints && !request.tools.isEmpty
    }

    /// 给用户看的说明（为什么这次的缓存没命中 / 命中了多少）
    public static func explanation(for quirks: ProviderQuirks) -> String {
        switch quirks.cacheStyle {
        case .explicitBreakpoints:
            return "该渠道需要显式缓存断点（最多 4 个）；Rune 会在系统提示的稳定层与工具定义上打点。"
        case .automatic:
            return "该渠道自动做前缀缓存；只要系统提示的稳定层字节不变就能命中。"
        case .implicitPrefix:
            return "该渠道隐式缓存前缀；注意它有最小输入长度门槛，太短的请求不会命中。"
        case .passThrough:
            return "该渠道（中转）是否缓存由上游决定，客户端不可控。"
        case .none:
            return "该渠道没有提示缓存。"
        }
    }
}
