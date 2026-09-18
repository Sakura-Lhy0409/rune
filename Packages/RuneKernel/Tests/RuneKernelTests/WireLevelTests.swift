import Testing
import Foundation
@testable import RuneKernel

// MARK: - 线路级假模型：真的编码，真的解字节
//
// 既有的 TurnRunner 测试全都用脚本化的 `[ModelEvent]`。那很方便，但它**跳过了整条脊梁**：
//
//     历史 → RequestBuilder → RequestEncoder → HTTP 请求体
//                                              ↓（这里换成脚本化的 SSE 字节）
//           [ModelEvent] ← StreamDecoder ← SSEParser
//
// 而"从来没被跑过"的东西，正是 bug 藏身之处 —— 上一个里程碑里
// 「目标从来没有进过 `state.messages`」就是这么躲了整整 997 项测试的。
//
// 这个假模型把两头的**真实实现**接上，只把中间的网络换成一串字节。
// 于是每一个断言都落在真实产物上：真的请求体、真的解码结果。
// 这是在没有网络、没有 macOS 的条件下，能做到的最接近"打真实渠道"的验证。

/// 一次往返：那一刻的历史 + 真的编出来的请求体
struct WireExchange {
    var round: Int
    var family: ProtocolFamily
    var history: [Message]
    var body: JSONValue
    /// 体检是否拦下了（拦下时 `body` 是空对象）
    var blocked: String?
}

/// 线路级假模型
final class WireLevelModel: @unchecked Sendable {
    private let lock = NSLock()
    private var _exchanges: [WireExchange] = []

    let family: ProtocolFamily
    let quirks: ProviderQuirks
    let modelID: String
    let toolRegistry: [String: ToolSpec]
    let maxOutputTokens: Int
    /// 第 N 轮（从 0 开始）返回哪些 SSE 原始分片
    let script: @Sendable (Int) -> [String]

    init(
        family: ProtocolFamily,
        quirks: ProviderQuirks,
        modelID: String = "wire-model",
        toolRegistry: [String: ToolSpec],
        maxOutputTokens: Int = 4096,
        script: @escaping @Sendable (Int) -> [String]
    ) {
        self.family = family
        self.quirks = quirks
        self.modelID = modelID
        self.toolRegistry = toolRegistry
        self.maxOutputTokens = maxOutputTokens
        self.script = script
    }

    var exchanges: [WireExchange] { lock.lock(); defer { lock.unlock() }; return _exchanges }
    var requests: [JSONValue] { exchanges.map(\.body) }
    var blockedReasons: [String] { exchanges.compactMap(\.blocked) }

    /// 给 `TurnRunner.Dependencies.modelEvents` 用的闭包
    func driver() -> @Sendable (TurnState) -> [ModelEvent] {
        { [self] state in events(for: state) }
    }

    private func events(for state: TurnState) -> [ModelEvent] {
        let round = state.round

        // ① 真的建请求（万一被体检拦下，记录下来 —— 这就是断言点）
        switch RequestBuilder.build(
            history: state.messages, toolRegistry: toolRegistry,
            maxOutputTokens: maxOutputTokens, family: family
        ) {
        case .blocked(let blocked):
            lock.lock()
            _exchanges.append(WireExchange(round: round, family: family, history: state.messages,
                                           body: .object([:]), blocked: blocked.userFacingText))
            lock.unlock()
            // 返回一个"错误结束"而不是崩溃：让测试去断言 blockedReasons 为空
            return [.finished(reason: .error)]

        case .ready(let request, _):
            // ② 真的编码成厂商请求体
            let body = RequestEncoder.encode(request, family: family, model: modelID, quirks: quirks)
            lock.lock()
            _exchanges.append(WireExchange(round: round, family: family, history: state.messages,
                                           body: body, blocked: nil))
            lock.unlock()

            // ③ 真的把 SSE 字节解回来
            var decoder = AnyStreamDecoder.make(family: family, quirks: quirks, model: modelID)
            var parser = SSEParser()
            var out: [ModelEvent] = []
            for chunk in script(round) {
                for event in parser.ingest(Data(chunk.utf8)) {
                    out.append(contentsOf: decoder.ingest(event))
                }
            }
            for event in parser.finish() { out.append(contentsOf: decoder.ingest(event)) }
            out.append(contentsOf: decoder.finish())
            return out
        }
    }
}

// MARK: - 三个协议族的 SSE 脚本
//
// 字节形态按 docs/附录A 的实测记录写：OpenAI 的 tool_calls 是**分片**的、
// Anthropic 是命名事件 + input_json_delta、Gemini 每个 chunk 给**完整** functionCall。

private func sseOpenAI(callID: String, tool: String, arguments: String) -> [String] {
    // 故意把 arguments 切成两片（真实渠道就是这么发的）
    let chars = Array(arguments)
    let half = max(1, chars.count / 2)
    let first = String(chars[0..<half])
    let second = String(chars[half...])
    func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    return [
        #"data: {"choices":[{"delta":{"content":"我看一下。"}}]}"# + "\n\n",
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"\#(callID)","function":{"name":"\#(tool)","arguments":"\#(escaped(first))"}}]}}]}"# + "\n\n",
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\#(escaped(second))"}}]}}]}"# + "\n\n",
        #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":900,"completion_tokens":40}}"# + "\n\n",
        "data: [DONE]\n\n",
    ]
}

private func sseOpenAIFinal(text: String) -> [String] {
    [
        #"data: {"choices":[{"delta":{"content":"\#(text)"}}]}"# + "\n\n",
        #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1200,"completion_tokens":30}}"# + "\n\n",
        "data: [DONE]\n\n",
    ]
}

private func sseAnthropic(callID: String, tool: String, arguments: String) -> [String] {
    let chars = Array(arguments)
    let half = max(1, chars.count / 2)
    let first = String(chars[0..<half])
    let second = String(chars[half...])
    func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    return [
        "event: message_start\ndata: {\"message\":{\"usage\":{\"input_tokens\":900}}}\n\n",
        "event: content_block_start\ndata: {\"index\":0,\"content_block\":{\"type\":\"text\"}}\n\n",
        "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"我看一下。\"}}\n\n",
        "event: content_block_stop\ndata: {\"index\":0}\n\n",
        "event: content_block_start\ndata: {\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"\(callID)\",\"name\":\"\(tool)\"}}\n\n",
        "event: content_block_delta\ndata: {\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\(escaped(first))\"}}\n\n",
        "event: content_block_delta\ndata: {\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\(escaped(second))\"}}\n\n",
        "event: content_block_stop\ndata: {\"index\":1}\n\n",
        "event: message_delta\ndata: {\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":40}}\n\n",
        "event: message_stop\ndata: {}\n\n",
    ]
}

private func sseAnthropicFinal(text: String) -> [String] {
    [
        "event: message_start\ndata: {\"message\":{\"usage\":{\"input_tokens\":1200}}}\n\n",
        "event: content_block_start\ndata: {\"index\":0,\"content_block\":{\"type\":\"text\"}}\n\n",
        "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(text)\"}}\n\n",
        "event: content_block_stop\ndata: {\"index\":0}\n\n",
        "event: message_delta\ndata: {\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":30}}\n\n",
        "event: message_stop\ndata: {}\n\n",
    ]
}

private func sseGemini(callID: String, tool: String, arguments: String) -> [String] {
    // ⚠️ Gemini 每个 chunk 给**完整**的 functionCall（不流式拼装 parameters）
    [
        #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"我看一下。"},{"functionCall":{"name":"\#(tool)","args":\#(arguments)}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":900,"candidatesTokenCount":40}}"# + "\n\n",
    ]
}

private func sseGeminiFinal(text: String) -> [String] {
    [
        #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"\#(text)"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1200,"candidatesTokenCount":30}}"# + "\n\n",
    ]
}

private func readSpecs() -> [String: ToolSpec] {
    let schema = JSONSchema.object(
        properties: ["path": .string(enumValues: nil, minLength: nil, maxLength: nil)],
        required: ["path"], additionalProperties: false
    )
    return [
        ToolName.readFile: ToolSpec(
            name: ToolName.readFile, description: "读文件", inputSchema: schema,
            pathParameters: ["path"], riskLevel: .safe, needsApproval: .never,
            requirements: [.fsRead]
        ),
        ToolName.grepSearch: ToolSpec(
            name: ToolName.grepSearch, description: "搜索", inputSchema: schema,
            pathParameters: ["path"], riskLevel: .safe, needsApproval: .never,
            requirements: [.fsRead]
        ),
    ]
}

private struct WireReader: ToolExecuting {
    func execute(_ call: ToolCall) throws -> ToolResult {
        .ok(callID: call.id, summary: "notes.md: 部署步骤 1. 构建 2. 上传")
    }
}

private func wirePolicyContext() -> PolicyEngine.Context {
    // ⚠️ 到期时间要相对**注入的时钟**（1_700_000_000）算，而不是相对真实时钟。
    //    这一条曾经踩过：令牌到期时间写成真实时间 + 1h 就没有确定性，
    //    而写成 2023 年的固定时间在"策略引擎读真实时钟"的旧实现下会**静默过期** ——
    //    表现是工具**一次都没被执行**，但结果里只有一句「本次授权已过期」。
    //    现在 `PolicyEngine.evaluate` 收 `now` 了，所以下面这个写法是确定性的。
    let token = CapabilityToken(
        issuedForTurn: UUID(),
        scopes: [.fsRead(VFSPath(mount: .workspace))],
        expiresAt: Date(timeIntervalSince1970: 1_700_000_000 + 3600),
        grantedBy: .planApproval, reason: "线路级验证"
    )
    return PolicyEngine.Context(trustDial: .collaborate, token: token, planApproved: true)
}

private func wireDeps(_ model: WireLevelModel) -> TurnRunner.Dependencies {
    TurnRunner.Dependencies(
        modelEvents: model.driver(),
        executor: WireReader(),
        policy: PolicyEngine(),
        policyContext: wirePolicyContext(),
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
}

private func wireConfig() -> TurnRunner.Config {
    var config = TurnRunner.Config(maxRounds: 6, maxToolCalls: 8, toolRegistry: readSpecs())
    config.maxCostMicroUSD = 0
    return config
}

@Suite("⭐⭐ 线路级：真的编码 → 真的解字节 → 跑完整一轮")

struct WireLevelTurnTests {

    // 三个协议族的脚本：第 0 轮读文件，第 1 轮收工
    private func openAIScript(_ round: Int) -> [String] {
        round == 0
            ? sseOpenAI(callID: "call_1", tool: "read_file", arguments: #"{"path":"/workspace/notes.md"}"#)
            : sseOpenAIFinal(text: "看完了：notes.md 里写的是部署步骤。")
    }
    private func anthropicScript(_ round: Int) -> [String] {
        round == 0
            ? sseAnthropic(callID: "toolu_1", tool: "read_file", arguments: #"{"path":"/workspace/notes.md"}"#)
            : sseAnthropicFinal(text: "看完了：notes.md 里写的是部署步骤。")
    }
    private func geminiScript(_ round: Int) -> [String] {
        round == 0
            ? sseGemini(callID: "g1", tool: "read_file", arguments: #"{"path":"/workspace/notes.md"}"#)
            : sseGeminiFinal(text: "看完了：notes.md 里写的是部署步骤。")
    }

    private func runTurn(_ model: WireLevelModel) -> TurnState {
        let (state, _, _) = TurnRunner.run(
            TurnState(objective: "看一下 notes.md 里写了什么"),
            deps: wireDeps(model), config: wireConfig()
        )
        return state
    }

    @Test("⭐⭐ OpenAI Chat：字节进、字节出，工具调用真的被执行、目标真的在请求里")
    func openAIWireRoundTrip() {
        let model = WireLevelModel(family: .openAIChat, quirks: .openAICompatible,
                                   toolRegistry: readSpecs(), script: openAIScript)
        let state = runTurn(model)

        // ⚠️ 一次都不许被体检拦下（拦下就等于"发不出去"）
        #expect(model.blockedReasons.isEmpty, "被拦下：\(model.blockedReasons)")

        let exchanges = model.exchanges
        #expect(exchanges.count == 2, "两轮模型往返，实际 \(exchanges.count)")

        // ① 第一轮的请求体：目标必须在 messages[0] 里（这正是 C33 修掉的那个 bug）
        let first = exchanges[0].body
        #expect(first.value(at: ["messages", "0", "role"]) == .string("user"))
        #expect(first.value(at: ["messages", "0", "content"])?.stringValue?
            .contains("notes.md") == true,
            "模型必须被告知要干什么")

        // ② 第一轮解码出来的工具调用真的被执行了 → 第二轮的历史里有配对结果
        #expect(state.messages.contains { message in
            message.blocks.contains { $0.toolResultValue != nil }
        }, "工具结果没进历史")

        // ③ 第二轮的请求体：tool 消息带 tool_call_id，且**各自一条**（OpenAI 的要求）
        let second = exchanges[1].body
        let roles = (0..<8).compactMap { second.value(at: ["messages", String($0), "role"])?.stringValue }
        #expect(roles.filter { $0 == "tool" }.count == 1)
        let toolIDs = (0..<8).compactMap {
            second.value(at: ["messages", String($0), "tool_call_id"])?.stringValue
        }
        #expect(toolIDs == ["call_1"], "结果必须带回真实的 call id")

        // ④ 收工话术真的被解出来了
        #expect(state.status == .completed)
        #expect(state.messages.last?.plainText.contains("部署步骤") == true,
                "最终回答没进历史：\(state.messages.last?.plainText ?? "nil")")
    }

    @Test("⭐⭐ Anthropic：三片输入拼成一个调用，结果合成一条 user 消息")
    func anthropicWireRoundTrip() {
        let model = WireLevelModel(family: .anthropicMessages, quirks: .anthropic,
                                   toolRegistry: readSpecs(), script: anthropicScript)
        let state = runTurn(model)

        #expect(model.blockedReasons.isEmpty, "被拦下：\(model.blockedReasons)")
        #expect(model.exchanges.count == 2)

        // ① system 是**顶层参数**，不是消息
        let first = model.exchanges[0].body
        #expect(first.value(at: ["messages", "0", "role"]) == .string("user"))
        #expect(first.value(at: ["model"])?.stringValue == "wire-model")

        // ② 第二轮：分片的 input_json_delta 真的拼成了一个合法参数对象
        let second = model.exchanges[1].body
        guard case .array(let messages)? = second.value(at: ["messages"]) else {
            Issue.record("没有 messages"); return
        }
        // user(目标) / assistant(tool_use) / user(tool_result) —— 一共三条
        #expect(messages.count == 3, "消息数：\(messages.count)")
        let types = (0..<8).compactMap { second.value(at: ["messages", "2", "content", String($0), "type"])?.stringValue }
        #expect(types == ["tool_result"], "结果必须放在 user 消息的 content 里")
        #expect(second.value(at: ["messages", "2", "content", "0", "tool_use_id"]) == .string("toolu_1"))
        // 成功的结果**不带** is_error
        let statuses = state.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }.map(\.status)
        let trace = state.steps.map { "\($0.index)·\($0.kind.rawValue)·\($0.summary)" }.joined(separator: " | ")
        let resultText = state.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }
            .map { "\($0.status.rawValue)：\($0.summary)" }.joined(separator: " / ")
        #expect(state.toolCallCount == 1,
                "工具必须真的被执行。步骤：\(trace)\n结果：\(resultText)")
        #expect(statuses == [.ok], "工具结果的真实状态：\(statuses)；步骤：\(trace)；结果：\(resultText)")
        #expect(second.value(at: ["messages", "2", "content", "0", "is_error"]) == nil,
                "成功的结果不该带 is_error")

        // ③ 分片拼装是否可信：参数真的落到了工具上（结果里的内容来自 WireReader）
        #expect(state.messages.contains { message in
            message.blocks.contains { $0.toolResultValue?.summary.contains("部署步骤") == true }
        }, "分片拼出来的参数没能让工具跑起来")
        #expect(state.status == .completed)
    }

    @Test("⭐⭐ Gemini：contents 必须交替，functionResponse 带真的函数名")
    func geminiWireRoundTrip() {
        let model = WireLevelModel(family: .geminiGenerate, quirks: .gemini,
                                   toolRegistry: readSpecs(), script: geminiScript)
        let state = runTurn(model)

        #expect(model.blockedReasons.isEmpty, "被拦下：\(model.blockedReasons)")
        #expect(model.exchanges.count == 2)

        let second = model.exchanges[1].body
        guard case .array(let contents)? = second.value(at: ["contents"]) else {
            Issue.record("没有 contents"); return
        }
        // ⚠️ 交替不变式（C30 的核心）
        let roles = contents.compactMap { $0.value(at: ["role"])?.stringValue }
        for index in 1..<max(1, roles.count) where roles.count > 1 {
            #expect(roles[index] != roles[index - 1], "相邻同角色会 INVALID_ARGUMENT：\(roles)")
        }
        #expect(roles.first == "user")
        #expect(roles.contains("model"))

        // ⚠️ 函数名必须是真的（不是硬编码的 "tool"）—— C30 修掉的第二个 bug
        let names = (0..<12).compactMap {
            second.value(at: ["contents", "2", "parts", String($0), "functionResponse", "name"])?.stringValue
        }
        #expect(names == ["read_file"], "实际：\(names)")
        #expect(!names.contains("tool"))
        #expect(state.status == .completed)
    }

    @Test("⭐ 三个协议族跑到同一个结果（渠道可换，行为不变）")
    func allFamiliesReachTheSameOutcome() {
        let openai = runTurn(WireLevelModel(family: .openAIChat, quirks: .openAICompatible,
                                           toolRegistry: readSpecs(), script: openAIScript))
        let anthropic = runTurn(WireLevelModel(family: .anthropicMessages, quirks: .anthropic,
                                              toolRegistry: readSpecs(), script: anthropicScript))
        let gemini = runTurn(WireLevelModel(family: .geminiGenerate, quirks: .gemini,
                                           toolRegistry: readSpecs(), script: geminiScript))

        for (name, state) in [("openai", openai), ("anthropic", anthropic), ("gemini", gemini)] {
            #expect(state.status == .completed, "\(name) 没跑完：\(state.status)")
            #expect(state.round == 2, "\(name) 的轮次：\(state.round)")
            #expect(state.toolCallCount == 1, "\(name) 的工具调用数：\(state.toolCallCount)")
        }
        // 三家拿到的"对话内容"应当一致 —— 这正是「不许厂商差异泄漏进运行时」的判据
        func shape(_ state: TurnState) -> [String] {
            state.messages.map { "\($0.role.rawValue):\($0.plainText.prefix(20))" }
        }
        #expect(shape(openai) == shape(anthropic))
        #expect(shape(anthropic) == shape(gemini))
    }

    @Test("⭐ 用量与成本一路解到底（字节里的 usage 真的变成了账）")
    func usageFlowsThrough() {
        var config = wireConfig()
        config.maxCostMicroUSD = 0
        let model = WireLevelModel(family: .openAIChat, quirks: .openAICompatible,
                                   toolRegistry: readSpecs(), script: openAIScript)
        // 价格：一万 token 一微美元
        var deps = wireDeps(model)
        deps.costOfRound = { usage in
            CostBreakdown(usage: usage, microUSD: (usage.inputTokens + usage.outputTokens) / 10_000,
                          providerID: "wire", modelID: "wire-model")
        }

        let (state, events, _) = TurnRunner.run(TurnState(objective: "看一下 notes.md"),
                                                deps: deps, config: config)
        // 第一轮 900+40，第二轮 1200+30 → 共 2170 token → 0 微美元（不足一万）
        #expect(state.usage.inputTokens == 2_100, "字节里的 prompt_tokens 没走到账本：\(state.usage.inputTokens)")
        #expect(state.usage.outputTokens == 70)
        #expect(events.contains { $0.kind == .costRecorded } == false,
                "不足一微美元时不写账（避免日志里全是 0）")
    }

    @Test("⚠️ 中转站形态：不发 [DONE]、也不发 finish_reason，仍然能收工")
    func relayWithoutDoneMarkerStillFinishes() {
        let model = WireLevelModel(family: .openAIChat, quirks: .relay,
                                   toolRegistry: readSpecs(), script: { _ in
            [#"data: {"choices":[{"delta":{"content":"我看了一下，没什么问题。"}}]}"# + "\n\n"]
        })
        let state = runTurn(model)
        #expect(model.blockedReasons.isEmpty)
        #expect(state.status == .completed, "兜底结束原因没生效：\(state.status)")
        #expect(state.messages.last?.plainText.contains("没什么问题") == true)
    }

    @Test("⚠️ 流中途报错（余额不足）→ **绝不能当成成功**，要停下来告诉用户去充值")
    func midStreamErrorSurfaces() {
        let model = WireLevelModel(family: .openAIChat, quirks: .relay,
                                   toolRegistry: readSpecs(), script: { round in
            round == 0
                ? [#"data: {"error":{"code":402,"message":"Insufficient credits"}}"# + "\n\n"]
                : [#"data: {"choices":[{"delta":{"content":"好了"}}]}"# + "\n\n"]
        })
        let (state, events, _) = TurnRunner.run(TurnState(objective: "看一下 notes.md"),
                                                deps: wireDeps(model), config: wireConfig())
        // 402 是**用户能修**的问题（去充值）→ 不重试、不继续，直接停下说清楚
        #expect(state.status == .failed, "余额不足却报成功，是最坏的一种失败：\(state.status)")
        #expect(model.exchanges.count == 1, "配置类错误不该被重试（实际往返 \(model.exchanges.count) 次）")
        let failure = events.last { $0.kind == .modelCallFailed }
        let message = failure?.payload.value(at: ["message"])?.stringValue ?? ""
        #expect(message.contains("余额"), "要告诉用户是余额问题：\(message)")
        #expect(message.contains("充值"), "而且要给出下一步：\(message)")
    }
}

@Suite("错误分类 —— 分类的唯一目的是决定谁来处理（docs/03 §7）")

struct ProviderErrorClassificationTests {

    /// 造一个"像真的"的错误：原始文案 + 分类后的面向用户文案
    private func classified(_ status: Int?, _ message: String) -> ProviderError {
        let kind = ProviderError.classify(statusCode: status, message: message)
        return ProviderError(kind: kind, providerID: "p", statusCode: status, message: message,
                             userFacingMessage: ProviderError.userFacing(kind: kind, statusCode: status, raw: message))
    }

    @Test("⭐⭐ 密钥 / 余额 / 权限错误一律**不可重试**（重试只会让用户看到反复失败）")
    func configurationErrorsAreNotRetryable() {
        for status in [401, 402, 403] {
            let error = classified(status, "nope")
            #expect(error.kind == .configuration, "\(status) 应当是配置问题，实际 \(error.kind)")
            #expect(!error.isRetryable, "\(status) 绝不该重试")
            if case .askUserToFixConfig = RetryPolicy.decide(error: error, attempt: 1).action {
                // 正确：让用户去改
            } else {
                Issue.record("\(status) 应当让用户去修配置")
            }
        }
    }

    @Test("⭐ 限流与 5xx 可重试（等一等真的会好）")
    func transientErrorsAreRetryable() {
        for status in [429, 500, 502, 503, 529] {
            let error = classified(status, "busy")
            #expect(error.kind == .transient, "\(status) 应当是瞬时问题，实际 \(error.kind)")
            #expect(error.isRetryable)
        }
    }

    @Test("⭐ 上下文超限优先识别（有些端点用 400 表达）")
    func contextOverflowIsDetected() {
        let cases = ["This model's maximum context length is 128000 tokens",
                     "prompt is too long: 200000 tokens",
                     "输入上下文超过了模型上限"]
        for message in cases {
            #expect(classified(400, message).kind == .contextOverflow, "没认出：\(message)")
        }
        #expect(classified(nil, "context_length_exceeded").kind == .contextOverflow)
    }

    @Test("⚠️ 没有状态码时从文案里认（部分中转站不给状态码）")
    func statuslessErrorsAreStillClassified() {
        #expect(classified(nil, "Insufficient credits").kind == .configuration)
        #expect(classified(nil, "invalid api key").kind == .configuration)
        #expect(classified(nil, "余额不足").kind == .configuration)
        // 认不出来就老实说不知道，不要瞎猜成"可重试"
        #expect(classified(nil, "??? ").kind == .unknown)
        #expect(!classified(nil, "??? ").isRetryable)
    }

    @Test("⭐ 面向用户的话要说清楚「怎么了」和「下一步做什么」")
    func userFacingMessagesAreActionable() {
        let balance = classified(402, "Insufficient credits")
        #expect(balance.userFacingMessage.contains("余额"))
        #expect(balance.userFacingMessage.contains("充值") || balance.userFacingMessage.contains("换一个渠道"))

        let auth = classified(401, "bad key")
        #expect(auth.userFacingMessage.contains("密钥"))

        let limited = classified(429, "slow down")
        #expect(limited.userFacingMessage.contains("稍等"))
    }

    @Test("⭐ Anthropic 的错误体没有状态码，靠 type 映射（否则只能一律当可重试）")
    func anthropicTypeMapping() {
        #expect(ProviderError.statusCode(forAnthropicType: "overloaded_error") == 529)
        #expect(ProviderError.statusCode(forAnthropicType: "rate_limit_error") == 429)
        #expect(ProviderError.statusCode(forAnthropicType: "authentication_error") == 401)
        #expect(ProviderError.statusCode(forAnthropicType: "invalid_request_error") == 400)
        #expect(ProviderError.statusCode(forAnthropicType: nil) == nil)

        // 映射之后分类才正确：鉴权错误绝不能重试
        let auth = classified(ProviderError.statusCode(forAnthropicType: "authentication_error"), "invalid x-api-key")
        #expect(auth.kind == .configuration)
        #expect(!auth.isRetryable)
        let overloaded = classified(ProviderError.statusCode(forAnthropicType: "overloaded_error"), "overloaded")
        #expect(overloaded.isRetryable)
    }

    @Test("⚠️ 真实字节流里的 402 会被解成「不可重试的配置问题」（端到端）")
    func decodedErrorIsClassified() {
        var decoder = AnyStreamDecoder.make(family: .openAIChat, quirks: .relay, model: "m")
        var parser = SSEParser()
        var events: [ModelEvent] = []
        for chunk in [#"data: {"error":{"code":402,"message":"Insufficient credits"}}"# + "\n\n"] {
            for event in parser.ingest(Data(chunk.utf8)) { events.append(contentsOf: decoder.ingest(event)) }
        }
        events.append(contentsOf: decoder.finish())
        let error = events.compactMap { if case .providerError(let e) = $0 { return e }; return nil }.first
        #expect(error?.statusCode == 402)
        #expect(error?.kind == .configuration, "实际 \(String(describing: error?.kind))")
        #expect(error?.isRetryable == false)
        #expect(error?.userFacingMessage.contains("余额") == true)
    }
}

@Suite("令牌有效期必须由注入的时钟决定（不是真实时钟）")

struct CapabilityExpiryDeterminismTests {

    private func context(expiresAt: Date) -> PolicyEngine.Context {
        let token = CapabilityToken(
            issuedForTurn: UUID(),
            scopes: [.fsRead(VFSPath(mount: .workspace))],
            expiresAt: expiresAt,
            grantedBy: .planApproval, reason: "到期判定的确定性测试"
        )
        return PolicyEngine.Context(trustDial: .collaborate, token: token, planApproved: true)
    }

    private func invocation() -> PolicyEngine.Invocation {
        let spec = readSpecs()[ToolName.readFile]!
        return PolicyEngine.Invocation(tool: spec, path: VFSPath(mount: .workspace, components: ["notes.md"]),
                                       access: .readOnly)
    }

    @Test("⭐ 时钟冻结在过去时，只要令牌在那一刻还没过期，就必须放行")
    func frozenClockDoesNotSilentlyExpire() {
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        // 令牌在冻结时刻之后 1 小时到期
        let decision = PolicyEngine().evaluate(invocation(),
                                              context: context(expiresAt: frozen.addingTimeInterval(3600)),
                                              now: frozen)
        #expect(decision.isAllowed, "冻结时钟不该让授权静默失效：\(decision)")
    }

    @Test("⭐ 真的过期了要拒（而且理由可读）")
    func trulyExpiredIsDenied() {
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let decision = PolicyEngine().evaluate(invocation(),
                                              context: context(expiresAt: frozen.addingTimeInterval(-1)),
                                              now: frozen)
        #expect(decision.isDenied)
        #expect("\(decision)".contains("过期"), "拒绝理由要能解释：\(decision)")
    }

    @Test("⚠️ 同一个输入在同一时刻必须得到同一个结论（这就是它之前不成立的地方）")
    func decisionIsReproducible() {
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let ctx = context(expiresAt: frozen.addingTimeInterval(3600))
        let engine = PolicyEngine()
        let first = engine.evaluate(invocation(), context: ctx, now: frozen)
        let second = engine.evaluate(invocation(), context: ctx, now: frozen)
        #expect(first == second)
        // 而"真实时钟"下的默认值不该被用到 —— 冻结在过去仍然放行就说明它没被读
        #expect(engine.evaluate(invocation(), context: ctx, now: frozen).isAllowed)
    }
}
