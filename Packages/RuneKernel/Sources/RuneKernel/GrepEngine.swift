import Foundation

// MARK: - 查询

/// `grep_search` 的查询参数。
///
/// 设计取舍：**一切都有预算**。手机上不能"先全扫完再截断"——
/// 那会在 10 万文件的仓库上耗掉几十秒和百分之几的电量。
/// 因此引擎在扫描过程中就检查配额并提前停止，并把"为什么提前停"如实报出来。
public struct GrepQuery: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable {
        /// 字面量匹配（默认；也是最快、最不容易出错的）
        case literal
        /// 正则匹配（ICU 语法）
        case regex
    }

    public enum OutputMode: String, Sendable, Equatable {
        /// 返回匹配行
        case matches
        /// 只返回每个文件的匹配数
        case countOnly
        /// 只返回有匹配的文件列表
        case filesWithMatches
    }

    public var pattern: String
    public var mode: Mode
    public var outputMode: OutputMode
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var contextBefore: Int
    public var contextAfter: Int
    /// 最多返回多少条匹配（默认 200 —— 超过这个数模型也读不完，还给上下文添乱）
    public var maxResults: Int
    /// 单行展示长度上限（超出截断，避免一行 10 万字符的东西毁掉上下文）
    public var maxLineLength: Int
    /// 单文件大小上限，超过则跳过
    public var maxFileBytes: Int
    /// 结果文本总字节上限
    public var maxTotalBytes: Int
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    /// 项目自身的忽略规则（`.gitignore`）—— **总是生效**
    public var projectIgnore: IgnoreRules
    /// 是否应用 Rune 内置的默认忽略（`.git/`、`node_modules/`、二进制媒体…）。
    /// 注意：**被显式 include 命中的文件会让默认层让位**（用户说"我要搜 *.png"就该搜）。
    public var applyDefaultIgnores: Bool

    public init(
        pattern: String,
        mode: Mode = .literal,
        outputMode: OutputMode = .matches,
        caseSensitive: Bool = false,
        wholeWord: Bool = false,
        contextBefore: Int = 0,
        contextAfter: Int = 0,
        maxResults: Int = 200,
        maxLineLength: Int = 400,
        maxFileBytes: Int = 2 * 1024 * 1024,
        maxTotalBytes: Int = 256 * 1024,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = [],
        projectIgnore: IgnoreRules = IgnoreRules(rules: [], source: "无"),
        applyDefaultIgnores: Bool = true
    ) {
        self.pattern = pattern
        self.mode = mode
        self.outputMode = outputMode
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.contextBefore = max(0, contextBefore)
        self.contextAfter = max(0, contextAfter)
        self.maxResults = max(1, maxResults)
        self.maxLineLength = max(40, maxLineLength)
        self.maxFileBytes = max(1024, maxFileBytes)
        self.maxTotalBytes = max(4096, maxTotalBytes)
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.projectIgnore = projectIgnore
        self.applyDefaultIgnores = applyDefaultIgnores
    }

    /// 正则模式是否合法（供工具层做参数校验并回灌可执行错误）
    public var compiledRegex: Result<NSRegularExpression, GrepError> {
        guard mode == .regex else { return .failure(.notRegexMode) }
        return GrepEngine.compile(pattern: pattern, caseSensitive: caseSensitive, wholeWord: wholeWord)
    }
}

// MARK: - 输入

/// 候选文件（由平台层的目录遍历产出）。引擎不碰真实文件系统，因此完全可单测。
public struct GrepCandidate: Sendable, Hashable {
    public var path: VFSPath
    public var byteSize: Int
    public var modifiedAt: Date?

    public init(path: VFSPath, byteSize: Int, modifiedAt: Date? = nil) {
        self.path = path
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
    }
}

/// 文件读取器
public struct GrepFileSource: Sendable {
    public var read: @Sendable (VFSPath, Int) throws -> Data?

    public init(read: @escaping @Sendable (VFSPath, Int) throws -> Data?) {
        self.read = read
    }

    /// 用内存字典构造（测试与 SwiftUI 预览用）。
    ///
    /// key 可以是 `src/a.py`（工作区相对）或 `/workspace/src/a.py`（完整虚拟路径），
    /// 两种写法都会被归一化 —— 写夹具时不该被迫记挂载点前缀。
    public static func inMemory(_ files: [String: String]) -> GrepFileSource {
        var normalized: [String: String] = [:]
        for (key, value) in files {
            let full = key.hasPrefix("/") ? key : "/\(MountPoint.workspace.rawValue)/\(key)"
            normalized[full] = value
        }
        // 捕获不可变副本：@Sendable 闭包不能捕获 var
        let snapshot = normalized
        return GrepFileSource { path, maxBytes in
            guard let text = snapshot[path.description] else { return nil }
            let data = Data(text.utf8)
            return data.count <= maxBytes ? data : nil
        }
    }
}

// MARK: - 输出

public struct GrepMatch: Sendable, Hashable {
    public var path: VFSPath
    /// 1-based
    public var line: Int
    /// 1-based（按字符计，不是字节）
    public var column: Int
    public var text: String
    public var contextBefore: [String]
    public var contextAfter: [String]
    /// 该行上共有几处命中（同一行只报告一条，避免噪音）
    public var occurrencesOnLine: Int

    public init(
        path: VFSPath,
        line: Int,
        column: Int,
        text: String,
        contextBefore: [String] = [],
        contextAfter: [String] = [],
        occurrencesOnLine: Int = 1
    ) {
        self.path = path
        self.line = line
        self.column = column
        self.text = text
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.occurrencesOnLine = occurrencesOnLine
    }
}

public struct GrepFileSummary: Sendable, Hashable {
    public var path: VFSPath
    public var matchCount: Int
    public var lines: [Int]
}

public struct GrepResult: Sendable {
    public var matches: [GrepMatch]
    public var fileSummaries: [GrepFileSummary]
    public var filesScanned: Int
    public var filesSkipped: Int
    /// 各跳过原因 → 次数（用于向模型/用户解释"为什么没搜到"）
    public var skipReasons: [String: Int]
    public var bytesScanned: Int
    public var truncated: Bool
    public var truncationReason: String?
    public var durationMS: Int
    /// 给模型看的文本（受 maxTotalBytes 约束）
    public var summary: String

    public var matchCount: Int { matches.count }

    public static func empty(reason: String) -> GrepResult {
        GrepResult(
            matches: [], fileSummaries: [], filesScanned: 0, filesSkipped: 0,
            skipReasons: [:], bytesScanned: 0, truncated: false,
            truncationReason: nil, durationMS: 0, summary: reason
        )
    }
}

// MARK: - 错误

public enum GrepError: Error, Sendable, Equatable {
    case emptyPattern
    case invalidRegex(String)
    case notRegexMode

    public var modelFacingMessage: String {
        switch self {
        case .emptyPattern:
            return "搜索内容为空。请给出要查找的字符串或正则。"
        case .invalidRegex(let detail):
            return "正则表达式不合法：\(detail)"
        case .notRegexMode:
            return "当前不是正则模式。"
        }
    }

    public var suggestion: String? {
        switch self {
        case .invalidRegex:
            return "如果是想搜字面量（含 `(` `[` `*` 等符号），请改用 mode=literal，不要转义。"
        case .emptyPattern:
            return "提供至少一个字符。"
        case .notRegexMode:
            return nil
        }
    }
}

// MARK: - 引擎

public enum GrepEngine {

    // MARK: 正则编译

    static func compile(
        pattern: String,
        caseSensitive: Bool,
        wholeWord: Bool
    ) -> Result<NSRegularExpression, GrepError> {
        guard !pattern.isEmpty else { return .failure(.emptyPattern) }
        var effective = pattern
        if wholeWord {
            effective = "\\b(?:\(pattern))\\b"
        }
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        do {
            return .success(try NSRegularExpression(pattern: effective, options: options))
        } catch {
            return .failure(.invalidRegex(String(describing: error)))
        }
    }

    /// 从正则里抽取**字面量前缀**，用于快速预筛（跳过明显不含目标的文件/行）。
    ///
    /// 规则：
    ///   * 普通字符进前缀
    ///   * **转义的元字符也算字面量**：`return round\(` → 前缀 `return round(`（`\(` 匹配的就是一个左括号）
    ///   * 遇到未转义的元字符（`. * + ? ( ) [ ] { } | ^ $`）停止
    ///   * 遇到字符类简写（`\d` `\w` `\s` 等）停止
    ///
    /// 这是"手机上 grep 10 万文件 ≤3s"的关键手段之一：先用廉价判定排除绝大多数行。
    public static func literalPrefix(ofRegex pattern: String) -> String {
        var out = ""
        var escaped = false
        for ch in pattern {
            if escaped {
                // 只有普通字符的转义才能进前缀；`\d` `\w` 这类不算
                if ch.isLetter || ch.isNumber {
                    break
                }
                out.append(ch)
                escaped = false
                continue
            }
            switch ch {
            case "\\":
                escaped = true
            case ".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "^", "$":
                return out
            default:
                out.append(ch)
            }
        }
        return out
    }

    // MARK: 二进制判定

    /// 判定是否为二进制内容。
    ///
    /// 规则：前 8000 字节内出现 NUL 字节即为二进制；或解码后替换字符占比过高（乱码文本）。
    /// 目的：**不去 grep 图片和模型权重**——那既没有意义，又极耗电。
    public static func looksBinary(_ data: Data) -> Bool {
        let probeCount = min(data.count, 8000)
        guard probeCount > 0 else { return false }
        let probe = data.prefix(probeCount)
        if probe.contains(0) { return true }

        guard let text = String(data: probe, encoding: .utf8) else {
            // 不是合法 UTF-8 → 很可能是二进制或非 UTF-8 编码
            return true
        }
        let replacementCount = text.unicodeScalars.filter { $0 == "\u{FFFD}" }.count
        return replacementCount > 0
    }

    // MARK: 主入口

    public static func search(
        query: GrepQuery,
        candidates: [GrepCandidate],
        source: GrepFileSource,
        now: Date = Date()
    ) throws -> GrepResult {
        let started = now

        guard !query.pattern.isEmpty else { throw GrepError.emptyPattern }

        let filter = PathFilter(
            projectIgnore: query.projectIgnore,
            defaultIgnore: query.applyDefaultIgnores ? .runeDefaults : IgnoreRules(rules: [], source: "已关闭"),
            includeGlobs: query.includeGlobs,
            excludeGlobs: query.excludeGlobs,
            caseSensitive: query.caseSensitive
        )

        // 预编译匹配器
        let regex: NSRegularExpression?
        let literalNeedle: String?
        switch query.mode {
        case .literal:
            regex = nil
            literalNeedle = query.pattern
        case .regex:
            switch compile(pattern: query.pattern, caseSensitive: query.caseSensitive, wholeWord: query.wholeWord) {
            case .success(let re):
                regex = re
                literalNeedle = nil
            case .failure(let e):
                throw e
            }
        }

        // 正则的字面量前缀用于预筛
        let prefilter: String? = {
            switch query.mode {
            case .literal:
                return literalNeedle
            case .regex:
                let prefix = literalPrefix(ofRegex: query.pattern)
                return prefix.count >= 3 ? prefix : nil   // 太短的前缀没有筛除价值
            }
        }()
        let prefilterOptions: String.CompareOptions = query.caseSensitive ? [] : [.caseInsensitive]

        var matches: [GrepMatch] = []
        var fileSummaries: [GrepFileSummary] = []
        var filesScanned = 0
        var filesSkipped = 0
        var skipReasons: [String: Int] = [:]
        var bytesScanned = 0
        var outputBytes = 0
        var truncated = false
        var truncationReason: String?

        func skip(_ reason: String) {
            filesSkipped += 1
            skipReasons[reason, default: 0] += 1
        }

        // 稳定顺序，保证同样输入得到同样输出（可回放、可测试）
        let ordered = candidates.sorted { $0.path.description < $1.path.description }

        outer: for candidate in ordered {
            let verdict = filter.evaluate(candidate.path)
            guard verdict.accepted else {
                skip(verdict.reason ?? "被过滤")
                continue
            }
            guard candidate.byteSize <= query.maxFileBytes else {
                skip("文件超过单文件大小上限（\(candidate.byteSize) > \(query.maxFileBytes) 字节）")
                continue
            }

            let data: Data
            do {
                guard let read = try source.read(candidate.path, query.maxFileBytes) else {
                    skip("读取失败或不存在")
                    continue
                }
                data = read
            } catch {
                skip("读取异常：\(error)")
                continue
            }

            if looksBinary(data) {
                skip("二进制文件")
                continue
            }

            guard let text = String(data: data, encoding: .utf8) else {
                skip("非 UTF-8 编码")
                continue
            }

            filesScanned += 1
            bytesScanned += data.count

            let table = LineTable.parse(text)
            var fileMatchLines: [Int] = []

            for (index, line) in table.lines.enumerated() {
                // 字面量预筛：这一行根本不含前缀 → 直接跳过（这是主要的速度来源）
                if let needle = prefilter,
                   line.range(of: needle, options: prefilterOptions) == nil {
                    continue
                }

                let hits = countMatches(in: line, query: query, regex: regex)
                guard hits.count > 0 else { continue }

                let lineNumber = index + 1
                fileMatchLines.append(lineNumber)

                if query.outputMode == .filesWithMatches {
                    fileSummaries.append(GrepFileSummary(path: candidate.path, matchCount: hits.count, lines: fileMatchLines))
                    if fileSummaries.count >= query.maxResults {
                        truncated = true
                        truncationReason = "已达文件数上限 \(query.maxResults)"
                        break outer
                    }
                    continue outer   // 每个文件只记一条
                }

                if query.outputMode == .countOnly {
                    continue
                }

                let shown = String(line.prefix(query.maxLineLength))
                let match = GrepMatch(
                    path: candidate.path,
                    line: lineNumber,
                    column: hits[0] + 1,
                    text: shown,
                    contextBefore: query.contextBefore > 0
                        ? Array(table.lines[max(0, index - query.contextBefore)..<index])
                        : [],
                    contextAfter: query.contextAfter > 0
                        ? Array(table.lines[(index + 1)..<min(table.lines.count, index + 1 + query.contextAfter)])
                        : [],
                    occurrencesOnLine: hits.count
                )
                matches.append(match)
                outputBytes += match.text.utf8.count + 32

                if matches.count >= query.maxResults {
                    truncated = true
                    truncationReason = "已达匹配条数上限 \(query.maxResults)"
                    break outer
                }
                if outputBytes >= query.maxTotalBytes {
                    truncated = true
                    truncationReason = "已达结果体积上限 \(query.maxTotalBytes) 字节"
                    break outer
                }
            }

            if query.outputMode == .countOnly, !fileMatchLines.isEmpty {
                fileSummaries.append(GrepFileSummary(
                    path: candidate.path, matchCount: fileMatchLines.count, lines: fileMatchLines
                ))
            }
            if query.outputMode == .matches, !fileMatchLines.isEmpty {
                fileSummaries.append(GrepFileSummary(
                    path: candidate.path, matchCount: fileMatchLines.count, lines: fileMatchLines
                ))
            }
        }

        let durationMS = Int(now.timeIntervalSince(started) * 1000)
        let summary = renderSummary(
            query: query,
            matches: matches,
            fileSummaries: fileSummaries,
            filesScanned: filesScanned,
            filesSkipped: filesSkipped,
            skipReasons: skipReasons,
            bytesScanned: bytesScanned,
            truncated: truncated,
            truncationReason: truncationReason
        )

        return GrepResult(
            matches: matches,
            fileSummaries: fileSummaries,
            filesScanned: filesScanned,
            filesSkipped: filesSkipped,
            skipReasons: skipReasons,
            bytesScanned: bytesScanned,
            truncated: truncated,
            truncationReason: truncationReason,
            durationMS: durationMS,
            summary: summary
        )
    }

    // MARK: 行内匹配

    /// 返回一行内所有命中的字符起始下标（0-based）
    ///
    /// ⚠️ 大小写不敏感时**不要**手写 `line.lowercased()` 再找下标：
    /// 某些字符 lowercase 后长度会变（如 `İ`），会让下标错位。
    /// 用 Foundation 的 `.caseInsensitive` 比较，保证下标始终落在原串上。
    static func countMatches(
        in line: String,
        query: GrepQuery,
        regex: NSRegularExpression?
    ) -> [Int] {
        guard !line.isEmpty else { return [] }

        switch query.mode {
        case .literal:
            guard !query.pattern.isEmpty else { return [] }
            var positions: [Int] = []
            let options: String.CompareOptions = query.caseSensitive ? [] : [.caseInsensitive]
            var searchStart = line.startIndex

            while searchStart < line.endIndex,
                  let found = line.range(of: query.pattern, options: options, range: searchStart..<line.endIndex) {
                if !query.wholeWord || isWholeWord(line: line, matchRange: found) {
                    positions.append(line.distance(from: line.startIndex, to: found.lowerBound))
                }
                guard found.lowerBound < line.endIndex else { break }
                searchStart = line.index(after: found.lowerBound)
            }
            return positions

        case .regex:
            guard let regex else { return [] }
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            let found = regex.matches(in: line, options: [], range: nsRange)
            return found.compactMap { result in
                guard let range = Range(result.range, in: line) else { return nil }
                return line.distance(from: line.startIndex, to: range.lowerBound)
            }
        }
    }

    /// 整词判定：命中区间的前后字符不能是"词字符"
    static func isWholeWord(line: String, matchRange: Range<String.Index>) -> Bool {
        func isWordChar(_ ch: Character?) -> Bool {
            guard let ch else { return false }
            return ch.isLetter || ch.isNumber || ch == "_"
        }
        let before = matchRange.lowerBound > line.startIndex
            ? line[line.index(before: matchRange.lowerBound)]
            : nil
        let after = matchRange.upperBound < line.endIndex
            ? line[matchRange.upperBound]
            : nil
        return !isWordChar(before) && !isWordChar(after)
    }

    // MARK: 渲染

    static func renderSummary(
        query: GrepQuery,
        matches: [GrepMatch],
        fileSummaries: [GrepFileSummary],
        filesScanned: Int,
        filesSkipped: Int,
        skipReasons: [String: Int],
        bytesScanned: Int,
        truncated: Bool,
        truncationReason: String?
    ) -> String {

        var out: [String] = []

        let fileCount = Set(matches.map(\.path.description)).count
        let head: String
        switch query.outputMode {
        case .matches:
            if matches.isEmpty {
                head = "没有找到匹配。"
            } else {
                head = "找到 \(matches.count) 处匹配，分布在 \(fileCount) 个文件。"
            }
        case .countOnly:
            head = fileSummaries.isEmpty
                ? "没有找到匹配。"
                : "\(fileSummaries.count) 个文件有匹配，共 \(fileSummaries.reduce(0) { $0 + $1.matchCount }) 处。"
        case .filesWithMatches:
            head = fileSummaries.isEmpty
                ? "没有文件包含该内容。"
                : "\(fileSummaries.count) 个文件包含该内容。"
        }
        out.append(head)

        if query.outputMode == .matches, !matches.isEmpty {
            var currentPath: String?
            for match in matches {
                if match.path.description != currentPath {
                    currentPath = match.path.description
                    out.append("")
                    out.append("\(currentPath!):")
                }
                for contextLine in match.contextBefore {
                    out.append("      \(String(contextLine.prefix(query.maxLineLength)))")
                }
                let occ = match.occurrencesOnLine > 1 ? "  (本行 \(match.occurrencesOnLine) 处)" : ""
                out.append("  \(match.line): \(match.text)\(occ)")
                for contextLine in match.contextAfter {
                    out.append("      \(String(contextLine.prefix(query.maxLineLength)))")
                }
            }
        } else if query.outputMode != .matches {
            for file in fileSummaries {
                if query.outputMode == .filesWithMatches {
                    out.append("  \(file.path.description)")
                } else {
                    out.append("  \(file.matchCount)\t\(file.path.description)")
                }
            }
        }

        out.append("")
        var stats = "已扫描 \(filesScanned) 个文件 / \(bytesScanned / 1024) KB，跳过 \(filesSkipped) 个。"
        if !skipReasons.isEmpty {
            let top = skipReasons.sorted { $0.value > $1.value }.prefix(3)
                .map { "\($0.key) ×\($0.value)" }
                .joined(separator: "；")
            stats += " 跳过原因：\(top)。"
        }
        out.append(stats)

        if truncated, let reason = truncationReason {
            out.append("⚠️ 结果已被截断（\(reason)）。可用更精确的模式、include/exclude 缩小范围，或分多次搜索。")
        }

        return out.joined(separator: "\n")
    }
}
