import Foundation

// MARK: - 文本行表
//
// 补丁处理的第一原则：**行尾风格必须保真**。
// 模型经常给出 LF 的补丁去改 CRLF 的文件；如果我们不记录原始风格，改完整个文件都会"变脏"，
// 用户看到的 diff 会有几千行噪音。

/// 文本的行视图（保留换行风格与"是否有末行换行"）
public struct LineTable: Sendable, Equatable {
    /// 行内容（**不含**换行符）
    public var lines: [String]
    /// 原文本是否以换行结尾
    public var endsWithNewline: Bool
    /// 原始换行风格（用于回写时保持一致）
    public var newline: String

    public init(lines: [String], endsWithNewline: Bool, newline: String = "\n") {
        self.lines = lines
        self.endsWithNewline = endsWithNewline
        self.newline = newline
    }

    /// 从文本解析。自动识别 CRLF / LF，并正确处理"末行无换行"。
    ///
    /// ⚠️ **Swift 陷阱**：`"\r\n"` 在 Swift 里是**单个 Character**（CR+LF 构成一个字素簇），
    /// 因此 `text.components(separatedBy: "\n")` 在 CRLF 文本上**根本不会分割**，
    /// 会把整个文件当成一行 —— 这会让所有按行匹配的补丁静默失败。
    /// 必须先归一化掉 CRLF，再按 LF 分割。
    /// （只支持 CRLF / LF；纯 CR 的古典 Mac 换行不做支持。）
    public static func parse(_ text: String) -> LineTable {
        let usesCRLF = text.contains("\r\n")
        let newline = usesCRLF ? "\r\n" : "\n"
        if text.isEmpty {
            return LineTable(lines: [], endsWithNewline: false, newline: newline)
        }
        let normalized = usesCRLF ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        var lines = normalized.components(separatedBy: "\n")
        var endsWithNewline = false
        if let last = lines.last, last.isEmpty {
            lines.removeLast()
            endsWithNewline = true
        }
        return LineTable(lines: lines, endsWithNewline: endsWithNewline, newline: newline)
    }

    public var text: String {
        guard !lines.isEmpty else { return "" }
        let joined = lines.joined(separator: newline)
        return endsWithNewline ? joined + newline : joined
    }

    public var count: Int { lines.count }
}

// MARK: - 匹配候选（用于给模型可执行的纠正建议）

/// 一次匹配的位置与上下文预览。
///
/// 补丁失败时**必须**返回候选，否则模型只能瞎猜（docs/05 §9 的兜底策略）。
public struct MatchCandidate: Sendable, Equatable, Hashable {
    /// 1-based 行号
    public var line: Int
    /// 前后各若干行的预览（便于模型定位）
    public var preview: [String]

    public init(line: Int, preview: [String]) {
        self.line = line
        self.preview = preview
    }

    public var displayString: String {
        "第 \(line) 行"
    }
}

// MARK: - 补丁结构

public enum HunkLine: Sendable, Equatable {
    case context(String)
    case remove(String)
    case add(String)

    public var text: String {
        switch self {
        case .context(let t), .remove(let t), .add(let t): return t
        }
    }

    public var isAdd: Bool { if case .add = self { return true }; return false }
    public var isRemove: Bool { if case .remove = self { return true }; return false }
    public var isContext: Bool { if case .context = self { return true }; return false }
}

/// 一个改动块。
public struct PatchHunk: Sendable, Equatable {
    /// `@@` 后面的提示文本（函数名、搜索串等）。用于在匹配失败时缩小搜索范围。
    public var anchor: String?
    public var lines: [HunkLine]

    public init(anchor: String? = nil, lines: [HunkLine]) {
        self.anchor = anchor
        self.lines = lines
    }

    /// 用于匹配的"旧内容"（context + remove）
    public var oldLines: [String] {
        lines.filter { !$0.isAdd }.map(\.text)
    }

    /// 替换后的"新内容"（context + add）
    public var newLines: [String] {
        lines.filter { !$0.isRemove }.map(\.text)
    }

    public var addedCount: Int { lines.filter(\.isAdd).count }
    public var removedCount: Int { lines.filter(\.isRemove).count }

    /// 是否为"纯插入"（没有要匹配的旧内容）
    public var isPureInsertion: Bool { oldLines.isEmpty }
}

/// 一个文件上的改动。
public struct PatchFile: Sendable, Equatable {
    public enum Action: String, Sendable, Equatable {
        case update
        case create
        case delete
    }

    public var path: VFSPath
    public var action: Action
    public var hunks: [PatchHunk]
    /// 创建文件时的初始内容（action == .create）
    public var initialContent: [String]?

    public init(path: VFSPath, action: Action = .update, hunks: [PatchHunk], initialContent: [String]? = nil) {
        self.path = path
        self.action = action
        self.hunks = hunks
        self.initialContent = initialContent
    }
}

/// 一份完整补丁（可跨多个文件）
public struct Patch: Sendable, Equatable {
    public var files: [PatchFile]

    public init(files: [PatchFile]) {
        self.files = files
    }
}

// MARK: - 匹配强度

/// 匹配放宽级别。**逐级放宽**，但每一级都必须保证唯一性。
///
/// 为什么需要放宽：模型给出的上下文行常有空白差异（缩进、行尾空格），
/// 如果只做精确匹配，补丁失败率会高得无法使用。
public enum MatchFuzz: Int, Sendable, CaseIterable, Comparable {
    /// 逐字节相同
    case exact = 0
    /// 忽略行尾空白
    case ignoreTrailingWhitespace = 1
    /// 忽略行首与行尾空白
    case ignoreLeadingAndTrailing = 2
    /// 忽略所有空白（含中间）
    case ignoreAllWhitespace = 3

    public static func < (lhs: MatchFuzz, rhs: MatchFuzz) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 按该级别规范化一行
    func normalize(_ line: String) -> String {
        switch self {
        case .exact:
            return line
        case .ignoreTrailingWhitespace:
            var s = line
            while let last = s.last, last == " " || last == "\t" { s.removeLast() }
            return s
        case .ignoreLeadingAndTrailing:
            return line.trimmingCharacters(in: .whitespaces)
        case .ignoreAllWhitespace:
            return line.filter { $0 != " " && $0 != "\t" }
        }
    }
}

// MARK: - 错误

public enum PatchError: Error, Sendable, Equatable {
    /// 语法错误（带行号，模型可以据此修正）
    case parseFailure(line: Int, message: String)
    /// 找不到要修改的上下文
    case hunkNotFound(path: String, hunkIndex: Int, oldLines: [String], nearest: [MatchCandidate])
    /// 上下文匹配到多处（**必须拒绝而不是猜**）
    case ambiguousMatch(path: String, hunkIndex: Int, matches: [MatchCandidate])
    /// 同一文件内的改动块重叠
    case overlappingHunks(path: String, first: Int, second: Int, atLine: Int)
    /// 目标文件不存在（action == .update）
    case fileNotFound(path: String)
    /// 文件已存在（action == .create）
    case fileAlreadyExists(path: String)
    case emptyPatch

    /// 面向模型的可执行说明（这是"修正性重试"的输入，docs/04 §4.4）
    public var modelFacingMessage: String {
        switch self {
        case .parseFailure(let line, let message):
            return "补丁第 \(line) 行语法有误：\(message)"
        case .hunkNotFound(let path, let index, let oldLines, let nearest):
            var s = "在 \(path) 中找不到第 \(index + 1) 个改动块的上下文。期望匹配的内容是：\n"
            s += oldLines.prefix(8).map { "  | " + $0 }.joined(separator: "\n")
            if nearest.isEmpty {
                s += "\n该文件中没有相似位置。请先用 read_file 确认当前内容。"
            } else {
                s += "\n最接近的位置：\n"
                s += nearest.map { c in
                    "  第 \(c.line) 行：\n" + c.preview.map { "    | " + $0 }.joined(separator: "\n")
                }.joined(separator: "\n")
            }
            return s
        case .ambiguousMatch(let path, let index, let matches):
            var s = "\(path) 中第 \(index + 1) 个改动块的上下文匹配到 \(matches.count) 处，无法确定改哪一处。"
            s += "\n请在上下文里多包含几行（或包含该处独有的内容）以唯一确定位置。候选：\n"
            s += matches.map { "  第 \($0.line) 行：\n" + $0.preview.map { "    | " + $0 }.joined(separator: "\n") }
                .joined(separator: "\n")
            return s
        case .overlappingHunks(let path, let first, let second, let line):
            return "\(path) 中第 \(first + 1) 与第 \(second + 1) 个改动块在文件第 \(line) 行附近重叠。请把它们合并成一个改动块。"
        case .fileNotFound(let path):
            return "文件 \(path) 不存在（补丁要求修改它）。若本意是新建，请使用 create 形式。"
        case .fileAlreadyExists(let path):
            return "文件 \(path) 已存在（补丁要求新建它）。若本意是修改，请使用 update 形式。"
        case .emptyPatch:
            return "补丁为空：没有解析出任何改动。"
        }
    }

    /// 建议的下一步
    public var suggestion: String? {
        switch self {
        case .hunkNotFound, .ambiguousMatch:
            return "先 read_file 读取文件当前内容，再基于实际内容重新生成补丁。"
        case .parseFailure:
            return "检查补丁格式：文件段以 `*** File: <路径>` 开头，改动块以 `@@` 开头，行前缀用 ` `（上下文）/ `-`（删除）/ `+`（新增）。"
        case .overlappingHunks:
            return "把相邻的改动合并为一个 @@ 块。"
        case .fileNotFound, .fileAlreadyExists:
            return "确认动作类型（update / create / delete）与文件当前状态是否一致。"
        case .emptyPatch:
            return "补丁内容不能为空。"
        }
    }
}

// MARK: - 解析

extension Patch {

    /// 解析补丁文本。**同时支持两种格式**：
    ///
    /// **① Rune 原生格式**（推荐，最明确）
    /// ```
    /// *** File: /workspace/src/money.py
    /// @@ def round_amount
    ///      amount = Decimal(amount)
    /// -    return round(amount)
    /// +    return round(amount, currency.exponent)
    ///
    /// *** Create: /workspace/docs/note.md
    /// +# 标题
    /// +正文
    ///
    /// *** Delete: /tmp/old.txt
    /// ```
    /// ⚠️ `+` 之后**不要加分隔空格**：`+# 标题` 表示新文件内容是 `# 标题`；
    /// 写成 `+ # 标题` 会得到 ` # 标题`（多一个前导空格）——这与 unified diff 的语义一致。
    ///
    /// **② 标准 unified diff**（模型最擅长产出的格式，必须能吃下）
    /// ```
    /// --- a/src/money.py
    /// +++ b/src/money.py
    /// @@ -10,3 +10,3 @@ def round_amount
    ///      amount = Decimal(amount)
    /// -    return round(amount)
    /// +    return round(amount, currency.exponent)
    /// ```
    /// 其中 `--- /dev/null` 视为新建、`+++ /dev/null` 视为删除；`index` / `new file mode` 等
    /// 元数据行被忽略。
    ///
    /// **宽容之处**（都是为了降低补丁失败率）：
    ///   * `@@` 后的提示文本可有可无；unified diff 的行号范围**不参与匹配**（我们按内容匹配，比按行号匹配更稳）
    ///   * 路径可以是相对的（视为相对 `/workspace`），也可以带 `a/` `b/` 前缀
    ///   * 行前缀外的前后空白会被忽略（`- ` 与 `-` 等价）
    ///   * `\ No newline at end of file` 被忽略（末行换行由 `LineTable` 自动保真）
    public static func parse(_ text: String) throws -> Patch {
        var files: [PatchFile] = []
        var currentPath: VFSPath?
        var currentAction: PatchFile.Action = .update
        var currentHunks: [PatchHunk] = []
        var currentInitial: [String]?
        var currentAnchor: String?
        var currentLines: [HunkLine] = []
        /// unified diff 的 `---` 行暂存的"旧路径"，用于判断 create / delete
        var pendingOldPath: String?

        func flushHunk() {
            defer { currentAnchor = nil; currentLines = [] }
            guard currentAnchor != nil, !currentLines.isEmpty else { return }
            currentHunks.append(PatchHunk(anchor: currentAnchor, lines: currentLines))
        }

        func flushFile() {
            flushHunk()
            defer {
                currentPath = nil; currentHunks = []; currentInitial = nil; currentAction = .update
            }
            guard let path = currentPath else { return }
            // create：裁掉尾部空行。
            // 理由：模型会在 create 块与下一个指令之间留空行作分隔，若保留就会让新文件多出空行。
            // 需要"文件末尾确实是空行"的场景，请在内容里显式多写一个 `+` 行。
            var initial = currentInitial
            if currentAction == .create {
                while let last = initial?.last, last.isEmpty { initial?.removeLast() }
            }
            files.append(PatchFile(
                path: path, action: currentAction, hunks: currentHunks, initialContent: initial
            ))
        }

        let rawLines = text.components(separatedBy: "\n")
        for (index, rawLine) in rawLines.enumerated() {
            let lineNumber = index + 1
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

            // ---------- Rune 原生指令 ----------
            if line.hasPrefix("***") {
                let directive = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let lowered = directive.lowercased()
                if lowered.hasPrefix("begin") || lowered.hasPrefix("end") { continue }
                flushFile()
                let (action, rawPath) = Self.parseRuneDirective(directive)
                guard !rawPath.isEmpty else {
                    throw PatchError.parseFailure(line: lineNumber, message: "文件段缺少路径：\(line)")
                }
                currentPath = try Self.resolvePath(rawPath, lineNumber: lineNumber)
                currentAction = action
                if action == .create { currentInitial = [] }
                continue
            }

            // ---------- unified diff 元数据 ----------
            if line.hasPrefix("diff --git") || line.hasPrefix("index ") ||
               line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode") ||
               line.hasPrefix("old mode") || line.hasPrefix("new mode") ||
               line.hasPrefix("similarity index") || line.hasPrefix("rename ") ||
               line.hasPrefix("\\ No newline") {
                continue
            }

            // ---------- unified diff 的 --- / +++ 头 ----------
            if line.hasPrefix("--- ") {
                pendingOldPath = Self.cleanUnifiedPath(String(line.dropFirst(4)))
                continue
            }
            if line.hasPrefix("+++ ") {
                let newPath = Self.cleanUnifiedPath(String(line.dropFirst(4)))
                flushFile()
                let isCreate = (pendingOldPath == "/dev/null")
                let isDelete = (newPath == "/dev/null")
                let target = isDelete ? (pendingOldPath ?? "") : newPath
                guard !target.isEmpty, target != "/dev/null" else {
                    throw PatchError.parseFailure(line: lineNumber, message: "无法从 `+++` 行确定目标文件路径：\(line)")
                }
                currentPath = try Self.resolvePath(target, lineNumber: lineNumber)
                currentAction = isCreate ? .create : (isDelete ? .delete : .update)
                if currentAction == .create { currentInitial = [] }
                pendingOldPath = nil
                continue
            }

            // ---------- hunk 头 ----------
            if line.hasPrefix("@@") {
                flushHunk()
                currentAnchor = Self.extractAnchor(fromHunkHeader: line)
                continue
            }

            // ---------- 尚未进入任何文件 ----------
            guard currentPath != nil else {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                throw PatchError.parseFailure(
                    line: lineNumber,
                    message: "在文件段之前出现了内容：\(line)。每个改动都必须先声明文件（`*** File: <路径>` 或 `---`/`+++`）。"
                )
            }

            // ---------- create：所有行都是新内容 ----------
            if currentAction == .create {
                var body = line
                if body.hasPrefix("+") { body = String(body.dropFirst()) }
                else if body.hasPrefix(" ") { body = String(body.dropFirst()) }
                currentInitial?.append(body)
                continue
            }

            // ---------- 空行 = 空上下文行 ----------
            if line.isEmpty {
                if currentAnchor != nil { currentLines.append(.context("")) }
                continue
            }

            guard currentAnchor != nil else {
                throw PatchError.parseFailure(
                    line: lineNumber,
                    message: "改动块之外出现了内容行：\(line)。每个改动块必须以 `@@` 开头。"
                )
            }

            switch line.first {
            case "-": currentLines.append(.remove(String(line.dropFirst())))
            case "+": currentLines.append(.add(String(line.dropFirst())))
            case " ": currentLines.append(.context(String(line.dropFirst())))
            default:  currentLines.append(.context(line))   // 无前缀 → 宽容当作上下文
            }
        }
        flushFile()

        guard !files.isEmpty else { throw PatchError.emptyPatch }
        return Patch(files: files)
    }

    /// `*** File: x` / `*** Create: x` / `*** Delete: x` / `*** Update File: x`
    private static func parseRuneDirective(_ directive: String) -> (PatchFile.Action, String) {
        let lowered = directive.lowercased()
        func afterColon() -> String {
            let parts = directive.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        }
        if lowered.hasPrefix("create") || lowered.hasPrefix("add file") { return (.create, afterColon()) }
        if lowered.hasPrefix("delete") || lowered.hasPrefix("remove file") { return (.delete, afterColon()) }
        if lowered.hasPrefix("file:") || lowered.hasPrefix("update") { return (.update, afterColon()) }
        return (.update, directive)   // 裸路径 → 当作 update
    }

    /// 清理 unified diff 路径：去掉 `a/` `b/` 前缀与制表符后的元数据
    private static func cleanUnifiedPath(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let tab = s.firstIndex(of: "\t") { s = String(s[s.startIndex..<tab]) }
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count > 1 { s = String(s.dropFirst().dropLast()) }
        if s.hasPrefix("a/") || s.hasPrefix("b/") { s = String(s.dropFirst(2)) }
        return s
    }

    /// 从 hunk 头取出锚点文本。**同时支持两种写法**：
    ///   * Rune 原生：`@@ def round_amount`          → 锚点 = "def round_amount"
    ///   * unified diff：`@@ -10,3 +10,3 @@ def foo` → 锚点 = "def foo"
    ///   * 无锚点：`@@ -1,2 +3,4 @@`                → 锚点 = ""
    private static func extractAnchor(fromHunkHeader line: String) -> String {
        let afterFirst = line.dropFirst(2)
        if let secondRange = afterFirst.range(of: "@@") {
            return afterFirst[secondRange.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        return afterFirst.trimmingCharacters(in: .whitespaces)
    }

    /// 解析路径：绝对虚拟路径直接用；相对路径视为相对 `/workspace`（模型常给仓库相对路径）
    private static func resolvePath(_ raw: String, lineNumber: Int) throws -> VFSPath {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") {
            do {
                return try VFSPath.parse(trimmed)
            } catch let e as VFSPath.ParseError {
                throw PatchError.parseFailure(line: lineNumber, message: e.modelFacingMessage)
            }
        }
        let components = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        guard !components.isEmpty, !components.contains("..") else {
            throw PatchError.parseFailure(
                line: lineNumber,
                message: "相对路径 `\(trimmed)` 非法（不能包含 `..`）。请给出相对于工作区的路径，或使用绝对虚拟路径 /workspace/…"
            )
        }
        return VFSPath(mount: .workspace, components: components)
    }
}

// MARK: - 应用结果

/// 一次"应用补丁"的完整结果。
///
/// ⚠️ **原子性**：只要任何一个 hunk 失败，整份补丁都不落地（`changes` 为空）。
/// 这是 docs/04 §4.3 的硬要求——半落地的补丁比失败更难收拾。
public struct PatchApplication: Sendable, Equatable {
    public struct FileChange: Sendable, Equatable {
        public var path: VFSPath
        public var action: PatchFile.Action
        /// 修改后的完整内容（delete 时为 nil）
        public var newContent: String?
        public var addedCount: Int
        public var removedCount: Int
        /// 命中的匹配强度（用于诊断与统计"模型给的上下文有多准"）
        public var fuzz: MatchFuzz

        public init(
            path: VFSPath,
            action: PatchFile.Action,
            newContent: String?,
            addedCount: Int,
            removedCount: Int,
            fuzz: MatchFuzz
        ) {
            self.path = path
            self.action = action
            self.newContent = newContent
            self.addedCount = addedCount
            self.removedCount = removedCount
            self.fuzz = fuzz
        }
    }

    public var changes: [FileChange]

    public var totalAdded: Int { changes.reduce(0) { $0 + $1.addedCount } }
    public var totalRemoved: Int { changes.reduce(0) { $0 + $1.removedCount } }
    public var isCleanMatch: Bool { changes.allSatisfy { $0.fuzz == .exact } }
}

// MARK: - 应用

extension Patch {

    /// 读取文件的闭包：返回 nil 表示文件不存在。
    /// 之所以用闭包而不是直接读文件系统，是为了让本模块**完全可单测**（不碰真实文件）。
    public typealias FileReader = (VFSPath) throws -> String?

    /// 应用补丁。**失败即整体不落地。**
    ///
    /// 算法：
    ///   1. 对每个文件，把每个 hunk 的"旧内容"在**原始行表**上做匹配（逐级放宽 fuzz）
    ///   2. 匹配必须唯一；0 处或 ≥2 处都直接失败并给出候选
    ///   3. 所有 hunk 在原始坐标上确认互不重叠
    ///   4. 一次遍历生成新内容（避免多处偏移漂移这类经典 bug）
    public func apply(reader: FileReader) throws -> PatchApplication {
        var changes: [PatchApplication.FileChange] = []

        for file in files {
            switch file.action {
            case .create:
                if (try reader(file.path)) != nil { throw PatchError.fileAlreadyExists(path: file.path.description) }
                let body = file.initialContent ?? []
                let table = LineTable(lines: body, endsWithNewline: !body.isEmpty, newline: "\n")
                changes.append(.init(
                    path: file.path,
                    action: .create,
                    newContent: table.text,
                    addedCount: body.count,
                    removedCount: 0,
                    fuzz: .exact
                ))

            case .delete:
                guard (try reader(file.path)) != nil else { throw PatchError.fileNotFound(path: file.path.description) }
                changes.append(.init(
                    path: file.path, action: .delete, newContent: nil,
                    addedCount: 0, removedCount: 0, fuzz: .exact
                ))

            case .update:
                guard let original = try reader(file.path) else {
                    throw PatchError.fileNotFound(path: file.path.description)
                }
                let change = try Self.applyHunksToFile(
                    path: file.path, original: original, hunks: file.hunks
                )
                changes.append(change)
            }
        }
        return PatchApplication(changes: changes)
    }

    /// 单文件应用（同时被 `apply` 与测试直接使用）
    static func applyHunksToFile(
        path: VFSPath,
        original: String,
        hunks: [PatchHunk]
    ) throws -> PatchApplication.FileChange {
        let table = LineTable.parse(original)

        struct Placement {
            var hunkIndex: Int
            var start: Int          // 0-based，起始行
            var length: Int         // 被替换的旧行数
            var fuzz: MatchFuzz
            var hunk: PatchHunk
        }

        var placements: [Placement] = []

        for (hunkIndex, hunk) in hunks.enumerated() {

            // 纯插入：用 anchor 定位，找不到就插到文件末尾
            if hunk.isPureInsertion {
                let insertAt: Int
                if let anchor = hunk.anchor, !anchor.isEmpty,
                   let found = Self.findAnchorLine(anchor, in: table.lines) {
                    insertAt = found + 1
                } else {
                    insertAt = table.lines.count
                }
                placements.append(Placement(
                    hunkIndex: hunkIndex, start: insertAt, length: 0, fuzz: .exact, hunk: hunk
                ))
                continue
            }

            let pattern = hunk.oldLines
            var best: (fuzz: MatchFuzz, matches: [Int])?

            for fuzz in MatchFuzz.allCases {
                let matches = Self.findMatches(pattern: pattern, in: table.lines, fuzz: fuzz)
                if !matches.isEmpty {
                    best = (fuzz, matches)
                    break
                }
            }

            guard let found = best else {
                // 全失败 → 给出"最接近的位置"作为纠正线索
                let nearest = Self.nearestCandidates(pattern: pattern, in: table.lines, limit: 3)
                throw PatchError.hunkNotFound(
                    path: path.description, hunkIndex: hunkIndex, oldLines: pattern, nearest: nearest
                )
            }

            if found.matches.count > 1 {
                let candidates = found.matches.prefix(5).map { start in
                    MatchCandidate(
                        line: start + 1,
                        preview: Self.preview(lines: table.lines, around: start, radius: 2)
                    )
                }
                throw PatchError.ambiguousMatch(
                    path: path.description, hunkIndex: hunkIndex, matches: Array(candidates)
                )
            }

            placements.append(Placement(
                hunkIndex: hunkIndex,
                start: found.matches[0],
                length: pattern.count,
                fuzz: found.fuzz,
                hunk: hunk
            ))
        }

        // 重叠检测（在原始坐标上）
        let sorted = placements.sorted { $0.start < $1.start }
        for i in 1..<max(sorted.count, 1) where sorted.count > 1 {
            let prev = sorted[i - 1]
            let cur = sorted[i]
            let prevEnd = prev.start + max(prev.length, 1)
            if cur.start < prevEnd {
                throw PatchError.overlappingHunks(
                    path: path.description,
                    first: prev.hunkIndex,
                    second: cur.hunkIndex,
                    atLine: cur.start + 1
                )
            }
        }

        // 一次遍历生成新内容
        var out: [String] = []
        var cursor = 0
        var added = 0
        var removed = 0
        var worstFuzz = MatchFuzz.exact

        for placement in sorted {
            // 拷贝未被改动的部分
            if placement.start > cursor {
                out.append(contentsOf: table.lines[cursor..<placement.start])
            }
            if placement.length > 0 {
                out.append(contentsOf: placement.hunk.newLines)
                removed += placement.hunk.removedCount
                added += placement.hunk.addedCount
            } else {
                out.append(contentsOf: placement.hunk.lines.filter(\.isAdd).map(\.text))
                added += placement.hunk.addedCount
            }
            if placement.fuzz > worstFuzz { worstFuzz = placement.fuzz }
            cursor = placement.start + placement.length
        }
        if cursor < table.lines.count {
            out.append(contentsOf: table.lines[cursor...])
        }

        let result = LineTable(lines: out, endsWithNewline: table.endsWithNewline, newline: table.newline)
        return PatchApplication.FileChange(
            path: path,
            action: .update,
            newContent: result.text,
            addedCount: added,
            removedCount: removed,
            fuzz: worstFuzz
        )
    }

    // MARK: 匹配辅助

    /// 在给定 fuzz 级别下找出 pattern 的所有出现位置（0-based 起始行）
    static func findMatches(pattern: [String], in lines: [String], fuzz: MatchFuzz) -> [Int] {
        guard !pattern.isEmpty, lines.count >= pattern.count else { return [] }
        let normalizedPattern = pattern.map { fuzz.normalize($0) }
        let normalizedLines = lines.map { fuzz.normalize($0) }
        var matches: [Int] = []
        let last = lines.count - pattern.count
        var i = 0
        while i <= last {
            var ok = true
            for j in 0..<pattern.count where normalizedLines[i + j] != normalizedPattern[j] {
                ok = false
                break
            }
            if ok {
                matches.append(i)
                i += 1     // 允许重叠出现（用于发现"匹配到多处"的情况）
            } else {
                i += 1
            }
        }
        return matches
    }

    /// 找 anchor 文本出现的行（返回首个匹配行的 0-based 下标）
    static func findAnchorLine(_ anchor: String, in lines: [String]) -> Int? {
        let needle = anchor.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        if let i = lines.firstIndex(where: { $0.contains(needle) }) { return i }
        // 退一步：忽略空白比较
        let compact = needle.filter { $0 != " " && $0 != "\t" }
        if compact.isEmpty { return nil }
        return lines.firstIndex { $0.filter { ch in ch != " " && ch != "\t" }.contains(compact) }
    }

    static func preview(lines: [String], around index: Int, radius: Int) -> [String] {
        let lower = max(0, index - radius)
        let upper = min(lines.count - 1, index + radius)
        guard lower <= upper else { return [] }
        return (lower...upper).map { lines[$0] }
    }

    /// 找"最接近"的位置：以第一行内容做模糊匹配，返回相似度最高的若干处
    static func nearestCandidates(pattern: [String], in lines: [String], limit: Int) -> [MatchCandidate] {
        guard let firstLine = pattern.first, !firstLine.isEmpty else { return [] }
        let needle = firstLine.filter { $0 != " " && $0 != "\t" }
        guard !needle.isEmpty else { return [] }

        struct Scored { var index: Int; var score: Int }
        var scored: [Scored] = []
        for (index, line) in lines.enumerated() {
            let hay = line.filter { $0 != " " && $0 != "\t" }
            guard !hay.isEmpty else { continue }
            let score = Self.sharedPrefixLength(needle, hay)
            if score >= max(3, needle.count / 3) {
                scored.append(Scored(index: index, score: score))
            }
        }
        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { MatchCandidate(line: $0.index + 1, preview: preview(lines: lines, around: $0.index, radius: 2)) }
    }

    private static func sharedPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        for (x, y) in zip(a, b) {
            if x == y { count += 1 } else { break }
        }
        return count
    }
}

// MARK: - 单点替换（edit_file 的核心）

/// `edit_file` 的引擎：**要求唯一匹配**，否则拒绝并给出候选。
///
/// 为什么不能用"替换全部"：模型想改一处却改了十处，是编码 Agent 最危险的失效模式之一。
public enum TextEdit {

    public enum EditError: Error, Sendable, Equatable {
        case notFound(find: String, nearest: [MatchCandidate])
        case ambiguous(find: String, matches: [MatchCandidate])
        case emptyFind

        public var modelFacingMessage: String {
            switch self {
            case .emptyFind:
                return "待查找的字符串为空。"
            case .notFound(let find, let nearest):
                var s = "在文件中找不到这段内容：\n" + find.split(separator: "\n").prefix(6).map { "  | \($0)" }.joined(separator: "\n")
                if !nearest.isEmpty {
                    s += "\n最接近的位置：\n" + nearest.map { "  第 \($0.line) 行" }.joined(separator: "、")
                }
                return s
            case .ambiguous(let find, let matches):
                let head = find.split(separator: "\n").prefix(3).map { "  | \($0)" }.joined(separator: "\n")
                return "这段内容在文件中出现 \(matches.count) 次，无法确定改哪一处（行号：\(matches.map { String($0.line) }.joined(separator: "、"))）：\n\(head)\n请包含更多上下文以唯一确定位置，或改用 apply_patch。"
            }
        }
    }

    /// 用 `replace` 替换文件中**唯一**出现的 `find`
    public static func replaceUnique(
        in text: String,
        find: String,
        replace: String,
        fuzz: MatchFuzz = .ignoreLeadingAndTrailing
    ) throws -> String {
        guard !find.isEmpty else { throw EditError.emptyFind }

        // ⚠️ 替换文本的换行风格必须**跟随目标文件**，否则会在 CRLF 文件里插进 LF 行，
        //    用户看到的 diff 会变成整文件噪音（这正是我们反复要避免的事）。
        let documentNewline = text.contains("\r\n") ? "\r\n" : "\n"
        let normalizedReplace = normalizeNewlines(replace, to: documentNewline)

        // 优先整段精确匹配
        if let range = uniqueRange(of: find, in: text) {
            var result = text
            result.replaceSubrange(range, with: normalizedReplace)
            return result
        }

        // 退一步：按行匹配（容忍空白差异）
        let table = LineTable.parse(text)
        let findLines = LineTable.parse(find).lines
        guard !findLines.isEmpty else { throw EditError.emptyFind }

        var matches: [Int] = []
        for level in MatchFuzz.allCases where level >= fuzz {
            matches = Patch.findMatches(pattern: findLines, in: table.lines, fuzz: level)
            if !matches.isEmpty { break }
        }

        guard !matches.isEmpty else {
            throw EditError.notFound(
                find: find,
                nearest: Patch.nearestCandidates(pattern: findLines, in: table.lines, limit: 3)
            )
        }
        guard matches.count == 1 else {
            throw EditError.ambiguous(
                find: find,
                matches: matches.prefix(5).map {
                    MatchCandidate(line: $0 + 1, preview: Patch.preview(lines: table.lines, around: $0, radius: 2))
                }
            )
        }

        let start = matches[0]
        var newLines = Array(table.lines[0..<start])
        newLines.append(contentsOf: LineTable.parse(normalizedReplace).lines)
        newLines.append(contentsOf: table.lines[(start + findLines.count)...])
        return LineTable(lines: newLines, endsWithNewline: table.endsWithNewline, newline: table.newline).text
    }

    /// 把文本的换行统一成指定风格
    static func normalizeNewlines(_ text: String, to newline: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard newline != "\n" else { return unified }
        return unified.replacingOccurrences(of: "\n", with: newline)
    }

    /// 找出 `find` 在 `text` 中唯一出现的区间；0 次或多次都返回 nil
    static func uniqueRange(of find: String, in text: String) -> Range<String.Index>? {
        guard let first = text.range(of: find) else { return nil }
        let after = first.upperBound
        if after < text.endIndex, text.range(of: find, range: after..<text.endIndex) != nil {
            return nil   // 出现多次
        }
        return first
    }
}
