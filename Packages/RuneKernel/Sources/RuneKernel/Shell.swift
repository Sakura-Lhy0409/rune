import Foundation

// MARK: - 自研命令解释器
//
// 设计依据（docs/05 §2.3）：**iOS 上没有真正的 shell 可给** ——
// `bash`/`zsh` 都需要 fork 子进程，而 App Store 应用不能 fork。
// a-Shell 的做法（也已上架验证）是：**每个命令注册成原生函数，由自研解释器调度**。
//
// 所以这一层的定位很明确：**不做通用 POSIX shell**，而是覆盖"模型最常用的那些管道表达"。
//
// ## 为什么"不支持什么"比"支持什么"更重要
//
// 模型对 shell 有很强的肌肉记忆。它一定会写出 `$(...)`、`if`、`heredoc`、`curl`。
// 如果这些只是**失败**，它就只会换个写法再试一次 —— 来回烧 token，最后还是不行。
//
// 所以每条不支持的语法都要给出**可执行的替代**：
//   * `$(...)` → "用两次调用，第一次的输出当第二次的参数"
//   * `curl`   → "用 `fetch_url` 工具（那会走出口白名单与审批）"
//   * `sed -i` → "用 `edit_file` / `apply_patch`（那才有检查点与回滚）"
//   * `python` → "用 `run_python`"
//
// 这一条把"shell 方言差异"从**模型要猜的事**变成**我们会说的事** ——
// 与修正性重试是同一个思路（docs/04 §4.4）。

// MARK: - 语法树

public struct ShellScript: Sendable, Hashable {
    /// 用 `;` / `&&` / `||` 连起来的若干条管道
    public var pipelines: [ShellPipeline]
    /// 连接符（比 pipelines 少一个）
    public var separators: [ShellSeparator]

    public init(pipelines: [ShellPipeline], separators: [ShellSeparator] = []) {
        self.pipelines = pipelines
        self.separators = separators
    }
}

public enum ShellSeparator: String, Sendable, Hashable, CaseIterable {
    /// `;` —— 无条件继续
    case always
    /// `&&` —— 上一条成功才继续
    case and
    /// `||` —— 上一条失败才继续
    case or
}

public struct ShellPipeline: Sendable, Hashable {
    public var commands: [ShellCommand]
    /// 该管道在原文里的样子（审计与回显）
    public var source: String

    public init(commands: [ShellCommand], source: String = "") {
        self.commands = commands
        self.source = source
    }

    public var isSingleCommand: Bool { commands.count == 1 }
}

public struct ShellCommand: Sendable, Hashable, Identifiable {
    public var id: Int
    public var executable: String
    public var arguments: [String]
    public var redirections: [ShellRedirection]

    public init(id: Int, executable: String, arguments: [String], redirections: [ShellRedirection] = []) {
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.redirections = redirections
    }

    /// 回显用（重定向之后）
    public var displayString: String {
        var parts = [executable] + arguments.map { argument in
            argument.contains(" ") || argument.contains("\"") || argument.contains("'")
                ? "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
                : argument
        }
        parts.append(contentsOf: redirections.map(\.displayString))
        return parts.joined(separator: " ")
    }
}

public struct ShellRedirection: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case stdin
        case stdout
        case stdoutAppend
        case stderr
        case stderrAppend
        /// `&>` —— 同时重定向 stdout 与 stderr
        case stdoutAndStderr
    }

    public var kind: Kind
    public var target: String

    public init(kind: Kind, target: String) {
        self.kind = kind
        self.target = target
    }

    public var displayString: String {
        switch kind {
        case .stdin: return "< \(target)"
        case .stdout: return "> \(target)"
        case .stdoutAppend: return ">> \(target)"
        case .stderr: return "2> \(target)"
        case .stderrAppend: return "2>> \(target)"
        case .stdoutAndStderr: return "&> \(target)"
        }
    }

    /// 是否会写文件（决定要不要走审批）
    public var writesFile: Bool {
        switch kind {
        case .stdin: return false
        case .stdout, .stdoutAppend, .stderr, .stderrAppend, .stdoutAndStderr: return true
        }
    }
}

// MARK: - 解析错误

public struct ShellParseError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        case empty
        /// 引号没闭合
        case unterminatedQuote
        /// 语法是我们**故意不支持**的（要给替代做法）
        case unsupported
        case trailingOperator
        case unexpectedToken
        case redirectionWithoutTarget
    }

    public var kind: Kind
    public var detail: String
    /// 出问题的片段（回显给模型，让它知道是哪一段）
    public var token: String
    public var position: Int
    /// **可执行的替代做法** —— 这一栏才是这个类型存在的理由
    public var suggestion: String?

    public init(kind: Kind, detail: String, token: String = "", position: Int = 0, suggestion: String? = nil) {
        self.kind = kind
        self.detail = detail
        self.token = token
        self.position = position
        self.suggestion = suggestion
    }

    public var description: String { detail }

    public var modelFacingText: String {
        var lines = [detail]
        if let suggestion { lines.append("👉 \(suggestion)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 分词

/// 一个词元
struct ShellToken: Equatable {
    enum Kind: Equatable {
        case word(String)
        case pipe          // |
        case or            // ||
        case and           // &&
        case semicolon     // ;
        case redirect(ShellRedirection.Kind)
    }
    var kind: Kind
    var raw: String
    var position: Int
}

enum ShellTokenizer {

    static let operators: [(String, ShellToken.Kind)] = [
        ("&>>", .redirect(.stdoutAndStderr)),
        ("&>", .redirect(.stdoutAndStderr)),
        ("2>>", .redirect(.stderrAppend)),
        ("2>", .redirect(.stderr)),
        (">>", .redirect(.stdoutAppend)),
        (">", .redirect(.stdout)),
        ("<", .redirect(.stdin)),
        ("||", .or),
        ("&&", .and),
        ("|", .pipe),
        (";", .semicolon),
    ]

    /// 我们**故意不支持**的语法。命中即给替代做法。
    ///
    /// ⚠️ 顺序有意义：`<<` 要在 `<` 之前判，`$((` 要在 `$(` 之前判。
    /// ⚠️ 顺序有意义：更长的前缀必须排在前面（`$((` 在 `$(` 之前、`<<<` 在 `<<` 之前），
    ///    否则会给出错误的替代建议。
    static let unsupported: [(String, String, String)] = [
        ("$((", "算术展开 `$((...))`",
         "我们的 shell 没有算术。计算请用 `run_python`。"),
        ("$((", "算术展开",
         "计算请用 `run_python`。"),
        ("$(", "命令替换 `$(...)`",
         "我们的 shell 不做命令替换。请**分两次调用**：先跑内层命令，拿到输出后把它作为参数传进下一条。"),
        ("`", "反引号命令替换",
         "我们的 shell 不做命令替换。请分两次调用。"),
        ("${", "变量展开 `${...}`",
         "我们的 shell 没有变量。需要复用某段文本时，直接把它写进命令里。"),
        ("<<<", "here-string `<<<`",
         "here-string 不支持。请用管道把内容喂给命令。"),
        ("<<", "heredoc `<<`",
         "heredoc 不支持。请先把内容写进文件（`write_file`），再用 `<` 读取。"),
        ("((", "算术求值 `((...))`",
         "算术请用 `run_python`。"),
    ]

    /// 控制结构关键字（作为**第一个词**出现时才算）
    static let controlKeywords: [(String, String)] = [
        ("if", "条件语句 `if`"),
        ("then", "`then`"),
        ("elif", "`elif`"),
        ("else", "`else`"),
        ("fi", "`fi`"),
        ("for", "循环 `for`"),
        ("while", "循环 `while`"),
        ("until", "循环 `until`"),
        ("do", "`do`"),
        ("done", "`done`"),
        ("case", "`case`"),
        ("esac", "`esac`"),
        ("function", "函数定义"),
    ]

    static func tokenize(_ input: String) throws -> [ShellToken] {
        var tokens: [ShellToken] = []
        var current = ""
        var currentStart = 0
        var index = input.startIndex
        var offset = 0
        var inWord = false

        func flush() {
            if inWord {
                tokens.append(ShellToken(kind: .word(current), raw: current, position: currentStart))
                current = ""
                inWord = false
            }
        }

        while index < input.endIndex {
            let character = input[index]

            // ---------- 空白 ----------
            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                flush()
                index = input.index(after: index)
                offset += 1
                continue
            }

            // ---------- 不支持的语法（先查，因为它可能跨越引号边界） ----------
            let remainder = String(input[index...])
            for (needle, name, suggestion) in unsupported where !name.isEmpty {
                if remainder.hasPrefix(needle) {
                    throw ShellParseError(
                        kind: .unsupported,
                        detail: "不支持 \(name)。",
                        token: needle, position: offset, suggestion: suggestion
                    )
                }
            }

            // ---------- 单引号（内部一切字面） ----------
            if character == "'" {
                let start = offset
                index = input.index(after: index); offset += 1
                var literal = ""
                var closed = false
                while index < input.endIndex {
                    if input[index] == "'" { closed = true; index = input.index(after: index); offset += 1; break }
                    literal.append(input[index])
                    index = input.index(after: index); offset += 1
                }
                guard closed else {
                    throw ShellParseError(kind: .unterminatedQuote, detail: "单引号没有闭合。",
                                          token: literal, position: start,
                                          suggestion: "补上收尾的 `'`；如果字符串里本来就有单引号，用双引号包起来。")
                }
                current += literal
                inWord = true
                continue
            }

            // ---------- 双引号（允许 \" \\ \$ 三种转义） ----------
            if character == "\"" {
                let start = offset
                index = input.index(after: index); offset += 1
                var literal = ""
                var closed = false
                while index < input.endIndex {
                    let c = input[index]
                    if c == "\\" {
                        let next = input.index(after: index)
                        guard next < input.endIndex else { break }
                        let escaped = input[next]
                        // POSIX：双引号内只有 $ ` " \ 与换行前的反斜杠有特殊含义
                        if escaped == "\"" || escaped == "\\" || escaped == "$" || escaped == "`" {
                            literal.append(escaped)
                        } else {
                            literal.append("\\")
                            literal.append(escaped)
                        }
                        index = input.index(after: next); offset += 2
                        continue
                    }
                    if c == "\"" { closed = true; index = input.index(after: index); offset += 1; break }
                    // ⚠️ 双引号里我们**也不做变量展开**（POSIX 会做）。
                    //    不报错的话，模型会拿到字面量 `$X` 而以为拿到了值 —— 那是静默的错误答案。
                    if c == "$" {
                        let next = input.index(after: index)
                        if next < input.endIndex {
                            let after = input[next]
                            if after.isLetter || after.isNumber || after == "_" || after == "{" {
                                throw ShellParseError(
                                    kind: .unsupported, detail: "双引号里也不支持变量展开 `$\(after)…`。",
                                    token: "$", position: offset,
                                    suggestion: "把要用的值直接写进命令里；只想要字面量 `$` 的话用单引号。"
                                )
                            }
                        }
                    }
                    literal.append(c)
                    index = input.index(after: index); offset += 1
                }
                guard closed else {
                    throw ShellParseError(kind: .unterminatedQuote, detail: "双引号没有闭合。",
                                          token: literal, position: start,
                                          suggestion: "补上收尾的 `\"`。")
                }
                current += literal
                inWord = true
                continue
            }

            // ---------- 反斜杠转义 ----------
            if character == "\\" {
                let next = input.index(after: index)
                guard next < input.endIndex else {
                    throw ShellParseError(kind: .unterminatedQuote, detail: "行尾的 `\\` 后面没有东西可转义。",
                                          position: offset,
                                          suggestion: "去掉它，或用引号把整段包起来。")
                }
                current.append(input[next])
                inWord = true
                index = input.index(after: next); offset += 2
                continue
            }

            // ---------- `#` 注释：只在词的起始位置生效（POSIX 语义） ----------
            if character == "#", !inWord {
                break   // 余下全部是注释
            }

            // ---------- 操作符 ----------
            if !inWord || character == "|" || character == ">" || character == "<" || character == ";" || character == "&" {
                var matched = false
                for (text, kind) in operators where remainder.hasPrefix(text) {
                    // `&` 不在表里 → 落到下面的"后台执行"拒绝
                    flush()
                    tokens.append(ShellToken(kind: kind, raw: text, position: offset))
                    index = input.index(index, offsetBy: text.count); offset += text.count
                    matched = true
                    break
                }
                if matched { continue }

                // `&` 单独出现 = 后台执行，不支持
                if remainder.hasPrefix("&") {
                    throw ShellParseError(
                        kind: .unsupported, detail: "不支持后台执行 `&`。",
                        token: "&", position: offset,
                        suggestion: "长任务请用 `start_job` 工具（它天然支持后台、增量读输出与取消）。"
                    )
                }
                // `!` 取反、`(` `)` 子 shell、`{` `}` 分组
                if remainder.hasPrefix("(") || remainder.hasPrefix(")") {
                    throw ShellParseError(
                        kind: .unsupported, detail: "不支持子 shell `( ... )`。",
                        token: "(", position: offset,
                        suggestion: "把里面的命令直接顺序写出来（用 `;` 或 `&&` 连接）。"
                    )
                }
                if remainder.hasPrefix("!") {
                    throw ShellParseError(
                        kind: .unsupported, detail: "不支持管道取反 `!`。",
                        token: "!", position: offset,
                        suggestion: "把判断逻辑放到 `run_python` 里做，或用 `||` 表达。"
                    )
                }
                // ⚠️ 裸 `$VAR` 必须被拒绝，**不能放过去**。
                //
                //    放过去的后果是静默的错误答案：模型以为 `$HOME` 会展开，
                //    实际上命令收到的是字面量字符串 `$HOME` —— 命令会以一种
                //    完全看不懂的方式失败（比如"找不到文件 $HOME/x"）。
                //    拒绝 + 说清"没有变量"比这好得多。
                if remainder.hasPrefix("$"), remainder.count > 1 {
                    let next = remainder[remainder.index(after: remainder.startIndex)]
                    if next.isLetter || next.isNumber || next == "_" || next == "{" {
                        throw ShellParseError(
                            kind: .unsupported, detail: "不支持变量展开 `$\(next)…`。",
                            token: "$", position: offset,
                            suggestion: "我们的 shell 没有变量。需要复用某段文本时，直接把它写进命令里；如果确实要一个字面量 `$`，用单引号包起来。"
                        )
                    }
                }

                // `~` 只在**词首**才是家目录展开（`a~b` 里的波浪号是普通字符）
                if !inWord, remainder.hasPrefix("~") {
                    throw ShellParseError(
                        kind: .unsupported, detail: "不支持 `~` 家目录展开。",
                        token: "~", position: offset,
                        suggestion: "没有家目录概念。请用工作区内的相对路径（例如 `src/a.py`）。"
                    )
                }
            }

            if !inWord { currentStart = offset }
            current.append(character)
            inWord = true
            index = input.index(after: index); offset += 1
        }

        flush()
        return tokens
    }
}

// MARK: - 解析

public enum ShellParser {

    /// 命令名是控制关键字的第一条命令 → 明确拒绝
    static func rejectControlKeyword(_ token: ShellToken) throws {
        guard case .word(let word) = token.kind, !word.isEmpty else { return }
        for (keyword, name) in ShellTokenizer.controlKeywords where word == keyword {
            throw ShellParseError(
                kind: .unsupported, detail: "不支持 \(name)。我们的 shell 只做「命令 + 管道 + 重定向」，没有控制流。",
                token: word, position: token.position,
                suggestion: "需要循环或条件请用 `run_python`（或 `run_javascript`）—— 那是完整的程序语言。"
            )
        }
    }

    public static func parse(_ command: String) -> Result<ShellScript, ShellParseError> {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ShellParseError(kind: .empty, detail: "命令是空的。",
                                            suggestion: "给出要执行的命令，例如 `git status --short`。"))
        }

        let tokens: [ShellToken]
        do {
            tokens = try ShellTokenizer.tokenize(command)
        } catch let error as ShellParseError {
            return .failure(error)
        } catch {
            return .failure(ShellParseError(kind: .unexpectedToken, detail: "解析失败：\(error)"))
        }

        var pipelines: [ShellPipeline] = []
        var separators: [ShellSeparator] = []
        /// 正在拼的那条命令；`nil` 表示"下一个词是命令名"
        var current: ShellCommand?
        var finished: [ShellCommand] = []
        var nextID = 0
        var pendingRedirection: (ShellRedirection.Kind, ShellToken)?

        func closeCommand() {
            if let command = current { finished.append(command); current = nil }
        }
        func closePipeline() {
            closeCommand()
            guard !finished.isEmpty else { return }
            pipelines.append(ShellPipeline(
                commands: finished,
                source: finished.map(\.displayString).joined(separator: " | ")
            ))
            finished = []
        }

        for token in tokens {
            // ---------- 重定向之后必须紧跟目标 ----------
            if let (kind, operatorToken) = pendingRedirection {
                guard case .word(let target) = token.kind, var command = current else {
                    return .failure(ShellParseError(
                        kind: .redirectionWithoutTarget,
                        detail: "重定向 `\(operatorToken.raw)` 后面缺少文件名。",
                        token: operatorToken.raw, position: operatorToken.position,
                        suggestion: "补上目标路径，例如 `> /workspace/out.txt`。"
                    ))
                }
                command.redirections.append(ShellRedirection(kind: kind, target: target))
                current = command
                pendingRedirection = nil
                continue
            }

            switch token.kind {
            case .word(let word):
                if var command = current {
                    command.arguments.append(word)
                    current = command
                } else {
                    // 这是**命令名**的位置 —— 也只有在此时才把控制关键字当关键字
                    do { try rejectControlKeyword(token) } catch let error as ShellParseError { return .failure(error) } catch {}
                    current = ShellCommand(id: nextID, executable: word, arguments: [])
                    nextID += 1
                }

            case .redirect(let kind):
                guard current != nil else {
                    return .failure(ShellParseError(
                        kind: .unexpectedToken, detail: "重定向出现在命令名之前。",
                        token: token.raw, position: token.position,
                        suggestion: "先写命令再写重定向，例如 `ls > out.txt`。"
                    ))
                }
                pendingRedirection = (kind, token)

            case .pipe:
                guard current != nil else {
                    return .failure(ShellParseError(
                        kind: .unexpectedToken, detail: "管道 `|` 前面没有命令。",
                        token: "|", position: token.position,
                        suggestion: "补上左边的命令。"
                    ))
                }
                closeCommand()

            case .and, .or, .semicolon:
                guard current != nil || !finished.isEmpty else {
                    return .failure(ShellParseError(
                        kind: .unexpectedToken, detail: "连接符 `\(token.raw)` 前面没有命令。",
                        token: token.raw, position: token.position,
                        suggestion: "去掉多余的连接符，或补上左边的命令。"
                    ))
                }
                separators.append(token.kind == .and ? .and : (token.kind == .or ? .or : .always))
                closePipeline()
            }
        }

        // ---------- 收尾检查 ----------
        if let (_, operatorToken) = pendingRedirection {
            return .failure(ShellParseError(
                kind: .redirectionWithoutTarget,
                detail: "重定向 `\(operatorToken.raw)` 后面缺少文件名。",
                token: operatorToken.raw, position: operatorToken.position,
                suggestion: "补上目标路径。"
            ))
        }
        if let last = tokens.last, last.kind == .and || last.kind == .or {
            let raw = last.kind == .and ? "&&" : "||"
            return .failure(ShellParseError(
                kind: .trailingOperator, detail: "命令以 `\(raw)` 结尾，后面没有东西。",
                token: raw, position: last.position,
                suggestion: "去掉结尾的 `\(raw)`，或补上后面的命令。"
            ))
        }
        closePipeline()

        guard !pipelines.isEmpty else {
            return .failure(ShellParseError(kind: .empty, detail: "没有解析出任何命令。",
                                            suggestion: "给出一条要执行的命令。"))
        }
        // 连接符必须恰好比管道少一个；多出来的（例如 `a ; ; b`）已经被上面的空段检查挡掉
        if separators.count != pipelines.count - 1 {
            separators = Array(separators.prefix(max(0, pipelines.count - 1)))
        }
        return .success(ShellScript(pipelines: pipelines, separators: separators))
    }
}
// MARK: - 命令表
//
// ⚠️ **这里是"我们的 shell 里到底有什么"的唯一真相源。**
// 模型调一个不在表里的命令，我们会给"最接近的那个"或"该用哪个工具"的建议 ——
// 而不是让它在原生层抛一个看不懂的错误。

public enum ShellCommandTable {

    public struct Entry: Sendable, Hashable {
        public enum Implementation: String, Sendable, Hashable {
            /// 原生 Swift 实现（随包）
            case native
            /// 随包 WASI 模块（`zip`/`unzip`/`xz`）
            case wasm
            /// 解释器内建（不产生输出、或不读文件）
            case builtin
        }
        public var name: String
        public var summary: String
        public var implementation: Implementation
        /// 是否是我们实现的**子集**（要在帮助里说清楚，否则模型会以为它是完整的）
        public var isSubset: Bool
        /// 建议优先使用的工具（同功能但更安全/更省上下文）
        public var preferTool: String?

        public init(name: String, summary: String, implementation: Implementation = .native,
                    isSubset: Bool = false, preferTool: String? = nil) {
            self.name = name
            self.summary = summary
            self.implementation = implementation
            self.isSubset = isSubset
            self.preferTool = preferTool
        }
    }

    /// docs/05 §5.1 的"自研 shell 解释器"清单 + 少量必要的补充
    public static let entries: [Entry] = [
        Entry(name: "echo", summary: "输出参数", implementation: .builtin),
        Entry(name: "pwd", summary: "打印当前工作区路径", implementation: .builtin),
        Entry(name: "true", summary: "总是成功（退出码 0）", implementation: .builtin),
        Entry(name: "false", summary: "总是失败（退出码 1）", implementation: .builtin),
        Entry(name: "ls", summary: "列目录", preferTool: "list_dir"),
        Entry(name: "cat", summary: "输出文件内容", preferTool: "read_file"),
        Entry(name: "head", summary: "取前 N 行", preferTool: "read_file"),
        Entry(name: "tail", summary: "取后 N 行", preferTool: "read_file"),
        Entry(name: "wc", summary: "统计行/词/字节"),
        Entry(name: "sort", summary: "排序"),
        Entry(name: "uniq", summary: "去重相邻重复行"),
        Entry(name: "cut", summary: "按列切分"),
        Entry(name: "tr", summary: "字符替换/删除"),
        Entry(name: "sed", summary: "流编辑（**子集**：只支持 s/// 与 -n p）", isSubset: true,
              preferTool: "edit_file"),
        Entry(name: "grep", summary: "按行匹配（**子集**：不支持 -P/-z）", isSubset: true,
              preferTool: "grep_search"),
        Entry(name: "find", summary: "按名字/类型查找（**子集**）", isSubset: true, preferTool: "glob"),
        Entry(name: "xargs", summary: "把 stdin 展开成参数"),
        Entry(name: "diff", summary: "比较两个文件", preferTool: "git_diff"),
        Entry(name: "patch", summary: "应用补丁", preferTool: "apply_patch"),
        Entry(name: "mkdir", summary: "建目录", preferTool: "make_dir"),
        Entry(name: "rm", summary: "删除（**默认进回收站**）", preferTool: "delete_path"),
        Entry(name: "mv", summary: "移动/重命名", preferTool: "move_path"),
        Entry(name: "cp", summary: "复制", preferTool: "copy_path"),
        Entry(name: "touch", summary: "创建空文件/更新时间戳"),
        Entry(name: "stat", summary: "查看文件信息", preferTool: "stat_path"),
        Entry(name: "du", summary: "统计目录占用"),
        Entry(name: "base64", summary: "base64 编解码"),
        Entry(name: "tar", summary: "打包/解包（**子集**，无压缩时优先用它）", isSubset: true),
        Entry(name: "gzip", summary: "gzip 压缩"),
        Entry(name: "gunzip", summary: "gzip 解压"),
        Entry(name: "zip", summary: "打包为 zip", implementation: .wasm),
        Entry(name: "unzip", summary: "解压 zip", implementation: .wasm),
        Entry(name: "xz", summary: "xz 压缩", implementation: .wasm),
        Entry(name: "git", summary: "Git（映射到原生 libgit2；写操作走对应的 git_* 工具）"),
        Entry(name: "sha256sum", summary: "算校验和", preferTool: "hash_file"),
    ]

    public static let byName: [String: Entry] = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

    /// 与工具重名但**不该在 shell 里跑**的东西（跑法不同，或者根本做不到）
    public static let redirectedCommands: [String: (reason: String, suggestion: String)] = [
        "curl": ("我们的 shell 没有网络能力。",
                 "用 `fetch_url` 工具 —— 它会走出口白名单、大小上限与审批。"),
        "wget": ("我们的 shell 没有网络能力。",
                 "用 `download_file` 工具 —— 它带大小上限与类型校验。"),
        "ssh": ("没有网络、也没有 fork。", "iOS 上跑不了 ssh。需要远端操作请用 `http_request` 调 API。"),
        "scp": ("没有网络、也没有 fork。", "用 `download_file` / `http_request`。"),
        "python": ("`python` 在 shell 里跑不了（需要 fork）。",
                   "用 `run_python` 工具 —— 它就是原生 CPython，而且带资源限额。"),
        "python3": ("`python` 在 shell 里跑不了（需要 fork）。", "用 `run_python`。"),
        "pip": ("`pip` 需要 fork 与网络。", "纯 Python 包的安装请通过 `run_python` 里的包管理接口。"),
        "node": ("`node` 在 iOS 上不可用。", "用 `run_javascript` 工具（JSC 沙箱）。"),
        "npm": ("`npm` 需要 fork 与网络。", "依赖安装不在设备上做；请用随包工具链。"),
        "make": ("`make` 需要 fork 子进程。", "用 `run_build`（它会自动探测构建系统并执行）。"),
        "cmake": ("`cmake` 需要 fork 子进程。", "用 `run_build`。"),
        "bash": ("`bash` 本身就是需要 fork 的进程。", "直接把命令写出来（我们的 shell 会解析管道）或放进 `run_shell` 里顺序执行。"),
        "sh": ("`sh` 本身就是需要 fork 的进程。", "直接把命令写出来。"),
        "zsh": ("`zsh` 本身就是需要 fork 的进程。", "直接把命令写出来。"),
        "sudo": ("iOS 上没有 sudo 这个概念。", "需要更高权限请让用户手动操作。"),
        "chmod": ("（我们只支持有限的权限模型）", "文件权限不在 VFS 的语义里；请说明为什么需要它。"),
        "open": ("（这是 macOS 的命令）", "要在别的 App 里打开东西，用 `open_url` 工具。"),
        "source": ("不支持 `source`（没有子 shell 环境可继承）。", "把脚本内容直接写出来，或用 `run_python`。"),
        "export": ("不支持环境变量。", "需要配置请直接写进命令参数。"),
        "cd": ("我们的 shell **没有持久工作目录**（每次调用都是独立的）。",
               "用 `run_shell` 的 `cwd` 参数指定工作目录，或在命令里用相对/绝对 VFS 路径。"),
        "clear": ("没有终端可清。", "直接忽略即可。"),
        "man": ("没有 man 手册。", "用 `list_dir` / `read_file` 看项目自己的文档。"),
    ]

    /// 最接近的命令名（模型拼错或用了别的方言时给建议）
    public static func nearest(to name: String) -> String? {
        var best: (name: String, distance: Int)?
        for entry in entries {
            let distance = SkillSearch.editDistance(name.lowercased(), entry.name.lowercased())
            if distance < (best?.distance ?? Int.max) { best = (entry.name, distance) }
        }
        guard let best, best.distance <= max(2, name.count / 2) else { return nil }
        return best.name
    }
}

// MARK: - 校验（把"跑不通的命令"变成"可执行的建议"）

public struct ShellIssue: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        case unknownCommand
        case redirectedToTool
        case dangerousInShell
        case writesFileNeedsApproval
        case tooManyCommands
        case gitWriteInShell
    }
    public var kind: Kind
    public var command: String
    public var detail: String
    public var suggestion: String?

    public init(kind: Kind, command: String, detail: String, suggestion: String? = nil) {
        self.kind = kind
        self.command = command
        self.detail = detail
        self.suggestion = suggestion
    }

    public var description: String { "[\(kind.rawValue)] \(command)：\(detail)" }
    public var modelFacingText: String {
        var lines = [detail]
        if let suggestion { lines.append("👉 \(suggestion)") }
        return lines.joined(separator: "\n")
    }
}

/// 命令里**不该在 shell 里做**的 git 子命令（它们有专门的工具，且带审批与审计）
public let shellForbiddenGitSubcommands: [String: String] = [
    "push": "git_push", "commit": "git_commit", "add": "git_add", "reset": "git_checkout",
    "clean": "git_checkout", "checkout": "git_checkout", "stash": "git_stash",
    "clone": "git_clone", "fetch": "git_fetch", "pull": "git_pull", "branch": "git_branch",
]

public enum ShellValidator {

    public struct Limits: Sendable, Hashable {
        public var maxCommands: Int
        public var maxArguments: Int
        public var maxCommandLength: Int

        public init(maxCommands: Int = 24, maxArguments: Int = 200, maxCommandLength: Int = 8_000) {
            self.maxCommands = max(1, maxCommands)
            self.maxArguments = max(1, maxArguments)
            self.maxCommandLength = max(64, maxCommandLength)
        }

        public static let mobile = Limits()
    }

    public static func validate(
        _ script: ShellScript,
        original: String = "",
        limits: Limits = .mobile
    ) -> [ShellIssue] {
        var issues: [ShellIssue] = []

        let commandCount = script.pipelines.reduce(0) { $0 + $1.commands.count }
        if commandCount > limits.maxCommands {
            issues.append(ShellIssue(
                kind: .tooManyCommands, command: original,
                detail: "一条命令里串了 \(commandCount) 个命令，超过上限 \(limits.maxCommands)。",
                suggestion: "拆成几次调用 —— 这样每次的失败都能单独定位与重试。"
            ))
        }
        if original.count > limits.maxCommandLength {
            issues.append(ShellIssue(kind: .tooManyCommands, command: String(original.prefix(80)),
                                     detail: "命令过长（\(original.count) 字符）。",
                                     suggestion: "把长脚本写进文件后用 `run_python` 执行。"))
        }

        for pipeline in script.pipelines {
            for command in pipeline.commands {
                if command.arguments.count > limits.maxArguments {
                    issues.append(ShellIssue(kind: .tooManyCommands, command: command.executable,
                                             detail: "参数过多（\(command.arguments.count) 个）。",
                                             suggestion: "用 `xargs` 或写进脚本。"))
                }

                let name = command.executable

                // ---------- 该用工具的 ----------
                if let redirect = ShellCommandTable.redirectedCommands[name] {
                    issues.append(ShellIssue(kind: .redirectedToTool, command: name,
                                             detail: redirect.reason, suggestion: redirect.suggestion))
                    continue
                }

                // ---------- 不在表里的 ----------
                guard let entry = ShellCommandTable.byName[name] else {
                    let nearest = ShellCommandTable.nearest(to: name)
                    issues.append(ShellIssue(
                        kind: .unknownCommand, command: name,
                        detail: "我们的 shell 里没有 `\(name)` 这个命令。",
                        suggestion: nearest.map { "你是不是想用 `\($0)`？" }
                            ?? "可用命令请见 `run_shell` 的说明；复杂处理请用 `run_python`。"
                    ))
                    continue
                }

                // ---------- git 的写操作要走去审批的工具 ----------
                if entry.name == "git", let subcommand = command.arguments.first,
                   let replacement = shellForbiddenGitSubcommands[subcommand] {
                    issues.append(ShellIssue(
                        kind: .gitWriteInShell, command: "git \(subcommand)",
                        detail: "`git \(subcommand)` 会改动仓库状态，在 shell 里做会绕过审批与审计。",
                        suggestion: "用 `\(replacement)` 工具 —— 它会展示影响面并要求确认。"
                    ))
                    continue
                }

                // ---------- 重定向写文件要知情 ----------
                if command.redirections.contains(where: \.writesFile) {
                    issues.append(ShellIssue(
                        kind: .writesFileNeedsApproval, command: command.displayString,
                        detail: "重定向会改写工作区里的文件。",
                        suggestion: "如果只是想改文件中几行，用 `edit_file` / `apply_patch` 更安全（有检查点可回滚）。"
                    ))
                }

                // ---------- `sed -i` 就地改写：这是最容易悄悄改坏文件的方式 ----------
                if entry.name == "sed", command.arguments.contains(where: { $0 == "-i" || $0.hasPrefix("-i.") || $0.hasPrefix("-i'") }) {
                    issues.append(ShellIssue(
                        kind: .dangerousInShell, command: command.displayString,
                        detail: "`sed -i` 会就地改写文件，且没有检查点。",
                        suggestion: "用 `edit_file`（唯一匹配才替换）或 `apply_patch`（一次多处、失败整体不落地）。"
                    ))
                }
            }
        }
        return issues
    }

    /// 只要有一条"必须改"的问题就不该执行。
    ///
    /// ⚠️ `writesFileNeedsApproval` 只是**知情**，不是错误 —— 重定向是合法用法，
    /// 只是要走审批（由运行时决定）。把它当成错误会把正常用法也堵死。
    public static func blockingIssues(_ issues: [ShellIssue]) -> [ShellIssue] {
        issues.filter { $0.kind != .writesFileNeedsApproval }
    }
}




// MARK: - 执行
//
// ⚠️ **这一层不碰任何真实 IO。** 命令实现与重定向落点都是注入的：
// 这样整条"管道 → 短路 → 重定向 → 退出码"的语义**可以完全确定性地测试**，
// 而真实实现（原生命令 / WASI 模块 / VFS）只是替换掉两个协议。
//
// 与 `TurnRunner`、`WorkflowEngine` 是同一套哲学：**引擎只负责语义，IO 由外部提供。**

public struct ShellInvocation: Sendable {
    public var command: ShellCommand
    /// 上游喂进来的字节（管道左边那条命令的输出）
    public var stdin: Data

    public init(command: ShellCommand, stdin: Data = Data()) {
        self.command = command
        self.stdin = stdin
    }
}

public struct ShellIOResult: Sendable {
    public var stdout: Data
    public var stderr: Data
    public var exitCode: Int32

    public init(stdout: Data = Data(), stderr: Data = Data(), exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public static func text(_ output: String, code: Int32 = 0) -> ShellIOResult {
        ShellIOResult(stdout: Data(output.utf8), exitCode: code)
    }
}

/// 一个命令的实现。真实实现是原生 Swift（`ls`/`cat`/`grep`…）或 WASI 模块。
public protocol ShellCommandImplementation: Sendable {
    func run(_ invocation: ShellInvocation) throws -> ShellIOResult
}

/// 命令实现的来源。
///
/// ⚠️ 做成协议而不是直接传字典，是因为真实实现需要**分层查找**：
/// 原生命令表 → 随包 WASI 模块表 → （未来）用户放的 wasm 模块。
/// 直接传字典的话，这个分层只能写在调用方，于是每个调用方都会写得不一样。
public protocol ShellCommandProvider: Sendable {
    func implementation(for name: String) -> (any ShellCommandImplementation)?
}

/// 默认实现：先查原生命令表，再查随包 WASI 模块表。
public struct ShellCommandRegistry: ShellCommandProvider {
    public var native: [String: any ShellCommandImplementation]
    public var wasm: [String: any ShellCommandImplementation]

    public init(
        native: [String: any ShellCommandImplementation] = [:],
        wasm: [String: any ShellCommandImplementation] = [:]
    ) {
        self.native = native
        self.wasm = wasm
    }

    public func implementation(for name: String) -> (any ShellCommandImplementation)? {
        native[name] ?? wasm[name]
    }
}

/// 重定向的落点。真实实现走 `VFS`（因此受路径钳制与审批约束）。
public protocol ShellRedirectionSink: Sendable {
    func read(_ path: String) throws -> Data
    func write(_ path: String, data: Data, append: Bool) throws
}

public struct ShellRunLimits: Sendable, Hashable {
    /// 单条命令的输出上限（**超出部分不丢，转制品** —— 由调用方负责）
    public var maxOutputBytesPerCommand: Int
    /// 整次运行的输出上限（防"17 条命令各吐 2MB"）
    public var maxTotalOutputBytes: Int
    /// 安全阀：最多执行多少条命令
    public var maxCommands: Int

    public init(maxOutputBytesPerCommand: Int = 256 * 1024,
                maxTotalOutputBytes: Int = 2 * 1024 * 1024,
                maxCommands: Int = 24) {
        self.maxOutputBytesPerCommand = max(1024, maxOutputBytesPerCommand)
        self.maxTotalOutputBytes = max(1024, maxTotalOutputBytes)
        self.maxCommands = max(1, maxCommands)
    }

    public static let mobile = ShellRunLimits()
}

public struct ShellRunOptions: Sendable, Hashable {
    /// 遇到失败就停下。
    ///
    /// ⚠️ 默认 **true**（POSIX shell 默认是继续，但对 Agent 来说"继续"更危险）：
    /// `rm -rf build && make` 里前半失败却继续跑后半，是很容易造成损失的一类事故；
    /// 而"停下来把失败报给模型"几乎总是更好的选择 —— 模型能看懂失败并调整。
    public var stopOnError: Bool
    /// 重定向的目标路径解析基准（相对路径按它解析）
    public var basePath: VFSPath

    public init(stopOnError: Bool = true, basePath: VFSPath = VFSPath(mount: .workspace)) {
        self.stopOnError = stopOnError
        self.basePath = basePath
    }

    public static let agentDefault = ShellRunOptions()
}

public struct ShellCommandOutput: Sendable, Hashable {
    public var command: String
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var wasTruncated: Bool
    /// 这条命令的 stdout 被管道下游吃掉了（它是**中间环节**）。
    ///
    /// ⚠️ 有这一位才不会把同一份内容喂给模型两次：
    /// `echo hello | upper` 里 `hello` 是管道的载荷，不是结果 ——
    /// 把它算进"可见输出"会让模型同时看到 `hello` 与 `HELLO`，还以为命令跑了两遍。
    public var isPiped: Bool

    public init(command: String, stdout: String, stderr: String, exitCode: Int32,
                wasTruncated: Bool = false, isPiped: Bool = false) {
        self.command = command
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.wasTruncated = wasTruncated
        self.isPiped = isPiped
    }

    /// 给模型看的 stdout（管道中间环节为空）
    public var visibleStdout: String { isPiped ? "" : stdout }
}

public struct ShellRunResult: Sendable, Hashable {
    /// 整条命令的退出码（POSIX：最后一条的退出码）
    public var exitCode: Int32
    public var outputs: [ShellCommandOutput]
    /// 因为短路（`&&` / `||`）或"失败即停"而**没有执行**的命令
    public var skipped: [String]
    public var wasTruncated: Bool
    public var stoppedEarly: Bool

    public var combinedStdout: String { outputs.map(\.visibleStdout).joined() }
    public var combinedStderr: String { outputs.map(\.stderr).joined() }
    public var succeeded: Bool { exitCode == 0 }

    /// 给模型看的一段摘要（**只保留最后一条命令的输出 + 失败信息**）
    ///
    /// ⚠️ 不是把所有输出拼起来：管道中间环节的输出通常对模型没用，
    /// 而"最后一条的结果 + 谁失败了"才是它判断下一步需要的东西。
    public var modelFacingSummary: String {
        var lines: [String] = []
        if let failed = outputs.last(where: { $0.exitCode != 0 }) {
            lines.append("命令 `\(failed.command)` 失败（退出码 \(failed.exitCode)）")
            if !failed.stderr.isEmpty { lines.append(failed.stderr) }
            if !failed.stdout.isEmpty { lines.append(failed.stdout) }
        }
        if let last = outputs.last, last.exitCode == 0, !last.visibleStdout.isEmpty {
            lines.append(last.visibleStdout)
        }
        if !skipped.isEmpty {
            lines.append("（未执行：\(skipped.joined(separator: "、"))）")
        }
        return lines.joined(separator: "\n")
    }
}

public enum ShellInterpreter {

    /// 输出截断：**保头也保尾**。
    ///
    /// ⚠️ 只保头是最常见的错误做法：命令输出的**结论**通常在最后几行
    /// （测试的 `12 passed`、构建的 `Build succeeded`、错误栈的最后一行）。
    /// 砍掉尾巴等于把最有用的信息扔掉、留一堆中间过程。
    public static func truncate(_ data: Data, to limit: Int) -> (data: Data, wasTruncated: Bool) {
        guard data.count > limit else { return (data, false) }
        let headBytes = limit * 3 / 5
        let tailBytes = limit - headBytes
        var truncated = data.prefix(headBytes)
        truncated.append(Data("\n…（中间省略 \(data.count - limit) 字节）…\n".utf8))
        truncated.append(data.suffix(tailBytes))
        return (truncated, true)
    }

    /// 执行一个脚本。
    public static func run(
        _ script: ShellScript,
        commands: [String: any ShellCommandImplementation],
        redirections: (any ShellRedirectionSink)? = nil,
        limits: ShellRunLimits = .mobile,
        options: ShellRunOptions = .agentDefault
    ) -> ShellRunResult {
        run(script, provider: ShellCommandRegistry(native: commands), redirections: redirections,
            limits: limits, options: options)
    }

    /// 执行一个脚本（命令实现由 provider 分层提供）。
    public static func run(
        _ script: ShellScript,
        provider: any ShellCommandProvider,
        redirections: (any ShellRedirectionSink)? = nil,
        limits: ShellRunLimits = .mobile,
        options: ShellRunOptions = .agentDefault
    ) -> ShellRunResult {
        var outputs: [ShellCommandOutput] = []
        var skipped: [String] = []
        var totalOutput = 0
        var anyTruncated = false
        var stoppedEarly = false
        var lastExitCode: Int32 = 0
        var executed = 0

        for (index, pipeline) in script.pipelines.enumerated() {
            // ---------- 短路判定（`&&` / `||`）----------
            if index > 0 {
                let separator = index - 1 < script.separators.count ? script.separators[index - 1] : .always
                let shouldRun: Bool
                switch separator {
                case .always: shouldRun = true
                case .and: shouldRun = lastExitCode == 0
                case .or: shouldRun = lastExitCode != 0
                }
                if !shouldRun {
                    skipped.append(contentsOf: pipeline.commands.map(\.displayString))
                    continue
                }
            }

            // ---------- 安全阀 ----------
            if executed >= limits.maxCommands {
                skipped.append(contentsOf: script.pipelines[index...].flatMap { $0.commands.map(\.displayString) })
                stoppedEarly = true
                break
            }

            // ---------- 管道：逐条串联 ----------
            var stdin = Data()
            var pipelineExit: Int32 = 0
            var pipelineFailed = false

            for command in pipeline.commands {
                executed += 1
                var stdout = Data()
                var stderr = Data()
                var code: Int32 = 0
                var truncated = false

                // 输入重定向优先于管道（POSIX 语义）
                if let input = command.redirections.first(where: { $0.kind == .stdin }) {
                    if let sink = redirections {
                        do {
                            stdin = try sink.read(resolve(input.target, base: options.basePath))
                        } catch {
                            stderr = Data("无法读取 \(input.target)：\(error)".utf8)
                            code = 1
                        }
                    } else {
                        stderr = Data("这个运行环境没有提供文件读取能力，`<` 无法生效。".utf8)
                        code = 1
                    }
                }

                if code == 0, let implementation = provider.implementation(for: command.executable) {
                    do {
                        let result = try implementation.run(ShellInvocation(command: command, stdin: stdin))
                        stdout = result.stdout
                        stderr = result.stderr
                        code = result.exitCode
                    } catch {
                        stderr = Data("\(command.executable)：\(error)".utf8)
                        code = 127
                    }
                } else if code == 0 {
                    stderr = Data("没有 `\(command.executable)` 的实现。".utf8)
                    code = 127
                }

                // ---------- 输出重定向 ----------
                for redirection in command.redirections where redirection.writesFile {
                    guard let sink = redirections else {
                        stderr.append(Data("\n（这个运行环境不支持 `\(redirection.kind.rawValue)` 重定向）".utf8))
                        code = code == 0 ? 1 : code
                        continue
                    }
                    do {
                        let append = redirection.kind == .stdoutAppend || redirection.kind == .stderrAppend
                        let target = resolve(redirection.target, base: options.basePath)
                        switch redirection.kind {
                        case .stdout, .stdoutAppend:
                            try sink.write(target, data: stdout, append: append)
                            stdout = Data()
                        case .stderr, .stderrAppend:
                            try sink.write(target, data: stderr, append: append)
                            stderr = Data()
                        case .stdoutAndStderr:
                            try sink.write(target, data: stdout + stderr, append: false)
                            stdout = Data(); stderr = Data()
                        case .stdin:
                            break
                        }
                    } catch {
                        stderr.append(Data("\n重定向到 \(redirection.target) 失败：\(error)".utf8))
                        code = code == 0 ? 1 : code
                    }
                }

                // ---------- 输出限额 ----------
                let (cappedOut, outTruncated) = truncate(stdout, to: limits.maxOutputBytesPerCommand)
                if outTruncated { truncated = true }
                totalOutput += cappedOut.count
                if totalOutput > limits.maxTotalOutputBytes {
                    let remaining = max(0, limits.maxTotalOutputBytes - (totalOutput - cappedOut.count))
                    stdout = truncate(cappedOut, to: remaining).data
                    truncated = true
                    stoppedEarly = true
                } else {
                    stdout = cappedOut
                }
                if truncated { anyTruncated = true }

                // 判断这条命令的 stdout 会不会被下游吃掉
                let hasDownstream = command.id < (pipeline.commands.last?.id ?? command.id)
                outputs.append(ShellCommandOutput(
                    command: command.displayString,
                    stdout: String(decoding: stdout, as: UTF8.self),
                    stderr: String(decoding: stderr, as: UTF8.self),
                    exitCode: code,
                    wasTruncated: truncated,
                    isPiped: hasDownstream
                ))

                if code != 0 { pipelineFailed = true }
                pipelineExit = code
                stdin = stdout      // 喂给管道下游

                if stoppedEarly { break }
            }

            lastExitCode = pipelineExit

            // ---------- 失败即停 ----------
            if options.stopOnError, pipelineFailed {
                let nextSeparator = index < script.separators.count ? script.separators[index] : nil
                // `||` 后面那条**本来就该跑**（它是错误处理路径），不算"提前停止"
                if nextSeparator != .or {
                    skipped.append(contentsOf: script.pipelines[(index + 1)...].flatMap { $0.commands.map(\.displayString) })
                    stoppedEarly = true
                    break
                }
            }
            if stoppedEarly { break }
        }

        return ShellRunResult(
            exitCode: lastExitCode,
            outputs: outputs,
            skipped: skipped,
            wasTruncated: anyTruncated,
            stoppedEarly: stoppedEarly
        )
    }

    /// 把重定向目标解析成 VFS 路径字符串。
    ///
    /// ⚠️ 相对路径按 `options.basePath` 解析，**而不是按进程的当前目录** ——
    /// iOS 上没有"当前目录"这个概念可用（进程的 cwd 是 App 的容器根，不是工作区）。
    static func resolve(_ target: String, base: VFSPath) -> String {
        if target.hasPrefix("/") { return target }
        let resolved = VFSPath.resolve(base: base, relative: target)
        return resolved.path.description
    }
}


