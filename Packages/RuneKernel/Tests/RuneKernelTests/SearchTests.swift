import Testing
import Foundation
@testable import RuneKernel

// MARK: - Glob 匹配

@Suite("GlobPattern —— 通配匹配")
struct GlobMatcherTests {

    private func path(_ s: String) throws -> VFSPath { try VFSPath.parse(s) }

    @Test("字面量精确匹配")
    func literal() throws {
        let p = GlobPattern("src/main.swift")
        #expect(p.matches(try path("/workspace/src/main.swift")))
        #expect(!p.matches(try path("/workspace/src/other.swift")))
        #expect(!p.matches(try path("/workspace/x/src/main.swift")))   // 含 `/` → 锚定
    }

    @Test("⚠️ 未锚定的 `*.swift` 应命中任意深度（模型最常用这一种）")
    func unanchoredMatchesAnyDepth() throws {
        let p = GlobPattern("*.swift")
        #expect(!p.isAnchored)
        #expect(p.matches(try path("/workspace/a.swift")))
        #expect(p.matches(try path("/workspace/src/a.swift")))
        #expect(p.matches(try path("/workspace/deep/nested/dir/a.swift")))
        #expect(!p.matches(try path("/workspace/a.txt")))
        #expect(!p.matches(try path("/workspace/a.swift.bak")))
    }

    @Test("`**` 跨任意层目录")
    func doubleStar() throws {
        #expect(GlobPattern("src/**/*.ts").matches(try path("/workspace/src/a.ts")))
        #expect(GlobPattern("src/**/*.ts").matches(try path("/workspace/src/x/y/a.ts")))
        #expect(!GlobPattern("src/**/*.ts").matches(try path("/workspace/other/a.ts")))

        #expect(GlobPattern("**/*.md").matches(try path("/workspace/a.md")))
        #expect(GlobPattern("**/*.md").matches(try path("/workspace/x/y/a.md")))

        // 尾部 `**` 吃掉剩余全部
        #expect(GlobPattern("src/**").matches(try path("/workspace/src/a/b/c.swift")))
        #expect(!GlobPattern("src/**").matches(try path("/workspace/other/a.swift")))
    }

    @Test("`?` 单字符")
    func questionMark() throws {
        let p = GlobPattern("file?.txt")
        #expect(p.matches(try path("/workspace/file1.txt")))
        #expect(!p.matches(try path("/workspace/file12.txt")))
        #expect(!p.matches(try path("/workspace/file.txt")))
    }

    @Test("字符类 `[abc]` / `[!abc]` / `[a-z]`")
    func charClasses() throws {
        #expect(GlobPattern("v[12].txt").matches(try path("/workspace/v1.txt")))
        #expect(GlobPattern("v[12].txt").matches(try path("/workspace/v2.txt")))
        #expect(!GlobPattern("v[12].txt").matches(try path("/workspace/v3.txt")))

        #expect(GlobPattern("v[!12].txt").matches(try path("/workspace/v3.txt")))
        #expect(!GlobPattern("v[!12].txt").matches(try path("/workspace/v1.txt")))

        #expect(GlobPattern("file[0-9].log").matches(try path("/workspace/file7.log")))
        #expect(!GlobPattern("file[0-9].log").matches(try path("/workspace/fileX.log")))
    }

    @Test("花括号择一 `{a,b}`（含多层展开）")
    func braces() throws {
        let p = GlobPattern("*.{swift,kt}")
        #expect(p.matches(try path("/workspace/a.swift")))
        #expect(p.matches(try path("/workspace/b.kt")))
        #expect(!p.matches(try path("/workspace/c.py")))

        #expect(GlobPattern("src/{a,b}/x.swift").matches(try path("/workspace/src/a/x.swift")))
        #expect(GlobPattern("src/{a,b}/x.swift").matches(try path("/workspace/src/b/x.swift")))
        #expect(!GlobPattern("src/{a,b}/x.swift").matches(try path("/workspace/src/c/x.swift")))
    }

    @Test("目录专用模式（结尾 `/`）")
    func directoryOnly() throws {
        let p = GlobPattern("node_modules/")
        #expect(p.directoryOnly)
        #expect(p.matches(components: ["node_modules"], isDirectory: true))
        #expect(!p.matches(components: ["node_modules"], isDirectory: false))
        // 其下内容由 IgnoreRules 的祖先逻辑处理，这里只测模式本身
    }

    @Test("前导 `/` 锚定到根")
    func leadingSlashAnchors() throws {
        let p = GlobPattern("/README.md")
        #expect(p.isAnchored)
        #expect(p.matches(try path("/workspace/README.md")))
        #expect(!p.matches(try path("/workspace/docs/README.md")))
    }

    @Test("⚠️ 默认大小写不敏感（避免 '在 Mac 上能跑、在 iOS 上跑不了'）")
    func caseInsensitiveByDefault() throws {
        #expect(GlobPattern("*.swift").matches(try path("/workspace/A.SWIFT")))
        #expect(GlobPattern("Readme.md").matches(try path("/workspace/readme.md")))
        // 显式要求区分大小写时
        #expect(!GlobPattern("*.swift", caseSensitive: true).matches(try path("/workspace/A.SWIFT")))
        #expect(GlobPattern("*.swift", caseSensitive: true).matches(try path("/workspace/a.swift")))
    }

    @Test("`*` 不跨目录分隔符（这是 glob 与正则的关键区别）")
    func starDoesNotCrossDirectories() throws {
        let p = GlobPattern("src/*.swift")
        #expect(p.matches(try path("/workspace/src/a.swift")))
        #expect(!p.matches(try path("/workspace/src/sub/a.swift")))
    }

    @Test("`**` 单独使用匹配一切")
    func doubleStarAlone() throws {
        let p = GlobPattern("**")
        #expect(p.matches(try path("/workspace/a")))
        #expect(p.matches(try path("/workspace/a/b/c")))
    }

    @Test("非法/空模式")
    func invalidPatterns() {
        #expect(!GlobPattern("").isValid)
        #expect(!GlobPattern("/").isValid)
        #expect(GlobPattern("*.swift").isValid)
    }

    @Test("parseAll 丢弃非法模式")
    func parseAllDropsInvalid() {
        let patterns = GlobPattern.parseAll(["*.swift", "", "src/**/*.ts"])
        #expect(patterns.count == 2)
    }

    @Test("`[` 未闭合时退化为字面量而不是崩溃")
    func unclosedClassIsLiteral() throws {
        let p = GlobPattern("file[abc")
        // 不崩即可；行为上当作字面量 `file[abc`
        _ = p.matches(try path("/workspace/file[abc"))
        #expect(true)
    }
}

// MARK: - 忽略规则

@Suite("IgnoreRules —— gitignore 语义")
struct IgnoreRulesTests {

    @Test("空行与注释被跳过")
    func commentsSkipped() {
        let rules = IgnoreRules.parse("""
        # 这是注释

        node_modules/
        """)
        #expect(rules.rules.count == 1)
        #expect(rules.rules[0].raw == "node_modules/")
    }

    @Test("⚠️ 目录被忽略 → 其下所有内容都被忽略（手机上最关键的一条）")
    func directoryIgnoreCascades() {
        let rules = IgnoreRules.parse("node_modules/")
        #expect(rules.isIgnored(VFSPath(mount: .workspace, components: ["node_modules"]), isDirectory: true))
        #expect(rules.isIgnored(VFSPath(mount: .workspace, components: ["node_modules", "react", "index.js"])))
        #expect(!rules.isIgnored(VFSPath(mount: .workspace, components: ["src", "index.js"])))
    }

    @Test("`!` 取反重新纳入")
    func negation() {
        let rules = IgnoreRules.parse("""
        *.log
        !important.log
        """)
        #expect(rules.isIgnored(VFSPath(mount: .workspace, components: ["debug.log"])))
        #expect(!rules.isIgnored(VFSPath(mount: .workspace, components: ["important.log"])))
    }

    @Test("⚠️ 最后一条匹配的规则生效")
    func lastMatchWins() {
        let rules = IgnoreRules.parse("""
        !keep.log
        *.log
        """)
        // 后面的 `*.log` 覆盖前面的取反
        #expect(rules.isIgnored(VFSPath(mount: .workspace, components: ["keep.log"])))
    }

    @Test("前导 `/` 锚定根目录")
    func anchoredPattern() {
        let rules = IgnoreRules.parse("/root.txt")
        #expect(rules.isIgnored(VFSPath(mount: .workspace, components: ["root.txt"])))
        #expect(!rules.isIgnored(VFSPath(mount: .workspace, components: ["sub", "root.txt"])))
    }

    @Test("不含 `/` 的模式匹配任意深度")
    func unanchoredMatchesAnyDepth() {
        let rules = IgnoreRules.parse("*.pyc")
        #expect(rules.isIgnored(VFSPath(mount: .workspace, components: ["a.pyc"])))
        #expect(rules.isIgnored(VFSPath(mount: .workspace, components: ["x", "y", "a.pyc"])))
    }

    @Test("决定里带得出是哪条规则（用户问「为什么没搜到」时要能答）")
    func decisionCarriesProvenance() {
        let rules = IgnoreRules.parse("# 注释\nnode_modules/", source: "工作区 .gitignore")
        let decision = rules.decide(components: ["node_modules", "x.js"], isDirectory: false)
        #expect(decision.isIgnored)
        #expect(decision.matchedRule == "node_modules/")
        #expect(decision.source?.contains(".gitignore") == true)
    }

    @Test("内置默认规则覆盖手机上必须跳过的那些目录与文件类型")
    func runeDefaults() {
        let rules = IgnoreRules.runeDefaults
        func ignored(_ p: String) -> Bool { rules.isIgnored(VFSPath(mount: .workspace, components: p.split(separator: "/").map(String.init))) }

        #expect(ignored(".git/config"))
        #expect(ignored("node_modules/react/index.js"))
        #expect(ignored("build/output.bin"))
        #expect(ignored("DerivedData/x/y"))
        #expect(ignored("__pycache__/a.pyc"))
        #expect(ignored("logo.png"))
        #expect(ignored("assets/icon.svg") == false)     // svg 是文本，应该能搜
        #expect(ignored("model.gguf"))
        #expect(ignored("weights.safetensors"))

        #expect(!ignored("src/main.swift"))
        #expect(!ignored("README.md"))
        #expect(!ignored("tests/test_api.py"))
    }

    @Test("两层规则可以追加合并")
    func appending() {
        let project = IgnoreRules.parse("*.tmp")
        let combined = project.appending(.runeDefaults)
        #expect(combined.isIgnored(VFSPath(mount: .workspace, components: ["a.tmp"])))
        #expect(combined.isIgnored(VFSPath(mount: .workspace, components: [".git", "HEAD"])))
    }

    @Test("反斜杠转义的 `#` 与 `!` 当字面量")
    func escapedHashAndBang() {
        let rules = IgnoreRules.parse("\\#file.txt")
        #expect(rules.rules.count == 1)
        #expect(rules.isIgnored(VFSPath(mount: .workspace, components: ["#file.txt"])))
    }
}

// MARK: - 路径过滤器

@Suite("PathFilter —— 两层忽略 + include/exclude")
struct PathFilterTests {

    private func ws(_ s: String) -> VFSPath { VFSPath(mount: .workspace, components: s.split(separator: "/").map(String.init)) }

    @Test("项目忽略规则一律生效")
    func projectIgnoreAlwaysWins() {
        let filter = PathFilter(
            projectIgnore: IgnoreRules.parse("secret/"),
            includeGlobs: ["secret/**"],
            excludeGlobs: []
        )
        // 即使 include 明确要求，项目规则仍然拒绝
        // （这是有意的：项目规则是用户自己写的，必须被尊重）
        let verdict = filter.evaluate(ws("secret/key.txt"))
        #expect(!verdict.accepted)
        #expect(verdict.reason?.contains("项目忽略规则") == true)
    }

    @Test("⚠️ 显式 include 让内置默认忽略让位")
    func explicitIncludeOverridesDefaults() {
        // 默认规则里有 *.png，但用户说"我要搜 *.png"就该搜
        let withInclude = PathFilter(includeGlobs: ["*.png"], excludeGlobs: [])
        #expect(withInclude.accepts(ws("screenshots/a.png")))

        let withoutInclude = PathFilter(includeGlobs: [], excludeGlobs: [])
        #expect(!withoutInclude.accepts(ws("screenshots/a.png")))
    }

    @Test("exclude 优先于 include")
    func excludeBeatsInclude() {
        let filter = PathFilter(includeGlobs: ["**/*.swift"], excludeGlobs: ["Tests/**"])
        #expect(filter.accepts(ws("Sources/a.swift")))
        #expect(!filter.accepts(ws("Tests/a.swift")))
    }

    @Test("include 非空时必须命中其中之一")
    func includeIsAllowlist() {
        let filter = PathFilter(includeGlobs: ["*.md"], excludeGlobs: [])
        #expect(filter.accepts(ws("README.md")))
        #expect(!filter.accepts(ws("main.swift")))
    }

    @Test("include 为空 = 全部接受（除忽略与 exclude）")
    func emptyIncludeMeansAll() {
        let filter = PathFilter(includeGlobs: [], excludeGlobs: [])
        #expect(filter.accepts(ws("src/a.swift")))
        #expect(filter.accepts(ws("docs/readme.md")))
        #expect(!filter.accepts(ws("node_modules/x.js")))
    }

    @Test("可关闭内置默认忽略（用于审计/调试场景）")
    func canDisableDefaults() {
        let filter = PathFilter(
            defaultIgnore: IgnoreRules(rules: [], source: "已关闭"),
            includeGlobs: [], excludeGlobs: []
        )
        #expect(filter.accepts(ws("node_modules/x.js")))
    }
}

// MARK: - grep 引擎

@Suite("GrepEngine —— 搜索核心")
struct GrepEngineTests {

    private func candidate(_ p: String, size: Int = 100) -> GrepCandidate {
        GrepCandidate(path: VFSPath(mount: .workspace, components: p.split(separator: "/").map(String.init)), byteSize: size)
    }

    private let sample: [String: String] = [
        "src/money.py": """
        def round_amount(amount):
            amount = Decimal(amount)
            return round(amount)   # TODO: 处理币种精度
        """,
        "src/orders.py": """
        def refund(order):
            return round(order.total)
        """,
        "docs/readme.md": "# 说明\n退款金额要四舍五入\n",
        "node_modules/pkg/index.js": "TODO: 不该被搜到\n",
    ]

    @Test("字面量搜索：行号与列号正确")
    func literalSearchLineAndColumn() throws {
        // 注意：用 "round(" 而不是 "round" —— 后者也会命中第 1 行的 `round_amount`，
        // 这个测试要的是"定位精度"，所以用更独特的模式（另一条测试专门覆盖宽匹配）。
        let query = GrepQuery(pattern: "round(")
        let result = try GrepEngine.search(
            query: query,
            candidates: [candidate("src/money.py"), candidate("src/orders.py")],
            source: .inMemory(sample)
        )
        #expect(result.matches.count == 2)
        #expect(result.matches[0].path.description == "/workspace/src/money.py")
        #expect(result.matches[0].line == 3)
        #expect(result.matches[0].column == 12)     // "    return round(" → r 在第 12 位
        #expect(result.matches[1].path.description == "/workspace/src/orders.py")
        #expect(result.matches[1].line == 2)
        #expect(result.matches[1].column == 12)
    }

    @Test("宽匹配会命中所有子串（含 `round_amount` 这类标识符）")
    func broadMatchHitsSubstrings() throws {
        let result = try GrepEngine.search(
            query: GrepQuery(pattern: "round"),
            candidates: [candidate("src/money.py"), candidate("src/orders.py")],
            source: .inMemory(sample)
        )
        // money.py: 第 1 行 `round_amount` + 第 3 行 `round(`；orders.py: 第 2 行 `round(`
        #expect(result.matches.count == 3)
        #expect(result.matches[0].line == 1)
        #expect(result.matches[0].column == 5)      // "def round_amount" → 第 5 位
    }

    @Test("⚠️ 默认忽略规则生效（node_modules 不会被扫）")
    func defaultIgnoresApplied() throws {
        let query = GrepQuery(pattern: "TODO")
        let result = try GrepEngine.search(
            query: query,
            candidates: [candidate("src/money.py"), candidate("node_modules/pkg/index.js")],
            source: .inMemory(sample)
        )
        #expect(result.matches.count == 1)
        #expect(result.matches[0].path.description == "/workspace/src/money.py")
        #expect(result.filesSkipped == 1)
        #expect(result.skipReasons.keys.contains { $0.contains("内置默认规则") })
    }

    @Test("大小写：默认不敏感，可显式敏感")
    func caseSensitivity() throws {
        let insens = try GrepEngine.search(
            query: GrepQuery(pattern: "TODO"),
            candidates: [candidate("src/money.py")],
            source: .inMemory(["src/money.py": "# todo: 小写\n"])
        )
        #expect(insens.matches.count == 1)

        let sens = try GrepEngine.search(
            query: GrepQuery(pattern: "TODO", caseSensitive: true),
            candidates: [candidate("src/money.py")],
            source: .inMemory(["src/money.py": "# todo: 小写\n"])
        )
        #expect(sens.matches.isEmpty)
    }

    @Test("整词匹配：`round` 不命中 `rounding`")
    func wholeWord() throws {
        let files = ["a.txt": "round(x)\nrounding(y)\n"]
        let loose = try GrepEngine.search(
            query: GrepQuery(pattern: "round"),
            candidates: [candidate("a.txt")], source: .inMemory(files)
        )
        #expect(loose.matches.count == 2)

        let strict = try GrepEngine.search(
            query: GrepQuery(pattern: "round", wholeWord: true),
            candidates: [candidate("a.txt")], source: .inMemory(files)
        )
        #expect(strict.matches.count == 1)
        #expect(strict.matches[0].line == 1)
    }

    @Test("正则模式")
    func regexMode() throws {
        let files = ["a.py": "def foo():\n    return 42\ndef bar():\n    return 43\n"]
        let result = try GrepEngine.search(
            query: GrepQuery(pattern: #"def \w+\(\):"#, mode: .regex),
            candidates: [candidate("a.py")], source: .inMemory(files)
        )
        #expect(result.matches.count == 2)
        #expect(result.matches[0].line == 1)
        #expect(result.matches[1].line == 3)
    }

    @Test("非法正则 → 可执行错误（建议改用 literal）")
    func invalidRegex() throws {
        do {
            _ = try GrepEngine.search(
                query: GrepQuery(pattern: "return round(", mode: .regex),
                candidates: [candidate("a.py")], source: .inMemory(sample)
            )
            Issue.record("应当抛 invalidRegex")
        } catch let e as GrepError {
            #expect(e.modelFacingMessage.contains("正则"))
            #expect(e.suggestion?.contains("literal") == true)
        }
    }

    @Test("正则字面量前缀抽取（预筛的关键）")
    func literalPrefixExtraction() {
        // ⚠️ 转义的元字符**算字面量**：`\(` 匹配的就是一个左括号，所以它属于前缀
        #expect(GrepEngine.literalPrefix(ofRegex: "return round\\(") == "return round(")
        #expect(GrepEngine.literalPrefix(ofRegex: "TODO") == "TODO")
        #expect(GrepEngine.literalPrefix(ofRegex: ".*foo") == "")
        #expect(GrepEngine.literalPrefix(ofRegex: "\\d+ items") == "")
        #expect(GrepEngine.literalPrefix(ofRegex: "abc.*def") == "abc")
        #expect(GrepEngine.literalPrefix(ofRegex: "\\w+") == "")
    }

    @Test("⚠️ 二进制文件被跳过（不浪费电量去 grep 图片/权重）")
    func binarySkipped() throws {
        let binary = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x0D, 0x0A, 0x1A, 0x0A])
        let source = GrepFileSource { path, _ in
            path.description.hasSuffix("a.png") ? binary : Data("TODO\n".utf8)
        }
        let result = try GrepEngine.search(
            query: GrepQuery(pattern: "TODO", includeGlobs: ["*.png", "*.txt"]),
            candidates: [candidate("a.png"), candidate("b.txt")],
            source: source
        )
        #expect(result.matches.count == 1)
        #expect(result.matches[0].path.description == "/workspace/b.txt")
        #expect(result.skipReasons.keys.contains("二进制文件"))
    }

    @Test("looksBinary 的判定")
    func looksBinaryDetection() {
        #expect(GrepEngine.looksBinary(Data([0x00, 0x01, 0x02])))
        #expect(!GrepEngine.looksBinary(Data("hello 世界\n".utf8)))
        #expect(GrepEngine.looksBinary(Data([0xFF, 0xFE, 0xFD, 0xFC])))   // 非 UTF-8
        #expect(!GrepEngine.looksBinary(Data()))
    }

    @Test("⚠️ 结果条数上限会截断，并如实告知（而不是假装搜完了）")
    func maxResultsTruncation() throws {
        let many = (1...50).map { "line \($0) TODO" }.joined(separator: "\n")
        let result = try GrepEngine.search(
            query: GrepQuery(pattern: "TODO", maxResults: 10),
            candidates: [candidate("a.txt")], source: .inMemory(["a.txt": many])
        )
        #expect(result.matches.count == 10)
        #expect(result.truncated)
        #expect(result.truncationReason?.contains("10") == true)
        #expect(result.summary.contains("已被截断"))
    }

    @Test("单文件大小上限会跳过超大文件")
    func fileSizeLimit() throws {
        let result = try GrepEngine.search(
            query: GrepQuery(pattern: "TODO", maxFileBytes: 1024),
            candidates: [candidate("big.txt", size: 5_000_000)],
            source: .inMemory(["big.txt": "TODO"])
        )
        #expect(result.matches.isEmpty)
        #expect(result.skipReasons.keys.contains { $0.contains("单文件大小上限") })
    }

    @Test("countOnly 模式：只报每文件命中数")
    func countOnlyMode() throws {
        let files = ["a.txt": "TODO\nTODO\nother\n", "b.txt": "TODO\n"]
        let result = try GrepEngine.search(
            query: GrepQuery(pattern: "TODO", outputMode: .countOnly),
            candidates: [candidate("a.txt"), candidate("b.txt")],
            source: .inMemory(files)
        )
        #expect(result.matches.isEmpty)
        #expect(result.fileSummaries.count == 2)
        #expect(result.fileSummaries[0].matchCount == 2)
        #expect(result.fileSummaries[1].matchCount == 1)
    }

    @Test("filesWithMatches 模式：只报文件列表")
    func filesWithMatchesMode() throws {
        let result = try GrepEngine.search(
            query: GrepQuery(pattern: "TODO", outputMode: .filesWithMatches),
            candidates: [candidate("src/money.py"), candidate("src/orders.py")],
            source: .inMemory(sample)
        )
        #expect(result.fileSummaries.count == 1)
        #expect(result.fileSummaries[0].path.description == "/workspace/src/money.py")
    }

    @Test("上下文行")
    func contextLines() throws {
        let files = ["a.txt": "l1\nl2\nTODO here\nl4\nl5\n"]
        let result = try GrepEngine.search(
            query: GrepQuery(pattern: "TODO", contextBefore: 1, contextAfter: 2),
            candidates: [candidate("a.txt")], source: .inMemory(files)
        )
        #expect(result.matches[0].contextBefore == ["l2"])
        #expect(result.matches[0].contextAfter == ["l4", "l5"])
        // 摘要里要能看到上下文
        #expect(result.summary.contains("l2"))
        #expect(result.summary.contains("l4"))
    }

    @Test("同一行多处命中只报告一条，但标注次数")
    func multipleOccurrencesOnOneLine() throws {
        let result = try GrepEngine.search(
            query: GrepQuery(pattern: "TODO"),
            candidates: [candidate("a.txt")], source: .inMemory(["a.txt": "TODO and TODO and TODO\n"])
        )
        #expect(result.matches.count == 1)
        #expect(result.matches[0].occurrencesOnLine == 3)
        #expect(result.summary.contains("本行 3 处"))
    }

    @Test("超长行被截断（避免一行 10 万字符毁掉上下文）")
    func longLineTruncation() throws {
        let long = String(repeating: "x", count: 5000) + "TODO"
        let result = try GrepEngine.search(
            query: GrepQuery(pattern: "TODO", maxLineLength: 100),
            candidates: [candidate("a.txt")], source: .inMemory(["a.txt": long])
        )
        #expect(result.matches[0].text.count == 100)
    }

    @Test("无匹配时的摘要要说明扫描范围（而不是干巴巴一句'没找到'）")
    func noMatchSummary() throws {
        let result = try GrepEngine.search(
            query: GrepQuery(pattern: "zzz_不存在"),
            candidates: [candidate("src/money.py")], source: .inMemory(sample)
        )
        #expect(result.matches.isEmpty)
        #expect(result.summary.contains("没有找到匹配"))
        #expect(result.summary.contains("已扫描"))
    }

    @Test("确定性：同样输入得到同样输出（可回放、可测试）")
    func deterministicOrdering() throws {
        let files = ["b.txt": "TODO\n", "a.txt": "TODO\n", "c.txt": "TODO\n"]
        let candidates = [candidate("c.txt"), candidate("b.txt"), candidate("a.txt")]
        let q = GrepQuery(pattern: "TODO")
        let r1 = try GrepEngine.search(query: q, candidates: candidates, source: .inMemory(files))
        let r2 = try GrepEngine.search(query: q, candidates: candidates.reversed(), source: .inMemory(files))
        #expect(r1.matches.map(\.path.description) == r2.matches.map(\.path.description))
        #expect(r1.matches.map(\.path.description) == [
            "/workspace/a.txt", "/workspace/b.txt", "/workspace/c.txt"
        ])
    }

    @Test("空模式被拒绝")
    func emptyPatternRejected() {
        #expect(throws: GrepError.self) {
            try GrepEngine.search(
                query: GrepQuery(pattern: ""),
                candidates: [], source: .inMemory([:])
            )
        }
    }

    @Test("中文内容可正确搜索与定位")
    func chineseContent() throws {
        let result = try GrepEngine.search(
            query: GrepQuery(pattern: "四舍五入"),
            candidates: [candidate("docs/readme.md")], source: .inMemory(sample)
        )
        #expect(result.matches.count == 1)
        #expect(result.matches[0].line == 2)
        #expect(result.matches[0].column == 6)   // "退款金额要四舍五入" → 「四」是第 6 个字符
    }
}
