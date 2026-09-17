import Testing
import Foundation
@testable import RuneKernel

// MARK: - 技能的测试
//
// 这一组守的是渐进式披露的**唯一价值**：正文不能自动进上下文。
// 一旦"顺手把正文也带上"，机制就退化成"全塞" —— 而它退化之后不会有任何报错，
// 只是账单变贵、关键信息被淹没。

private func skill(
    _ name: String,
    description: String = "一句话说明",
    whenToUse: String = "需要时",
    body: String = "正文若干",
    source: RuneSkill.Source = .user,
    checks: [String] = ["检查一"],
    capabilities: SkillCapabilityRequest = .init(),
    useCount: Int = 0,
    lastUsedAt: Date? = nil,
    enabled: Bool = true,
    workspaceID: UUID? = nil
) -> RuneSkill {
    RuneSkill(
        name: name, description: description, whenToUse: whenToUse,
        source: source, body: body, checks: checks,
        requestedCapabilities: capabilities,
        useCount: useCount, lastUsedAt: lastUsedAt, isEnabled: enabled,
        workspaceID: workspaceID
    )
}

// MARK: - 内置库

@Suite("SkillLibrary —— 内置技能库")

struct SkillLibraryTests {

    @Test("⭐ 内置 12 个技能，且全部通过校验")
    func builtinIsValid() {
        #expect(SkillLibrary.builtin.count == 12)
        let registry = SkillRegistry(skills: SkillLibrary.builtin)
        let issues = registry.validate()
        for issue in issues { Issue.record("\(issue.description)") }
        #expect(issues.isEmpty)
    }

    @Test("⭐ 每个内置技能都有「何时用」与验证清单")
    func builtinsAreActionable() {
        for skill in SkillLibrary.builtin {
            #expect(!skill.whenToUse.isEmpty, "\(skill.name) 没有 when_to_use")
            #expect(!skill.checks.isEmpty, "\(skill.name) 没有验证清单 —— 模型会在改完就宣布完成")
            #expect(!skill.body.isEmpty)
            // 正文要够具体（太短等于没有指导）
            #expect(skill.body.count >= 200, "\(skill.name) 的正文太短（\(skill.body.count) 字）")
        }
    }

    @Test("⚠️ 中文 L0 条目要落在实测校准过的预算内（设计文档写的 15 token 是英文尺子）")
    func catalogEntriesFitBudget() {
        for skill in SkillLibrary.builtin {
            #expect(skill.catalogTokens <= SkillRegistry.maxCatalogEntryTokens,
                    "\(skill.name) 的 L0 条目 \(skill.catalogTokens) token，超过 \(SkillRegistry.maxCatalogEntryTokens)")
        }
        // 12 个技能的目录总成本必须远小于任何真实窗口
        let total = SkillLibrary.builtin.reduce(0) { $0 + $1.catalogTokens }
        #expect(total < 600, "12 个技能目录占了 \(total) token")
    }

    @Test("正文用词刻意不写死具体命令（不同项目的测试框架不一样）")
    func bodiesAvoidHardcodedCommands() {
        // 写死 `pytest -q` 会让非 Python 项目照抄错的命令
        let text = SkillLibrary.builtin.map(\.body).joined()
        #expect(!text.contains("pytest -q"))
        #expect(!text.contains("npm test --"))
    }
}

// MARK: - L0 目录

@Suite("L0 目录 —— 渐进式披露的第一层")

struct SkillCatalogTests {

    @Test("目录里只有名称/一句话/何时用，**绝不含正文**")
    func catalogNeverLeaksBodies() {
        let registry = SkillRegistry(skills: SkillLibrary.builtin)
        let catalog = registry.catalog()
        for skill in SkillLibrary.builtin {
            // 取正文里一个有辨识度但不属于 description/when_to_use 的片段
            let probe = String(skill.body.prefix(30))
            #expect(!catalog.text.contains(probe), "\(skill.name) 的正文漏进了目录")
        }
    }

    @Test("⚠️ 条目数上限 40：超了必须截断**并且**给出提示")
    func catalogCapsAtFortyEntries() {
        let many = (0..<60).map { skill("s\($0)") }
        let catalog = SkillRegistry(skills: many).catalog()
        #expect(catalog.entries.count == 40)
        #expect(catalog.omittedCount == 20)
        #expect(catalog.isTruncated)
        // 提示必须出现，否则模型不知道还有东西可查
        #expect(catalog.text.contains("search_skills"))
        #expect(catalog.hint?.contains("20") == true)
    }

    @Test("⚠️ token 预算也会截断（条目数没超但总成本超了）")
    func catalogRespectsTokenBudget() {
        // 每条都很贵 → 条目数远没到 40，预算就先满了
        let expensive = (0..<12).map { i in
            skill("s\(i)", description: String(repeating: "说明", count: 20),
                  whenToUse: String(repeating: "场景", count: 20))
        }
        let catalog = SkillRegistry(skills: expensive, catalogTokenBudget: 300).catalog()
        #expect(catalog.entries.count < 12)
        #expect(catalog.tokens <= 300)
        #expect(catalog.text.contains("search_skills"))
        #expect(catalog.reason.contains("预算"))
    }

    @Test("禁用与别的 workspace 的技能不进目录")
    func catalogFilters() {
        let mine = UUID()
        let other = UUID()
        let skills = [
            skill("enabled-one"),
            skill("disabled-one", enabled: false),
            skill("mine", workspaceID: mine),
            skill("theirs", workspaceID: other),
        ]
        let catalog = SkillRegistry(skills: skills).catalog(workspaceID: mine)
        let names = catalog.entries.map(\.name)
        #expect(names.contains("enabled-one"))
        #expect(names.contains("mine"))
        #expect(!names.contains("disabled-one"))
        #expect(!names.contains("theirs"))
    }

    @Test("⚠️ 排序：相关的排前面（模型按顺序读）")
    func catalogRanksRelevantFirst() {
        let skills = [
            skill("unrelated", description: "做饭", whenToUse: "饿了"),
            skill("sql-migration", description: "写数据库迁移", whenToUse: "改表结构"),
            skill("chart-report", description: "画图", whenToUse: "要图表"),
        ]
        let catalog = SkillRegistry(skills: skills).catalog(query: "数据库迁移 改表")
        #expect(catalog.entries.first?.name == "sql-migration")
    }

    @Test("最近用过的排前面（无查询时）")
    func recencyWinsWithoutQuery() {
        let now = Date()
        let skills = [
            skill("old", useCount: 0, lastUsedAt: now.addingTimeInterval(-30 * 86_400)),
            skill("just-used", useCount: 0, lastUsedAt: now.addingTimeInterval(-60)),
        ]
        let catalog = SkillRegistry(skills: skills).catalog(now: now)
        #expect(catalog.entries.first?.name == "just-used")
    }

    @Test("排序必须确定性（同一批素材两次装配字节一致 → 缓存才命中）")
    func catalogIsDeterministic() {
        let registry = SkillRegistry(skills: SkillLibrary.builtin)
        let a = registry.catalog()
        let b = registry.catalog()
        #expect(a.text == b.text)
        #expect(a.entries.map(\.name) == b.entries.map(\.name))
    }

    @Test("⭐ 目录区块落在可缓存的系统层 2，来源是项目指令")
    func catalogItemIsCacheable() {
        let registry = SkillRegistry(skills: SkillLibrary.builtin)
        let item = registry.catalogItem()
        #expect(item.block == .systemLayer2)
        #expect(item.trust == .projectInstruction)
        #expect(item.tokens > 0)
    }

    @Test("⭐ 目录能直接进上下文装配器")
    func catalogFlowsIntoAssembler() {
        let registry = SkillRegistry(skills: SkillLibrary.builtin)
        let objective = ContextItem(
            id: "obj", block: .systemLayer1, text: "目标：修好 CI",
            relevance: 1.0, recency: 1.0, pinnedRole: .objective
        )
        let assembly = ContextAssembler.assemble(
            items: [objective, registry.catalogItem(query: "CI 失败")],
            budget: ContextBudget(window: 20_000)
        )
        #expect(assembly.passed)
        #expect(assembly.blocks.contains { $0.id == "skill-catalog" })
    }
}

// MARK: - L1 加载

@Suite("L1 加载 —— use_skill")

struct SkillLoadTests {

    @Test("⭐ 加载正文并记一次使用")
    func loadRecordsUsage() {
        var registry = SkillRegistry(skills: [skill("a", body: "正文内容")])
        let now = Date()
        let result = registry.load("a", now: now)
        guard case .loaded(let loaded) = result else {
            Issue.record("应当加载成功，实际 \(result)")
            return
        }
        #expect(loaded.body == "正文内容")
        #expect(registry.skill(named: "a")?.useCount == 1)
        #expect(registry.skill(named: "a")?.lastUsedAt == now)
    }

    @Test("技能名拼错 → 给出最接近的名字（宁可不给，也不要给错）")
    func misspelledNameSuggests() {
        var registry = SkillRegistry(skills: [skill("flaky-test-triage"), skill("ci-triage")])
        let result = registry.load("flaky-test-triag", now: Date())
        guard case .notFound(_, let suggestion) = result else {
            Issue.record("应当 notFound，实际 \(result)")
            return
        }
        #expect(suggestion == "flaky-test-triage")
    }

    @Test("差太远就不猜")
    func farMisspellingGivesNoSuggestion() {
        var registry = SkillRegistry(skills: [skill("flaky-test-triage")])
        let result = registry.load("zzzzzzzzzzzz", now: Date())
        guard case .notFound(_, let suggestion) = result else {
            Issue.record("应当 notFound")
            return
        }
        #expect(suggestion == nil)
    }

    @Test("禁用的技能不给加载")
    func disabledSkillRejected() {
        var registry = SkillRegistry(skills: [skill("a", enabled: false)])
        let result = registry.load("a", now: Date())
        guard case .disabled(let name) = result else {
            Issue.record("应当 disabled，实际 \(result)")
            return
        }
        #expect(name == "a")
    }

    @Test("⚠️ 技能申请的权限没到位 → **必须先走审批**，不能先加载了再说")
    func capabilityGateBlocksLoad() {
        // 正文本身就会引导模型去用那些权限 —— 「先加载、遇到越权再拒」等于已经让它进了一次上下文
        let needsEgress = skill(
            "web-scrape",
            body: "去抓某个网站……",
            capabilities: SkillCapabilityRequest(egressDomains: ["api.example.com"])
        )
        var registry = SkillRegistry(skills: [needsEgress])

        let granted = GrantedCapabilities()   // 什么都没授
        let result = registry.load("web-scrape", now: Date(), granted: granted)
        guard case .needsApproval(_, let request, let reason) = result else {
            Issue.record("应当 needsApproval，实际 \(result)")
            return
        }
        #expect(request.egressDomains == ["api.example.com"])
        #expect(reason.contains("权限"))
        // 被拦下时不记使用次数
        #expect(registry.skill(named: "web-scrape")?.useCount == 0)
    }

    @Test("权限已覆盖 → 正常加载")
    func grantedCoverageAllowsLoad() {
        let needsWrite = skill(
            "fmt",
            capabilities: SkillCapabilityRequest(writePaths: ["/workspace/src"])
        )
        var registry = SkillRegistry(skills: [needsWrite])
        let granted = GrantedCapabilities(
            writePaths: [VFSPath(mount: .workspace, components: ["src"])],
            runtimes: [.python]
        )
        guard case .loaded = registry.load("fmt", now: Date(), granted: granted) else {
            Issue.record("权限已覆盖，应当放行")
            return
        }
    }

    @Test("不传 granted 时不做权限判定（只读预览用）")
    func nilGrantSkipsCapabilityCheck() {
        let needsWrite = skill("fmt", capabilities: SkillCapabilityRequest(writePaths: ["/workspace/src"]))
        var registry = SkillRegistry(skills: [needsWrite])
        guard case .loaded = registry.load("fmt", now: Date(), granted: nil) else {
            Issue.record("不传 granted 时应当放行")
            return
        }
    }

    @Test("⭐ 正文区块必须带上验证清单（否则模型改完就宣布完成）")
    func bodyBlockIncludesChecks() {
        let registry = SkillRegistry(skills: [
            skill("a", body: "步骤一\n步骤二", checks: ["跑通测试", "说明影响面"])
        ])
        let block = registry.bodyBlock(of: "a")
        #expect(block?.text.contains("步骤一") == true)
        #expect(block?.text.contains("跑通测试") == true)
        #expect(block?.text.contains("说明影响面") == true)
        #expect(block?.trust == .projectInstruction)
    }

    @Test("L2 示例按需给，且限量")
    func examplesOnDemand() {
        let withExamples = RuneSkill(
            name: "a", description: "d", whenToUse: "w", source: .user,
            body: "b",
            examples: [
                SkillExample(title: "一", content: "1"),
                SkillExample(title: "二", content: "2"),
                SkillExample(title: "三", content: "3"),
                SkillExample(title: "四", content: "4"),
            ]
        )
        let registry = SkillRegistry(skills: [withExamples])
        #expect(registry.examples(of: "a", limit: 2).count == 2)
        // 目录里不能出现示例
        #expect(!registry.catalog().text.contains("一"))
    }

    @Test("读取不存在的技能的示例返回空，不崩")
    func examplesOfMissingSkill() {
        #expect(SkillRegistry(skills: [skill("a")]).examples(of: "nope").isEmpty)
    }

    @Test("upsert 保留使用统计（重新导入不该把「最近用过」清零）")
    func upsertKeepsUsage() {
        var registry = SkillRegistry(skills: [skill("a", body: "旧")])
        _ = registry.load("a", now: Date())
        registry.upsert(skill("a", body: "新"))
        #expect(registry.skill(named: "a")?.body == "新")
        #expect(registry.skill(named: "a")?.useCount == 1)
    }
}

// MARK: - 搜索

@Suite("search_skills —— 中文要能搜到")

struct SkillSearchTests {

    private var registry: SkillRegistry {
        SkillRegistry(skills: [
            skill("sql-migration", description: "写数据库迁移", whenToUse: "改表结构或数据回填"),
            skill("chart-report", description: "由数据出图", whenToUse: "要把数据变成图"),
            skill("flaky-test-triage", description: "不稳定测试排查", whenToUse: "测试时好时坏"),
        ])
    }

    @Test("⭐ 中文查询能命中（中文没有空格，必须用 bigram）")
    func chineseQueryWorks() {
        let hits = registry.search("数据库迁移")
        #expect(hits.first?.name == "sql-migration")
        #expect(registry.search("数据回填").first?.name == "sql-migration")
    }

    @Test("英文查询能命中技能名")
    func englishQueryWorks() {
        #expect(registry.search("flaky").first?.name == "flaky-test-triage")
    }

    @Test("无关查询返回空（宁可不给，也不要给一堆不相干的）")
    func irrelevantQueryReturnsNothing() {
        #expect(registry.search("做红烧肉").isEmpty)
    }

    @Test("空查询返回空（不要把整库倒出来）")
    func emptyQueryReturnsNothing() {
        #expect(registry.search("   ").isEmpty)
    }

    @Test("限量生效，且排序确定性")
    func limitAndDeterminism() {
        let a = registry.search("数据", limit: 1)
        let b = registry.search("数据", limit: 1)
        #expect(a.count == 1)
        #expect(a.map(\.name) == b.map(\.name))
    }

    @Test("bigram 只取含 CJK 的片段")
    func bigramExtraction() {
        #expect(SkillSearch.bigrams("abc").isEmpty)
        #expect(SkillSearch.bigrams("中文").count == 1)
        #expect(SkillSearch.bigrams("数据库迁移").count == 4)   // 5 个字符 → 4 个 bigram
        // 单字没有 bigram
        #expect(SkillSearch.bigrams("中").isEmpty)
    }
}

// MARK: - frontmatter

@Suite("SkillFrontmatter —— 解析必须给人话错误")

struct FrontmatterTests {

    @Test("正常解析")
    func happyPath() {
        let text = """
        ---
        name: flaky-test-triage
        description: 不稳定测试排查
        when_to_use: 测试时好时坏
        ---

        正文第一行
        正文第二行
        """
        guard case .success(let (meta, body)) = SkillFrontmatter.parse(text) else {
            Issue.record("应当解析成功")
            return
        }
        #expect(meta.name == "flaky-test-triage")
        #expect(meta.whenToUse == "测试时好时坏")
        #expect(body.contains("正文第一行"))
        #expect(!body.contains("name:"))
    }

    @Test("⚠️ 缺 when_to_use → 明确报缺哪个键（不是笼统的解析失败）")
    func missingWhenToUse() {
        let text = """
        ---
        name: a
        description: d
        ---
        body
        """
        guard case .failure(let failure) = SkillFrontmatter.parse(text) else {
            Issue.record("应当失败")
            return
        }
        #expect(failure == .missingKey("when_to_use"))
        #expect(failure.description.contains("when_to_use"))
    }

    @Test("空值也算缺失（空值等于没写）")
    func emptyValueTreatedAsMissing() {
        let text = """
        ---
        name: a
        description:
        when_to_use: w
        ---
        """
        guard case .failure(let failure) = SkillFrontmatter.parse(text) else {
            Issue.record("应当失败")
            return
        }
        #expect(failure == .emptyValue("description"))
    }

    @Test("没有 frontmatter → 告诉用户正确写法")
    func noFrontmatter() {
        guard case .failure(let failure) = SkillFrontmatter.parse("直接就是正文") else {
            Issue.record("应当失败")
            return
        }
        #expect(failure == .missingFrontmatter)
        #expect(failure.description.contains("---"))
    }

    @Test("没收尾的 `---` → 说清是没收尾")
    func unterminated() {
        guard case .failure(let failure) = SkillFrontmatter.parse("---\nname: a\ndescription: d") else {
            Issue.record("应当失败")
            return
        }
        #expect(failure == .unterminatedFrontmatter)
    }

    @Test("⚠️ CRLF 文件也必须能解析（`\\r\\n` 在 Swift 里是单个字素簇）")
    func crlfParses() {
        let text = "---\r\nname: a\r\ndescription: d\r\nwhen_to_use: w\r\n---\r\n\r\n正文\r\n"
        guard case .success(let (meta, body)) = SkillFrontmatter.parse(text) else {
            Issue.record("CRLF 文件应当能解析")
            return
        }
        #expect(meta.name == "a")
        #expect(body.contains("正文"))
        // 正文里不该残留 `\r`（它会让后续所有按行匹配失效）
        #expect(!body.contains("\r"))
    }

    @Test("去掉两侧引号（用户会写 name: \"x\"）")
    func stripsQuotes() {
        let text = """
        ---
        name: "quoted"
        description: '单引号'
        when_to_use: w
        ---
        """
        guard case .success(let (meta, _)) = SkillFrontmatter.parse(text) else {
            Issue.record("应当成功")
            return
        }
        #expect(meta.name == "quoted")
        #expect(meta.description == "单引号")
    }

    @Test("未知键进 extra，注释与空行跳过")
    func extrasAndComments() {
        let text = """
        ---
        # 这是注释
        name: a
        description: d
        when_to_use: w
        author: 某人

        ---
        """
        guard case .success(let (meta, _)) = SkillFrontmatter.parse(text) else {
            Issue.record("应当成功")
            return
        }
        #expect(meta.extra["author"] == "某人")
        #expect(meta.extra["name"] == nil)
    }

    @Test("渲染与解析可往返")
    func roundTrip() {
        let original = SkillFrontmatter(name: "a", description: "d", whenToUse: "w", extra: ["author": "某人"])
        let text = original.rendered(body: "正文")
        guard case .success(let (parsed, body)) = SkillFrontmatter.parse(text) else {
            Issue.record("往返应当成功")
            return
        }
        #expect(parsed == original)
        #expect(body.contains("正文"))
    }
}

// MARK: - 校验

@Suite("SkillRegistry.validate —— 每条规则都真的会报")

struct SkillValidationTests {

    private func rules(_ skills: [RuneSkill]) -> Set<SkillRegistry.Issue.Rule> {
        Set(SkillRegistry(skills: skills).validate().map(\.rule))
    }

    @Test("重名会被抓到")
    func duplicate() {
        #expect(rules([skill("a"), skill("a")]).contains(.duplicateName))
    }

    @Test("⚠️ 非 kebab-case 会被抓到（`#技能名` 引用会产生歧义）")
    func kebabCase() {
        #expect(rules([skill("Flaky Test")]).contains(.nameNotKebabCase))
        #expect(rules([skill("flaky_test")]).contains(.nameNotKebabCase))
        #expect(!rules([skill("flaky-test")]).contains(.nameNotKebabCase))
    }

    @Test("⚠️ 缺 when_to_use 会被抓到")
    func missingWhenToUse() {
        #expect(rules([skill("a", whenToUse: "  ")]).contains(.missingWhenToUse))
    }

    @Test("空正文会被抓到")
    func emptyBody() {
        #expect(rules([skill("a", body: "")]).contains(.emptyBody))
    }

    @Test("description 过长、L0 条目过贵都会被抓到")
    func catalogCostRules() {
        #expect(rules([skill("a", description: String(repeating: "很长的说明", count: 20))])
            .contains(.descriptionTooLong))
        let expensive = skill("a", description: String(repeating: "说明", count: 30))
        #expect(rules([expensive]).contains(.catalogEntryTooExpensive))
    }

    @Test("⚠️ 技能申请人类专属区会被抓到（技能不能给自己提权）")
    func humanOnlyRequest() {
        let sneaky = skill("a", capabilities: SkillCapabilityRequest(nativeAPIs: ["credentials"]))
        #expect(rules([sneaky]).contains(.requestsHumanOnly))
    }

    @Test("内置技能没有验证清单会被抓到")
    func builtinNeedsChecks() {
        #expect(rules([skill("a", source: .builtin, checks: [])]).contains(.builtinWithoutChecks))
        // 用户自建的技能不强制
        #expect(!rules([skill("a", source: .user, checks: [])]).contains(.builtinWithoutChecks))
    }

    @Test("示例没有标题会被抓到")
    func exampleNeedsTitle() {
        let withBadExample = RuneSkill(
            name: "a", description: "d", whenToUse: "w", source: .user, body: "b",
            examples: [SkillExample(title: "", content: "x")]
        )
        #expect(rules([withBadExample]).contains(.exampleWithoutTitle))
    }

    @Test("一个完全合规的技能不报任何问题")
    func cleanSkillPasses() {
        let issues = SkillRegistry(skills: [skill("clean-one")]).validate()
        for issue in issues { Issue.record("\(issue.description)") }
        #expect(issues.isEmpty)
    }
}

// MARK: - 授权覆盖判定

@Suite("GrantedCapabilities —— 申请是否已被覆盖")

struct GrantedCapabilitiesTests {

    @Test("⭐ 更宽的作用域包含更窄的申请")
    func broaderScopeCoversNarrower() {
        let granted = GrantedCapabilities(
            writePaths: [VFSPath(mount: .workspace, components: ["src"])]
        )
        // 申请 src/utils → 被 src 覆盖
        let covered = granted.missing(from: SkillCapabilityRequest(writePaths: ["/workspace/src/utils"]))
        #expect(covered.writePaths.isEmpty)
        // 申请 lib → 不被覆盖
        let notCovered = granted.missing(from: SkillCapabilityRequest(writePaths: ["/workspace/lib"]))
        #expect(notCovered.writePaths == ["/workspace/lib"])
    }

    @Test("⚠️ 解析不了的路径一律视为未覆盖（不猜）")
    func unparsablePathIsNotCovered() {
        let granted = GrantedCapabilities(writePaths: [VFSPath(mount: .workspace)])
        // 相对路径写法 → 解析失败 → 视为未覆盖（技能文件里应当写绝对路径）
        let missing = granted.missing(from: SkillCapabilityRequest(writePaths: ["src/a.py"]))
        #expect(missing.writePaths == ["src/a.py"])
    }

    @Test("域名后缀覆盖：授了 example.com，api.example.com 算覆盖")
    func domainSuffixCoverage() {
        let granted = GrantedCapabilities(egressDomains: ["example.com"])
        #expect(granted.missing(from: SkillCapabilityRequest(egressDomains: ["api.example.com"])).egressDomains.isEmpty)
        // 但 evil-example.com 不算
        #expect(!granted.missing(from: SkillCapabilityRequest(egressDomains: ["evil-example.com"])).egressDomains.isEmpty)
    }

    @Test("运行时与原生能力按集合判定")
    func runtimesAndNative() {
        let granted = GrantedCapabilities(runtimes: [.python], nativeAPIs: ["camera"])
        let missing = granted.missing(from: SkillCapabilityRequest(runtimes: [.python, .shell], nativeAPIs: ["camera", "photos"]))
        #expect(missing.runtimes == [.shell])
        #expect(missing.nativeAPIs == ["photos"])
    }

    @Test("⭐ 从能力令牌推导（令牌是授权的唯一真相源）")
    func derivesFromToken() {
        let token = CapabilityToken(
            issuedForTurn: UUID(),
            scopes: [
                .fsWrite(VFSPath(mount: .workspace, components: ["src"])),
                .exec(runtime: .python),
                .egress(EgressRule(host: "api.example.com", reason: "测试")),
            ],
            expiresAt: Date().addingTimeInterval(3600),
            grantedBy: .planApproval,
            reason: "测试"
        )
        let granted = GrantedCapabilities.from(token: token)
        #expect(granted.writePaths.count == 1)
        #expect(granted.runtimes.contains(.python))
        #expect(granted.egressDomains.contains("api.example.com"))
    }

    @Test("申请为空时永远算覆盖（大部分技能不申请任何权限）")
    func emptyRequestAlwaysCovered() {
        let granted = GrantedCapabilities()
        let missing = granted.missing(from: SkillCapabilityRequest())
        #expect(missing.isEmpty)
    }
}

// MARK: - 申请摘要（审批卡片要用）

@Suite("SkillCapabilityRequest —— 用户要看得懂才能做决定")

struct CapabilityRequestSummaryTests {

    @Test("摘要按类别分行，中文可读")
    func summaryIsReadable() {
        let request = SkillCapabilityRequest(
            writePaths: ["/workspace/src"],
            egressDomains: ["api.github.com"],
            runtimes: [.python],
            nativeAPIs: ["camera"]
        )
        let lines = request.summaryLines
        #expect(lines.count == 4)
        #expect(lines.contains { $0.hasPrefix("写入：") })
        #expect(lines.contains { $0.hasPrefix("联网：") })
        #expect(lines.contains { $0.contains("Python") })
        #expect(lines.contains { $0.hasPrefix("系统能力：") })
    }

    @Test("没有申请的类别不显示空行（不要用噪音淹没信息）")
    func emptyCategoriesOmitted() {
        #expect(SkillCapabilityRequest(egressDomains: ["a.com"]).summaryLines.count == 1)
        #expect(SkillCapabilityRequest().summaryLines.isEmpty)
        #expect(SkillCapabilityRequest().isEmpty)
    }
}


