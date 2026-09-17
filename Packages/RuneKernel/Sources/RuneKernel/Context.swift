import Foundation

// MARK: - Token 估算
//
// 设计依据（docs/07 §1）：手机上跑 Agent，**上下文是最贵的资源** ——
// 它同时消耗钱（按 token 付费）、内存、延迟和电量。
// 所以上下文引擎不是"把东西塞进去"，而是一套**预算制装配管线**。
//
// 而预算制的前提是**能估准**。估不准的话整套预算都是自欺欺人。

/// Token 估算。
///
/// ⚠️ 这里有一个**会让中文用户多花好几倍钱**的陷阱：
/// 教科书上的经验值是"1 token ≈ 4 个英文字符"，但**中文是 1 字符 ≈ 1 token**
/// （CJK 不在 BPE 的合并收益区里）。用 `count / 4` 去估一段中文，
/// 会把 4000 token 的内容估成 1000 —— 于是装配器以为还很空，继续往里塞，
/// 直到真的把窗口撑爆、请求 400，或者账单比预期高 4 倍。
///
/// 所以估算必须**按字符类别分开算**。
public enum TokenEstimator {

    /// 非 CJK 字符每多少个算 1 token。
    ///
    /// 取 3.5 而不是教科书上的 4：代码与 JSON 里标点、缩进密集，实际比值接近 3。
    /// **宁可略高估**：高估的代价是提前压缩（多花一点点），
    /// 低估的代价是撑爆窗口（请求失败）或账单失控。
    public static let charsPerToken: Double = 3.5

    /// 估算一段文本的 token 数
    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
            } else if scalar == " " || scalar == "\t" {
                // 空白便宜得多（BPE 会把连续空白和相邻词一起合并）
                other += 1
            } else {
                other += 1
            }
        }
        // CJK：约 1 字符 1 token。其余：按 charsPerToken 折算，空白打个折。
        let blankCount = text.unicodeScalars.reduce(0) { acc, s in
            acc + ((s == " " || s == "\t") ? 1 : 0)
        }
        let effectiveOther = Double(other) - Double(blankCount) * 0.6
        return cjk + Int((max(0, effectiveOther) / charsPerToken).rounded(.up))
    }

    /// 是否 CJK（含假名与谚文：它们同样是 1 字符 ≈ 1 token）
    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,      // CJK 标点
             0x3040...0x30FF,      // 平假名 / 片假名
             0x3400...0x4DBF,      // CJK 扩展 A
             0x4E00...0x9FFF,      // CJK 基本区
             0xF900...0xFAFF,      // CJK 兼容
             0xAC00...0xD7AF,      // 谚文音节
             0xFF00...0xFFEF,      // 全角字符
             0x20000...0x2FA1F:    // CJK 扩展 B+
            return true
        default:
            return false
        }
    }

    /// 估算一组消息
    public static func estimate(messages: [Message]) -> Int {
        messages.reduce(0) { $0 + estimate($1) }
    }

    /// 估算一条消息（含工具调用的参数）
    public static func estimate(_ message: Message) -> Int {
        var total = 4   // 每条消息的角色与分隔开销
        for block in message.blocks {
            switch block.kind {
            case .text(let s):              total += estimate(s)
            case .reasoning(let s, _):      total += estimate(s)
            case .toolCall(let call):       total += estimate(call.name) + estimate(call.argumentsPreview) + 8
            case .toolResult(let result):   total += estimate(result.summary) + 8
            case .artifact(let ref):        total += estimate(ref.displayName) + 16
            case .image:                    total += 1100   // 图片按固定开销估（约等于一张低分辨率图）
            }
        }
        return total
    }
}

// MARK: - 预算

/// 单次模型调用的预算与配额（docs/07 §1.1）
public struct ContextBudget: Sendable, Codable, Hashable {

    /// 各区块的 token 配额
    public struct Allocation: Sendable, Codable, Hashable {
        public var systemLayers: Int
        public var history: Int
        public var toolResults: Int
        public var memory: Int
        /// 输出预留。**绝不允许被挤占** —— 挤占它等于让模型说到一半被截断
        public var outputReserve: Int
        /// 不可压缩项（目标 / todo / 最近失败 / 用户显式引用）实际占用的额度
        public var pinned: Int
        public var window: Int

        public var fillable: Int { systemLayers + history + toolResults + memory }
        /// 还能塞多少（用于 UI 与自检）
        public var spare: Int { window - outputReserve - pinned - fillable }
    }

    /// 模型窗口
    public var window: Int
    /// 若由成本倒推，记录目标成本（微美元）
    public var costCeilingMicroUSD: Int?
    /// 历史占比超过它就建议压缩（docs/07 §5.1 的 L3 触发）
    public var compactionTriggerRatio: Double
    /// 配额比例
    public var ratios: Ratios

    public struct Ratios: Sendable, Codable, Hashable {
        public var systemLayers: Double
        public var history: Double
        public var toolResults: Double
        public var memory: Double
        public var outputReserve: Double

        public init(
            systemLayers: Double = 0.25,
            history: Double = 0.30,
            toolResults: Double = 0.25,
            memory: Double = 0.10,
            outputReserve: Double = 0.10
        ) {
            self.systemLayers = systemLayers
            self.history = history
            self.toolResults = toolResults
            self.memory = memory
            self.outputReserve = outputReserve
        }

        /// docs/07 §1.1 的默认配额表
        public static let documented = Ratios()
    }

    public init(
        window: Int,
        costCeilingMicroUSD: Int? = nil,
        compactionTriggerRatio: Double = 0.60,
        ratios: Ratios = .documented
    ) {
        self.window = max(1024, window)
        self.costCeilingMicroUSD = costCeilingMicroUSD
        self.compactionTriggerRatio = compactionTriggerRatio
        self.ratios = ratios
    }

    /// ⭐ **按目标成本倒推窗口**（docs/07 §1.1 的实现要点）
    ///
    /// 原文：「装配器先按"目标成本"倒推，而不是"能塞多少塞多少"。
    /// 用户设了单 Turn ≤ $0.05，装配器就会把上下文压到对应 token 数，而不是把 200k 窗口用满。」
    ///
    /// 这是**手机上最关键的一条成本控制**：窗口大不等于应该用满。
    public static func derive(
        modelWindow: Int,
        costCeilingMicroUSD: Int?,
        inputPriceMicroUSDPerMillion: Int?,
        ratios: Ratios = .documented,
        compactionTriggerRatio: Double = 0.60
    ) -> ContextBudget {
        var window = modelWindow
        if let ceiling = costCeilingMicroUSD, let price = inputPriceMicroUSDPerMillion, price > 0 {
            // 目标成本能买多少输入 token
            let affordable = Int((Double(ceiling) / Double(price)) * 1_000_000)
            window = min(window, max(1024, affordable))
        }
        return ContextBudget(
            window: window,
            costCeilingMicroUSD: costCeilingMicroUSD,
            compactionTriggerRatio: compactionTriggerRatio,
            ratios: ratios
        )
    }

    /// 扣掉不可压缩项之后，把剩余额度按比例分配给四个可填充区块
    public func allocation(pinnedTokens: Int) -> Allocation {
        let reserve = Int(Double(window) * ratios.outputReserve)
        let available = max(0, window - reserve - pinnedTokens)
        return Allocation(
            systemLayers: Int(Double(available) * ratios.systemLayers),
            history: Int(Double(available) * ratios.history),
            toolResults: Int(Double(available) * ratios.toolResults),
            memory: Int(Double(available) * ratios.memory),
            outputReserve: reserve,
            pinned: pinnedTokens,
            window: window
        )
    }
}

// MARK: - 上下文区块

/// 装配的最小单位（docs/07 §1.2 的"素材"）
public struct ContextItem: Sendable, Codable, Hashable, Identifiable {
    public enum Block: String, Sendable, Codable, Hashable, CaseIterable {
        /// 层 1：身份、铁律、工具使用守则（**字节级稳定** → Prompt Cache）
        case systemLayer1
        /// 层 2：项目指令文件（RUNE.md / AGENTS.md）
        case systemLayer2
        /// 工作区结构摘要
        case workspaceMap
        /// 记忆命中（三层记忆，docs/07 §6）
        case memory
        /// 会话历史（含压缩摘要）
        case history
        /// 本轮工具结果
        case toolResult
        /// 用户显式引用（@文件 / 粘贴 / 图片 / 分享）
        case userExplicit
        /// 用户转向 / 运行时引导语
        case steering
    }

    /// **必须有**的角色。缺一个就不许把上下文发出去（docs/07 §1.2 第 6 步的硬性断言）。
    ///
    /// 经验：**"漏掉当前目标"和"漏掉最近的失败"是两个最常见的导致 Agent 跑偏的原因。**
    public enum PinnedRole: String, Sendable, Codable, Hashable {
        case objective
        case openTodos
        case lastFailure
        /// 用户显式引用的素材（他点名要看的，不能因为预算不够就悄悄丢掉）
        case userReference
    }

    public var id: String
    public var block: Block
    public var text: String
    /// token 数（由 `TokenEstimator` 算，或调用方给实测值）
    public var tokens: Int
    public var trust: TrustLevel
    public var taint: TaintOrigin?
    /// 语义相关性 0..1
    public var relevance: Double
    /// 新鲜度 0..1（越大越新）
    public var recency: Double
    /// 不可压缩 / 必进
    public var pinnedRole: PinnedRole?
    /// 全文句柄（被裁剪后模型靠它按需拉取）
    public var artifactHandle: String?
    /// 去重键：内容相同的项只保留一份（同样的东西不该占两份预算）
    public var dedupeKey: String?

    public init(
        id: String,
        block: Block,
        text: String,
        tokens: Int? = nil,
        trust: TrustLevel = .toolResultTrusted,
        taint: TaintOrigin? = nil,
        relevance: Double = 0.5,
        recency: Double = 0.5,
        pinnedRole: PinnedRole? = nil,
        artifactHandle: String? = nil,
        dedupeKey: String? = nil
    ) {
        self.id = id
        self.block = block
        self.text = text
        self.tokens = tokens ?? TokenEstimator.estimate(text)
        self.trust = trust
        self.taint = taint
        self.relevance = relevance
        self.recency = recency
        self.pinnedRole = pinnedRole
        self.artifactHandle = artifactHandle
        self.dedupeKey = dedupeKey
    }

    public var isPinned: Bool { pinnedRole != nil }
}

// MARK: - 装配结果

/// 某个区块里被丢掉的一项 + 原因（UI 要能回答"为什么它没看到那个文件"）
public struct DroppedItem: Sendable, Codable, Hashable {
    public enum Reason: String, Sendable, Codable, Hashable {
        case overQuota
        case duplicate
        case trimmedToHandle
        case selfCheckRetry
    }
    public var id: String
    public var block: ContextItem.Block
    public var tokens: Int
    public var reason: Reason
}

/// 自检项（docs/07 §1.2 第 6 步）
public struct SelfCheck: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case objectivePresent
        case openTodosPresent
        case lastFailurePresent
        case untrustedBoundaryPresent
        case outputReserveSufficient
        case withinWindow
    }
    public var kind: Kind
    public var passed: Bool
    public var detail: String
}

/// 一次装配的完整结果
public struct Assembly: Sendable, Codable, Hashable {
    /// 按**固定顺序**排好的区块文本（顺序稳定 → Prompt Cache 才能命中）
    public var blocks: [ContextItem]
    public var dropped: [DroppedItem]
    public var allocation: ContextBudget.Allocation
    public var selfChecks: [SelfCheck]
    public var usedTokens: Int
    /// 是否降级过（说明预算很紧）
    public var degradationRounds: Int
    /// 建议做 L3 主模型压缩（**装配器自己不会去花这个钱**，见下）
    public var needsMainModelCompaction: Bool
    /// 需要 L3 压缩的历史项 id
    public var compactionCandidates: [String]
    public var estimatedInputMicroUSD: Int?

    public var passed: Bool { selfChecks.allSatisfy { $0.passed } }

    /// 按渲染顺序拼好的全文（网关直接把它作为 messages 的来源）
    public var renderedText: String {
        blocks.map(\.text).joined(separator: "\n\n")
    }

    /// 给 UI / 调试面板看的一行
    public var observabilityLine: String {
        var parts = ["上下文 \(usedTokens)/\(allocation.window) token"]
        if allocation.pinned > 0 { parts.append("必进 \(allocation.pinned)") }
        if !dropped.isEmpty { parts.append("丢弃 \(dropped.count) 项") }
        if degradationRounds > 0 { parts.append("降级 \(degradationRounds) 轮") }
        if needsMainModelCompaction { parts.append("建议压缩历史") }
        if let micro = estimatedInputMicroUSD {
            parts.append(String(format: "约 $%.4f", Double(micro) / 1_000_000))
        }
        return parts.joined(separator: " · ")
    }

    /// 不可信内容是否在场（决定要不要加边界标记）
    public var hasUntrustedContent: Bool {
        blocks.contains { $0.taint != nil || $0.trust == .untrustedContent }
    }
}

// MARK: - 装配器

/// **预算制上下文装配器**（docs/07 §1.2）：
/// 素材收集 → 打分 → 配额填充 → 压缩 → 稳定性对齐 → 自检。
///
/// ## 三条设计红线
///
/// 1. **缺必进项就不许发出去。** 自检失败时用更小的上下文重试并降级，
///    而不是把"没有当前目标"的上下文发出去 —— 那是 Agent 跑偏的第一大原因。
/// 2. **装配器永不自己花钱。** L2（端侧摘要）通过注入的闭包做（零成本），
///    L3（主模型压缩）只**报告需要**，由运行时决定并落事件 —— 因为那是一次要付费的模型调用。
///    让一个"装配"函数悄悄扣钱，是成本失控最典型的来源。
/// 3. **顺序与字节必须稳定。** 层 1+2 在两次装配之间必须逐字节一致，否则 Prompt Cache 永不命中，
///    而缓存能把输入成本压到 0.1× —— 那是手机上最实在的一笔省钱。
public enum ContextAssembler {

    public struct Config: Sendable {
        // 打分权重（docs/07 §1.2 步骤 2）
        public var relevanceWeight: Double
        public var recencyWeight: Double
        public var userReferencedBoost: Double
        public var tokenCostWeight: Double
        public var taintPenalty: Double
        /// 自检失败时最多降级几轮
        public var maxDegradationRounds: Int
        /// 每轮降级把可填充额度缩到原来的多少
        public var degradationFactor: Double

        public init(
            relevanceWeight: Double = 1.0,
            recencyWeight: Double = 0.5,
            userReferencedBoost: Double = 1.5,
            tokenCostWeight: Double = 0.3,
            taintPenalty: Double = 0.8,
            maxDegradationRounds: Int = 3,
            degradationFactor: Double = 0.75
        ) {
            self.relevanceWeight = relevanceWeight
            self.recencyWeight = recencyWeight
            self.userReferencedBoost = userReferencedBoost
            self.tokenCostWeight = tokenCostWeight
            self.taintPenalty = taintPenalty
            self.maxDegradationRounds = max(0, maxDegradationRounds)
            self.degradationFactor = min(0.95, max(0.3, degradationFactor))
        }

        public static let `default` = Config()
    }

    /// 端侧摘要器（L2）。返回 nil 表示"压不动"。
    ///
    /// ⚠️ 它是**注入**的，不是内联实现的：端侧模型在 iOS 上（Apple Foundation Models），
    /// 在 Windows 上根本不存在。装配器的职责是"决定要不要压、压哪些"，不是"怎么压"。
    public typealias Summarizer = @Sendable ([ContextItem]) -> String?

    /// 区块的**固定渲染顺序**（这个顺序是缓存命中的前提，不要随心情改）
    public static let blockOrder: [ContextItem.Block] = [
        .systemLayer1, .systemLayer2, .workspaceMap,
        .steering, .userExplicit,
        .memory, .history, .toolResult,
    ]

    // MARK: 主入口

    public static func assemble(
        items: [ContextItem],
        budget: ContextBudget,
        config: Config = .default,
        endSideSummarizer: Summarizer? = nil
    ) -> Assembly {
        var dropped: [DroppedItem] = []
        var rounds = 0
        var effective = budget
        var result = run(
            items: items, budget: effective, config: config,
            summarizer: endSideSummarizer, dropped: &dropped
        )

        // ⚠️ 自检失败 → **降级重试**，而不是把不完整的上下文发出去。
        //    注意重试只解决"额度不够"，解决不了"必进项根本没给"（那是调用方的 bug，
        //    这种失败会一直失败下去，所以循环有次数上限，最后如实上报）。
        while !result.passed, rounds < config.maxDegradationRounds, canDegrade(result) {
            rounds += 1
            effective = ContextBudget(
                window: Int(Double(effective.window) * config.degradationFactor),
                costCeilingMicroUSD: effective.costCeilingMicroUSD,
                compactionTriggerRatio: effective.compactionTriggerRatio,
                ratios: effective.ratios
            )
            dropped.removeAll { $0.reason == .selfCheckRetry }
            result = run(
                items: items, budget: effective, config: config,
                summarizer: endSideSummarizer, dropped: &dropped
            )
        }

        result.degradationRounds = rounds
        result.dropped = dropped + result.dropped
        return result
    }

    /// 只有"额度不够"这类失败才值得降级重试；"必进项压根没给"重试一万次也一样
    static func canDegrade(_ assembly: Assembly) -> Bool {
        assembly.selfChecks.contains { !$0.passed && $0.kind == .withinWindow }
    }

    // MARK: 单轮装配

    static func run(
        items: [ContextItem],
        budget: ContextBudget,
        config: Config,
        summarizer: Summarizer?,
        dropped: inout [DroppedItem]
    ) -> Assembly {
        // ---------- 步骤 1：去重 ----------
        //
        // 同一个文件被读两次、同一段历史被重复注入 —— 不去重就等于花两份钱买同一份信息。
        var seenKeys = Set<String>()
        var pool: [ContextItem] = []
        for item in items {
            guard let key = item.dedupeKey else { pool.append(item); continue }
            if seenKeys.contains(key) {
                dropped.append(DroppedItem(id: item.id, block: item.block, tokens: item.tokens, reason: .duplicate))
                continue
            }
            seenKeys.insert(key)
            pool.append(item)
        }

        // ---------- 步骤 2：必进项先占位 ----------
        let pinned = pool.filter(\.isPinned)
        let pinnedTokens = pinned.reduce(0) { $0 + $1.tokens }
        let allocation = budget.allocation(pinnedTokens: pinnedTokens)

        // ---------- 步骤 3：配额填充（块内按分数贪心） ----------
        var chosen: [ContextItem] = pinned
        var perBlockUsed: [ContextItem.Block: Int] = [:]
        for item in pinned { perBlockUsed[item.block, default: 0] += item.tokens }

        for block in ContextItem.Block.allCases {
            let quota = quota(for: block, allocation: allocation)
            guard quota > 0 else {
                // 该区块完全没有额度 → 里面的东西全部记录为超配额
                for item in pool where item.block == block && !item.isPinned {
                    dropped.append(DroppedItem(id: item.id, block: block, tokens: item.tokens, reason: .overQuota))
                }
                continue
            }
            var used = perBlockUsed[block] ?? 0
            let candidates = pool
                .filter { $0.block == block && !$0.isPinned }
                .sorted { score($0, config: config) > score($1, config: config) }

            for item in candidates {
                if used + item.tokens <= quota {
                    chosen.append(item)
                    used += item.tokens
                    continue
                }
                // 塞不下 → 先试 L1 裁剪（把大输出压成「结论 + 关键行 + 制品句柄」）
                let remaining = quota - used
                if remaining >= ContextAssembler.minTrimmedTokens, item.artifactHandle != nil {
                    let trimmed = structuralTrim(item, to: remaining)
                    if trimmed.tokens < item.tokens {
                        chosen.append(trimmed)
                        used += trimmed.tokens
                        dropped.append(DroppedItem(id: item.id, block: block, tokens: item.tokens - trimmed.tokens, reason: .trimmedToHandle))
                        continue
                    }
                }
                dropped.append(DroppedItem(id: item.id, block: block, tokens: item.tokens, reason: .overQuota))
            }
            perBlockUsed[block] = used
        }

        var selected = chosen

        // ---------- 步骤 4：历史超配额 → L2 端侧摘要 ----------
        var needsL3 = false
        var candidates: [String] = []
        let historyTokens = selected.filter { $0.block == .history }.reduce(0) { $0 + $1.tokens }
        let historyQuota = allocation.history
        if historyQuota > 0, Double(historyTokens) > Double(historyQuota) * budget.compactionTriggerRatio {
            needsL3 = true
        }
        let totalBefore = selected.reduce(0) { $0 + $1.tokens }
        if totalBefore > allocation.window - allocation.outputReserve {
            // 真的超了 → 端侧先压（零成本），压不动才建议花主模型的钱
            needsL3 = true
        }
        if needsL3, let summarizer {
            let compressible = selected
                .filter { $0.block == .history || $0.block == .toolResult }
                .sorted { $0.recency < $1.recency }        // 先压最旧的
            let half = Array(compressible.prefix(max(1, compressible.count / 2)))
            if let digest = summarizer(half), !digest.isEmpty {
                let digestItem = ContextItem(
                    id: "end-side-digest",
                    block: .history,
                    text: digest,
                    trust: .modelOutput,
                    relevance: 0.7,
                    recency: 0.4
                )
                let ids = Set(half.map(\.id))
                let removedTokens = half.reduce(0) { $0 + $1.tokens }
                selected.removeAll { ids.contains($0.id) }
                selected.append(digestItem)
                dropped.append(contentsOf: half.map {
                    DroppedItem(id: $0.id, block: $0.block, tokens: $0.tokens, reason: .overQuota)
                })
                // 端侧压完如果已经够了，就不必再花钱
                let after = selected.reduce(0) { $0 + $1.tokens }
                if after + digestItem.tokens <= allocation.window - allocation.outputReserve,
                   Double(after) <= Double(historyQuota) * budget.compactionTriggerRatio {
                    needsL3 = false
                }
                _ = removedTokens
            }
        }
        if needsL3 {
            candidates = selected
                .filter { $0.block == .history || $0.block == .toolResult }
                .sorted { $0.recency < $1.recency }
                .prefix(24)
                .map(\.id)
        }

        // ---------- 步骤 5：稳定性对齐（固定渲染顺序） ----------
        let ordered = selected.sorted { a, b in
            let ia = blockOrder.firstIndex(of: a.block) ?? 99
            let ib = blockOrder.firstIndex(of: b.block) ?? 99
            if ia != ib { return ia < ib }
            // 块内必须**确定性**排序：id 兜底，避免同一批素材两次装配产出不同字节
            if a.recency != b.recency { return a.recency > b.recency }
            return a.id < b.id
        }

        // ---------- 步骤 6：自检 ----------
        let used = ordered.reduce(0) { $0 + $1.tokens }
        var checks = selfCheck(
            ordered: ordered,
            sourcePool: pool,
            used: used,
            allocation: allocation,
            pinnedTokens: pinnedTokens
        )

        // 超窗口 → 通过丢弃"最不必要"的非必进项来救（而不是删必进项）
        if !checks.first(where: { $0.kind == .withinWindow })!.passed {
            let toDrop = ordered
                .filter { !$0.isPinned }
                .sorted { score($0, config: config) < score($1, config: config) }
            var trimmed = ordered
            var nowUsed = used
            let limit = allocation.window - allocation.outputReserve
            for item in toDrop where nowUsed > limit {
                trimmed.removeAll { $0.id == item.id }
                nowUsed -= item.tokens
                dropped.append(DroppedItem(id: item.id, block: item.block, tokens: item.tokens, reason: .selfCheckRetry))
            }
            let reordered = trimmed.sorted { a, b in
                let ia = blockOrder.firstIndex(of: a.block) ?? 99
                let ib = blockOrder.firstIndex(of: b.block) ?? 99
                if ia != ib { return ia < ib }
                if a.recency != b.recency { return a.recency > b.recency }
                return a.id < b.id
            }
            checks = selfCheck(
                ordered: reordered, sourcePool: pool, used: nowUsed,
                allocation: allocation, pinnedTokens: pinnedTokens
            )
            return Assembly(
                blocks: reordered, dropped: dropped, allocation: allocation,
                selfChecks: checks, usedTokens: nowUsed, degradationRounds: 0,
                needsMainModelCompaction: needsL3, compactionCandidates: candidates,
                estimatedInputMicroUSD: nil
            )
        }

        return Assembly(
            blocks: ordered, dropped: dropped, allocation: allocation,
            selfChecks: checks, usedTokens: used, degradationRounds: 0,
            needsMainModelCompaction: needsL3, compactionCandidates: candidates,
            estimatedInputMicroUSD: nil
        )
    }

    /// 裁剪到这个 token 数以下就不值得再裁（再裁就只剩标题了，不如整块丢掉）
    static let minTrimmedTokens = 40

    static func quota(for block: ContextItem.Block, allocation: ContextBudget.Allocation) -> Int {
        switch block {
        case .systemLayer1, .systemLayer2, .workspaceMap: return allocation.systemLayers
        case .history:      return allocation.history
        case .toolResult:   return allocation.toolResults
        case .memory:       return allocation.memory
        // 用户显式引用与转向：不设配额，走"必进"通道（用户点名要的东西不能因为预算被悄悄丢掉）
        case .userExplicit, .steering: return 0
        }
    }

    /// 打分（docs/07 §1.2 步骤 2）
    ///
    /// `score = w1·相关性 + w2·新鲜度 + w3·用户显式引用 − w4·token 成本 − w5·污点惩罚`
    public static func score(_ item: ContextItem, config: Config) -> Double {
        var s = config.relevanceWeight * item.relevance
        s += config.recencyWeight * item.recency
        if item.pinnedRole == .userReference { s += config.userReferencedBoost }
        // 成本惩罚：以 1000 token 为一个单位（1 万 token 的项按默认权重约扣 3 分）
        s -= config.tokenCostWeight * (Double(item.tokens) / 1000.0)
        if item.taint != nil || item.trust == .untrustedContent { s -= config.taintPenalty }
        return s
    }

    // MARK: L1 结构化裁剪
    //
    // docs/07 §5.1：单区块超配额时，工具结果只保留
    // **结论 + 关键行 + 制品句柄**，丢弃中间过程。本地零成本。

    /// 诊断关键词（这些行无论多长都要留 —— 它们就是"关键行"）
    static let diagnosticMarkers = [
        "error", "Error", "ERROR", "fail", "Fail", "FAIL",
        "Traceback", "Exception", "panic", "fatal",
        "错误", "失败", "异常", "警告", "警告：",
        "✗", "×", "❌",
    ]

    /// 把一项裁到 `limit` token 以内：保留头部结论 + 诊断行 + 制品句柄
    public static func structuralTrim(_ item: ContextItem, to limit: Int) -> ContextItem {
        guard item.tokens > limit, limit >= minTrimmedTokens else { return item }

        let lines = item.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var head: [String] = []
        var keyLines: [String] = []
        var used = 0
        // 头部（通常就是"结论"：git status、命令输出、文件开头）
        for line in lines.prefix(12) {
            let cost = TokenEstimator.estimate(line) + 1
            if used + cost > limit / 2 { break }
            head.append(line)
            used += cost
        }
        // 关键行（按原始顺序保留，最多 20 行）
        for line in lines where diagnosticMarkers.contains(where: { line.contains($0) }) {
            guard keyLines.count < 20 else { break }
            let cost = TokenEstimator.estimate(line) + 1
            if used + cost > limit - 20 { break }
            if head.contains(line) { continue }
            keyLines.append(line)
            used += cost
        }

        var text = head.joined(separator: "\n")
        if !keyLines.isEmpty {
            text += "\n…（关键行）\n" + keyLines.joined(separator: "\n")
        }
        let omitted = max(0, lines.count - head.count)
        if omitted > 0 {
            text += "\n…（已省略 \(omitted) 行）"
        }
        if let handle = item.artifactHandle {
            text += "\n[全文：\(handle)]"
        }

        return ContextItem(
            id: item.id,
            block: item.block,
            text: text,
            tokens: min(limit, TokenEstimator.estimate(text)),
            trust: item.trust,
            taint: item.taint,
            relevance: item.relevance,
            recency: item.recency,
            pinnedRole: item.pinnedRole,
            artifactHandle: item.artifactHandle,
            dedupeKey: item.dedupeKey
        )
    }

    // MARK: 自检

    static func selfCheck(
        ordered: [ContextItem],
        sourcePool: [ContextItem],
        used: Int,
        allocation: ContextBudget.Allocation,
        pinnedTokens: Int
    ) -> [SelfCheck] {
        var checks: [SelfCheck] = []

        func hasRole(_ role: ContextItem.PinnedRole) -> Bool {
            ordered.contains { $0.pinnedRole == role }
        }
        func poolHasRole(_ role: ContextItem.PinnedRole) -> Bool {
            sourcePool.contains { $0.pinnedRole == role }
        }

        checks.append(SelfCheck(
            kind: .objectivePresent, passed: hasRole(.objective),
            detail: hasRole(.objective) ? "当前目标在场" : "⚠️ 上下文里没有「当前目标」—— Agent 跑偏的第一大原因"
        ))
        // todo / 最近失败是**有条件必进**：素材池里有，就必须进来
        checks.append(SelfCheck(
            kind: .openTodosPresent,
            passed: !poolHasRole(.openTodos) || hasRole(.openTodos),
            detail: poolHasRole(.openTodos)
                ? (hasRole(.openTodos) ? "未完成 todo 在场" : "⚠️ 有未完成 todo 却没进上下文")
                : "没有未完成 todo（无需检查）"
        ))
        checks.append(SelfCheck(
            kind: .lastFailurePresent,
            passed: !poolHasRole(.lastFailure) || hasRole(.lastFailure),
            detail: poolHasRole(.lastFailure)
                ? (hasRole(.lastFailure) ? "最近失败在场" : "⚠️ 有最近失败却没进上下文 —— 会导致它重走已经失败的路")
                : "没有失败记录（无需检查）"
        ))

        let untrustedInPool = sourcePool.contains { $0.taint != nil || $0.trust == .untrustedContent }
        let untrustedIncluded = ordered.contains { $0.taint != nil || $0.trust == .untrustedContent }
        checks.append(SelfCheck(
            kind: .untrustedBoundaryPresent,
            passed: !untrustedInPool || untrustedIncluded,
            detail: untrustedInPool
                ? (untrustedIncluded ? "不可信内容带边界标记在场" : "⚠️ 素材里有不可信内容但没带上边界标记")
                : "没有不可信内容（无需检查）"
        ))

        let limit = allocation.window - allocation.outputReserve
        checks.append(SelfCheck(
            kind: .outputReserveSufficient,
            passed: allocation.outputReserve >= Int(Double(allocation.window) * 0.10),
            detail: allocation.outputReserve >= Int(Double(allocation.window) * 0.10)
                ? "输出预留 \(allocation.outputReserve) token（≥10%）"
                : "⚠️ 输出预留被挤到 \(allocation.outputReserve) token（<10%），模型会说到一半被截断"
        ))
        checks.append(SelfCheck(
            kind: .withinWindow, passed: used <= limit,
            detail: used <= limit
                ? "总占用 \(used) ≤ 上限 \(limit)"
                : "超出上限：\(used) > \(limit)（需降级重试）"
        ))
        _ = pinnedTokens
        return checks
    }
}
