import Foundation

// MARK: - 流解码器
//
// 把各厂商的 SSE 事件还原成归一化 `ModelEvent`。
// 这是"换模型能力不塌"的关键一环：`AgentRuntime` 只认 ModelEvent，
// 因此任何新渠道只要能解码成它，就自动获得全部上层能力（并行工具、检查点、审批…）。

public protocol StreamDecoding: Sendable {
    mutating func ingest(_ event: SSEEvent) -> [ModelEvent]
    mutating func finish() -> [ModelEvent]
}

// MARK: - 分发器（枚举而不是 existential：简单、Sendable、无装箱）

public enum AnyStreamDecoder: Sendable {
    case openAIChat(OpenAIChatDecoder)
    case openAIResponses(OpenAIResponsesDecoder)
    case anthropic(AnthropicDecoder)
    case gemini(GeminiDecoder)
    case ollama(OllamaDecoder)

    public static func make(family: ProtocolFamily, quirks: ProviderQuirks, model: String) -> AnyStreamDecoder {
        switch family {
        case .openAIChat, .custom:
            return .openAIChat(OpenAIChatDecoder(quirks: quirks, model: model))
        case .openAIResponses:
            return .openAIResponses(OpenAIResponsesDecoder(quirks: quirks, model: model))
        case .anthropicMessages:
            return .anthropic(AnthropicDecoder(quirks: quirks, model: model))
        case .geminiGenerate, .geminiInteractions:
            return .gemini(GeminiDecoder(quirks: quirks, model: model))
        case .ollamaNative:
            return .ollama(OllamaDecoder(quirks: quirks, model: model))
        }
    }

    /// 一个 SSE 事件 → 零或多个归一化事件
    public mutating func ingest(_ event: SSEEvent) -> [ModelEvent] {
        switch self {
        case .openAIChat(var d): defer { self = .openAIChat(d) }; return d.ingest(event)
        case .openAIResponses(var d): defer { self = .openAIResponses(d) }; return d.ingest(event)
        case .anthropic(var d): defer { self = .anthropic(d) }; return d.ingest(event)
        case .gemini(var d): defer { self = .gemini(d) }; return d.ingest(event)
        case .ollama(var d): defer { self = .ollama(d) }; return d.ingest(event)
        }
    }

    /// 一行 NDJSON → 零或多个归一化事件
    public mutating func ingestLine(_ line: String) -> [ModelEvent] {
        switch self {
        case .ollama(var d): defer { self = .ollama(d) }; return d.ingestLine(line)
        default: return []
        }
    }

    public mutating func finish() -> [ModelEvent] {
        switch self {
        case .openAIChat(var d): defer { self = .openAIChat(d) }; return d.finish()
        case .openAIResponses(var d): defer { self = .openAIResponses(d) }; return d.finish()
        case .anthropic(var d): defer { self = .anthropic(d) }; return d.finish()
        case .gemini(var d): defer { self = .gemini(d) }; return d.finish()
        case .ollama(var d): defer { self = .ollama(d) }; return d.finish()
        }
    }

    public var diagnostics: String {
        switch self {
        case .openAIChat(let d): return d.diagnostics
        case .openAIResponses(let d): return d.diagnostics
        case .anthropic(let d): return d.diagnostics
        case .gemini(let d): return d.diagnostics
        case .ollama(let d): return d.diagnostics
        }
    }
}

// MARK: - 公共解析辅助

/// 解码器的公共状态：是否已发 started、是否已发 finished
struct DecoderState: Sendable {
    var model: String
    var didStart = false
    var didFinish = false
    var malformedEvents = 0

    /// ⚠️ 必须 `mutating`：忘了置位 `didStart` 的话，**每一个事件都会重发一次 started**。
    mutating func startIfNeeded(providerID: String, into out: inout [ModelEvent]) -> Bool {
        guard !didStart else { return false }
        didStart = true
        out.append(.started(modelID: model, providerID: providerID))
        return true
    }
}

enum UsageParser {

    /// OpenAI 风格：`usage.prompt_tokens` / `completion_tokens` / `prompt_tokens_details.cached_tokens`
    static func openAI(_ usage: JSONValue) -> TokenUsage {
        TokenUsage(
            inputTokens: usage.value(at: ["prompt_tokens"])?.intValue ?? 0,
            outputTokens: usage.value(at: ["completion_tokens"])?.intValue ?? 0,
            cachedInputTokens: usage.value(at: ["prompt_tokens_details", "cached_tokens"])?.intValue ?? 0,
            cacheWriteTokens: usage.value(at: ["prompt_tokens_details", "cache_write_tokens"])?.intValue
                ?? usage.value(at: ["cache_write_tokens"])?.intValue ?? 0,
            reasoningTokens: usage.value(at: ["completion_tokens_details", "reasoning_tokens"])?.intValue,
            isEstimated: false
        )
    }

    /// Anthropic：`input_tokens` / `output_tokens` / `cache_read_input_tokens` / `cache_creation_input_tokens`
    static func anthropic(_ usage: JSONValue) -> TokenUsage {
        TokenUsage(
            inputTokens: usage.value(at: ["input_tokens"])?.intValue ?? 0,
            outputTokens: usage.value(at: ["output_tokens"])?.intValue ?? 0,
            cachedInputTokens: usage.value(at: ["cache_read_input_tokens"])?.intValue ?? 0,
            cacheWriteTokens: usage.value(at: ["cache_creation_input_tokens"])?.intValue ?? 0,
            reasoningTokens: nil,
            isEstimated: false
        )
    }

    /// Gemini：`promptTokenCount` / `candidatesTokenCount` / `cachedContentTokenCount` / `thoughtsTokenCount`
    static func gemini(_ usage: JSONValue) -> TokenUsage {
        TokenUsage(
            inputTokens: usage.value(at: ["promptTokenCount"])?.intValue ?? 0,
            outputTokens: usage.value(at: ["candidatesTokenCount"])?.intValue ?? 0,
            cachedInputTokens: usage.value(at: ["cachedContentTokenCount"])?.intValue ?? 0,
            cacheWriteTokens: 0,
            reasoningTokens: usage.value(at: ["thoughtsTokenCount"])?.intValue,
            isEstimated: false
        )
    }

    /// 把 finish_reason 字符串映射成归一化枚举
    static func finishReason(_ raw: String?) -> FinishReason {
        switch raw {
        case "stop", "end_turn", "STOP": return .stop
        case "length", "max_tokens", "MAX_TOKENS": return .length
        case "tool_calls", "tool_use", "function_call": return .toolCalls
        case "content_filter", "SAFETY", "RECITATION": return .contentFilter
        case "error": return .error
        default: return .unknown
        }
    }
}

// MARK: - OpenAI Chat Completions

public struct OpenAIChatDecoder: StreamDecoding {
    private var state: DecoderState
    private let quirks: ProviderQuirks
    private var pendingFinish: FinishReason?

    public init(quirks: ProviderQuirks = .openAICompatible, model: String = "") {
        self.quirks = quirks
        self.state = DecoderState(model: model)
    }

    public mutating func ingest(_ event: SSEEvent) -> [ModelEvent] {
        var out: [ModelEvent] = []
        _ = state.startIfNeeded(providerID: "openai-compatible", into: &out)

        if event.isDoneMarker {
            out.append(.finished(reason: pendingFinish ?? .stop))
            state.didFinish = true
            return out
        }
        guard let json = try? JSONValue.parse(event.data) else {
            state.malformedEvents += 1
            return out
        }

        // 顶层 error（OpenRouter 的中途错误就是这个形状）
        if let error = json.value(at: ["error"]) {
            // ⚠️ 分类必须看状态码：一律 `.transient` 会让"余额不足"被重试、被当成没出事
            let status = error.value(at: ["code"])?.intValue
            let raw = error.value(at: ["message"])?.stringValue ?? "未知错误"
            let kind = ProviderError.classify(statusCode: status, message: raw)
            out.append(.providerError(ProviderError(
                kind: kind,
                providerID: "openai-compatible",
                statusCode: status,
                message: raw,
                userFacingMessage: ProviderError.userFacing(kind: kind, statusCode: status, raw: raw)
            )))
            state.didFinish = true
            return out
        }

        if let usage = json.value(at: ["usage"]), !usage.isNull {
            out.append(.usage(UsageParser.openAI(usage)))
        }

        let choice = json.value(at: ["choices", "0"])
        guard let choice else { return out }

        if let delta = choice.value(at: ["delta"]) {
            if let content = delta.value(at: ["content"])?.stringValue, !content.isEmpty {
                out.append(.textDelta(content))
            }
            // 思考链字段名因厂商而异（附录A §2.6）
            switch quirks.reasoningField {
            case .reasoningContent:
                if let r = delta.value(at: ["reasoning_content"])?.stringValue, !r.isEmpty {
                    out.append(.reasoningDelta(r))
                }
            case .reasoning:
                if let r = delta.value(at: ["reasoning"])?.stringValue, !r.isEmpty {
                    out.append(.reasoningDelta(r))
                }
            case .reasoningDetails:
                if let details = delta.value(at: ["reasoning_details"])?.arrayValue {
                    for item in details {
                        if let text = item.value(at: ["text"])?.stringValue, !text.isEmpty {
                            out.append(.reasoningDelta(text))
                        }
                    }
                }
            default:
                // 未声明思考字段时也兜底看一眼最常用的两个名字
                for key in ["reasoning_content", "reasoning"] {
                    if let r = delta.value(at: [key])?.stringValue, !r.isEmpty {
                        out.append(.reasoningDelta(r))
                        break
                    }
                }
            }

            if let toolCalls = delta.value(at: ["tool_calls"])?.arrayValue {
                for (position, call) in toolCalls.enumerated() {
                    // ⚠️ index 是**分片分组的键**，缺省时按位置兜底
                    let index = call.value(at: ["index"])?.intValue ?? position
                    let id = call.value(at: ["id"])?.stringValue ?? ""
                    let name = call.value(at: ["function", "name"])?.stringValue ?? ""
                    if !name.isEmpty || !id.isEmpty {
                        out.append(.toolCallStarted(index: index, id: id, name: name))
                    }
                    if let args = call.value(at: ["function", "arguments"])?.stringValue, !args.isEmpty {
                        out.append(.toolCallArgumentsDelta(index: index, jsonFragment: args))
                    }
                }
            }
        }

        if let raw = choice.value(at: ["finish_reason"])?.stringValue, !raw.isEmpty {
            let reason = UsageParser.finishReason(raw)
            pendingFinish = reason
            // Chat Completions 的结束信号就在这一条里；工具参数的分片在此之前已全部到达
            out.append(.finished(reason: reason))
            state.didFinish = true
        }
        return out
    }

    public mutating func finish() -> [ModelEvent] {
        // 有些中转站既不发 `[DONE]` 也不发 finish_reason
        guard !state.didFinish else { return [] }
        state.didFinish = true
        return [.finished(reason: pendingFinish ?? .unknown)]
    }

    public var diagnostics: String {
        "OpenAI Chat：解析失败 \(state.malformedEvents) 条\(state.didFinish ? "" : "，未收到结束原因")"
    }
}

// MARK: - OpenAI Responses

public struct OpenAIResponsesDecoder: StreamDecoding {
    private var state: DecoderState
    private let quirks: ProviderQuirks
    /// output_index → (callID, name)，用于把 delta 归位
    private var callIndex: [Int: (id: String, name: String)] = [:]

    public init(quirks: ProviderQuirks = .openAIResponses, model: String = "") {
        self.quirks = quirks
        self.state = DecoderState(model: model)
    }

    public mutating func ingest(_ event: SSEEvent) -> [ModelEvent] {
        var out: [ModelEvent] = []
        _ = state.startIfNeeded(providerID: "openai-responses", into: &out)

        guard let json = try? JSONValue.parse(event.data) else {
            state.malformedEvents += 1
            return out
        }
        // 事件类型可能在 `event:` 里，也可能在 body 的 `type` 里
        let type = event.name ?? json.value(at: ["type"])?.stringValue ?? ""

        switch type {
        case "response.output_text.delta":
            if let delta = json.value(at: ["delta"])?.stringValue, !delta.isEmpty {
                out.append(.textDelta(delta))
            }

        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            if let delta = json.value(at: ["delta"])?.stringValue, !delta.isEmpty {
                out.append(.reasoningDelta(delta))
            }

        case "response.output_item.added":
            let item = json.value(at: ["item"])
            if item?.value(at: ["type"])?.stringValue == "function_call" {
                let index = json.value(at: ["output_index"])?.intValue ?? callIndex.count
                let id = item?.value(at: ["call_id"])?.stringValue ?? item?.value(at: ["id"])?.stringValue ?? ""
                let name = item?.value(at: ["name"])?.stringValue ?? ""
                callIndex[index] = (id, name)
                out.append(.toolCallStarted(index: index, id: id, name: name))
            }

        case "response.function_call_arguments.delta":
            let index = json.value(at: ["output_index"])?.intValue ?? 0
            if let delta = json.value(at: ["delta"])?.stringValue, !delta.isEmpty {
                out.append(.toolCallArgumentsDelta(index: index, jsonFragment: delta))
            }

        case "response.function_call_arguments.done":
            let index = json.value(at: ["output_index"])?.intValue ?? 0
            let known = callIndex[index]
            out.append(.toolCallCompleted(
                index: index,
                id: json.value(at: ["item_id"])?.stringValue ?? known?.id ?? "",
                name: json.value(at: ["name"])?.stringValue ?? known?.name ?? "",
                argumentsJSON: Data((json.value(at: ["arguments"])?.stringValue ?? "{}").utf8)
            ))

        case "response.completed", "response.done":
            if let usage = json.value(at: ["response", "usage"]) {
                out.append(.usage(UsageParser.openAI(usage)))
            }
            out.append(.finished(reason: callIndex.isEmpty ? .stop : .toolCalls))
            state.didFinish = true

        case "response.incomplete":
            out.append(.finished(reason: .length))
            state.didFinish = true

        case "response.failed", "error":
            let message = json.value(at: ["response", "error", "message"])?.stringValue
                ?? json.value(at: ["message"])?.stringValue ?? "请求失败"
            let status = json.value(at: ["response", "error", "code"])?.intValue
                ?? json.value(at: ["status"])?.intValue
            let kind = ProviderError.classify(statusCode: status, message: message)
            out.append(.providerError(ProviderError(
                kind: kind, providerID: "openai-responses", statusCode: status,
                message: message,
                userFacingMessage: ProviderError.userFacing(kind: kind, statusCode: status, raw: message)
            )))
            state.didFinish = true

        default:
            break
        }
        return out
    }

    public mutating func finish() -> [ModelEvent] {
        guard !state.didFinish else { return [] }
        state.didFinish = true
        return [.finished(reason: callIndex.isEmpty ? .unknown : .toolCalls)]
    }

    public var diagnostics: String {
        "OpenAI Responses：\(callIndex.count) 个工具调用，解析失败 \(state.malformedEvents) 条"
    }
}

// MARK: - Anthropic Messages

public struct AnthropicDecoder: StreamDecoding {
    private var state: DecoderState
    private let quirks: ProviderQuirks
    private var blockIndex = 0
    private var pendingStopReason: FinishReason?
    private var didEmitUsage = false
    /// index → 是不是 tool_use 块（用于判断 input_json_delta 的归属）
    private var toolBlocks: Set<Int> = []

    public init(quirks: ProviderQuirks = .anthropic, model: String = "") {
        self.quirks = quirks
        self.state = DecoderState(model: model)
    }

    public mutating func ingest(_ event: SSEEvent) -> [ModelEvent] {
        var out: [ModelEvent] = []
        guard let json = try? JSONValue.parse(event.data) else {
            state.malformedEvents += 1
            return out
        }
        let type = event.name ?? json.value(at: ["type"])?.stringValue ?? ""

        switch type {
        case "message_start":
            _ = state.startIfNeeded(providerID: "anthropic", into: &out)
            if let usage = json.value(at: ["message", "usage"]) {
                out.append(.usage(UsageParser.anthropic(usage)))
                didEmitUsage = true
            }

        case "content_block_start":
            let index = json.value(at: ["index"])?.intValue ?? 0
            blockIndex = index
            let block = json.value(at: ["content_block"])
            let blockType = block?.value(at: ["type"])?.stringValue ?? ""
            if blockType == "tool_use" {
                toolBlocks.insert(index)
                out.append(.toolCallStarted(
                    index: index,
                    id: block?.value(at: ["id"])?.stringValue ?? "",
                    name: block?.value(at: ["name"])?.stringValue ?? ""
                ))
            }

        case "content_block_delta":
            let index = json.value(at: ["index"])?.intValue ?? blockIndex
            let delta = json.value(at: ["delta"])
            let deltaType = delta?.value(at: ["type"])?.stringValue ?? ""
            switch deltaType {
            case "text_delta":
                if let text = delta?.value(at: ["text"])?.stringValue, !text.isEmpty {
                    out.append(.textDelta(text))
                }
            case "thinking_delta":
                if let text = delta?.value(at: ["thinking"])?.stringValue, !text.isEmpty {
                    out.append(.reasoningDelta(text))
                }
            case "signature_delta":
                if let signature = delta?.value(at: ["signature"])?.stringValue,
                   let data = Data(base64Encoded: signature) {
                    out.append(.reasoningSignature(data))
                }
            case "input_json_delta":
                if let partial = delta?.value(at: ["partial_json"])?.stringValue, !partial.isEmpty {
                    out.append(.toolCallArgumentsDelta(index: index, jsonFragment: partial))
                }
            default:
                break
            }

        case "content_block_stop":
            break       // Anthropic 的块结束不代表工具调用结束，等 message_delta

        case "message_delta":
            if let usage = json.value(at: ["usage"]) {
                out.append(.usage(UsageParser.anthropic(usage)))
            }
            if let raw = json.value(at: ["delta", "stop_reason"])?.stringValue {
                pendingStopReason = UsageParser.finishReason(raw)
            }

        case "message_stop":
            out.append(.finished(reason: pendingStopReason ?? .stop))
            state.didFinish = true

        case "error":
            let message = json.value(at: ["error", "message"])?.stringValue ?? "Anthropic 返回错误"
            // ⚠️ `overloaded_error` 是 529（可重试），但 `invalid_request_error`、鉴权类
            //    绝不能一律当 transient —— 见 `ProviderError.classify` 的注释
            let type = json.value(at: ["error", "type"])?.stringValue
            let status = json.value(at: ["error", "status"])?.intValue
                ?? ProviderError.statusCode(forAnthropicType: type)
            let kind = ProviderError.classify(statusCode: status, message: message)
            out.append(.providerError(ProviderError(
                kind: kind, providerID: "anthropic", statusCode: status,
                message: message,
                userFacingMessage: ProviderError.userFacing(kind: kind, statusCode: status, raw: message)
            )))
            state.didFinish = true

        case "ping":
            break       // 心跳

        default:
            break
        }
        return out
    }

    public mutating func finish() -> [ModelEvent] {
        guard !state.didFinish else { return [] }
        state.didFinish = true
        return [.finished(reason: pendingStopReason ?? .unknown)]
    }

    public var diagnostics: String {
        "Anthropic：\(toolBlocks.count) 个工具块，解析失败 \(state.malformedEvents) 条"
    }
}

// MARK: - Gemini

public struct GeminiDecoder: StreamDecoding {
    private var state: DecoderState
    private let quirks: ProviderQuirks
    private var toolIndex = 0
    private var sawToolCall = false

    public init(quirks: ProviderQuirks = .gemini, model: String = "") {
        self.quirks = quirks
        self.state = DecoderState(model: model)
    }

    public mutating func ingest(_ event: SSEEvent) -> [ModelEvent] {
        var out: [ModelEvent] = []
        _ = state.startIfNeeded(providerID: "gemini", into: &out)

        guard let json = try? JSONValue.parse(event.data) else {
            state.malformedEvents += 1
            return out
        }

        if let usage = json.value(at: ["usageMetadata"]) {
            out.append(.usage(UsageParser.gemini(usage)))
        }

        guard let parts = json.value(at: ["candidates", "0", "content", "parts"])?.arrayValue else {
            // 可能是只带 finishReason 或只带 usageMetadata 的收尾帧
            // ⚠️ 这里**也必须**做"有 functionCall 就修正为 toolCalls"——真实流量里
            //    finishReason 经常出现在一个**不带 parts 的独立帧**里，漏掉修正会让上层
            //    误以为模型只是"说完了"，从而丢掉工具调用。
            if let raw = json.value(at: ["candidates", "0", "finishReason"])?.stringValue {
                out.append(.finished(reason: correctedFinish(raw)))
                state.didFinish = true
            }
            return out
        }

        for part in parts {
            // 思考部分（含不透明签名，必须原样回传）
            if part.value(at: ["thought"])?.boolValue == true {
                if let text = part.value(at: ["text"])?.stringValue, !text.isEmpty {
                    out.append(.reasoningDelta(text))
                }
                if let signature = part.value(at: ["thoughtSignature"])?.stringValue,
                   let data = Data(base64Encoded: signature) {
                    out.append(.reasoningSignature(data))
                }
                continue
            }

            if let text = part.value(at: ["text"])?.stringValue, !text.isEmpty {
                out.append(.textDelta(text))
            }

            if let call = part.value(at: ["functionCall"]) {
                let name = call.value(at: ["name"])?.stringValue ?? ""
                let id = call.value(at: ["id"])?.stringValue ?? "gemini_\(toolIndex)"
                let args = call.value(at: ["args"]) ?? .object([:])
                out.append(.toolCallCompleted(
                    index: toolIndex, id: id, name: name,
                    argumentsJSON: Data(args.canonicalString().utf8)
                ))
                toolIndex += 1
                sawToolCall = true
            }
        }

        if let raw = json.value(at: ["candidates", "0", "finishReason"])?.stringValue {
            out.append(.finished(reason: correctedFinish(raw)))
            state.didFinish = true
        }
        return out
    }

    /// Gemini 用 `STOP` 表示"正常结束"，**不区分**是否要调用工具 →
    /// 只要这一轮出现过 functionCall，就修正为 `.toolCalls`（否则上层不会去执行工具）。
    private func correctedFinish(_ raw: String) -> FinishReason {
        let reason = UsageParser.finishReason(raw)
        if reason == .stop && sawToolCall { return .toolCalls }
        return reason
    }

    public mutating func finish() -> [ModelEvent] {
        guard !state.didFinish else { return [] }
        state.didFinish = true
        return [.finished(reason: sawToolCall ? .toolCalls : .unknown)]
    }

    public var diagnostics: String {
        "Gemini：\(toolIndex) 个 functionCall，解析失败 \(state.malformedEvents) 条"
    }
}

// MARK: - Ollama（NDJSON）

public struct OllamaDecoder: StreamDecoding {
    private var state: DecoderState
    private let quirks: ProviderQuirks
    private var toolIndex = 0
    /// Ollama 的 `/v1/chat/completions` 兼容端点走 SSE —— 复用一个真正的 OpenAI 解码器，
    /// 而不是每次新建（新建会丢掉"是否已发 started"这类状态）。
    private var sseFallback: OpenAIChatDecoder

    public init(quirks: ProviderQuirks = .relay, model: String = "") {
        self.quirks = quirks
        self.state = DecoderState(model: model)
        self.sseFallback = OpenAIChatDecoder(quirks: quirks, model: model)
    }

    /// Ollama 用的是 NDJSON：每行一个完整对象
    public mutating func ingestLine(_ line: String) -> [ModelEvent] {
        var out: [ModelEvent] = []
        _ = state.startIfNeeded(providerID: "ollama", into: &out)

        guard let json = try? JSONValue.parse(line) else {
            state.malformedEvents += 1
            return out
        }
        if let message = json.value(at: ["message"]) {
            if let content = message.value(at: ["content"])?.stringValue, !content.isEmpty {
                out.append(.textDelta(content))
            }
            if let calls = message.value(at: ["tool_calls"])?.arrayValue {
                for call in calls {
                    let fn = call.value(at: ["function"])
                    out.append(.toolCallCompleted(
                        index: toolIndex,
                        id: "ollama_\(toolIndex)",
                        name: fn?.value(at: ["name"])?.stringValue ?? "",
                        argumentsJSON: Data((fn?.value(at: ["arguments"])?.canonicalString() ?? "{}").utf8)
                    ))
                    toolIndex += 1
                }
            }
        }
        if json.value(at: ["done"])?.boolValue == true {
            if let prompt = json.value(at: ["prompt_eval_count"])?.intValue {
                out.append(.usage(TokenUsage(
                    inputTokens: prompt,
                    outputTokens: json.value(at: ["eval_count"])?.intValue ?? 0,
                    isEstimated: true
                )))
            }
            out.append(.finished(reason: toolIndex > 0 ? .toolCalls : .stop))
            state.didFinish = true
        }
        return out
    }

    public mutating func ingest(_ event: SSEEvent) -> [ModelEvent] {
        sseFallback.ingest(event)
    }

    public mutating func finish() -> [ModelEvent] {
        guard !state.didFinish else { return [] }
        state.didFinish = true
        return [.finished(reason: .unknown)]
    }

    public var diagnostics: String {
        "Ollama：\(toolIndex) 个工具调用，解析失败 \(state.malformedEvents) 条"
    }
}
