import Testing
import Foundation
@testable import RuneKernel

// MARK: - SSE / NDJSON 解析
//
// 真实世界的 SSE 非常脏：心跳、注释、跨包断开、UTF-8 多字节被切断、不发 [DONE]…
// 这些都必须容错，否则"偶尔卡住"会变成最难查的线上问题。

@Suite("SSEParser —— 增量且容错的 SSE 解析")
struct SSEParserTests {

    private func events(_ chunks: [String]) -> [SSEEvent] {
        var parser = SSEParser()
        var out: [SSEEvent] = []
        for chunk in chunks { out.append(contentsOf: parser.ingest(Data(chunk.utf8))) }
        out.append(contentsOf: parser.finish())
        return out
    }

    @Test("单包内多个事件")
    func multipleEventsInOneChunk() {
        let out = events(["data: {\"a\":1}\n\ndata: {\"b\":2}\n\n"])
        #expect(out.count == 2)
        #expect(out[0].data == #"{"a":1}"#)
        #expect(out[1].data == #"{"b":2}"#)
    }

    @Test("⚠️ 事件跨网络包断开（最常见的真实情况）")
    func eventsSplitAcrossChunks() {
        let out = events(["data: {\"a\"", ":1}\n", "\ndata: {\"b\":2}", "\n\n"])
        #expect(out.count == 2)
        #expect(out[0].data == #"{"a":1}"#)
        #expect(out[1].data == #"{"b":2}"#)
    }

    @Test("⚠️ UTF-8 多字节字符被网络包切断也不能丢数据")
    func utf8SplitAcrossChunks() {
        // "中文" 的 UTF-8 是 6 个字节；故意从第 2 个字节中间切开
        let full = "data: 中文\n\n"
        let bytes = Array(full.utf8)
        var parser = SSEParser()
        var out = parser.ingest(Data(bytes[0..<8]))     // 切在"中"字中间
        out += parser.ingest(Data(bytes[8...]))
        out += parser.finish()
        #expect(out.count == 1)
        #expect(out[0].data == "中文")
    }

    @Test("CRLF 换行")
    func crlfLineEndings() {
        let out = events(["data: hello\r\n\r\n"])
        #expect(out.count == 1)
        #expect(out[0].data == "hello")
    }

    @Test("⚠️ 注释行（心跳）被忽略但被计数（uni-api 发 `: keepalive`）")
    func commentsAreIgnoredButCounted() {
        var parser = SSEParser()
        var out = parser.ingest(Data(": keepalive\n\ndata: x\n\n: keepalive\n\n".utf8))
        out += parser.finish()
        #expect(out.count == 1)
        #expect(out[0].data == "x")
        #expect(parser.commentCount == 2)
        #expect(parser.diagnostics.contains("心跳"))
    }

    @Test("命名事件（Anthropic 用它分类）")
    func namedEvents() {
        let out = events(["event: content_block_delta\ndata: {\"x\":1}\n\n"])
        #expect(out.count == 1)
        #expect(out[0].name == "content_block_delta")
    }

    @Test("多行 data 用换行拼接（SSE 规范）")
    func multilineData() {
        let out = events(["data: line1\ndata: line2\n\n"])
        #expect(out.count == 1)
        #expect(out[0].data == "line1\nline2")
    }

    @Test("⚠️ 流结束时残留缓冲要被处理（有些服务端最后一帧不带结尾空行）")
    func finishFlushesResidual() {
        var parser = SSEParser()
        let partial = parser.ingest(Data(#"data: {"a":1}"#.utf8))   // 没有结尾 \n\n
        #expect(partial.isEmpty)
        let flushed = parser.finish()
        #expect(flushed.count == 1)
        #expect(flushed[0].data == #"{"a":1}"#)
    }

    @Test("[DONE] 标记被识别")
    func doneMarker() {
        let out = events(["data: [DONE]\n\n"])
        #expect(out.count == 1)
        #expect(out[0].isDoneMarker)
    }

    @Test("空行不会产生幽灵事件")
    func blankLinesProduceNothing() {
        let out = events(["\n\n\n\n", "data: x\n\n", "\n\n"])
        #expect(out.count == 1)
    }

    @Test("字段切分：冒号后只吃掉一个空格")
    func fieldSplitting() {
        #expect(SSEParser.splitField("data:  x").value == " x")
        #expect(SSEParser.splitField("data:x").value == "x")
        #expect(SSEParser.splitField("data:").value == "")
        #expect(SSEParser.splitField("event").field == "event")
    }

    @Test("id 与 retry 字段被容忍（retry 忽略）")
    func idAndRetryTolerated() {
        let out = events(["id: 42\nretry: 3000\ndata: x\n\n"])
        #expect(out.count == 1)
        #expect(out[0].id == "42")
    }
}

@Suite("NDJSONParser —— Ollama 原生端点")
struct NDJSONParserTests {

    @Test("每行一个 JSON 对象（不是 SSE！）")
    func linePerObject() {
        var parser = NDJSONParser()
        var out = parser.ingest(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        out += parser.finish()
        #expect(out.count == 2)
        #expect(out[0] == #"{"a":1}"#)
    }

    @Test("跨包断开的行")
    func splitAcrossChunks() {
        var parser = NDJSONParser()
        var out = parser.ingest(Data("{\"a\"".utf8))
        #expect(out.isEmpty)
        out += parser.ingest(Data(":1}\n".utf8))
        #expect(out.count == 1)
    }

    @Test("流结束时的残留行")
    func residualAtFinish() {
        var parser = NDJSONParser()
        _ = parser.ingest(Data("{\"a\":1}".utf8))   // 无换行
        let out = parser.finish()
        #expect(out.count == 1)
    }

    @Test("空行被跳过")
    func blankLinesSkipped() {
        var parser = NDJSONParser()
        var out = parser.ingest(Data("\n\n{\"a\":1}\n\n".utf8))
        out += parser.finish()
        #expect(out.count == 1)
    }
}

// MARK: - 请求序列化

@Suite("RequestEncoder —— 请求序列化")
struct RequestEncoderTests {

    private let readTool = ToolSpec(
        name: "read_file",
        description: "读文件\n何时不要用：目录",
        inputSchema: .object(
            properties: ["path": .string(enumValues: nil, minLength: nil, maxLength: nil)],
            required: ["path"], additionalProperties: false
        )
    )

    private func request(
        withTools: Bool = true,
        reasoning: ReasoningRequest? = nil,
        messages: [Message]? = nil
    ) -> ChatRequest {
        ChatRequest(
            systemBlocks: [
                SystemBlock(layer: .identity, label: "契约", text: "你是 Rune。"),
                SystemBlock(layer: .projectStable, label: "项目", text: "这是 shop-api。"),
                SystemBlock(layer: .sessionVolatile, label: "本轮", text: "目标：修测试。"),
            ],
            messages: messages ?? [Message(role: .user, blocks: [.text("修一下退款测试", origin: .userInstruction)], origin: .userInstruction)],
            tools: withTools ? [readTool] : [],
            maxOutputTokens: 4096,
            reasoning: reasoning
        )
    }

    // MARK: OpenAI Chat

    @Test("OpenAI Chat：system 作为消息、工具用 function 包装")
    func openAIChat() throws {
        let body = RequestEncoder.encode(request(), family: .openAIChat, model: "m", quirks: .openAICompatible)
        #expect(body.value(at: ["model"]) == .string("m"))
        #expect(body.value(at: ["messages", "0", "role"]) == .string("system"))
        #expect(body.value(at: ["messages", "0", "content"])?.stringValue?.contains("你是 Rune。") == true)
        #expect(body.value(at: ["messages", "1", "role"]) == .string("user"))
        #expect(body.value(at: ["tools", "0", "type"]) == .string("function"))
        #expect(body.value(at: ["tools", "0", "function", "name"]) == .string("read_file"))
        #expect(body.value(at: ["tools", "0", "function", "parameters", "type"]) == .string("object"))
        #expect(body.value(at: ["tool_choice"]) == .string("auto"))
        #expect(body.value(at: ["stream"]) == .bool(true))
        #expect(body.value(at: ["stream_options", "include_usage"]) == .bool(true))
        #expect(body.value(at: ["max_tokens"]) == .int(4096))
    }

    @Test("⚠️ maxTokens 字段名因厂商而异（写错直接 400）")
    func maxTokensFieldName() {
        var quirks = ProviderQuirks.openAIResponses
        let body = RequestEncoder.encode(request(), family: .openAIResponses, model: "m", quirks: quirks)
        #expect(body.value(at: ["max_output_tokens"]) == .int(4096))
        #expect(body.value(at: ["max_tokens"]) == nil)

        quirks = ProviderQuirks.openAICompatible
        let chat = RequestEncoder.encode(request(), family: .openAIChat, model: "m", quirks: quirks)
        #expect(chat.value(at: ["max_tokens"]) == .int(4096))
    }

    @Test("工具调用与工具结果的消息形态")
    func assistantToolCallsAndResults() throws {
        let call = ToolCall(id: "c1", name: "read_file", argumentsJSON: Data(#"{"path":"a"}"#.utf8))
        let messages = [
            Message(role: .user, blocks: [.text("读一下", origin: .userInstruction)], origin: .userInstruction),
            Message(role: .assistant, blocks: [
                .text("好", origin: .modelOutput),
                ContentBlock(kind: .toolCall(call), origin: .modelOutput),
            ], origin: .modelOutput),
            Message(role: .tool, blocks: [
                ContentBlock(kind: .toolResult(.ok(callID: "c1", summary: "内容")), origin: .toolResultTrusted),
            ], origin: .toolResultTrusted),
        ]
        let body = RequestEncoder.encode(request(messages: messages), family: .openAIChat, model: "m", quirks: .openAICompatible)

        #expect(body.value(at: ["messages", "2", "role"]) == .string("assistant"))
        #expect(body.value(at: ["messages", "2", "tool_calls", "0", "id"]) == .string("c1"))
        #expect(body.value(at: ["messages", "2", "tool_calls", "0", "type"]) == .string("function"))
        #expect(body.value(at: ["messages", "2", "tool_calls", "0", "function", "name"]) == .string("read_file"))
        // arguments 必须是**字符串**形式的 JSON，不是对象
        #expect(body.value(at: ["messages", "2", "tool_calls", "0", "function", "arguments"])?.stringValue == #"{"path":"a"}"#)
        #expect(body.value(at: ["messages", "3", "role"]) == .string("tool"))
        #expect(body.value(at: ["messages", "3", "tool_call_id"]) == .string("c1"))
    }

    @Test("⚠️ requiresToolResultName 的端点要求 tool 消息带 name")
    func toolResultNameQuirk() {
        let call = ToolCall(id: "c1", name: "read_file", argumentsJSON: Data("{}".utf8))
        let messages = [Message(role: .tool, blocks: [
            ContentBlock(kind: .toolResult(.ok(callID: "c1", summary: "x")), origin: .toolResultTrusted),
        ], origin: .toolResultTrusted)]

        var quirks = ProviderQuirks.openAICompatible
        quirks.requiresToolResultName = true
        let body = RequestEncoder.encode(request(messages: messages), family: .openAIChat, model: "m", quirks: quirks)
        #expect(body.value(at: ["messages", "1", "name"]) != nil)
        _ = call
    }

    @Test("unsupportedFields 会被剔除（某些端点见未知字段就 400）")
    func unsupportedFieldsRemoved() {
        var quirks = ProviderQuirks.openAICompatible
        quirks.unsupportedFields = ["stream_options", "temperature"]
        var req = request()
        req.temperature = 0.5
        let body = RequestEncoder.encode(req, family: .openAIChat, model: "m", quirks: quirks)
        #expect(body.value(at: ["stream_options"]) == nil)
        #expect(body.value(at: ["temperature"]) == nil)
    }

    // MARK: OpenAI Responses

    @Test("Responses：instructions + function_call/function_call_output + strict 工具")
    func openAIResponses() throws {
        let call = ToolCall(id: "c1", name: "read_file", argumentsJSON: Data(#"{"path":"a"}"#.utf8))
        let messages = [
            Message(role: .user, blocks: [.text("读", origin: .userInstruction)], origin: .userInstruction),
            Message(role: .assistant, blocks: [ContentBlock(kind: .toolCall(call), origin: .modelOutput)], origin: .modelOutput),
            Message(role: .tool, blocks: [ContentBlock(kind: .toolResult(.ok(callID: "c1", summary: "内容")), origin: .toolResultTrusted)], origin: .toolResultTrusted),
        ]
        let body = RequestEncoder.encode(request(messages: messages), family: .openAIResponses, model: "m", quirks: .openAIResponses)

        #expect(body.value(at: ["instructions"])?.stringValue?.contains("你是 Rune。") == true)
        #expect(body.value(at: ["input", "0", "type"]) == .string("message"))
        #expect(body.value(at: ["input", "0", "content", "0", "type"]) == .string("input_text"))
        #expect(body.value(at: ["input", "1", "type"]) == .string("function_call"))
        #expect(body.value(at: ["input", "1", "call_id"]) == .string("c1"))
        #expect(body.value(at: ["input", "2", "type"]) == .string("function_call_output"))
        #expect(body.value(at: ["tools", "0", "strict"]) == .bool(true))
        // GPT-5.6+ 不打点就不产生缓存写入
        #expect(body.value(at: ["prompt_cache_options", "mode"]) == .string("explicit"))
    }

    @Test("Responses：reasoning.summary 必须显式要求才会返回摘要")
    func reasoningSummaryRequested() {
        let body = RequestEncoder.encode(
            request(reasoning: .effort(.high)), family: .openAIResponses, model: "m", quirks: .openAIResponses
        )
        #expect(body.value(at: ["reasoning", "effort"]) == .string("high"))
        #expect(body.value(at: ["reasoning", "summary"]) == .string("auto"))
    }

    // MARK: Anthropic

    @Test("Anthropic：system 是顶层参数、工具用 input_schema")
    func anthropicShape() throws {
        let body = RequestEncoder.encode(request(), family: .anthropicMessages, model: "m", quirks: .anthropic)
        #expect(body.value(at: ["system", "0", "type"]) == .string("text"))
        #expect(body.value(at: ["system", "0", "text"])?.stringValue?.contains("你是 Rune。") == true)
        #expect(body.value(at: ["messages", "0", "role"]) == .string("user"))
        #expect(body.value(at: ["tools", "0", "input_schema", "type"]) == .string("object"))
        #expect(body.value(at: ["max_tokens"]) == .int(4096))
    }

    @Test("⚠️ Anthropic 缓存断点：只断在稳定层，且最多 4 个")
    func anthropicCacheBreakpoints() {
        let body = RequestEncoder.encode(request(), family: .anthropicMessages, model: "m", quirks: .anthropic)
        let system = body.value(at: ["system"])?.arrayValue ?? []
        // 层 1、2 各一个断点；层 3 不断（它每轮都变）
        let withCache = system.enumerated().filter { $0.element.value(at: ["cache_control"]) != nil }.map(\.offset)
        #expect(withCache == [0, 1])
        // 工具定义也占一个断点
        #expect(body.value(at: ["tools", "0", "cache_control", "type"]) == .string("ephemeral"))
    }

    @Test("⚠️ Anthropic：thinking 块必须排在 text 之前，且缺 signature 就不回传")
    func anthropicThinkingOrderAndSignature() throws {
        let signature = Data([1, 2, 3])
        let messages = [
            Message(role: .user, blocks: [.text("问题", origin: .userInstruction)], origin: .userInstruction),
            Message(role: .assistant, blocks: [
                ContentBlock(kind: .text("回答"), origin: .modelOutput),           // text 在前
                ContentBlock(kind: .reasoning(text: "思考", signature: signature), origin: .modelOutput), // thinking 在后
            ], origin: .modelOutput),
        ]
        let body = RequestEncoder.encode(request(messages: messages), family: .anthropicMessages, model: "m", quirks: .anthropic)
        let content = body.value(at: ["messages", "1", "content"])?.arrayValue ?? []
        #expect(content.first?.value(at: ["type"]) == .string("thinking"), "thinking 必须被提到最前")
        #expect(content.first?.value(at: ["signature"])?.stringValue == signature.base64EncodedString())

        // 没有 signature 的思考块**不能**回传（否则 400）
        let noSignature = [
            Message(role: .user, blocks: [.text("x", origin: .userInstruction)], origin: .userInstruction),
            Message(role: .assistant, blocks: [
                ContentBlock(kind: .reasoning(text: "思考", signature: nil), origin: .modelOutput),
                ContentBlock(kind: .text("回答"), origin: .modelOutput),
            ], origin: .modelOutput),
        ]
        let body2 = RequestEncoder.encode(request(messages: noSignature), family: .anthropicMessages, model: "m", quirks: .anthropic)
        let content2 = body2.value(at: ["messages", "1", "content"])?.arrayValue ?? []
        #expect(content2.allSatisfy { $0.value(at: ["type"]) != .string("thinking") })
    }

    @Test("Anthropic：只用自适应思考（手动 budget_tokens 在 4.7+ 会 400）")
    func anthropicAdaptiveThinking() {
        let body = RequestEncoder.encode(
            request(reasoning: .effort(.high)), family: .anthropicMessages, model: "m", quirks: .anthropic
        )
        #expect(body.value(at: ["thinking", "type"]) == .string("adaptive"))
        #expect(body.value(at: ["thinking", "budget_tokens"]) == nil)
        #expect(body.value(at: ["output_config", "effort"]) == .string("high"))
    }

    // MARK: Gemini

    @Test("Gemini：contents 用 user/model 角色、systemInstruction 顶层、functionDeclarations")
    func geminiShape() throws {
        let call = ToolCall(id: "c1", name: "read_file", argumentsJSON: Data(#"{"path":"a"}"#.utf8))
        let messages = [
            Message(role: .user, blocks: [.text("读", origin: .userInstruction)], origin: .userInstruction),
            Message(role: .assistant, blocks: [ContentBlock(kind: .toolCall(call), origin: .modelOutput)], origin: .modelOutput),
            Message(role: .tool, blocks: [ContentBlock(kind: .toolResult(.ok(callID: "c1", summary: "内容")), origin: .toolResultTrusted)], origin: .toolResultTrusted),
        ]
        let body = RequestEncoder.encode(request(messages: messages), family: .geminiGenerate, model: "m", quirks: .gemini)

        #expect(body.value(at: ["systemInstruction", "parts", "0", "text"])?.stringValue?.contains("你是 Rune。") == true)
        #expect(body.value(at: ["contents", "0", "role"]) == .string("user"))
        #expect(body.value(at: ["contents", "1", "role"]) == .string("model"))
        #expect(body.value(at: ["contents", "1", "parts", "0", "functionCall", "name"]) == .string("read_file"))
        // ⚠️ Gemini 拿的是**对象**形式的 args，不是字符串
        #expect(body.value(at: ["contents", "1", "parts", "0", "functionCall", "args", "path"]) == .string("a"))
        #expect(body.value(at: ["contents", "2", "parts", "0", "functionResponse"]) != nil)
        #expect(body.value(at: ["tools", "0", "functionDeclarations", "0", "name"]) == .string("read_file"))
        #expect(body.value(at: ["generationConfig", "maxOutputTokens"]) == .int(4096))
    }

    // MARK: 思考链回传策略

    @Test("⚠️ DeepSeek：只有带 tools 时才回传 reasoning_content（否则 400）")
    func deepSeekReasoningReplay() {
        let assistant = Message(role: .assistant, blocks: [
            ContentBlock(kind: .reasoning(text: "我先想一下", signature: nil), origin: .modelOutput),
            ContentBlock(kind: .text("好的"), origin: .modelOutput),
        ], origin: .modelOutput)
        let messages = [
            Message(role: .user, blocks: [.text("x", origin: .userInstruction)], origin: .userInstruction),
            assistant,
        ]

        // 带 tools → 必须回传
        let withTools = RequestEncoder.encode(
            request(withTools: true, messages: messages), family: .openAIChat, model: "m", quirks: .deepSeek
        )
        #expect(withTools.value(at: ["messages", "2", "reasoning_content"]) == .string("我先想一下"))

        // 不带 tools → 不回传（带了反而多余）
        let withoutTools = RequestEncoder.encode(
            request(withTools: false, messages: messages), family: .openAIChat, model: "m", quirks: .deepSeek
        )
        #expect(withoutTools.value(at: ["messages", "2", "reasoning_content"]) == nil)
    }

    @Test("推理档位映射：不支持的档位要就近降级（不能直传）")
    func reasoningEffortMapping() {
        #expect(ReasoningEffort.medium.mapped(toSupported: [.low, .high, .max], fallback: .high) == .high)
        #expect(ReasoningEffort.xhigh.mapped(toSupported: [.low, .high, .max], fallback: .high) == .max)
        #expect(ReasoningEffort.none.mapped(toSupported: [.low, .high], fallback: .high) == .low)
        #expect(ReasoningEffort.low.mapped(toSupported: [.low, .high], fallback: .high) == .low)
    }

    @Test("请求路径按协议族生成")
    func requestPaths() {
        #expect(RequestEncoder.path(family: .openAIChat, model: "m") == "/chat/completions")
        #expect(RequestEncoder.path(family: .openAIResponses, model: "m") == "/responses")
        #expect(RequestEncoder.path(family: .anthropicMessages, model: "m") == "/messages")
        #expect(RequestEncoder.path(family: .geminiGenerate, model: "m").contains("streamGenerateContent"))
    }

    @Test("请求指纹对同内容稳定（幂等去重的前提）")
    func fingerprintStability() {
        let a = request()
        let b = request()
        #expect(a.fingerprintBody() == b.fingerprintBody())

        var c = request()
        c.maxOutputTokens = 999
        #expect(a.fingerprintBody() != c.fingerprintBody())
    }
}

// MARK: - 响应解码

@Suite("StreamDecoder —— 响应解码")
struct StreamDecoderTests {

    private func feed(_ decoder: inout AnyStreamDecoder, _ raw: [String]) -> [ModelEvent] {
        var parser = SSEParser()
        var out: [ModelEvent] = []
        for chunk in raw {
            for event in parser.ingest(Data(chunk.utf8)) { out.append(contentsOf: decoder.ingest(event)) }
        }
        for event in parser.finish() { out.append(contentsOf: decoder.ingest(event)) }
        out.append(contentsOf: decoder.finish())
        return out
    }

    private func texts(_ events: [ModelEvent]) -> String {
        events.compactMap { if case .textDelta(let t) = $0 { return t }; return nil }.joined()
    }
    private func reasonings(_ events: [ModelEvent]) -> String {
        events.compactMap { if case .reasoningDelta(let t) = $0 { return t }; return nil }.joined()
    }
    private func finished(_ events: [ModelEvent]) -> FinishReason? {
        for event in events { if case .finished(let r) = event { return r } }
        return nil
    }
    private func usage(_ events: [ModelEvent]) -> TokenUsage? {
        for event in events { if case .usage(let u) = event { return u } }
        return nil
    }

    // MARK: OpenAI Chat

    @Test("OpenAI Chat：文本增量 + 工具分片 + 用量 + 结束原因")
    func openAIChatStream() {
        var d = AnyStreamDecoder.make(family: .openAIChat, quirks: .openAICompatible, model: "m")
        let events = feed(&d, [
            #"data: {"choices":[{"delta":{"content":"我来"}}]}"# + "\n\n",
            #"data: {"choices":[{"delta":{"content":"看看"}}]}"# + "\n\n",
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read_file","arguments":"{\"pa"}}]}}]}"# + "\n\n",
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"a\"}"}}]}}]}"# + "\n\n",
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":100,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":80}}}"# + "\n\n",
            "data: [DONE]\n\n",
        ])
        #expect(texts(events) == "我来看看")
        #expect(finished(events) == .toolCalls)
        let u = usage(events)
        #expect(u?.inputTokens == 100)
        #expect(u?.cachedInputTokens == 80)
        // started 只应出现一次
        #expect(events.filter { if case .started = $0 { return true }; return false }.count == 1)
    }

    @Test("⚠️ 中转站不发 [DONE] 也不发 finish_reason → finish() 兜底")
    func missingFinishReasonFallback() {
        var d = AnyStreamDecoder.make(family: .openAIChat, quirks: .relay, model: "m")
        let events = feed(&d, [#"data: {"choices":[{"delta":{"content":"hi"}}]}"# + "\n\n"])
        #expect(texts(events) == "hi")
        #expect(finished(events) == .unknown)
    }

    @Test("⚠️ 流中途的错误对象（OpenRouter 就是这个形状）")
    func midStreamError() {
        var d = AnyStreamDecoder.make(family: .openAIChat, quirks: .relay, model: "m")
        let events = feed(&d, [
            #"data: {"choices":[{"delta":{"content":"部分"}}]}"# + "\n\n",
            #"data: {"error":{"code":402,"message":"Insufficient credits"}}"# + "\n\n",
        ])
        let error = events.compactMap { if case .providerError(let e) = $0 { return e }; return nil }.first
        #expect(error?.statusCode == 402)
        #expect(error?.userFacingMessage.contains("Insufficient") == true)
    }

    @Test("DeepSeek 的 reasoning_content 被识别为思考链")
    func deepSeekReasoning() {
        var d = AnyStreamDecoder.make(family: .openAIChat, quirks: .deepSeek, model: "m")
        let events = feed(&d, [
            #"data: {"choices":[{"delta":{"reasoning_content":"先分析"}}]}"# + "\n\n",
            #"data: {"choices":[{"delta":{"content":"结论"}}]}"# + "\n\n",
        ])
        #expect(reasonings(events) == "先分析")
        #expect(texts(events) == "结论")
    }

    // MARK: OpenAI Responses

    @Test("Responses：语义化事件流")
    func responsesStream() {
        var d = AnyStreamDecoder.make(family: .openAIResponses, quirks: .openAIResponses, model: "m")
        let events = feed(&d, [
            "event: response.output_text.delta\ndata: {\"delta\":\"你好\"}\n\n",
            "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"read_file\"}}\n\n",
            "event: response.function_call_arguments.delta\ndata: {\"output_index\":0,\"delta\":\"{\\\"path\\\"\"}\n\n",
            "event: response.function_call_arguments.delta\ndata: {\"output_index\":0,\"delta\":\":\\\"a\\\"}\"}\n\n",
            "event: response.function_call_arguments.done\ndata: {\"output_index\":0,\"arguments\":\"{\\\"path\\\":\\\"a\\\"}\"}\n\n",
            "event: response.completed\ndata: {\"response\":{\"usage\":{\"prompt_tokens\":50,\"completion_tokens\":10}}}\n\n",
        ])
        #expect(texts(events) == "你好")
        #expect(finished(events) == .toolCalls)
        #expect(usage(events)?.inputTokens == 50)

        let started = events.compactMap { if case .toolCallStarted(let i, let id, let name) = $0 { return (i, id, name) }; return nil }
        #expect(started.count == 1)
        #expect(started[0].1 == "c1")
        #expect(started[0].2 == "read_file")
    }

    // MARK: Anthropic

    @Test("Anthropic：命名事件 + 工具块 + 签名 + 累积用量")
    func anthropicStream() {
        var d = AnyStreamDecoder.make(family: .anthropicMessages, quirks: .anthropic, model: "claude")
        let events = feed(&d, [
            "event: message_start\ndata: {\"message\":{\"usage\":{\"input_tokens\":200,\"cache_read_input_tokens\":150}}}\n\n",
            "event: content_block_start\ndata: {\"index\":0,\"content_block\":{\"type\":\"thinking\"}}\n\n",
            "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"我需要先看代码\"}}\n\n",
            "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"AQID\"}}\n\n",
            "event: content_block_start\ndata: {\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read_file\"}}\n\n",
            "event: content_block_delta\ndata: {\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\"\"}}\n\n",
            "event: content_block_delta\ndata: {\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\":\\\"a\\\"}\"}\n\n",
            "event: content_block_stop\ndata: {\"index\":1}\n\n",
            "event: message_delta\ndata: {\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":42}}\n\n",
            "event: message_stop\ndata: {}\n\n",
        ])
        #expect(reasonings(events) == "我需要先看代码")
        #expect(finished(events) == .toolCalls)

        let signatures = events.compactMap { if case .reasoningSignature(let d) = $0 { return d }; return nil }
        #expect(signatures.first == Data([1, 2, 3]))

        let started = events.compactMap { if case .toolCallStarted(_, let id, let name) = $0 { return (id, name) }; return nil }
        #expect(started.first?.0 == "toolu_1")
        #expect(started.first?.1 == "read_file")

        let u = usage(events)
        #expect(u?.cachedInputTokens == 150)
    }

    @Test("Anthropic 的 error 事件（overloaded_error → 529）")
    func anthropicError() {
        var d = AnyStreamDecoder.make(family: .anthropicMessages, quirks: .anthropic, model: "m")
        let events = feed(&d, [
            "event: error\ndata: {\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n",
        ])
        let error = events.compactMap { if case .providerError(let e) = $0 { return e }; return nil }.first
        #expect(error?.statusCode == 529)
    }

    // MARK: Gemini

    @Test("Gemini：parts 里的 text / thought / functionCall")
    func geminiStream() {
        var d = AnyStreamDecoder.make(family: .geminiGenerate, quirks: .gemini, model: "gemini")
        let events = feed(&d, [
            #"data: {"candidates":[{"content":{"parts":[{"text":"让我看看"}]}}]}"# + "\n\n",
            #"data: {"candidates":[{"content":{"parts":[{"thought":true,"text":"先分析"}]}}]}"# + "\n\n",
            #"data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"read_file","args":{"path":"a"}}}]}}]}"# + "\n\n",
            #"data: {"candidates":[{"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":30,"candidatesTokenCount":8}}"# + "\n\n",
        ])
        #expect(texts(events) == "让我看看")
        #expect(reasonings(events) == "先分析")
        #expect(finished(events) == .toolCalls)      // 有 functionCall → 修正为 toolCalls
        #expect(usage(events)?.inputTokens == 30)

        let completed = events.compactMap {
            if case .toolCallCompleted(_, _, let name, let args) = $0 { return (name, String(decoding: args, as: UTF8.self)) }
            return nil
        }
        #expect(completed.first?.0 == "read_file")
        #expect(completed.first?.1.contains("\"path\"") == true)
    }

    // MARK: Ollama

    @Test("Ollama：NDJSON 逐行解析")
    func ollamaNDJSON() {
        var d = AnyStreamDecoder.make(family: .ollamaNative, quirks: .relay, model: "qwen")
        let lines = [
            #"{"message":{"role":"assistant","content":"你好"},"done":false}"#,
            #"{"message":{"role":"assistant","tool_calls":[{"function":{"name":"read_file","arguments":{"path":"a"}}}]},"done":false}"#,
            #"{"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":12,"eval_count":5}"#,
        ]
        var events: [ModelEvent] = []
        for line in lines { events.append(contentsOf: d.ingestLine(line)) }
        events.append(contentsOf: d.finish())

        #expect(texts(events) == "你好")
        #expect(finished(events) == .toolCalls)
        #expect(usage(events)?.inputTokens == 12)
    }

    // MARK: 端到端（最高价值的测试）

    @Test("⚠️【端到端】真实 SSE 字节流 → 解析 → 解码 → 工具调用拼装")
    func endToEndPipeline() {
        // 模拟一段真实录制的流：故意切成不规则的网络包，并夹杂心跳
        let wire = """
        : keepalive

        data: {"choices":[{"delta":{"content":"我来看看这个文件"}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","function":{"name":"read_file","arguments":"{\\"pa"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\\":\\"/workspace/src/money.py\\"}"}}]}}]}

        : keepalive

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """

        var sse = SSEParser()
        var decoder = AnyStreamDecoder.make(family: .openAIChat, quirks: .openAICompatible, model: "m")
        var assembler = ToolCallAssembler()

        var modelEvents: [ModelEvent] = []
        var calls: [ToolCall] = []

        // 用 7 字节的碎块喂进去（模拟最恶劣的网络分包）
        let bytes = Array(wire.utf8)
        var index = 0

        /// 把一个归一化事件同时喂给拼装器（**这才是真实运行时的顺序**）
        func absorb(_ decoded: [ModelEvent]) {
            modelEvents.append(contentsOf: decoded)
            for modelEvent in decoded {
                calls.append(contentsOf: assembler.ingest(modelEvent).map(\.call))
            }
        }

        while index < bytes.count {
            let end = min(index + 7, bytes.count)
            for event in sse.ingest(Data(bytes[index..<end])) {
                absorb(decoder.ingest(event))
            }
            index = end
        }
        for event in sse.finish() {
            absorb(decoder.ingest(event))
        }
        absorb(decoder.finish())
        calls.append(contentsOf: assembler.flush().map(\.call))

        // 文本完整
        #expect(modelEvents.compactMap { if case .textDelta(let t) = $0 { return t }; return nil }.joined() == "我来看看这个文件")
        // 工具调用被正确拼装（分片跨包、参数是合法 JSON）
        #expect(calls.count == 1)
        #expect(calls[0].name == "read_file")
        #expect(calls[0].id == "call_abc")
        let args = try? calls[0].arguments()
        #expect(args?.value(at: ["path"]) == .string("/workspace/src/money.py"))
        // 心跳被识别并计数
        #expect(sse.commentCount == 2)
    }
}

// MARK: - 缓存规划

@Suite("CachePlanner —— 缓存断点规划")
struct CachePlannerTests {

    private let request = ChatRequest(
        systemBlocks: [
            SystemBlock(layer: .identity, label: "契约", text: "身份"),
            SystemBlock(layer: .projectStable, label: "项目", text: "项目指令"),
            SystemBlock(layer: .projectStable, label: "结构", text: "目录树"),
            SystemBlock(layer: .sessionVolatile, label: "本轮", text: "目标"),
        ],
        messages: [Message(role: .user, blocks: [.text("x", origin: .userInstruction)], origin: .userInstruction)],
        tools: [ToolSpec(name: "t", description: "d", inputSchema: .object(properties: [:], required: [], additionalProperties: false))]
    )

    @Test("⚠️ 只有需要显式断点的渠道才规划断点")
    func onlyExplicitStyles() {
        #expect(CachePlanner.breakpoints(for: request, quirks: .anthropic).count == 2)
        #expect(CachePlanner.breakpoints(for: request, quirks: .openAIResponses).count == 2)
        // 自动缓存的渠道不打点（打了也没用）
        #expect(CachePlanner.breakpoints(for: request, quirks: .deepSeek).isEmpty)
        #expect(CachePlanner.breakpoints(for: request, quirks: .relay).isEmpty)
        #expect(CachePlanner.breakpoints(for: request, quirks: .openAICompatible).isEmpty)
    }

    @Test("⚠️ 只断在稳定层（层 3 每轮都变，断在它上面是浪费额度）")
    func onlyStableLayers() {
        let breakpoints = CachePlanner.breakpoints(for: request, quirks: .anthropic)
        #expect(!breakpoints.contains(3), "会话易变层不该被打断点")
        // 策略是"取每层**最后一个**块"——前缀越长，缓存命中越多
        #expect(breakpoints.contains(2), "projectStable 层的最后一个块（下标 2）应被打断点")
        #expect(breakpoints.contains(0), "identity 层应被打断点")
    }

    @Test("工具定义占一个断点（工具多时它比系统提示更值得缓存）")
    func toolsGetBreakpoint() {
        #expect(CachePlanner.cacheTools(request, quirks: .anthropic))
        #expect(!CachePlanner.cacheTools(request, quirks: .deepSeek))
    }

    @Test("每种缓存风格都有可读解释（UI 要展示）")
    func explanations() {
        for style in [CacheStyle.none, .automatic, .explicitBreakpoints, .implicitPrefix, .passThrough] {
            var q = ProviderQuirks.openAICompatible
            q.cacheStyle = style
            #expect(!CachePlanner.explanation(for: q).isEmpty)
        }
    }
}


