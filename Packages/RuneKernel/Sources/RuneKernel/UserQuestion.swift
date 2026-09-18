import Foundation

// MARK: - `ask_user`：让模型**主动问**的结构化提问
//
// ⚠️ 这是本项目第六个「声明了但没接上」：
//    ① `ToolRegistry` 里有 `ask_user` 契约（还给足了使用纪律）；
//    ② `TurnStatus.awaitingUser` 状态**早就存在**（注释写着"等待用户输入（稳定态）"），
//       而且已经进了 `isStable` 的名单；
//    ③ `Correction` 里有 `.askUser` 动作，`EventLog` 里有 `askUser` 事件类型。
//    —— 但**没有任何东西会进入 `awaitingUser`**，`Sources/` 里也找不到一行实现。
//    （与 T48/T49/T54/T59/C57 同源，这是第六次。）
//
// ⚠️ 为什么它重要：一个不会提问的 Agent 只有两种行为 ——
//    **猜**（猜错代价可能很大，而且用户不知道它在猜），或者**卡住**（用户不知道它在等什么）。
//    结构化提问把"歧义"变成一次可回答的交互，这是移动端体验的关键一环
//    （用户在手机上更不可能容忍"它自己瞎猜然后返工"）。

/// 模型提出的一个问题。
public struct UserQuestion: Sendable, Codable, Hashable {
    public struct Option: Sendable, Codable, Hashable {
        public let label: String
        public let detail: String?

        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    /// 问题本身（一句话说清要用户决定什么）
    public let question: String
    /// 可选项（可以为空 —— 那就是开放题）
    public let options: [Option]
    /// 模型的默认建议（用户可以直接采纳）
    public let defaultValue: String?
    /// **为什么需要问**（这条最有价值：用户据此判断该不该回答、回答什么）
    public let why: String?
    /// 提出这个问题的工具调用（用于配对结果）
    public let callID: String

    public init(question: String, options: [Option], defaultValue: String?, why: String?, callID: String) {
        self.question = question
        self.options = options
        self.defaultValue = defaultValue
        self.why = why
        self.callID = callID
    }

    /// 一条提问最多几个选项。
    ///
    /// ⚠️ 上限不是为了省 token，而是为了**逼模型真的想清楚**：
    ///    五个以上的选项通常意味着它还没搞明白问题在哪，于是把"我拿不准的点"
    ///    一股脑丢给用户 —— 而用户在手机上不会去读第五个选项。
    public static let maxOptions = 4

    /// 渲染给用户看（也用于工具结果回灌给模型，让双方看到的是同一段话）。
    public var displayText: String {
        var lines = [question]
        if !options.isEmpty {
            lines.append("")
            for (index, option) in options.enumerated() {
                var line = "  \(index + 1). \(option.label)"
                if let detail = option.detail, !detail.isEmpty { line += " —— \(detail)" }
                lines.append(line)
            }
        }
        if let defaultValue, !defaultValue.isEmpty {
            lines.append("")
            lines.append("默认建议：\(defaultValue)")
        }
        if let why, !why.isEmpty {
            lines.append("")
            lines.append("为什么需要问：\(why)")
        }
        return lines.joined(separator: "\n")
    }

    /// 从工具参数解析。解析失败返回 nil（调用方负责回灌可执行的错误）。
    ///
    /// ⚠️ 与 `TodoList.items(from:)` 同样的立场：**解析与校验只有一处实现**，
    ///    运行时与工具执行器共用，避免两边判据分叉。
    public static func parse(_ arguments: JSONValue, callID: String) -> UserQuestion? {
        guard let question = arguments.value(at: ["question"])?.stringValue,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var options: [Option] = []
        for element in arguments.value(at: ["options"])?.arrayValue ?? [] {
            guard let label = element.value(at: ["label"])?.stringValue, !label.isEmpty else { continue }
            options.append(Option(label: label, detail: element.value(at: ["detail"])?.stringValue))
        }
        return UserQuestion(
            question: question,
            options: Array(options.prefix(maxOptions)),
            defaultValue: arguments.value(at: ["default"])?.stringValue,
            why: arguments.value(at: ["why"])?.stringValue,
            callID: callID
        )
    }

    /// 校验（在挂起之前做，避免把一个坏问题变成用户的负担）。
    public static func validate(_ question: UserQuestion) -> String? {
        let trimmed = question.question.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "问题不能为空。" }
        if trimmed.count > 500 { return "问题太长（超过 500 字）—— 把背景放到对话里，只把要决定的那一点写进 question。" }
        let labels = question.options.map(\.label)
        if Set(labels).count != labels.count { return "选项的 label 有重复。" }
        if question.options.count > maxOptions { return "选项最多 \(maxOptions) 个。" }
        // ⚠️ 这是工具文档里写死的纪律，也是模型最容易犯的错：
        //    "不要问「要不要我继续」这种废话"。那类问题把决定权推回给用户，
        //    却没有提供任何新信息 —— 它只是让 Agent 显得谨慎，实际是浪费用户的一次点击。
        let filler = ["要不要我继续", "是否继续", "可以继续吗", "要我继续吗", "是否可行", "continue?"]
        for phrase in filler where trimmed.contains(phrase) {
            return "这类「\(phrase)」的问题没有信息量 —— 你有足够信息就直接做，做完把结果告诉用户。"
        }
        return nil
    }
}
