import Foundation

// MARK: - 技能（Skills）与渐进式披露
//
// 设计依据（docs/04 §7）：技能解决的**不是能力问题，是上下文问题**。
//
// 一个"技能"本质上就是一段写给模型的领域指令（怎么排查 flaky 测试、怎么做 SQL 迁移…）。
// 最朴素的做法是把所有技能的全文塞进系统提示 —— 12 个技能 × 1000 token = 一万多 token，
// 每一轮对话都要付这笔钱，而其中 11 个跟当前任务无关。
//
// 所以 Rune 走**三层加载**（docs/04 §7.2）：
//
// | 层 | 何时加载 | 成本 |
// |---|---|---|
// | L0 目录 | 每次装配上下文 | 每条 ~15 token（名称 + 一句话 + 何时用） |
// | L1 指令正文 | 模型调用 `use_skill(name)` | 通常 300–2000 token |
// | L2 示例与夹具 | 模型进一步请求，或运行时判定需要 | 按需 |
//
// ⚠️ 一条**绝不能破**的规则：**L1 正文永远不能自动加载。**
// 一旦"顺手把正文也带上"，渐进式披露就退化成"全塞"，而它退化之后没有任何报错 ——
// 只是账单变贵、模型变慢、关键信息被淹没。
// 所以本模块的 API 从设计上就**不提供**"取全部正文"这种方便方法。

// MARK: - 技能包

/// 一个技能包（docs/04 §7.1）。
public struct RuneSkill: Sendable, Codable, Hashable, Identifiable {

    public enum Source: String, Sendable, Codable, Hashable, CaseIterable {
        /// 随包分发（已审计）
        case builtin
        /// 用户自己写的
        case user
        /// 从文件导入的（仍是用户的文件，但来源不是他本人写的，审计上要区分）
        case imported

        public var displayName: String {
            switch self {
            case .builtin: return "内置"
            case .user: return "自建"
            case .imported: return "导入"
            }
        }
    }

    /// 三层加载的层级（用于给 UI 显示"这次进了多少上下文"）
    public enum Layer: String, Sendable, Codable, Hashable {
        case catalog
        case body
        case examples
    }

    /// `name` 同时是 id：它是唯一的、稳定的引用键（`use_skill("flaky-test-triage")`、`#flaky-test-triage`）
    public var id: String { name }
    /// ⚠️ 必须是 kebab-case：它会被 `#技能名` 语法引用，含空格或大写会让引用歧义
    public var name: String
    /// L0 目录里的"一句话"（**必须短**：它就是目录成本的大头）
    public var description: String
    /// L0 目录里的"何时用"。
    ///
    /// ⚠️ 这是目录里**唯一能帮模型做决策**的信息。少了它，模型只能靠名字猜，
    /// 于是要么不用技能，要么用错技能 —— 两者都比没有技能更糟。
    public var whenToUse: String
    public var source: Source
    /// L1 指令正文（`RUNE.md`）
    public var body: String
    /// L2 少样本示例
    public var examples: [SkillExample]
    /// L2 夹具（例如一个复现用的最小仓库）
    public var fixtures: [String]
    /// 验证清单（"修完必须能跑通 X"）——
    /// ⚠️ 有清单的技能，模型真的会去验证；没有清单的技能，它会在改完就宣布完成
    public var checks: [String]
    /// 本技能**申请**的能力（`policy.toml`）。
    ///
    /// ⚠️ 这是"申请"，不是"授权"：技能**不能给自己提权**（docs/04 §12.3）。
    /// 它必须走正常的审批流程，且永远不能申请人类专属区。
    public var requestedCapabilities: SkillCapabilityRequest
    /// 正文的信任级。内置与自建的都是 `.projectInstruction`（用户自己的东西，半可信）
    public var bodyTrust: TrustLevel
    public var useCount: Int
    public var lastUsedAt: Date?
    public var isEnabled: Bool
    /// nil = 全局可用
    public var workspaceID: UUID?

    public init(
        name: String,
        description: String,
        whenToUse: String,
        source: Source = .builtin,
        body: String,
        examples: [SkillExample] = [],
        fixtures: [String] = [],
        checks: [String] = [],
        requestedCapabilities: SkillCapabilityRequest = .init(),
        bodyTrust: TrustLevel = .projectInstruction,
        useCount: Int = 0,
        lastUsedAt: Date? = nil,
        isEnabled: Bool = true,
        workspaceID: UUID? = nil
    ) {
        self.name = name
        self.description = description
        self.whenToUse = whenToUse
        self.source = source
        self.body = body
        self.examples = examples
        self.fixtures = fixtures
        self.checks = checks
        self.requestedCapabilities = requestedCapabilities
        self.bodyTrust = bodyTrust
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.isEnabled = isEnabled
        self.workspaceID = workspaceID
    }

    // MARK: L0 成本

    /// L0 目录里的一行
    public var catalogLine: String {
        "· \(name)：\(description) —— 何时用：\(whenToUse)"
    }

    /// 这一条在 L0 里要花多少 token
    public var catalogTokens: Int { TokenEstimator.estimate(catalogLine) }

    /// L1 正文的 token 成本（UI 上要能回答"加载它花了多少"）
    public var bodyTokens: Int { TokenEstimator.estimate(body) }

    /// 检索用的一段文本（名称权重更高，所以名字重复一次）
    var searchText: String { "\(name) \(name) \(description) \(whenToUse)" }
}

/// L2 少样本示例
public struct SkillExample: Sendable, Codable, Hashable {
    public var title: String
    public var content: String
    /// 相关的文件（可以直接喂给 `read_file`）
    public var files: [String]

    public init(title: String, content: String, files: [String] = []) {
        self.title = title
        self.content = content
        self.files = files
    }
}

/// 技能申请的权限（`policy.toml` 的内容）
public struct SkillCapabilityRequest: Sendable, Codable, Hashable {
    /// 申请可写的路径（相对工作区）
    public var writePaths: [String]
    /// 申请可访问的域名
    public var egressDomains: [String]
    /// 申请可用的执行环境
    public var runtimes: [SandboxRuntime]
    /// 申请可用的 iOS 原生能力（相册/日历/…）
    public var nativeAPIs: [String]

    public init(
        writePaths: [String] = [],
        egressDomains: [String] = [],
        runtimes: [SandboxRuntime] = [],
        nativeAPIs: [String] = []
    ) {
        self.writePaths = writePaths
        self.egressDomains = egressDomains
        self.runtimes = runtimes
        self.nativeAPIs = nativeAPIs
    }

    public var isEmpty: Bool {
        writePaths.isEmpty && egressDomains.isEmpty && runtimes.isEmpty && nativeAPIs.isEmpty
    }

    /// 申请摘要（给审批卡片用；用户必须在**看得懂**的前提下做决定）
    public var summaryLines: [String] {
        var lines: [String] = []
        if !writePaths.isEmpty { lines.append("写入：\(writePaths.joined(separator: "、"))") }
        if !egressDomains.isEmpty { lines.append("联网：\(egressDomains.joined(separator: "、"))") }
        if !runtimes.isEmpty { lines.append("执行：\(runtimes.map(\.displayName).joined(separator: "、"))") }
        if !nativeAPIs.isEmpty { lines.append("系统能力：\(nativeAPIs.joined(separator: "、"))") }
        return lines
    }
}

// MARK: - frontmatter

/// `RUNE.md` 的 frontmatter（`---` 包围的极简 YAML 子集：`key: value`）。
///
/// ⚠️ 为什么只做极简子集：这是给用户手写的文件。支持的语法越多，
/// 用户写出"看起来对但解析失败"的文件的概率就越大。
/// 只认 `key: value`，其余原样忽略 —— **解析失败必须给出人话原因**，而不是静默丢掉技能。
public struct SkillFrontmatter: Sendable, Codable, Hashable {
    public var name: String
    public var description: String
    public var whenToUse: String
    public var extra: [String: String]

    public init(name: String, description: String, whenToUse: String, extra: [String: String] = [:]) {
        self.name = name
        self.description = description
        self.whenToUse = whenToUse
        self.extra = extra
    }

    public enum ParseFailure: Error, Sendable, Hashable, CustomStringConvertible {
        case missingFrontmatter
        case unterminatedFrontmatter
        case missingKey(String)
        case emptyValue(String)

        public var description: String {
            switch self {
            case .missingFrontmatter:
                return "文件开头没有 frontmatter。正确写法是文件第一行是 `---`，然后是 name/description/when_to_use，再用一行 `---` 收尾。"
            case .unterminatedFrontmatter:
                return "frontmatter 没有收尾的 `---`。"
            case .missingKey(let key):
                return "frontmatter 缺少必填项 `\(key)`。"
            case .emptyValue(let key):
                return "frontmatter 的 `\(key)` 是空的 —— 空值等于没写，会让模型无法判断何时该用这个技能。"
            }
        }
    }

    /// 解析。返回 frontmatter 与**正文**（frontmatter 之后的内容）。
    public static func parse(_ text: String) -> Result<(SkillFrontmatter, String), ParseFailure> {
        // ⚠️ 先归一化换行：`"\r\n"` 在 Swift 里是**单个 Character**，
        //    直接 `components(separatedBy: "\n")` 在 CRLF 文件上根本不会分割。
        let normalized = TextEdit.normalizeNewlines(text, to: "\n")
        let lines = normalized.components(separatedBy: "\n")

        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return .failure(.missingFrontmatter)
        }
        guard let endIndex = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return .failure(.unterminatedFrontmatter)
        }

        var fields: [String: String] = [:]
        for line in lines[1..<endIndex] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // 去掉两侧引号（用户会写 `name: "x"`）
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }

        func require(_ key: String) -> Result<String, ParseFailure> {
            guard let value = fields[key], !value.isEmpty else {
                return .failure(fields[key] == nil ? .missingKey(key) : .emptyValue(key))
            }
            return .success(value)
        }

        // ⚠️ `when_to_use` 是**必填**：没有它模型只能靠名字猜，比没有技能更糟
        var values: [String: String] = [:]
        for key in ["name", "description", "when_to_use"] {
            switch require(key) {
            case .success(let value): values[key] = value
            case .failure(let failure): return .failure(failure)
            }
        }

        let body = lines[(endIndex + 1)...].joined(separator: "\n")
        var extra = fields
        extra.removeValue(forKey: "name")
        extra.removeValue(forKey: "description")
        extra.removeValue(forKey: "when_to_use")
        return .success((
            SkillFrontmatter(
                name: values["name"] ?? "",
                description: values["description"] ?? "",
                whenToUse: values["when_to_use"] ?? "",
                extra: extra
            ),
            body
        ))
    }

    /// 生成一个 `RUNE.md`（用于"把这个技能导出/另存为"）
    public func rendered(body: String) -> String {
        var lines = ["---", "name: \(name)", "description: \(description)", "when_to_use: \(whenToUse)"]
        for (key, value) in extra.sorted(by: { $0.key < $1.key }) { lines.append("\(key): \(value)") }
        lines.append("---")
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n")
    }
}

// MARK: - 注册表

/// 技能注册表 + 渐进式披露。
///
/// 它是**值类型**（`mutating` 方法用于记录使用次数），因此完全可测、可回放。
public struct SkillRegistry: Sendable, Codable, Hashable {

    /// 设计红线（docs/04 §7.2）：L0 目录条目不得超过 40 条
    public var maxCatalogEntries: Int
    /// L0 目录的 token 上限（40 条 × ~15 token，留一点余量）
    public var catalogTokenBudget: Int
    public private(set) var skills: [RuneSkill]

    public init(
        skills: [RuneSkill] = SkillLibrary.builtin,
        maxCatalogEntries: Int = 40,
        catalogTokenBudget: Int = 1600
    ) {
        self.skills = skills
        self.maxCatalogEntries = max(1, maxCatalogEntries)
        self.catalogTokenBudget = max(40, catalogTokenBudget)
    }

    // MARK: 查找

    public func skill(named name: String) -> RuneSkill? {
        skills.first { $0.name == name }
    }

    /// 某个工作区可见的技能（全局 + 该工作区）
    public func available(workspaceID: UUID?) -> [RuneSkill] {
        skills.filter { $0.isEnabled && ($0.workspaceID == nil || $0.workspaceID == workspaceID) }
    }

    // MARK: L0 目录

    public struct Catalog: Sendable, Codable, Hashable {
        public var entries: [RuneSkill]
        /// 被截断掉的条数（> 0 时目录里必须出现提示）
        public var omittedCount: Int
        public var tokens: Int
        public var text: String
        public var reason: String

        public var isTruncated: Bool { omittedCount > 0 }
        /// 提示语（**必须出现**，否则模型不知道还有东西可查）
        public var hint: String? {
            omittedCount > 0 ? "还有 \(omittedCount) 个技能可用 —— 用 `search_skills` 按关键词查询。" : nil
        }
    }

    /// 生成 L0 目录（docs/04 §7.2）。
    ///
    /// - Parameter query: 当前任务的关键词（有它时按相关性 + 最近使用排序）
    public func catalog(
        query: String? = nil,
        workspaceID: UUID? = nil,
        budgetTokens: Int? = nil,
        now: Date = Date()
    ) -> Catalog {
        let pool = available(workspaceID: workspaceID)
        let budget = budgetTokens ?? catalogTokenBudget
        let ranked = rank(pool, query: query, now: now)

        // ⚠️ 预算必须**先把固定开销扣掉**，否则它就不是硬预算。
        //    这里踩过一次：只累加各条目的成本，忘了标题行与可能的「还有 N 个」提示行，
        //    于是「预算 300」实际产出 306 —— 超出的部分会悄悄挤掉别的区块的额度。
        let header = "可用技能（L0 目录 —— 需要时用 `use_skill` 加载正文）：\n"
        let hintAllowance = 24
        var chosen: [RuneSkill] = []
        var used = TokenEstimator.estimate(header) + hintAllowance
        var reason = "全部 \(pool.count) 个都在预算内"
        for skill in ranked {
            if chosen.count >= maxCatalogEntries { reason = "条目数达到上限 \(maxCatalogEntries)"; break }
            let cost = skill.catalogTokens + 1     // 换行
            if used + cost > budget { reason = "token 预算 \(budget) 已满"; break }
            chosen.append(skill)
            used += cost
        }

        // ⚠️ 顺序：模型按顺序读，所以把相关的排前面
        var text = header
        text += chosen.map(\.catalogLine).joined(separator: "\n")
        let omitted = pool.count - chosen.count
        if omitted > 0 {
            text += "\n（还有 \(omitted) 个技能可用，用 `search_skills` 按关键词查询）"
        }
        return Catalog(
            entries: chosen,
            omittedCount: omitted,
            tokens: TokenEstimator.estimate(text),
            text: text,
            reason: reason
        )
    }

    /// 给上下文装配器用的区块。
    ///
    /// 放在**系统层 2**（会话内基本不变）→ 落进可缓存前缀，这是 prompt cache 能命中的前提。
    public func catalogItem(
        query: String? = nil,
        workspaceID: UUID? = nil,
        budgetTokens: Int? = nil,
        now: Date = Date()
    ) -> ContextItem {
        let built = catalog(query: query, workspaceID: workspaceID, budgetTokens: budgetTokens, now: now)
        return ContextItem(
            id: "skill-catalog",
            block: .systemLayer2,
            text: built.text,
            tokens: built.tokens,
            trust: .projectInstruction,
            relevance: 0.8,
            recency: 1.0
        )
    }

    /// 排序：语义相关 + 最近使用 + 使用频次（docs/04 §7.2 的"最近使用 + 语义相关"）。
    func rank(_ pool: [RuneSkill], query: String?, now: Date) -> [RuneSkill] {
        pool
            .map { skill -> (RuneSkill, Double) in
                var score = 0.0
                if let query, !query.isEmpty {
                    score += 3.0 * SkillSearch.relevance(skill, query: query)
                }
                // 最近使用：7 天内线性衰减
                if let last = skill.lastUsedAt {
                    let days = max(0, now.timeIntervalSince(last) / 86_400)
                    score += 1.5 * max(0, 1.0 - days / 7.0)
                }
                // 频次：对数压缩，避免一个高频技能永远压住其他所有技能
                score += 0.4 * log(1.0 + Double(skill.useCount))
                return (skill, score)
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.name < b.0.name      // 确定性兜底（缓存稳定性）
            }
            .map(\.0)
    }

    // MARK: L1 加载（`use_skill`）

    public enum LoadResult: Sendable, Hashable {
        case loaded(RuneSkill)
        case notFound(name: String, suggestion: String?)
        case disabled(name: String)
        /// ⚠️ 技能申请的权限尚未获得 → **必须先走审批**，不能"先加载了再说"
        case needsApproval(skill: RuneSkill, request: SkillCapabilityRequest, reason: String)

        public var skillName: String {
            switch self {
            case .loaded(let s): return s.name
            case .notFound(let n, _): return n
            case .disabled(let n): return n
            case .needsApproval(let s, _, _): return s.name
            }
        }
    }

    /// 加载技能正文。
    ///
    /// - Parameter granted: 当前已授予的能力描述（用于判断技能申请的权限是否已经覆盖）。
    ///   传 nil 表示"不做权限判定"（例如只读档下预览）。
    public mutating func load(
        _ name: String,
        now: Date,
        granted: GrantedCapabilities? = nil
    ) -> LoadResult {
        guard let index = skills.firstIndex(where: { $0.name == name }) else {
            let suggestion = nearestName(to: name)
            return .notFound(name: name, suggestion: suggestion)
        }
        guard skills[index].isEnabled else { return .disabled(name: name) }

        let skill = skills[index]

        // ⚠️ 权限门：技能申请的权限必须在**加载之前**就位。
        //    "先加载正文、遇到越权再拒绝"是不行的 —— 正文本身就会引导模型去申请那些权限，
        //    而那已经是一次提示注入式的提权尝试了。
        if let granted, !skill.requestedCapabilities.isEmpty {
            let missing = granted.missing(from: skill.requestedCapabilities)
            if !missing.isEmpty {
                return .needsApproval(
                    skill: skill,
                    request: skill.requestedCapabilities,
                    reason: "技能「\(skill.name)」需要额外的权限才能用：\(missing.summaryLines.joined(separator: "；"))"
                )
            }
        }

        // 记一次使用（喂给 L0 排序）
        skills[index].useCount += 1
        skills[index].lastUsedAt = now
        return .loaded(skills[index])
    }

    /// L2：示例与夹具（模型进一步请求时才给）
    public func examples(of name: String, limit: Int = 3) -> [SkillExample] {
        guard let skill = skill(named: name) else { return [] }
        return Array(skill.examples.prefix(max(0, limit)))
    }

    /// 把 L1 正文渲染成给模型的一块上下文（`use_skill` 的返回值就是它）
    ///
    /// ⚠️ 渲染里**必须**带上验证清单：有清单的技能模型才会真的去验证，
    /// 没有清单的技能它会在改完就宣布完成。
    public func bodyBlock(of name: String) -> ContextItem? {
        guard let skill = skill(named: name) else { return nil }
        var text = "【技能：\(skill.name)】\n\(skill.body)"
        if !skill.checks.isEmpty {
            text += "\n\n完成前必须逐条确认：\n" + skill.checks.map { "· \($0)" }.joined(separator: "\n")
        }
        if !skill.fixtures.isEmpty {
            text += "\n\n可用夹具：\(skill.fixtures.joined(separator: "、"))"
        }
        return ContextItem(
            id: "skill-body-\(skill.name)",
            block: .memory,
            text: text,
            trust: skill.bodyTrust,
            relevance: 1.0,
            recency: 1.0
        )
    }

    // MARK: `search_skills`

    /// 在技能库里检索（L0 被截断时用）
    public func search(_ query: String, limit: Int = 8, workspaceID: UUID? = nil) -> [RuneSkill] {
        let pool = available(workspaceID: workspaceID)
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return pool
            .map { ($0, SkillSearch.relevance($0, query: query)) }
            .filter { $0.1 > 0 }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.name < b.0.name
            }
            .prefix(max(0, limit))
            .map(\.0)
    }

    // MARK: 增删改

    /// 注册/覆盖一个技能（导入用户文件时用）
    public mutating func upsert(_ skill: RuneSkill) {
        if let index = skills.firstIndex(where: { $0.name == skill.name }) {
            // 保留使用统计（重新导入不该把"最近用过"清零）
            var updated = skill
            updated.useCount = skills[index].useCount
            updated.lastUsedAt = skills[index].lastUsedAt
            skills[index] = updated
        } else {
            skills.append(skill)
        }
    }

    public mutating func setEnabled(_ name: String, _ enabled: Bool) {
        guard let index = skills.firstIndex(where: { $0.name == name }) else { return }
        skills[index].isEnabled = enabled
    }

    public mutating func remove(_ name: String) {
        skills.removeAll { $0.name == name }
    }

    private func nearestName(to name: String) -> String? {
        var best: (name: String, distance: Int)?
        for skill in skills {
            let distance = SkillSearch.editDistance(name.lowercased(), skill.name.lowercased())
            if distance < (best?.distance ?? Int.max) { best = (skill.name, distance) }
        }
        // 差太远就别猜（宁可不给建议，也不要给错建议）
        guard let best, best.distance <= max(4, name.count / 2) else { return nil }
        return best.name
    }
}

// MARK: - 已授予的能力（判断技能申请是否已覆盖）

public struct GrantedCapabilities: Sendable, Codable, Hashable {
    public var writePaths: [VFSPath]
    public var egressDomains: [String]
    public var runtimes: Set<SandboxRuntime>
    public var nativeAPIs: Set<String>

    public init(
        writePaths: [VFSPath] = [],
        egressDomains: [String] = [],
        runtimes: Set<SandboxRuntime> = [],
        nativeAPIs: Set<String> = []
    ) {
        self.writePaths = writePaths
        self.egressDomains = egressDomains
        self.runtimes = runtimes
        self.nativeAPIs = nativeAPIs
    }

    /// 从能力令牌推导（令牌是授权的唯一真相源）
    public static func from(token: CapabilityToken) -> GrantedCapabilities {
        var writePaths: [VFSPath] = []
        var runtimes: Set<SandboxRuntime> = []
        var domains: [String] = []
        for scope in token.scopes {
            switch scope {
            case .fsWrite(let path), .fsDelete(let path): writePaths.append(path)
            case .exec(let runtime): runtimes.insert(runtime)
            case .egress(let rule):
                if let host = rule.host { domains.append(host) }
                if let suffix = rule.hostSuffix { domains.append(suffix) }
            default: break
            }
        }
        return GrantedCapabilities(writePaths: writePaths, egressDomains: domains, runtimes: runtimes)
    }

    /// 哪些申请还没被覆盖
    public func missing(from request: SkillCapabilityRequest) -> SkillCapabilityRequest {
        // 申请可写的路径：必须被某个已授权的作用域**包含**（包含，不是相等 —— 授权更宽就是覆盖了）
        let missingPaths = request.writePaths.filter { raw in
            guard let needed = VFSPath.parseOrNil(raw) else { return true }
            return !writePaths.contains { needed.isWithin($0) }
        }
        let missingDomains = request.egressDomains.filter { domain in
            !egressDomains.contains { granted in
                granted == domain || domain.hasSuffix("." + granted)
            }
        }
        let missingRuntimes = request.runtimes.filter { !runtimes.contains($0) }
        let missingNative = request.nativeAPIs.filter { !nativeAPIs.contains($0) }
        return SkillCapabilityRequest(
            writePaths: missingPaths,
            egressDomains: missingDomains,
            runtimes: missingRuntimes,
            nativeAPIs: missingNative
        )
    }
}

// MARK: - 检索（词法打分）
//
// ⚠️ 这里刻意**只做词法匹配**，不做向量检索：
// 技能目录通常只有十几到几十条，词法匹配足够；而向量检索要端侧 embedding，
// 在 Windows 上根本不存在。真需要语义时由 `semantic_search` 那条路走（macOS 阶段）。
//
// 中文的处理要点：**按字符 bigram 匹配**，因为中文没有空格分词。

enum SkillSearch {

    /// 技能与查询的相关性（0..1）
    static func relevance(_ skill: RuneSkill, query: String) -> Double {
        let haystack = skill.searchText.lowercased()
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return 0 }

        // ① 子串命中（对中英文都有效）
        var score = 0.0
        if haystack.contains(needle) { score += 0.6 }
        if skill.name.lowercased().contains(needle) { score += 0.4 }

        // ② 逐词命中（英文场景）
        let terms = needle.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).map(String.init)
        if !terms.isEmpty {
            let hits = terms.filter { haystack.contains($0) }.count
            score += 0.5 * (Double(hits) / Double(terms.count))
        }

        // ③ 中文 bigram（中文没有空格，逐词匹配会全落空）
        let bigrams = self.bigrams(needle)
        if !bigrams.isEmpty {
            let hits = bigrams.filter { haystack.contains($0) }.count
            score += 0.5 * (Double(hits) / Double(bigrams.count))
        }

        return min(1.0, score)
    }

    /// 中文 bigram（只取含 CJK 的连续片段）
    static func bigrams(_ text: String) -> [String] {
        let chars = Array(text)
        guard chars.count >= 2 else { return [] }
        var result: [String] = []
        for i in 0..<(chars.count - 1) {
            let pair = String(chars[i...(i + 1)])
            if pair.unicodeScalars.contains(where: { TokenEstimator.isCJK($0) }) {
                result.append(pair)
            }
        }
        return result
    }

    /// 编辑距离（用于"技能名拼错"的兜底建议）
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}

// MARK: - 校验

public extension SkillRegistry {

    struct Issue: Sendable, Hashable, CustomStringConvertible {
        public enum Rule: String, Sendable, Hashable {
            case duplicateName
            case nameNotKebabCase
            case missingWhenToUse
            case emptyBody
            case descriptionTooLong
            case catalogEntryTooExpensive
            case requestsHumanOnly
            case builtinWithoutChecks
            case exampleWithoutTitle
        }
        public var skill: String
        public var rule: Rule
        public var detail: String
        public var description: String { "[\(rule.rawValue)] \(skill)：\(detail)" }
    }

    /// L0 单条的成本上限。
    ///
    /// ⚠️ **这里把设计文档里的"~15 token"改成了 40，理由是实测**：
    /// `docs/04 §7.2` 写的 15 token 是**按英文估的**（英文 1 token ≈ 4 字符）。
    /// 而中文是 **1 字符 ≈ 1 token**，同样的信息量在中文里要 30–40 token。
    /// 用 15 去卡，结果就是所有中文技能条目全部"超标" —— 那不是条目写坏了，是尺子错了。
    ///
    /// 换算之后的账：40 条 × ~35 token ≈ 1400 token。
    /// 在 200k 窗口里是 0.7%，在 32k 窗口里是 4.4%，都不成问题；
    /// **但在端侧模型那 4096 token 的窗口里是 34%** —— 所以端侧反射模式**不带技能目录**。
    /// 这就是为什么这个预算必须是一个显式的数字，而不是"越小越好"的口号。
    static let maxCatalogEntryTokens = 45

    /// 全量校验。测试里必须断言返回为空。
    func validate() -> [Issue] {
        var issues: [Issue] = []
        var seen = Set<String>()
        for skill in skills {
            if !seen.insert(skill.name).inserted {
                issues.append(Issue(skill: skill.name, rule: .duplicateName, detail: "技能名重复"))
            }
            // ⚠️ kebab-case：它会被 `#技能名` 引用，含大写/空格会让引用产生歧义
            if skill.name.isEmpty || skill.name != skill.name.lowercased()
                || skill.name.contains(" ") || skill.name.contains("_") {
                issues.append(Issue(skill: skill.name, rule: .nameNotKebabCase,
                                    detail: "技能名必须是 kebab-case（小写 + 连字符），才能被 `#名字` 无歧义引用"))
            }
            if skill.whenToUse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(Issue(skill: skill.name, rule: .missingWhenToUse,
                                    detail: "没有 when_to_use —— 模型只能靠名字猜，比没有技能更糟"))
            }
            if skill.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(Issue(skill: skill.name, rule: .emptyBody, detail: "正文为空"))
            }
            if skill.description.count > 60 {
                issues.append(Issue(skill: skill.name, rule: .descriptionTooLong,
                                    detail: "description 有 \(skill.description.count) 字，L0 目录是每一轮都要付的成本"))
            }
            if skill.catalogTokens > Self.maxCatalogEntryTokens {
                issues.append(Issue(skill: skill.name, rule: .catalogEntryTooExpensive,
                                    detail: "L0 条目 \(skill.catalogTokens) token，超过 \(Self.maxCatalogEntryTokens) —— 会挤掉别的技能"))
            }
            // ⚠️ 技能不能给自己提权：不许申请任何人类专属区的能力
            let forbidden = Set(HumanOnlyZone.allCases.map(\.rawValue))
            let requestedForbidden = skill.requestedCapabilities.nativeAPIs.filter { forbidden.contains($0) }
            if !requestedForbidden.isEmpty {
                issues.append(Issue(skill: skill.name, rule: .requestsHumanOnly,
                                    detail: "技能申请了人类专属区（\(requestedForbidden.joined(separator: "、"))）—— 技能永远不能为自己提权"))
            }
            // 内置技能必须有验证清单（它们是"开箱可用"的门面）
            if skill.source == .builtin, skill.checks.isEmpty {
                issues.append(Issue(skill: skill.name, rule: .builtinWithoutChecks,
                                    detail: "内置技能没有验证清单 —— 模型会在改完就宣布完成"))
            }
            for example in skill.examples where example.title.isEmpty {
                issues.append(Issue(skill: skill.name, rule: .exampleWithoutTitle,
                                    detail: "示例没有标题（模型需要标题来判断该看哪个）"))
            }
        }
        return issues
    }
}



