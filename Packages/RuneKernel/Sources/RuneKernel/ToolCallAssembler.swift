import Foundation

// MARK: - JSON 修复
//
// 模型生成的工具参数经常是坏 JSON（被 max_tokens 截断、少个括号、多了尾逗号）。
// 直接失败会让长任务成功率明显下降，所以先尽力修一次；修不好再走"修正性重试"
// （docs/04 §4.4），并把**原始文本**一并保留，供错误回灌时展示。

public enum JSONRepair {

    public struct Result: Sendable, Equatable {
        public var value: JSONValue
        /// 是否做过修复（用于诊断与统计"模型给的参数有多不准"）
        public var wasRepaired: Bool
        public var fixes: [String]

        public init(value: JSONValue, wasRepaired: Bool, fixes: [String] = []) {
            self.value = value
            self.wasRepaired = wasRepaired
            self.fixes = fixes
        }
    }

    /// 尝试解析；失败则逐级修复。
    /// 返回 nil 表示**修不好**（调用方应走修正性重试，不要把半成品当参数用）。
    public static func parse(_ text: String) -> Result? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 空参数是合法的（无参工具），不是错误
        if trimmed.isEmpty {
            return Result(value: .object([:]), wasRepaired: true, fixes: ["空参数按 {} 处理"])
        }

        // 1. 直接解析
        if let value = try? JSONValue.parse(trimmed) {
            return Result(value: value, wasRepaired: false)
        }

        // 2. 逐级修复
        var fixes: [String] = []
        var candidate = trimmed

        // 2a. 去掉尾随的未完成转义反斜杠
        if candidate.hasSuffix("\\") {
            candidate.removeLast()
            fixes.append("去掉未完成的转义反斜杠")
        }

        // 2b. 补上未闭合的字符串
        if needsStringClosure(candidate) {
            candidate.append("\"")
            fixes.append("补上未闭合的字符串引号")
        }

        // 2c. 去掉尾逗号（`{"a":1,}` / `[1,2,]` / 嵌套的 `{"a":{"b":1,},}`）
        if let cleaned = removingTrailingCommas(candidate), cleaned != candidate {
            candidate = cleaned
            fixes.append("去掉尾逗号")
        }

        // 2d. 去掉悬空的键（形如 `{"a":1,"b"` 或 `{"a":1,"b":`）
        if let cleaned = removingDanglingMember(candidate), cleaned != candidate {
            candidate = cleaned
            fixes.append("丢弃被截断的最后一个成员")
        }

        // 2e. 补齐未闭合的括号
        let (balanced, closers) = closingBrackets(candidate)
        if !closers.isEmpty {
            candidate = balanced
            fixes.append("补齐未闭合的 \(closers.joined())")
        }

        if !fixes.isEmpty, let value = try? JSONValue.parse(candidate) {
            return Result(value: value, wasRepaired: true, fixes: fixes)
        }

        // 3. 最后再试一次：把常见的中文标点/单引号替换掉（模型偶尔会这么写）
        var relaxed = candidate
        var relaxedFixes: [String] = []
        for (from, to) in [("“", "\""), ("”", "\""), ("：", ":"), ("，", ",")] where relaxed.contains(from) {
            relaxed = relaxed.replacingOccurrences(of: from, with: to)
            relaxedFixes.append("替换中文标点 \(from) → \(to)")
        }
        if !relaxedFixes.isEmpty, let value = try? JSONValue.parse(relaxed) {
            return Result(value: value, wasRepaired: true, fixes: fixes + relaxedFixes)
        }

        return nil
    }

    // MARK: 扫描辅助

    /// 扫描文本，返回字符串状态与括号栈
    private static func scan(_ text: String) -> (inString: Bool, escaped: Bool, stack: [Character]) {
        var inString = false
        var escaped = false
        var stack: [Character] = []
        for ch in text {
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{": stack.append("}")
            case "[": stack.append("]")
            case "}", "]":
                if stack.last == ch { stack.removeLast() }
            default: break
            }
        }
        return (inString, escaped, stack)
    }

    private static func needsStringClosure(_ text: String) -> Bool {
        let state = scan(text)
        return state.inString && !state.escaped
    }

    private static func closingBrackets(_ text: String) -> (String, [String]) {
        let state = scan(text)
        guard !state.stack.isEmpty else { return (text, []) }
        return (text + String(state.stack.reversed()), state.stack.reversed().map(String.init))
    }

    /// 去掉**所有**紧随闭合括号的逗号。
    ///
    /// ⚠️ 不能只看字符串末尾：`{"a": 1, "b": 2,}` 的尾逗号在最后那个 `}` **之前**，
    /// 从末尾往前找只会看到 `}` 从而漏掉它。必须做一次带字符串状态的单遍扫描。
    private static func removingTrailingCommas(_ text: String) -> String? {
        var out = ""
        var inString = false
        var escaped = false
        var removed = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inString {
                out.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                i += 1
                continue
            }
            if ch == "\"" {
                inString = true
                out.append(ch)
                i += 1
                continue
            }
            if ch == "," {
                // 向后跳过空白，看下一个非空白字符是不是闭合括号
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" {
                    removed = true
                    i += 1          // 丢弃这个逗号
                    continue
                }
            }
            out.append(ch)
            i += 1
        }
        return removed ? out : nil
    }

    /// 丢掉被截断的最后一个成员：`{"a":1,"b"` → `{"a":1}`；`{"a":1,"b":` → `{"a":1}`
    private static func removingDanglingMember(_ text: String) -> String? {
        let state = scan(text)
        guard !state.stack.isEmpty, state.stack.last == "}" else { return text }

        // 从尾部往前找最后一段"不完整的成员"
        var chars = Array(text)
        var i = chars.count - 1

        // 情形 A：以 `:` 结尾 → 键在但值没有 → 丢掉该键
        while i >= 0, chars[i].isWhitespace { i -= 1 }
        if i >= 0, chars[i] == ":" {
            return dropBackToLastComma(chars, before: i)
        }

        // 情形 B：以字符串结尾（已完成但没跟冒号）→ 若它前面紧跟 `{` 或 `,`，说明是悬空键
        if !state.inString, i >= 0, chars[i] == "\"" {
            // 找这个字符串的起点
            var j = i - 1
            var escaped = false
            while j >= 0 {
                let c = chars[j]
                if escaped { escaped = false; j -= 1; continue }
                if c == "\\" { escaped = true; j -= 1; continue }
                if c == "\"" { break }
                j -= 1
            }
            guard j > 0 else { return text }
            var k = j - 1
            while k >= 0, chars[k].isWhitespace { k -= 1 }
            if k >= 0, chars[k] == "{" || chars[k] == "," {
                return dropBackToLastComma(chars, before: k)
            }
        }
        return text
    }

    /// 从 `index` 往前找到逗号并把它之后的内容全部丢弃（含该逗号）
    private static func dropBackToLastComma(_ chars: [Character], before index: Int) -> String {
        var i = index
        while i >= 0 {
            if chars[i] == "," {
                return String(chars[0..<i])
            }
            if chars[i] == "{" { return String(chars[0...i]) }
            i -= 1
        }
        return String(chars)
    }
}

// MARK: - 拼装结果

/// 拼装完成的一次工具调用。
///
/// `call` 是运行时直接可用的类型；其余字段是**诊断信息**——
/// 它们让"模型给的参数有多不准"变成可观测的数据（用于持续优化工具描述）。
public struct AssembledToolCall: Sendable, Hashable {
    public var call: ToolCall
    /// 参数 JSON 是否被修复过
    public var wasRepaired: Bool
    /// 是否收到了明确的结束信号（`.toolCallCompleted` 或 `finish_reason == .toolCalls`）
    public var isComplete: Bool
    public var issues: [AssemblyIssue]
    /// 原始（未修复）参数文本，供错误回灌时展示
    public var rawArguments: String

    public init(
        call: ToolCall,
        wasRepaired: Bool,
        isComplete: Bool,
        issues: [AssemblyIssue],
        rawArguments: String
    ) {
        self.call = call
        self.wasRepaired = wasRepaired
        self.isComplete = isComplete
        self.issues = issues
        self.rawArguments = rawArguments
    }
}

public enum AssemblyIssue: Sendable, Hashable {
    /// 分片到了但从未收到 start（部分中转站会这样）
    case deltaWithoutStart(index: Int)
    /// 同一 index 的 name 出现了不同值（取最后一个，但要记录——可能被中转站篡改）
    case nameChanged(index: Int, from: String, to: String)
    /// 既没有 name 也没有 id
    case missingIdentity(index: Int)
    /// 参数 JSON 被修复过
    case argumentsRepaired(index: Int, fixes: [String])
    /// 参数 JSON 修不好（**调用方必须走修正性重试**）
    case argumentsUnrepairable(index: Int, raw: String)
    /// 重复的 completed 事件
    case duplicateCompletion(index: Int)
    /// 流结束了但从未收到 finish_reason
    case finishReasonMissing
    /// finish_reason 不是 toolCalls 但仍有未完成的工具调用
    case unexpectedFinishWithPending(reason: FinishReason)

    public var isFatal: Bool {
        switch self {
        case .argumentsUnrepairable, .missingIdentity: return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .deltaWithoutStart(let i):
            return "第 \(i) 个工具调用的参数分片先于其开始事件到达（部分中转站会如此）"
        case .nameChanged(let i, let from, let to):
            return "第 \(i) 个工具调用的名称出现过不同值（\(from) → \(to)），已取最后一个"
        case .missingIdentity(let i):
            return "第 \(i) 个工具调用既无 id 也无 name，无法执行"
        case .argumentsRepaired(let i, let fixes):
            return "第 \(i) 个工具调用的参数 JSON 已修复：\(fixes.joined(separator: "；"))"
        case .argumentsUnrepairable(let i, _):
            return "第 \(i) 个工具调用的参数 JSON 无法修复"
        case .duplicateCompletion(let i):
            return "第 \(i) 个工具调用收到了重复的完成事件"
        case .finishReasonMissing:
            return "流在未收到结束原因的情况下结束"
        case .unexpectedFinishWithPending(let reason):
            return "结束原因为 \(reason.rawValue)，但仍有未完成的工具调用"
        }
    }
}

// MARK: - 拼装器

/// 把**分片**的流式工具调用拼成完整调用。
///
/// 这是整个网关里最容易写错的一块（docs/06 §4）。三种协议形态的差异：
///   * **OpenAI 标准**：同一 `index` 的多个 delta 分片，`arguments` 是字符串片段需要拼接；
///     `id`/`name` 通常只在首个分片出现
///   * **OpenAI Responses**：按 `output_index` 分组，`done` 事件给全量
///   * **Anthropic**：`content_block_start` → 多个 `input_json_delta.partial_json` → `stop`
///   * **Gemini**：每个 chunk 给完整的 `functionCall`（不拼装）
///
/// 适配器负责把这些形态**归一化成 `ModelEvent`**；本类型只负责"拼装与容错"。
public struct ToolCallAssembler: Sendable {

    private struct Partial {
        var id: String?
        var name: String?
        var json: String = ""
        var completed = false
        var emitted = false
        var issues: [AssemblyIssue] = []
    }

    private var partials: [Int: Partial] = [:]
    private var order: [Int] = []
    private var warnings: [AssemblyIssue] = []
    public private(set) var finishReason: FinishReason?
    /// 是否已经收到过结束信号
    public private(set) var didFinish = false

    public init() {}

    /// 尚未组装的调用数
    public var pendingCount: Int {
        partials.values.filter { !$0.emitted }.count
    }

    /// 累计的全部诊断信息（含已产出调用的）
    public var allIssues: [AssemblyIssue] {
        warnings + partials.values.flatMap(\.issues)
    }

    // MARK: 摄入事件

    /// 摄入一个归一化事件；返回本次**新完成**的工具调用。
    public mutating func ingest(_ event: ModelEvent) -> [AssembledToolCall] {
        switch event {
        case .toolCallStarted(let index, let id, let name):
            ensureSlot(index)
            if let existing = partials[index]?.name, !existing.isEmpty, existing != name, !name.isEmpty {
                partials[index]?.issues.append(.nameChanged(index: index, from: existing, to: name))
            }
            if !id.isEmpty { partials[index]?.id = id }
            if !name.isEmpty { partials[index]?.name = name }
            return []

        case .toolCallArgumentsDelta(let index, let fragment):
            if partials[index] == nil {
                ensureSlot(index)
                partials[index]?.issues.append(.deltaWithoutStart(index: index))
            }
            partials[index]?.json += fragment
            return []

        case .toolCallCompleted(let index, let id, let name, let argumentsJSON):
            ensureSlot(index)
            if partials[index]?.completed == true {
                partials[index]?.issues.append(.duplicateCompletion(index: index))
                return []
            }
            // 某些端点只给完整结果（Gemini 风格）→ 以完整值覆盖，避免重复拼装
            let existingName = partials[index]?.name
            let existingID = partials[index]?.id
            if let existing = existingName, !existing.isEmpty, existing != name, !name.isEmpty {
                partials[index]?.issues.append(.nameChanged(index: index, from: existing, to: name))
            }
            // ⚠️ 不能写 `partials[i]?.id = id.isEmpty ? partials[i]?.id : id`：
            //    同一表达式里既读又写同一个下标会触发独占性检查（ExclusivityViolation）。
            partials[index]?.id = id.isEmpty ? existingID : id
            partials[index]?.name = name.isEmpty ? existingName : name
            partials[index]?.json = String(decoding: argumentsJSON, as: UTF8.self)
            partials[index]?.completed = true
            return emit(index)

        case .finished(let reason):
            didFinish = true
            finishReason = reason
            var out: [AssembledToolCall] = []
            if pendingCount > 0, reason != .toolCalls {
                warnings.append(.unexpectedFinishWithPending(reason: reason))
            }
            for index in order {
                out.append(contentsOf: emit(index))
            }
            return out

        default:
            return []
        }
    }

    /// 流结束时调用（`finish_reason` 缺失时的兜底）。
    ///
    /// 设计依据（docs/06 §4.3 脏情况 7）：部分中转站不发 `[DONE]` 也不发 `finish_reason`，
    /// 此时以"连接正常关闭"为结束信号 —— 但**必须记录警告**，因为这意味着
    /// 我们无法区分"模型说完了"和"流被截断了"。
    public mutating func flush() -> [AssembledToolCall] {
        if !didFinish {
            warnings.append(.finishReasonMissing)
        }
        var out: [AssembledToolCall] = []
        for index in order {
            out.append(contentsOf: emit(index))
        }
        return out
    }

    // MARK: 内部

    private mutating func ensureSlot(_ index: Int) {
        if partials[index] == nil {
            partials[index] = Partial()
            order.append(index)
            order.sort()
        }
    }

    /// 组装并标记已产出（防重复）
    private mutating func emit(_ index: Int) -> [AssembledToolCall] {
        guard var partial = partials[index], !partial.emitted else { return [] }
        partial.emitted = true

        let rawJSON = partial.json
        var issues = partial.issues
        var repaired = false

        // 组装参数
        var argumentsJSON: Data
        if let repair = JSONRepair.parse(rawJSON) {
            repaired = repair.wasRepaired
            if repair.wasRepaired {
                issues.append(.argumentsRepaired(index: index, fixes: repair.fixes))
            }
            argumentsJSON = Data(repair.value.canonicalString().utf8)
        } else {
            issues.append(.argumentsUnrepairable(index: index, raw: rawJSON))
            // 仍然产出（带上原始文本），由运行时的修正性重试处理
            argumentsJSON = Data(rawJSON.utf8)
        }

        let name = partial.name ?? ""
        if name.isEmpty {
            issues.append(.missingIdentity(index: index))
        }
        let id = partial.id ?? "call_\(index)"

        // ⚠️ 必须把追加过 issue 的数组**写回** partial，否则这些诊断会在
        //    `asm.allIssues` / `diagnostics` 里丢失（只有本次返回值能看到）。
        partial.issues = issues
        partials[index] = partial

        let call = ToolCall(
            id: id,
            name: name,
            argumentsJSON: argumentsJSON,
            sourceIndex: index
        )

        return [AssembledToolCall(
            call: call,
            wasRepaired: repaired,
            isComplete: partial.completed || didFinish,
            issues: issues,
            rawArguments: rawJSON
        )]
    }

    /// 组装器自身的健康度（供调试面板显示"这个渠道的流有多脏"）
    public var diagnostics: String {
        var parts: [String] = []
        parts.append("已产出 \(partials.values.filter(\.emitted).count) 个工具调用")
        if !warnings.isEmpty { parts.append("警告 \(warnings.count) 条") }
        let repaired = partials.values.flatMap(\.issues).filter {
            if case .argumentsRepaired = $0 { return true }
            return false
        }.count
        if repaired > 0 { parts.append("参数被修复 \(repaired) 次") }
        if let finishReason { parts.append("结束原因 \(finishReason.rawValue)") }
        else { parts.append("未收到结束原因") }
        return parts.joined(separator: " · ")
    }
}
