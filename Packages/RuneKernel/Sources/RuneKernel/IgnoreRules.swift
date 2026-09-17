import Foundation

// MARK: - 忽略规则（gitignore 语义）
//
// 为什么需要它：手机上**必须**跳过 `.git/`、`node_modules/`、`build/`、`DerivedData/`，
// 否则一次 glob 或 grep 会扫到几十万个文件、耗光电量、并且**结果里全是噪音**。
//
// 语义（按 gitignore 的实际行为实现）：
//   * 空行与 `#` 开头的行被忽略
//   * `!pattern` 取反（重新纳入）
//   * 结尾 `/` 只匹配目录
//   * 含 `/` 的模式（或前导 `/`）锚定到根；否则可匹配任意深度
//   * `**` 跨任意层
//   * **最后一条匹配的规则生效**
//   * 父目录被忽略 → 其下所有内容都被忽略（除非父目录本身被取反重新纳入）

public struct IgnoreRules: Sendable, Hashable {
    public struct Rule: Sendable, Hashable {
        public let pattern: GlobPattern
        public let isNegation: Bool
        public let sourceLine: Int
        /// 原文本（诊断时展示"是哪条规则忽略了它"）
        public let raw: String
    }

    public let rules: [Rule]
    /// 规则来源（"工作区 .gitignore" / "内置默认" / "策略文件"），用于向用户解释
    public let source: String

    public init(rules: [Rule], source: String = "内置默认") {
        self.rules = rules
        self.source = source
    }

    /// 解析 gitignore 文本
    public static func parse(_ text: String, source: String = ".gitignore") -> IgnoreRules {
        var rules: [Rule] = []
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            var line = rawLine
            if line.hasSuffix("\r") { line.removeLast() }
            // 去掉行尾未转义的空格
            while let last = line.last, last == " " {
                if line.count >= 2, line[line.index(line.endIndex, offsetBy: -2)] == "\\" { break }
                line.removeLast()
            }
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }

            var isNegation = false
            if line.hasPrefix("!") {
                isNegation = true
                line = String(line.dropFirst())
                if line.isEmpty { continue }
            } else if line.hasPrefix("\\#") || line.hasPrefix("\\!") {
                line = String(line.dropFirst())
            }

            let pattern = GlobPattern(line)
            guard pattern.isValid else { continue }
            rules.append(Rule(pattern: pattern, isNegation: isNegation, sourceLine: index + 1, raw: rawLine))
        }
        return IgnoreRules(rules: rules, source: source)
    }

    /// 追加一组内置默认规则（`.git/` 等永远应该跳过的目录）
    public func appending(_ other: IgnoreRules) -> IgnoreRules {
        IgnoreRules(rules: rules + other.rules, source: "\(source) + \(other.source)")
    }

    /// Rune 的内置默认忽略清单。
    ///
    /// 这些是"扫了也没用、只会吃电量和上下文"的东西。
    /// 注意：`.git/` 被忽略**只影响搜索**，Git 工具本身仍然正常工作。
    public static let runeDefaults = IgnoreRules.parse("""
    # 版本控制与工具链元数据
    .git/
    .svn/
    .hg/

    # 依赖目录（体积大、噪音多）
    node_modules/
    Pods/
    .venv/
    venv/
    __pycache__/
    .tox/
    .gradle/
    .cocoapods/
    vendor/bundle/

    # 构建产物
    build/
    dist/
    out/
    target/
    DerivedData/
    .build/
    *.o
    *.a
    *.so
    *.dylib
    *.class
    *.pyc

    # 缓存与临时
    .cache/
    .next/
    .turbo/
    tmp/
    *.log

    # 二进制与媒体（grep 扫它们没有意义）
    *.png
    *.jpg
    *.jpeg
    *.gif
    *.webp
    *.ico
    *.pdf
    *.zip
    *.tar
    *.gz
    *.7z
    *.mp3
    *.mp4
    *.mov
    *.woff
    *.woff2
    *.ttf
    *.otf

    # 大体积数据与模型权重
    *.gguf
    *.safetensors
    *.aimodel
    *.onnx
    *.parquet
    """, source: "Rune 内置默认")

    // MARK: 判定

    public struct Decision: Sendable, Equatable {
        public var isIgnored: Bool
        /// 是哪条规则决定的（用于向用户解释"为什么这个文件没被搜到"）
        public var matchedRule: String?
        public var source: String?

        public static let notIgnored = Decision(isIgnored: false, matchedRule: nil, source: nil)
    }

    /// 判断一个路径是否被忽略。
    ///
    /// 逐级检查祖先：父目录被忽略 ⇒ 其后代也被忽略（除非有取反规则命中）。
    public func decide(components: [String], isDirectory: Bool) -> Decision {
        guard !rules.isEmpty, !components.isEmpty else { return .notIgnored }

        var ignored = false
        var matched: Rule?

        for depth in 1...components.count {
            let prefix = Array(components[0..<depth])
            let isDir = depth < components.count || isDirectory
            for rule in rules where rule.pattern.matches(components: prefix, isDirectory: isDir) {
                ignored = !rule.isNegation
                matched = ignored ? rule : nil
            }
        }

        return Decision(
            isIgnored: ignored,
            matchedRule: ignored ? matched?.raw : nil,
            source: ignored ? (matched.map { "\(source) 第 \($0.sourceLine) 行" }) : nil
        )
    }

    public func isIgnored(_ path: VFSPath, isDirectory: Bool = false) -> Bool {
        decide(components: path.components, isDirectory: isDirectory).isIgnored
    }

    /// 是否"因为默认规则而必然导入/可导出"——供 UI 解释使用
    public var isEmpty: Bool { rules.isEmpty }
}

// MARK: - 路径过滤（include / exclude 组合）

/// `grep_search` 与 `glob` 共用的路径过滤器。
///
/// **两层忽略规则，语义不同**（这条区分很重要，否则用户会困惑"为什么我明明指定了却搜不到"）：
///   * `projectIgnore` —— 来自项目自己的 `.gitignore` 等，**一律生效**（用户自己写的规则必须被尊重）
///   * `defaultIgnore` —— Rune 内置的"扫了也没用"清单（`.git/`、`node_modules/`、`*.png`…）。
///     当文件**被显式 include 命中**时，这一层**让位** —— 用户说"我要搜 *.png"就该搜。
///
/// 判定顺序：
///   1. `projectIgnore` 命中 → 跳过
///   2. `defaultIgnore` 命中且未被显式 include → 跳过
///   3. `excludes` 命中 → 跳过
///   4. `includes` 非空且全部未命中 → 跳过
///   5. 接受
public struct PathFilter: Sendable {
    public let projectIgnore: IgnoreRules
    public let defaultIgnore: IgnoreRules
    public let includes: [GlobPattern]
    public let excludes: [GlobPattern]

    public init(
        projectIgnore: IgnoreRules = IgnoreRules(rules: [], source: "无"),
        defaultIgnore: IgnoreRules = .runeDefaults,
        includes: [GlobPattern] = [],
        excludes: [GlobPattern] = []
    ) {
        self.projectIgnore = projectIgnore
        self.defaultIgnore = defaultIgnore
        self.includes = includes
        self.excludes = excludes
    }

    public init(
        projectIgnore: IgnoreRules = IgnoreRules(rules: [], source: "无"),
        defaultIgnore: IgnoreRules = .runeDefaults,
        includeGlobs: [String],
        excludeGlobs: [String],
        caseSensitive: Bool = false
    ) {
        self.init(
            projectIgnore: projectIgnore,
            defaultIgnore: defaultIgnore,
            includes: GlobPattern.parseAll(includeGlobs, caseSensitive: caseSensitive),
            excludes: GlobPattern.parseAll(excludeGlobs, caseSensitive: caseSensitive)
        )
    }

    public struct Verdict: Sendable, Equatable {
        public var accepted: Bool
        public var reason: String?
    }

    public func evaluate(_ path: VFSPath, isDirectory: Bool = false) -> Verdict {
        // 1. 项目自己的忽略规则 —— 一律生效
        let project = projectIgnore.decide(components: path.components, isDirectory: isDirectory)
        if project.isIgnored {
            return Verdict(
                accepted: false,
                reason: "被项目忽略规则跳过（\(project.source ?? projectIgnore.source)：\(project.matchedRule ?? "")）"
            )
        }

        // 2. 内置默认忽略 —— 显式 include 命中时让位
        let explicitlyIncluded = !includes.isEmpty && includes.contains { $0.matches(path, isDirectory: isDirectory) }
        if !explicitlyIncluded {
            let fallback = defaultIgnore.decide(components: path.components, isDirectory: isDirectory)
            if fallback.isIgnored {
                return Verdict(
                    accepted: false,
                    reason: "被内置默认规则跳过（\(fallback.matchedRule ?? "")）；若确实需要搜索，请用 include 显式指定"
                )
            }
        }

        // 3. exclude
        for pattern in excludes where pattern.matches(path, isDirectory: isDirectory) {
            return Verdict(accepted: false, reason: "被 exclude 规则跳过（\(pattern.raw)）")
        }

        // 4. include
        if !includes.isEmpty && !explicitlyIncluded {
            return Verdict(accepted: false, reason: "不匹配任何 include 规则")
        }

        return Verdict(accepted: true, reason: nil)
    }

    public func accepts(_ path: VFSPath, isDirectory: Bool = false) -> Bool {
        evaluate(path, isDirectory: isDirectory).accepted
    }
}
