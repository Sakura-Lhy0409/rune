import Foundation

// MARK: - 模型网关：渠道配置、路由、降级、重试
//
// 设计依据（docs/06 §6 / §8）。这一层解决的是用户最关心的两件事：
//   **「接入市面上主流的模型」** 与 **「支持中转站」**。
//
// ## 为什么中转站要做成一等公民（docs/06 §6）
//
// 中文开发者生态里中转站是刚需。不把它做成一等公民的结果，是用户自己去找野路子 ——
// 那才是真正的风险。所以 Rune 的做法是：**功能完整 + 风险透明**。
//
// ## 这一层里只有三条是"硬规则"，其余都是策略
//
//   ① **禁止静默降级**：换了模型必须发事件、必须让用户看见。
//      用户付费买的是特定模型的能力，换了不说，等于把"按量付费"变成"盲盒"。
//   ② **`verify` 必须与执行用不同模型**：同模型自我验证几乎没有价值。
//   ③ **敏感项目里中转渠道不出现在可选列表**（并解释原因），而不是"用了再提醒"。

// MARK: - 渠道配置

/// 渠道类别。它决定**隐私提示**与**敏感项目里能不能用**。
public enum ProviderCategory: String, Sendable, Codable, Hashable, CaseIterable {
    /// 官方直连
    case official
    /// 官方云（Azure / Bedrock / Vertex 等）
    case officialCloud
    /// **第三方中转** —— 中文开发者刚需，但服务方能看到你的全部内容
    case thirdPartyRelay
    /// 局域网自建（Ollama / LM Studio / 自建服务）
    case selfHostedLAN
    /// 端侧模型（Apple FM / 本地小模型）
    case onDevice

    public var displayName: String {
        switch self {
        case .official: return "官方直连"
        case .officialCloud: return "官方云"
        case .thirdPartyRelay: return "第三方中转"
        case .selfHostedLAN: return "局域网自建"
        case .onDevice: return "端侧模型"
        }
    }

    public var isRelay: Bool { self == .thirdPartyRelay }

    /// 渠道列表上要显示的隐私提示（docs/06 §6.3 的"风险标注"）
    public var privacyNote: String? {
        switch self {
        case .thirdPartyRelay:
            return "第三方中转 · 服务方可见你的全部内容"
        case .selfHostedLAN:
            return "局域网自建 · 内容不出本地网络"
        case .onDevice:
            return "端侧模型 · 内容不离开这台设备"
        case .official, .officialCloud:
            return nil
        }
    }

    /// 敏感项目里允不允许用。
    ///
    /// ⚠️ 判定放在**这里**（而不是在 UI 里逐个 if）：那样"哪些渠道算可信"
    ///    只有一份定义，加一个类别时不会漏掉某一处。
    /// ⚠️ 注意 `selfHostedLAN` **不在**白名单里：局域网地址可能是共享的，
    ///    而且用户勾"敏感项目"时想的是"别出去"，不是"只出到局域网"。
    ///    真要用自建服务，用户可以把它放在官方直连那一档并自己承担。
    public var isAllowedInSensitiveProject: Bool {
        switch self {
        case .official, .officialCloud, .onDevice: return true
        case .thirdPartyRelay, .selfHostedLAN: return false
        }
    }
}

/// 鉴权方式。
///
/// ⚠️ **只存引用（`keyRef`），永不存密钥本身。**
///    真值在 Keychain 里，UI 上只显示尾 4 位；这样"配置"这个值类型可以被随手复制、
///    写进日志、编码进 JSON 而不泄密 —— 泄密面从"到处都可能"缩到"Keychain 一处"。
public enum AuthConfig: Sendable, Codable, Hashable {
    case bearer(keyRef: String)
    case header(name: String, keyRef: String)
    case query(name: String, keyRef: String)
    case none

    public var keyRef: String? {
        switch self {
        case .bearer(let ref): return ref
        case .header(_, let ref): return ref
        case .query(_, let ref): return ref
        case .none: return nil
        }
    }

    public var headerName: String? {
        switch self {
        case .bearer: return "Authorization"
        case .header(let name, _): return name
        case .query, .none: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .bearer: return "Bearer"
        case .header(let name, _): return "自定义头 \(name)"
        case .query(let name, _): return "查询参数 \(name)"
        case .none: return "无鉴权"
        }
    }
}

/// 一个模型（探测出来的，或用户手填的）
public struct ModelDescriptor: Sendable, Codable, Hashable {
    public var id: String
    /// 本地别名（用户/路由用别名，避免把远端模型名写死在配置里）
    public var alias: String?
    public var contextWindow: Int
    public var supportsTools: Bool
    public var supportsVision: Bool
    public var supportsReasoning: Bool
    public var price: ModelPrice?
    /// 探测是否成功（`nil` = 还没探测过）
    public var isVerified: Bool?

    public init(
        id: String,
        alias: String? = nil,
        contextWindow: Int = 128_000,
        supportsTools: Bool = true,
        supportsVision: Bool = false,
        supportsReasoning: Bool = false,
        price: ModelPrice? = nil,
        isVerified: Bool? = nil
    ) {
        self.id = id
        self.alias = alias
        self.contextWindow = contextWindow
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.supportsReasoning = supportsReasoning
        self.price = price
        self.isVerified = isVerified
    }
}

/// 渠道配置（docs/06 §6.1）
public struct ProviderConfig: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var protocolFamily: ProtocolFamily
    /// ★ 任意，含路径前缀（`/v1` 或 `/api/v1`）—— 中转站的前缀五花八门
    public var baseURL: String
    public var auth: AuthConfig
    public var extraHeaders: [String: String]
    public var category: ProviderCategory
    public var riskNote: String?
    public var modelAliases: [String: String]
    public var priceOverrides: [String: ModelPrice]
    public var quirks: ProviderQuirks
    public var allowInsecureTLS: Bool
    public var allowPrivateNetwork: Bool
    public var isEnabled: Bool
    public var models: [ModelDescriptor]

    public init(
        id: String,
        displayName: String,
        protocolFamily: ProtocolFamily,
        baseURL: String,
        auth: AuthConfig,
        extraHeaders: [String: String] = [:],
        category: ProviderCategory = .official,
        riskNote: String? = nil,
        modelAliases: [String: String] = [:],
        priceOverrides: [String: ModelPrice] = [:],
        quirks: ProviderQuirks = .openAICompatible,
        allowInsecureTLS: Bool = false,
        allowPrivateNetwork: Bool = false,
        isEnabled: Bool = true,
        models: [ModelDescriptor] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.protocolFamily = protocolFamily
        self.baseURL = baseURL
        self.auth = auth
        self.extraHeaders = extraHeaders
        self.category = category
        self.riskNote = riskNote
        self.modelAliases = modelAliases
        self.priceOverrides = priceOverrides
        self.quirks = quirks
        self.allowInsecureTLS = allowInsecureTLS
        self.allowPrivateNetwork = allowPrivateNetwork
        self.isEnabled = isEnabled
        self.models = models
    }

    public func model(_ id: String) -> ModelDescriptor? { models.first { $0.id == id } }
    public func model(alias: String) -> ModelDescriptor? { models.first { $0.alias == alias } }

    /// 别名 → 远端模型名。
    ///
    /// ⚠️ 中转站常用"别名指向别家模型"（你选 `gpt-4o`，实际给你的是别的）。
    ///    所以映射必须**声明式、可展示** —— 用户有权知道自己到底在用什么。
    public func resolve(_ name: String) -> String? {
        if let mapped = modelAliases[name] { return mapped }
        if model(name) != nil { return name }
        if let descriptor = model(alias: name) { return descriptor.id }
        return nil
    }

    /// 这个别名在这条渠道上实际会打到哪个模型（用于 UI 提示）
    public func mappingNotice(_ name: String) -> String? {
        guard let remote = resolve(name), remote != name else { return nil }
        return "你选的「\(name)」在这条渠道上实际映射为「\(remote)」"
    }
}

// MARK: - 任务类型与路由规则

public enum TaskKind: String, Sendable, Codable, Hashable, CaseIterable {
    /// 意图分类、标题生成、脱敏判定
    case triage
    /// 规划、架构决策
    case plan
    /// 写代码、改代码（成本敏感）
    case code
    /// 大文件分析、全仓库理解（长窗口优先）
    case longContext = "long_context"
    case vision
    /// 摘要、分类、格式化、commit message
    case cheap
    /// **独立验证** —— 必须与执行用不同模型
    case verify

    public var displayName: String {
        switch self {
        case .triage: return "分类"
        case .plan: return "规划"
        case .code: return "写码"
        case .longContext: return "长上下文"
        case .vision: return "看图"
        case .cheap: return "廉价任务"
        case .verify: return "独立验证"
        }
    }
}

public struct RouteRule: Sendable, Codable, Hashable {
    public var task: TaskKind
    /// `渠道id:模型名或别名`
    public var model: String
    public var fallback: [String]
    public var maxCostMicroUSD: Int?
    public var minContextWindow: Int?
    /// ⚠️ 硬规则：验证必须与执行用不同的模型（同模型自我验证几乎没有价值）
    public var mustDifferFromExecutor: Bool

    public init(
        task: TaskKind,
        model: String,
        fallback: [String] = [],
        maxCostMicroUSD: Int? = nil,
        minContextWindow: Int? = nil,
        mustDifferFromExecutor: Bool = false
    ) {
        self.task = task
        self.model = model
        self.fallback = fallback
        self.maxCostMicroUSD = maxCostMicroUSD
        self.minContextWindow = minContextWindow
        self.mustDifferFromExecutor = mustDifferFromExecutor
    }

    /// 默认策略（用户开箱即用；高级用户可完整覆盖 —— docs/06 §8.1）
    ///
    /// ⚠️ 这里**刻意不写死具体模型名**：模型阵容变动极快（2026-09 已与一年前完全不同）。
    ///    默认规则用**端侧 + 别名**表达，真实模型名由渠道探测决定。
    public static let defaults: [RouteRule] = [
        RouteRule(task: .triage, model: "on_device:apple-fm"),
        RouteRule(task: .cheap, model: "on_device:apple-fm"),
        RouteRule(task: .plan, model: "plan:strong"),
        RouteRule(task: .code, model: "code:default"),
        RouteRule(task: .longContext, model: "long:default", minContextWindow: 200_000),
        RouteRule(task: .vision, model: "vision:default"),
        RouteRule(task: .verify, model: "verify:default", mustDifferFromExecutor: true),
    ]
}

/// 一次路由需要满足的条件
public struct RoutingRequirements: Sendable, Hashable {
    public var needsTools: Bool
    public var needsVision: Bool
    public var needsReasoning: Bool
    /// 这次要发多少 token（用来卡上下文窗口）
    public var contextTokens: Int
    public var maxCostMicroUSD: Int?
    /// 敏感项目：中转与局域网渠道**不出现在可选列表**
    public var sensitiveProject: Bool
    /// 独立验证时，执行用的是哪个模型（用于"必须不同"）
    public var executorModel: ModelRef?

    public init(
        needsTools: Bool = true,
        needsVision: Bool = false,
        needsReasoning: Bool = false,
        contextTokens: Int = 0,
        maxCostMicroUSD: Int? = nil,
        sensitiveProject: Bool = false,
        executorModel: ModelRef? = nil
    ) {
        self.needsTools = needsTools
        self.needsVision = needsVision
        self.needsReasoning = needsReasoning
        self.contextTokens = contextTokens
        self.maxCostMicroUSD = maxCostMicroUSD
        self.sensitiveProject = sensitiveProject
        self.executorModel = executorModel
    }
}

/// 一个具体的"渠道 + 模型"
public struct ModelRef: Sendable, Codable, Hashable {
    public var providerID: String
    public var providerName: String
    public var modelID: String
    public var alias: String?
    public var category: ProviderCategory
    public var contextWindow: Int
    public var supportsTools: Bool
    public var supportsVision: Bool
    public var supportsReasoning: Bool
    public var price: ModelPrice?
    public var protocolFamily: ProtocolFamily

    public init(
        providerID: String, providerName: String, modelID: String, alias: String? = nil,
        category: ProviderCategory, contextWindow: Int,
        supportsTools: Bool, supportsVision: Bool, supportsReasoning: Bool,
        price: ModelPrice? = nil, protocolFamily: ProtocolFamily
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.modelID = modelID
        self.alias = alias
        self.category = category
        self.contextWindow = contextWindow
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.supportsReasoning = supportsReasoning
        self.price = price
        self.protocolFamily = protocolFamily
    }

    /// 界面与事件里显示的名字（**把实际模型名写出来**，不让用户以为自己在用别的）
    public var displayString: String {
        let name = alias.map { "\($0)（实际 \(modelID)）" } ?? modelID
        return "\(providerName)/\(name)"
    }

    /// 同一模型要"不同"时用来判等（渠道不同也算不同 —— 不同渠道背后多半是不同部署）
    public func isSameModel(as other: ModelRef?) -> Bool {
        guard let other else { return false }
        return providerID == other.providerID && modelID == other.modelID
    }
}

// MARK: - 健康状态

public struct ProviderHealth: Sendable, Codable, Hashable {
    public var providerID: String
    public var consecutiveFailures: Int = 0
    public var lastSuccessAt: Date?
    public var lastFailureAt: Date?
    public var lastError: String?
    public var lastLatencyMS: Int?
    public var lastFirstTokenMS: Int?

    public init(providerID: String) { self.providerID = providerID }
}

/// 渠道健康与探活（docs/06 §6.3「健康探测」）
public struct HealthTracker: Sendable, Codable, Hashable {
    /// 连续失败多少次就标记 `failing` 并从路由里摘掉
    public static let failureThreshold = 3
    /// 后台探活间隔（6 小时）
    public static let probeInterval: TimeInterval = 6 * 3_600

    public private(set) var entries: [String: ProviderHealth] = [:]

    public init() {}

    public func health(_ providerID: String) -> ProviderHealth {
        entries[providerID] ?? ProviderHealth(providerID: providerID)
    }

    /// 能不能用（连续失败过多就摘掉）
    public func isUsable(_ providerID: String) -> Bool {
        health(providerID).consecutiveFailures < Self.failureThreshold
    }

    public mutating func recordSuccess(_ providerID: String, latencyMS: Int? = nil,
                                       firstTokenMS: Int? = nil, now: Date) {
        var entry = health(providerID)
        entry.consecutiveFailures = 0
        entry.lastSuccessAt = now
        entry.lastError = nil
        if let latencyMS { entry.lastLatencyMS = latencyMS }
        if let firstTokenMS { entry.lastFirstTokenMS = firstTokenMS }
        entries[providerID] = entry
    }

    public mutating func recordFailure(_ providerID: String, error: String, now: Date) {
        var entry = health(providerID)
        entry.consecutiveFailures += 1
        entry.lastFailureAt = now
        entry.lastError = error
        entries[providerID] = entry
    }

    /// 哪些渠道该在后台探活了
    public func needsProbe(now: Date) -> [String] {
        entries.values.filter { entry in
            guard let last = entry.lastSuccessAt ?? entry.lastFailureAt else { return true }
            return now.timeIntervalSince(last) >= Self.probeInterval
        }.map(\.providerID).sorted()
    }
}

// MARK: - 路由结果

public struct RoutingDecision: Sendable {
    public struct Rejection: Sendable, Hashable {
        public var ref: String
        public var reason: String
    }

    /// 选中的 + 降级链（按优先级排）
    public var chain: [ModelRef]
    /// 被排除的候选与原因（**UI 要能回答"为什么没用那个渠道"**）
    public var rejections: [Rejection]
    public var notes: [String]

    public var primary: ModelRef? { chain.first }
    public var hasFallback: Bool { chain.count > 1 }

    public var isEmpty: Bool { chain.isEmpty }

    /// 给用户看的一句解释
    public var explanation: String {
        guard let primary else {
            let reasons = rejections.prefix(3).map { "· \($0.ref)：\($0.reason)" }.joined(separator: "\n")
            return "没有可用的渠道。\n\(reasons)"
        }
        var text = "用 \(primary.displayString)"
        if hasFallback { text += "（备选 \(chain.count - 1) 条）" }
        if let note = primary.category.privacyNote { text += "\n\(note)" }
        return text
    }
}

// MARK: - 路由器

public enum GatewayRouter {

    /// 按任务类型与条件选渠道，并给出**降级链**。
    public static func route(
        task: TaskKind,
        requirements: RoutingRequirements,
        channels: [ProviderConfig],
        rules: [RouteRule] = RouteRule.defaults,
        health: HealthTracker = HealthTracker(),
        enabledAliases: Set<String>? = nil
    ) -> RoutingDecision {
        var chains: [[String]] = []
        var notes: [String] = []
        let rule = rules.first { $0.task == task }

        // ① 规则里的主 + 备选
        if let rule {
            chains.append([rule.model] + rule.fallback)
        } else {
            notes.append("没有为「\(task.displayName)」配置路由规则，按渠道声明顺序兜底。")
        }
        // ② 兜底：所有渠道里所有模型（保底能用）
        chains.append(channels.flatMap { channel in
            channel.models.map { "\(channel.id):\($0.alias ?? $0.id)" }
        })

        var rejections: [RoutingDecision.Rejection] = []
        var selected: [ModelRef] = []
        var seen = Set<String>()

        for chain in chains {
            for reference in chain {
                guard let ref = resolve(reference, channels: channels, enabledAliases: enabledAliases) else {
                    // 别名解析不到是**正常情况**（用户没配那个渠道），不当作"拒绝"刷屏
                    continue
                }
                let key = "\(ref.providerID)|\(ref.modelID)"
                guard seen.insert(key).inserted else { continue }

                if let reason = reject(ref, requirements: requirements, health: health) {
                    rejections.append(.init(ref: ref.displayString, reason: reason))
                    continue
                }
                // ⚠️ 硬规则：验证必须与执行用不同的模型
                if rule?.mustDifferFromExecutor == true, ref.isSameModel(as: requirements.executorModel) {
                    rejections.append(.init(ref: ref.displayString,
                                            reason: "这是执行用的模型；独立验证必须换一个（同模型自我验证几乎没有价值）"))
                    continue
                }
                selected.append(ref)
            }
            // 第一条能出结果的就够了，不必再兜底
            if !selected.isEmpty { break }
        }

        if requirements.sensitiveProject, !rejections.contains(where: { $0.reason.contains("敏感项目") }) {
            let blocked = channels.filter { !$0.category.isAllowedInSensitiveProject }
            for channel in blocked {
                rejections.append(.init(ref: channel.displayName,
                                        reason: "敏感项目：\(channel.category.displayName)渠道不可用（内容可能离开可信范围）"))
            }
        }

        return RoutingDecision(chain: selected, rejections: rejections, notes: notes)
    }

    /// 把 `渠道id:模型名或别名` 解析成一个 `ModelRef`
    public static func resolve(
        _ reference: String,
        channels: [ProviderConfig],
        enabledAliases: Set<String>? = nil
    ) -> ModelRef? {
        let parts = reference.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let providerID = parts[0]
        let name = parts[1]
        guard let channel = channels.first(where: { $0.id == providerID }), channel.isEnabled else { return nil }
        guard let remote = channel.resolve(name), let descriptor = channel.model(remote) else { return nil }
        if let enabledAliases, let alias = descriptor.alias, !enabledAliases.contains(alias) { return nil }

        return ModelRef(
            providerID: channel.id,
            providerName: channel.displayName,
            modelID: descriptor.id,
            alias: descriptor.alias,
            category: channel.category,
            contextWindow: descriptor.contextWindow,
            supportsTools: descriptor.supportsTools,
            supportsVision: descriptor.supportsVision,
            supportsReasoning: descriptor.supportsReasoning,
            price: channel.priceOverrides[descriptor.id] ?? descriptor.price,
            protocolFamily: channel.protocolFamily
        )
    }

    /// 金额格式化。⚠️ 金额一律用**整数微美元**存储与计算，只在显示时才变成小数 ——
    /// 用浮点存钱是账本类代码的经典错误。
    public static func money(_ microUSD: Int) -> String {
        String(format: "$%.4f", Double(microUSD) / 1_000_000)
    }

    /// 为什么这个候选被排除（返回 nil = 可用）
    public static func reject(_ ref: ModelRef, requirements: RoutingRequirements, health: HealthTracker) -> String? {
        if !health.isUsable(ref.providerID) {
            let entry = health.health(ref.providerID)
            return "连续失败 \(entry.consecutiveFailures) 次，已暂时摘掉：\(entry.lastError ?? "未知原因")"
        }
        if requirements.sensitiveProject, !ref.category.isAllowedInSensitiveProject {
            return "敏感项目：\(ref.category.displayName)渠道不可用（内容可能离开可信范围）"
        }
        if requirements.needsTools, !ref.supportsTools {
            return "它不支持工具调用，而这一步必须调工具"
        }
        if requirements.needsVision, !ref.supportsVision {
            return "它不支持图片输入"
        }
        if requirements.needsReasoning, !ref.supportsReasoning {
            return "它不支持思考链"
        }
        if requirements.contextTokens > 0, ref.contextWindow < requirements.contextTokens {
            return "上下文窗口 \(ref.contextWindow) 装不下这次的 \(requirements.contextTokens) token"
        }
        if let ceiling = requirements.maxCostMicroUSD, let price = ref.price {
            // 用"发满上下文 + 4k 输出"估一个上界，超了就别选它
            let estimate = CostCalculator.cost(
                usage: TokenUsage(inputTokens: requirements.contextTokens, outputTokens: 4_000),
                price: price,
                providerID: ref.providerID,
                modelID: ref.modelID
            ).microUSD
            if estimate > ceiling {
                return "按这次上下文估算要 \(Self.money(estimate))，超过这一步的上限 \(Self.money(ceiling))"
            }
        }
        return nil
    }
}

// MARK: - 重试策略（docs/06 §8.3）

public enum RetryPolicy {

    public struct Decision: Sendable, Hashable {
        public enum Action: Sendable, Hashable {
            /// 同渠道退避重试
            case retrySameChannel(afterSeconds: Int)
            /// 换下一个渠道
            case switchChannel
            /// 先压缩上下文再重试一次
            case recompressAndRetry
            /// 配置问题，**不要重试**，让用户去改 key
            case askUserToFixConfig(String)
            /// 放弃，把原因如实告诉用户
            case giveUp(userFacing: String)
        }
        public var action: Action
        public var rationale: String
    }

    public static let maxTransientRetries = 3
    public static let maxGatewayRetries = 2
    /// 首 token 多久没到就认为渠道卡住了
    public static let firstTokenTimeoutSeconds = 8

    /// 退避秒数：1s / 2s / 4s（指数），厂商给了 `Retry-After` 就听它的
    public static func backoffSeconds(attempt: Int, retryAfter: Int?) -> Int {
        if let retryAfter, retryAfter > 0 { return min(retryAfter, 60) }
        return min(1 << max(0, attempt - 1), 30)
    }

    public static func decide(error: ProviderError, attempt: Int, isStreaming: Bool = false) -> Decision {
        switch error.kind {
        case .transient:
            let isGatewayError = (error.statusCode ?? 0) >= 500
            let limit = isGatewayError ? maxGatewayRetries : maxTransientRetries
            if attempt <= limit {
                let after = backoffSeconds(attempt: attempt, retryAfter: error.retryAfterSeconds)
                return Decision(
                    action: .retrySameChannel(afterSeconds: after),
                    rationale: "限流或瞬时抖动（\(error.statusCode.map(String.init) ?? "无状态码")），"
                        + "退避 \(after) 秒后重试第 \(attempt) 次"
                )
            }
            return Decision(action: .switchChannel,
                            rationale: "同一渠道重试 \(limit) 次仍失败，换下一个渠道")

        case .configuration:
            // ⚠️ 鉴权/余额问题重试只会让用户看到反复失败 —— 必须让他去改配置
            return Decision(
                action: .askUserToFixConfig(error.userFacingMessage),
                rationale: "这是配置问题（密钥或余额），重试不会变好"
            )

        case .contextOverflow:
            return Decision(action: .recompressAndRetry,
                            rationale: "上下文超限：先压缩再重试一次（而不是直接放弃）")

        case .truncated:
            if isStreaming, attempt <= 1 {
                return Decision(action: .retrySameChannel(afterSeconds: 0),
                                rationale: "流被截断，结果不完整；重发一次（有缓存，重发很便宜）")
            }
            return Decision(action: .giveUp(userFacing: "这一轮的输出被截断了，重发也没能完整收完。可以让我继续，或换个更聚焦的目标。"),
                            rationale: "流反复被截断")

        case .request, .unknown:
            return Decision(action: .giveUp(userFacing: error.userFacingMessage),
                            rationale: "请求本身有问题（参数或内容过滤），重试不会变好")
        }
    }
}

// MARK: - 降级（docs/06 §8.2）

public struct DegradationPlan: Sendable, Hashable {
    public var from: ModelRef
    public var to: ModelRef
    /// 是否必须重建上下文（思考链支持变了 —— 旧渠道的 reasoning blocks 新渠道不认）
    public var mustRebuildContext: Bool
    /// 是否必须压缩（新渠道窗口更小）
    public var mustRecompress: Bool
    /// 能力是否变了（降级要如实告知"能力可能变化"）
    public var capabilityChanged: Bool
    /// UI 与事件里的那句话
    public var notice: String
    /// ⚠️ **永远为 true**。这一位存在的意义是让"禁止静默降级"变成代码里显式的一行。
    public var isVisibleToUser: Bool = true

    public init(from: ModelRef, to: ModelRef, mustRebuildContext: Bool,
                mustRecompress: Bool, capabilityChanged: Bool, notice: String) {
        self.from = from
        self.to = to
        self.mustRebuildContext = mustRebuildContext
        self.mustRecompress = mustRecompress
        self.capabilityChanged = capabilityChanged
        self.notice = notice
    }
}

public enum Degradation {

    public static func plan(from: ModelRef, to: ModelRef) -> DegradationPlan {
        // ① 思考链支持变了 → 旧渠道的 reasoning blocks 新渠道不认，必须重建
        let reasoningChanged = from.supportsReasoning != to.supportsReasoning
        // ② 窗口变小 → 得压
        let narrowed = to.contextWindow < from.contextWindow
        // ③ 能力变化（工具/视觉/协议族）
        let capabilityChanged = from.supportsTools != to.supportsTools
            || from.supportsVision != to.supportsVision
            || from.protocolFamily != to.protocolFamily
            || reasoningChanged

        var reasons: [String] = []
        if reasoningChanged { reasons.append("思考链支持变了，已清掉上一个渠道的思考块") }
        if narrowed { reasons.append("新渠道窗口更小（\(to.contextWindow)），已压缩上下文") }
        if from.protocolFamily != to.protocolFamily {
            reasons.append("协议族从 \(from.protocolFamily.rawValue) 换成 \(to.protocolFamily.rawValue)")
        }

        var notice = "因主渠道不可用，本轮从 \(from.displayString) 降级到 \(to.displayString)"
        if capabilityChanged { notice += "（**能力可能变化**）" }
        if !reasons.isEmpty { notice += "。" + reasons.joined(separator: "；") }

        return DegradationPlan(
            from: from, to: to,
            mustRebuildContext: reasoningChanged,
            mustRecompress: narrowed,
            capabilityChanged: capabilityChanged,
            notice: notice
        )
    }
}

// MARK: - 请求去重（没有厂商幂等键时的第一个手段）

/// 同一 Turn 内出现相同请求指纹且已有完整响应 → **直接复用，不再发请求**（省一次计费）。
///
/// ⚠️ 为什么这件事在手机上尤其重要：重试、降级重发、崩溃恢复都会重发同样的请求。
///    而**没有任何厂商提供官方幂等键**（`X-Client-Request-Id` 只是追踪 id）——
///    所以省钱的唯一办法就是**自己认出来这是同一个请求**。
public struct RequestDeduplicator: Sendable {
    private var completed: [Data: ModelRef] = [:]

    public init() {}

    public mutating func begin(providerID: String, modelID: String, body: Data) -> Data {
        Fingerprint.request(providerID: providerID, modelID: modelID, serializedBody: body)
    }

    /// 已经有完整响应的话，返回当时是谁答的（那次就不必再发）
    public func cachedResponder(for fingerprint: Data) -> ModelRef? { completed[fingerprint] }

    public mutating func record(fingerprint: Data, answeredBy: ModelRef) {
        completed[fingerprint] = answeredBy
    }

    public mutating func reset() { completed.removeAll() }

    public var count: Int { completed.count }
}

