import Testing
import Foundation
@testable import RuneKernel

// MARK: - 历史分组：三家的要求是**相反**的
//
// 这一组测试守的是一个"只要写测试就能提前抓到、不写就只能等用户第一次用才炸"的错。
// 运行时的历史长这样（因为 OpenAI 要求这样）：
//
//     assistant: [toolCall c1, toolCall c2, toolCall c3]
//     tool:      [toolResult c1]
//     tool:      [toolResult c2]
//     tool:      [toolResult c3]
//
// 三家对它的要求：
//   OpenAI    必须**保持三条** `tool` 消息（合并 → 后两个 id 找不到宿主 → 400）
//   Anthropic 三条 `tool_result` 应合成**一条 user 消息**
//   Gemini    必须合成**一条 user content**（相邻同角色 → INVALID_ARGUMENT）

private func call(_ id: String, _ name: String, _ args: String = "{}") -> ToolCall {
    ToolCall(id: id, name: name, argumentsJSON: Data(args.utf8))
}

/// 一次波次：助手并发三个工具调用 + 三条结果
private func parallelWave() -> [Message] {
    [
        Message(role: .user, blocks: [.text("把这三个文件都读一下", origin: .userInstruction)],
                origin: .userInstruction),
        Message(role: .assistant, blocks: [
            ContentBlock(kind: .text("好"), origin: .modelOutput),
            ContentBlock(kind: .toolCall(call("c1", "read_file")), origin: .modelOutput),
            ContentBlock(kind: .toolCall(call("c2", "read_file")), origin: .modelOutput),
            ContentBlock(kind: .toolCall(call("c3", "stat_path")), origin: .modelOutput),
        ], origin: .modelOutput),
        Message(role: .tool, blocks: [ContentBlock(kind: .toolResult(.ok(callID: "c1", summary: "a 的内容")),
                                                  origin: .toolResultTrusted)], origin: .toolResultTrusted),
        Message(role: .tool, blocks: [ContentBlock(kind: .toolResult(.ok(callID: "c2", summary: "b 的内容")),
                                                  origin: .toolResultTrusted)], origin: .toolResultTrusted),
        Message(role: .tool, blocks: [ContentBlock(kind: .toolResult(.ok(callID: "c3", summary: "c 的大小")),
                                                  origin: .toolResultTrusted)], origin: .toolResultTrusted),
    ]
}

private func encode(_ messages: [Message], family: ProtocolFamily, tools: [ToolSpec] = []) -> JSONValue {
    let request = ChatRequest(
        systemBlocks: [],
        messages: messages,
        tools: tools,
        toolChoice: .auto,
        maxOutputTokens: 4096
    )
    return RequestEncoder.encode(request, family: family, model: "m", quirks: .openAICompatible)
}

private func roles(_ body: JSONValue, key: String = "messages") -> [String] {
    guard case .array(let list)? = body.value(at: [key]) else { return [] }
    return list.compactMap { $0.value(at: ["role"])?.stringValue }
}

@Suite("历史分组 —— 每个协议族用自己的规则切历史")

struct MessageGroupingTests {

    @Test("分组规则：OpenAI 系不合并，Anthropic/Gemini 合并")
    func ruleTable() {
        #expect(HistoryGrouping.forFamily(.openAIChat) == .perMessage)
        #expect(HistoryGrouping.forFamily(.openAIResponses) == .perMessage)
        #expect(HistoryGrouping.forFamily(.ollamaNative) == .perMessage)
        #expect(HistoryGrouping.forFamily(.anthropicMessages) == .adjacentSameRole)
        #expect(HistoryGrouping.forFamily(.geminiGenerate) == .adjacentSameRole)
        #expect(HistoryGrouping.forFamily(.geminiInteractions) == .adjacentSameRole)
        // ⚠️ 未知协议族偏保守：少合并只是少一层优化，多合并是不可恢复的 400
        #expect(HistoryGrouping.forFamily(.custom) == .perMessage)
    }

    @Test("有效角色：Anthropic 的 tool 与 user 是同一个角色（这就是必须合并的原因）")
    func effectiveRoles() {
        #expect(MessageGrouping.effectiveRole(.tool, family: .anthropicMessages) == "user")
        #expect(MessageGrouping.effectiveRole(.user, family: .anthropicMessages) == "user")
        #expect(MessageGrouping.effectiveRole(.assistant, family: .anthropicMessages) == "assistant")
        #expect(MessageGrouping.effectiveRole(.tool, family: .geminiGenerate) == "user")
        #expect(MessageGrouping.effectiveRole(.assistant, family: .geminiGenerate) == "model")
        // OpenAI 保持原样（tool 就是 tool，不能变成 user）
        #expect(MessageGrouping.effectiveRole(.tool, family: .openAIChat) == "tool")
    }

    @Test("⭐ 两个 gemini 协议族必须共用同一条规则（编码器拿 .geminiGenerate 当代表）")
    func geminiFamiliesShareOneRule() {
        #expect(HistoryGrouping.forFamily(.geminiGenerate) == HistoryGrouping.forFamily(.geminiInteractions))
    }

    @Test("⭐⭐ 规则表必须是**编码器的必经之路**，不能只是文档")
    func ruleTableActuallyDrivesTheEncoders() {
        // 这条测试用"entry 入口"直接验证契约：applying 对 OpenAI 系原样返回、对 Anthropic/Gemini 合并。
        // 为什么值得单独测：规则表一度只被测试用到，而编码器各自无条件调 merge ——
        // 于是表里写"不合并"、实际却合并，**而规则表那几条断言照样全绿**。
        let entries: [(role: String, payload: [JSONValue])] = [
            ("user", [.string("a")]),
            ("user", [.string("b")]),
        ]
        #expect(MessageGrouping.applying(.openAIChat, to: entries).count == 2)
        #expect(MessageGrouping.applying(.anthropicMessages, to: entries).count == 1)
        #expect(MessageGrouping.applying(.geminiGenerate, to: entries).count == 1)
        #expect(MessageGrouping.applying(.ollamaNative, to: entries).count == 2)
    }

    @Test("⭐ 空条目要被**先丢掉再合并**，否则它会成为一道假的「角色隔断」")
    func emptyEntriesAreDroppedBeforeMerging() {
        let entries: [(role: String, payload: [JSONValue])] = [
            ("user", [.string("a")]),
            ("assistant", []),           // 空：缺 signature 的 thinking 块会被保守丢掉
            ("user", [.string("b")]),
        ]
        let merged = MessageGrouping.merge(entries)
        // 若顺序反了（先合并再过滤），这里会得到两条 user
        #expect(merged.count == 1)
        #expect(merged[0].payload == [.string("a"), .string("b")])
    }

    @Test("工具名能从配对的 toolCall 里找回来")
    func toolNamesRecovered() {
        let names = MessageGrouping.toolNames(in: parallelWave())
        #expect(names == ["c1": "read_file", "c2": "read_file", "c3": "stat_path"])
    }
}

@Suite("OpenAI —— 工具结果必须各自一条（不能被合并掉）")

struct OpenAIToolResultGroupingTests {

    @Test("⭐ 三个并行结果 = 三条 tool 消息（合并会让后两个 id 找不到宿主）")
    func keepsOneToolMessagePerCall() {
        let body = encode(parallelWave(), family: .openAIChat)
        #expect(roles(body) == ["user", "assistant", "tool", "tool", "tool"])

        // 每条 tool 消息各自带自己的 id —— 这正是"不能合并"的原因
        #expect(body.value(at: ["messages", "2", "tool_call_id"]) == .string("c1"))
        #expect(body.value(at: ["messages", "3", "tool_call_id"]) == .string("c2"))
        #expect(body.value(at: ["messages", "4", "tool_call_id"]) == .string("c3"))
    }

    @Test("助手那条的三个调用按 index 顺序排列")
    func assistantCallsInOrder() {
        let body = encode(parallelWave(), family: .openAIChat)
        #expect(body.value(at: ["messages", "1", "tool_calls", "0", "id"]) == .string("c1"))
        #expect(body.value(at: ["messages", "1", "tool_calls", "1", "id"]) == .string("c2"))
        #expect(body.value(at: ["messages", "1", "tool_calls", "2", "id"]) == .string("c3"))
    }

    @Test("⭐ requiresToolResultName 的端点要拿到**真实函数名**，不是占位的「tool」")
    func toolResultNameIsTheRealToolName() {
        var quirks = ProviderQuirks.openAICompatible
        quirks.requiresToolResultName = true
        let request = ChatRequest(systemBlocks: [], messages: parallelWave(), maxOutputTokens: 4096)
        let body = RequestEncoder.encode(request, family: .openAIChat, model: "m", quirks: quirks)

        let names = (2..<5).compactMap { body.value(at: ["messages", String($0), "name"])?.stringValue }
        #expect(names == ["read_file", "read_file", "stat_path"],
                "名字要与 assistant 里 tool_calls[].function.name 一致：\(names)")
        #expect(!names.contains("tool"))
    }

    @Test("不需要 name 的端点**不能**多送这个字段（有的端点见到未知字段就 400）")
    func nameFieldOnlyWhenRequired() {
        let body = encode(parallelWave(), family: .openAIChat)
        #expect(body.value(at: ["messages", "2", "name"]) == nil)
    }
}

@Suite("Anthropic —— 工具结果合成一条 user 消息")

struct AnthropicToolResultGroupingTests {

    @Test("⭐ 三个并行结果 = **一条** user 消息里的三个 tool_result 块")
    func mergesToolResultsIntoOneUserMessage() {
        let body = encode(parallelWave(), family: .anthropicMessages)
        #expect(roles(body) == ["user", "assistant", "user"])

        let content = body.value(at: ["messages", "2", "content"])
        guard case .array(let blocks)? = content else { Issue.record("content 不是数组"); return }
        #expect(blocks.count == 3)
        #expect(blocks.allSatisfy { $0.value(at: ["type"]) == .string("tool_result") })
        #expect(blocks.compactMap { $0.value(at: ["tool_use_id"])?.stringValue } == ["c1", "c2", "c3"])
    }

    @Test("⭐ 运行时的引导语紧跟在工具结果之后 → 也合成同一条（否则就是连续 user）")
    func guidanceAfterToolResultsIsMerged() {
        var messages = parallelWave()
        // injectGuidance 用的就是 `.user` —— 这是运行时真实会产生的形状
        messages.append(Message(role: .user,
                                blocks: [ContentBlock(kind: .text("上次路径写错了，注意用相对路径"),
                                                      origin: .runtimeGuidance)],
                                origin: .runtimeGuidance))

        let body = encode(messages, family: .anthropicMessages)
        #expect(roles(body) == ["user", "assistant", "user"], "引导语必须并进同一条，不能另起一条 user")

        guard case .array(let blocks)? = body.value(at: ["messages", "2", "content"]) else {
            Issue.record("content 不是数组"); return
        }
        #expect(blocks.count == 4, "三段结果 + 一段引导语")
        #expect(blocks.last?.value(at: ["type"]) == .string("text"))
    }

    @Test("⭐ 失败的工具结果必须带 is_error（否则模型把「权限被拒」当成一次成功输出）")
    func failedResultsAreMarkedAsErrors() {
        let error = ToolError(kind: .capabilityDenied,
                              modelFacingMessage: "越出授权目录",
                              suggestion: "改用工作区内的路径")
        let messages = [
            Message(role: .assistant, blocks: [
                ContentBlock(kind: .toolCall(call("c1", "write_file")), origin: .modelOutput),
                ContentBlock(kind: .toolCall(call("c2", "read_file")), origin: .modelOutput),
                ContentBlock(kind: .toolCall(call("c3", "grep_search")), origin: .modelOutput),
            ], origin: .modelOutput),
            Message(role: .tool, blocks: [ContentBlock(kind: .toolResult(.failure(callID: "c1", error: error)),
                                                      origin: .toolResultTrusted)], origin: .toolResultTrusted),
            Message(role: .tool, blocks: [ContentBlock(kind: .toolResult(.ok(callID: "c2", summary: "正常内容")),
                                                      origin: .toolResultTrusted)], origin: .toolResultTrusted),
            Message(role: .tool, blocks: [ContentBlock(kind: .toolResult(
                ToolResult(callID: "c3", status: .truncated, summary: "太长已转制品 handle=x")),
                origin: .toolResultTrusted)], origin: .toolResultTrusted),
        ]
        let body = encode(messages, family: .anthropicMessages)

        // c1 失败 → 带 is_error
        #expect(body.value(at: ["messages", "1", "content", "0", "is_error"]) == .bool(true))
        // c2 成功 → **不能**带这个字段（带了会让模型以为成功的那步没做成）
        #expect(body.value(at: ["messages", "1", "content", "1", "is_error"]) == nil)
        // c3 截断：调用本身是成功的，只是输出太长 → 不算错误
        #expect(body.value(at: ["messages", "1", "content", "2", "is_error"]) == nil)

        // 而失败原因（含建议）仍然要如实送出去
        let text = body.value(at: ["messages", "1", "content", "0", "content"])?.stringValue ?? ""
        #expect(text.contains("越出授权目录"))
        #expect(text.contains("工作区内的路径"), "suggestion 必须一起发出去（T17）")
    }

    @Test("⚠️ 相邻的两条 assistant 消息也要合并")
    func adjacentAssistantMessagesMerge() {
        let messages = [
            Message(role: .assistant, blocks: [ContentBlock(kind: .text("第一步"), origin: .modelOutput)],
                    origin: .modelOutput),
            Message(role: .assistant, blocks: [ContentBlock(kind: .text("第二步"), origin: .modelOutput)],
                    origin: .modelOutput),
        ]
        let body = encode(messages, family: .anthropicMessages)
        #expect(roles(body) == ["assistant"])
        guard case .array(let blocks)? = body.value(at: ["messages", "0", "content"]) else {
            Issue.record("content 不是数组"); return
        }
        #expect(blocks.compactMap { $0.value(at: ["text"])?.stringValue } == ["第一步", "第二步"])
    }
}

@Suite("Gemini —— contents 必须 user / model 交替")

struct GeminiGroupingTests {

    @Test("⭐⭐ 三个并行结果 = 一条 user content（相邻同角色直接 INVALID_ARGUMENT）")
    func mergesIntoOneContent() {
        let body = encode(parallelWave(), family: .geminiGenerate)
        #expect(roles(body, key: "contents") == ["user", "model", "user"])

        guard case .array(let parts)? = body.value(at: ["contents", "2", "parts"]) else {
            Issue.record("parts 不是数组"); return
        }
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { $0.value(at: ["functionResponse"]) != nil })
    }

    @Test("⭐⭐ functionResponse.name 必须是**函数名**，不是硬编码的「tool」")
    func functionResponseNameIsTheToolName() {
        let body = encode(parallelWave(), family: .geminiGenerate)
        let names = (0..<3).compactMap {
            body.value(at: ["contents", "2", "parts", String($0), "functionResponse", "name"])?.stringValue
        }
        #expect(names == ["read_file", "read_file", "stat_path"],
                "名字要与 functionDeclarations 里声明的一致，否则配不上：\(names)")
        #expect(!names.contains("tool"))
    }

    @Test("⭐ 失败的结果用 error 字段（否则「权限被拒」看起来像一次成功输出）")
    func failuresCarryErrorNotContent() {
        let error = ToolError(kind: .capabilityDenied, modelFacingMessage: "越出授权目录", suggestion: nil)
        let messages = [
            Message(role: .assistant, blocks: [
                ContentBlock(kind: .toolCall(call("c1", "write_file")), origin: .modelOutput),
                ContentBlock(kind: .toolCall(call("c2", "read_file")), origin: .modelOutput),
            ], origin: .modelOutput),
            Message(role: .tool, blocks: [ContentBlock(kind: .toolResult(.failure(callID: "c1", error: error)),
                                                      origin: .toolResultTrusted)], origin: .toolResultTrusted),
            Message(role: .tool, blocks: [ContentBlock(kind: .toolResult(.ok(callID: "c2", summary: "正常")),
                                                      origin: .toolResultTrusted)], origin: .toolResultTrusted),
        ]
        let body = encode(messages, family: .geminiGenerate)

        #expect(body.value(at: ["contents", "1", "parts", "0", "functionResponse", "response", "error"]) != nil)
        #expect(body.value(at: ["contents", "1", "parts", "0", "functionResponse", "name"]) == .string("write_file"))
        #expect(body.value(at: ["contents", "1", "parts", "1", "functionResponse", "response", "content"]) != nil)
        #expect(body.value(at: ["contents", "1", "parts", "1", "functionResponse", "response", "error"]) == nil)
    }

    @Test("⭐ 不变量：分组之后，任何相邻两条 content 的角色都不相同")
    func alternationInvariantHolds() {
        // 一段刻意"脏"的历史：连续的工具结果、运行时引导语、连续的助手消息、
        // 以及一条**内容为空**的助手消息（缺 signature 的 thinking 块会被保守丢掉）
        var messages: [Message] = [
            Message(role: .user, blocks: [.text("目标", origin: .userInstruction)], origin: .userInstruction),
        ]
        for round in 0..<3 {
            messages.append(Message(role: .assistant, blocks: [
                ContentBlock(kind: .reasoning(text: "想一下", signature: nil), origin: .modelOutput),
                ContentBlock(kind: .toolCall(call("r\(round)a", "read_file")), origin: .modelOutput),
                ContentBlock(kind: .toolCall(call("r\(round)b", "glob")), origin: .modelOutput),
            ], origin: .modelOutput))
            messages.append(Message(role: .tool, blocks: [ContentBlock(
                kind: .toolResult(.ok(callID: "r\(round)a", summary: "x")), origin: .toolResultTrusted)],
                origin: .toolResultTrusted))
            messages.append(Message(role: .tool, blocks: [ContentBlock(
                kind: .toolResult(.ok(callID: "r\(round)b", summary: "y")), origin: .toolResultTrusted)],
                origin: .toolResultTrusted))
            messages.append(Message(role: .user, blocks: [ContentBlock(kind: .text("继续"), origin: .runtimeGuidance)],
                                    origin: .runtimeGuidance))
        }
        // 一条整体为空的助手消息：只有缺 signature 的 thinking
        messages.append(Message(role: .assistant, blocks: [
            ContentBlock(kind: .reasoning(text: "只有思考没有正文", signature: nil), origin: .modelOutput),
        ], origin: .modelOutput))
        messages.append(Message(role: .assistant, blocks: [ContentBlock(kind: .text("收尾"), origin: .modelOutput)],
                                origin: .modelOutput))

        let body = encode(messages, family: .geminiGenerate)
        let list = roles(body, key: "contents")
        #expect(!list.isEmpty)
        for index in 1..<list.count {
            #expect(list[index] != list[index - 1],
                    "第 \(index) 条与上一条同为 \(list[index]) —— Gemini 会报 INVALID_ARGUMENT")
        }
        // 空的那条助手消息不能留下一段空的 parts
        guard case .array(let contents)? = body.value(at: ["contents"]) else { return }
        #expect(contents.allSatisfy { entry in
            if case .array(let parts)? = entry.value(at: ["parts"]) { return !parts.isEmpty }
            return false
        })
    }

    @Test("找不到配对的名字时宁可不给，也不要给一个错名字")
    func orphanResultOmitsName() {
        // 只有结果、没有配对的 toolCall（正常运行时不该出现，但编码器不能崩也不能撒谎）
        let messages = [
            Message(role: .tool, blocks: [ContentBlock(kind: .toolResult(.ok(callID: "没有配对", summary: "x")),
                                                      origin: .toolResultTrusted)], origin: .toolResultTrusted),
        ]
        let body = encode(messages, family: .geminiGenerate)
        #expect(body.value(at: ["contents", "0", "parts", "0", "functionResponse", "name"]) == nil)
        #expect(body.value(at: ["contents", "0", "parts", "0", "functionResponse", "response", "content"]) != nil)
    }
}

@Suite("合并永不提权（信任级）")

struct MergeTrustTests {

    @Test("⭐ 工具结果 + 运行时引导语 → 仍是运行时引导语，**不能**变成用户指令")
    func mergingNeverElevatesTrust() {
        let merged = TrustLevel.mostConservative(.toolResultTrusted, .runtimeGuidance)
        #expect(merged == .runtimeGuidance)
        // 这条是安全含义所在：运行时的引导语不能因为合并而获得"用户授权"的身份
        #expect(!merged.isInstruction)
        #expect(!merged.canDriveDangerousAction)
    }

    @Test("不可信内容与任何东西合并，结果都是不可信")
    func untrustedWinsEveryMerge() {
        for other in TrustLevel.allCases {
            #expect(TrustLevel.mostConservative(.untrustedContent, other) == .untrustedContent)
            #expect(TrustLevel.mostConservative(other, .untrustedContent) == .untrustedContent)
        }
    }

    @Test("同级别合并保持原样")
    func sameLevelIsStable() {
        for level in TrustLevel.allCases {
            #expect(TrustLevel.mostConservative(level, level) == level)
        }
    }
}
