import Foundation

// MARK: - 编码上下文
//
// 适配器是**纯逻辑**，不能读盘。因此凡是需要 IO 的东西（例如把图片制品解析成
// 可内联的 base64）都由上层通过这个上下文注入。

public struct RequestEncodingContext: Sendable {
    /// 把制品引用解析为可内联的图片数据（返回 nil 表示无法解析 → 退化为文字占位）
    public var resolveImage: @Sendable (ArtifactRef) -> (data: Data, mime: String)?
    /// 模型的真实远端名（渠道别名 → 远端名在网关上完成映射；这里拿到的已是最终名）
    public var supportsImages: Bool

    public init(
        resolveImage: @escaping @Sendable (ArtifactRef) -> (data: Data, mime: String)? = { _ in nil },
        supportsImages: Bool = true
    ) {
        self.resolveImage = resolveImage
        self.supportsImages = supportsImages
    }

    public static let plain = RequestEncodingContext()
}

// MARK: - 请求序列化

/// 把归一化 `ChatRequest` 序列化成各厂商的请求体。
///
/// **这是"支持市面上主流模型"的地基**：字段名写错就是 400，思考链回传策略写错也是 400。
/// 因此每一条映射都在 docs/附录A 里核对过，并有测试守着。
public enum RequestEncoder {

    public static func encode(
        _ request: ChatRequest,
        family: ProtocolFamily,
        model: String,
        quirks: ProviderQuirks,
        context: RequestEncodingContext = .plain
    ) -> JSONValue {
        switch family {
        case .openAIChat, .custom, .ollamaNative:
            return openAIChat(request, model: model, quirks: quirks, context: context)
        case .openAIResponses:
            return openAIResponses(request, model: model, quirks: quirks, context: context)
        case .anthropicMessages:
            return anthropic(request, model: model, quirks: quirks, context: context)
        case .geminiGenerate, .geminiInteractions:
            return gemini(request, model: model, quirks: quirks, context: context)
        }
    }

    /// 请求路径（相对 baseURL）
    public static func path(family: ProtocolFamily, model: String) -> String {
        switch family {
        case .openAIChat, .custom, .ollamaNative: return "/chat/completions"
        case .openAIResponses: return "/responses"
        case .anthropicMessages: return "/messages"
        case .geminiGenerate: return "/models/\(model):streamGenerateContent?alt=sse"
        case .geminiInteractions: return "/interactions?alt=sse"
        }
    }

    // MARK: - OpenAI Chat Completions

    static func openAIChat(
        _ request: ChatRequest,
        model: String,
        quirks: ProviderQuirks,
        context: RequestEncodingContext
    ) -> JSONValue {
        var messages: [JSONValue] = []

        if !request.systemBlocks.isEmpty {
            messages.append(.object([
                "role": .string("system"),
                "content": .string(request.flattenedSystemText),
            ]))
        }

        // ⚠️ 思考链是否回传取决于**整个请求里有没有 tools**，不是"这条消息有没有工具调用"。
        //    DeepSeek 的规则是"请求带 tools 时，历史每一轮的 reasoning_content 都必须回传，否则 400"。
        let requestHasTools = !request.tools.isEmpty

        // 需要 `name` 的端点要求这个名字与 `tool_calls[].function.name` 一致 ——
        // 而 `ToolResult` 只带 `callID`，名字得从配对的 `toolCall` 里找回来（同 Gemini 那条）。
        let toolNames = MessageGrouping.toolNames(in: request.messages)

        for message in request.messages {
            messages.append(contentsOf: openAIMessages(
                message, quirks: quirks, context: context,
                requestHasTools: requestHasTools, toolNames: toolNames
            ))
        }

        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages),
            "stream": .bool(request.stream),
        ]
        // ⚠️ 字段名因厂商而异：GPT-5.4+ 用 max_completion_tokens；xAI 也已弃用 max_tokens
        body[quirks.maxTokensField] = .int(request.maxOutputTokens)
        if let temperature = request.temperature { body["temperature"] = .double(temperature) }
        if !request.stopSequences.isEmpty { body["stop"] = .array(request.stopSequences.map { .string($0) }) }

        appendOpenAITools(&body, request: request, quirks: quirks)

        if request.includeUsage && request.stream {
            body["stream_options"] = .object(["include_usage": .bool(true)])
        }
        if let reasoning = request.reasoning, let effort = reasoning.effortValue {
            // ⚠️ 各厂商档位不一致，必须**映射**而不是直传（附录A §2.6）
            //    例：DeepSeek 只认 low / high / max，传 medium 会被静默忽略或报错
            let supported: Set<ReasoningEffort> = [.none, .low, .high, .max]
            let mapped = effort.mapped(toSupported: supported, fallback: .high)
            body["reasoning_effort"] = .string(mapped.rawValue)
            // DeepSeek 走 OpenAI 路径时，思考开关是嵌套字段
            body["thinking"] = .object(["type": .string(mapped == .none ? "disabled" : "enabled")])
        } else if case .off = request.reasoning {
            body["thinking"] = .object(["type": .string("disabled")])
        }

        removeUnsupported(&body, quirks: quirks)
        return .object(body)
    }

    /// 一条消息 → 一条或多条 OpenAI Chat 消息
    ///
    /// `requestHasTools` 是**请求级**信息：思考链是否回传看的是它，而不是本消息里有没有工具调用。
    static func openAIMessages(
        _ message: Message,
        quirks: ProviderQuirks,
        context: RequestEncodingContext,
        requestHasTools: Bool,
        toolNames: [String: String] = [:]
    ) -> [JSONValue] {
        switch message.role {

        case .system:
            return [.object(["role": .string("system"), "content": .string(message.plainText)])]

        case .user:
            return [.object(["role": .string("user"), "content": openAIContent(message, context: context)])]

        case .assistant:
            var dict: [String: JSONValue] = ["role": .string("assistant")]
            let text = message.plainText
            dict["content"] = text.isEmpty ? .null : .string(text)

            let toolCalls = message.blocks.compactMap(\.toolCallValue)
            if !toolCalls.isEmpty {
                dict["tool_calls"] = .array(toolCalls.map { call in
                    .object([
                        "id": .string(call.id),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string(call.name),
                            "arguments": .string(String(decoding: call.argumentsJSON, as: UTF8.self)),
                        ]),
                    ])
                })
            }

            // 思考链回传（DeepSeek 在**请求带 tools** 时**必须**回传，否则 400）
            if quirks.reasoningReplay.shouldReplay(hasTools: requestHasTools) {
                let reasoning = message.blocks.compactMap { block -> String? in
                    if case .reasoning(let text, _) = block.kind { return text }
                    return nil
                }.joined()
                if !reasoning.isEmpty, quirks.reasoningField == .reasoningContent {
                    dict["reasoning_content"] = .string(reasoning)
                } else if !reasoning.isEmpty, quirks.reasoningField == .reasoning {
                    dict["reasoning"] = .string(reasoning)
                }
            }
            return [.object(dict)]

        case .tool:
            // 一条 tool 消息只承载一个工具结果（OpenAI 的约定）
            return message.blocks.compactMap(\.toolResultValue).map { result in
                var dict: [String: JSONValue] = [
                    "role": .string("tool"),
                    "tool_call_id": .string(result.callID),
                    "content": .string(result.summary),
                ]
                // 部分兼容端点要求带 name，且**必须与该次调用的函数名一致**。
                // 原来这里写的是字面量 `"tool"` —— 那是一个不存在的函数名，
                // 端点校验严的时候会直接拒（而且这种错只在那一小撮端点上才暴露，最难查）。
                // 真的找不到配对（正常运行时不出现）才退回占位，避免整个请求 400。
                if quirks.requiresToolResultName {
                    dict["name"] = .string(toolNames[result.callID] ?? "tool")
                }
                return .object(dict)
            }
        }
    }

    static func openAIContent(_ message: Message, context: RequestEncodingContext) -> JSONValue {
        let hasImage = message.blocks.contains { if case .image = $0.kind { return true }; return false }
        guard hasImage, context.supportsImages else { return .string(message.plainText) }

        var parts: [JSONValue] = []
        for block in message.blocks {
            switch block.kind {
            case .text(let text):
                parts.append(.object(["type": .string("text"), "text": .string(text)]))
            case .image(let ref, let mime):
                if let resolved = context.resolveImage(ref) {
                    let b64 = resolved.data.base64EncodedString()
                    parts.append(.object([
                        "type": .string("image_url"),
                        "image_url": .object(["url": .string("data:\(resolved.mime);base64,\(b64)")]),
                    ]))
                } else {
                    // 拿不到字节 → 退化为文字说明（**不要**静默丢掉图片，模型需要知道有图）
                    parts.append(.object([
                        "type": .string("text"),
                        "text": .string("[图片未能内联：\(ref.displayName)（\(mime)）]"),
                    ]))
                }
            default:
                break
            }
        }
        return .array(parts)
    }

    static func appendOpenAITools(_ body: inout [String: JSONValue], request: ChatRequest, quirks: ProviderQuirks) {
        guard !request.tools.isEmpty, quirks.toolChoiceStyle != .unsupported else { return }
        body["tools"] = .array(request.tools.map { spec in
            .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string(spec.name),
                    "description": .string(spec.description),
                    "parameters": spec.inputSchema.jsonSchemaValue(),
                ]),
            ])
        })
        body["tool_choice"] = request.toolChoice.openAIStyleValue
        if !quirks.supportsParallelToolCalls {
            body["parallel_tool_calls"] = .bool(false)
        }
    }

    // MARK: - OpenAI Responses

    static func openAIResponses(
        _ request: ChatRequest,
        model: String,
        quirks: ProviderQuirks,
        context: RequestEncodingContext
    ) -> JSONValue {
        var input: [JSONValue] = []

        for message in request.messages {
            for block in message.blocks {
                switch block.kind {
                case .text(let text):
                    guard !text.isEmpty else { continue }
                    let type = message.role == .assistant ? "output_text" : "input_text"
                    input.append(.object([
                        "type": .string("message"),
                        "role": .string(message.role == .tool ? "user" : message.role.rawValue),
                        "content": .array([.object(["type": .string(type), "text": .string(text)])]),
                    ]))
                case .toolCall(let call):
                    input.append(.object([
                        "type": .string("function_call"),
                        "call_id": .string(call.id),
                        "name": .string(call.name),
                        "arguments": .string(String(decoding: call.argumentsJSON, as: UTF8.self)),
                    ]))
                case .toolResult(let result):
                    input.append(.object([
                        "type": .string("function_call_output"),
                        "call_id": .string(result.callID),
                        "output": .string(result.summary),
                    ]))
                case .reasoning(let text, let signature):
                    // 无状态模式必须回传加密思考内容（docs/附录A §4.2）
                    guard quirks.reasoningReplay.shouldReplay(hasTools: !request.tools.isEmpty) else { continue }
                    var item: [String: JSONValue] = ["type": .string("reasoning")]
                    if let signature { item["encrypted_content"] = .string(signature.base64EncodedString()) }
                    if !text.isEmpty { item["summary"] = .array([.object(["type": .string("summary_text"), "text": .string(text)])]) }
                    input.append(.object(item))
                case .image, .artifact:
                    break   // Responses 把图片走 message 的 input_image，M2 再接
                }
            }
        }

        var body: [String: JSONValue] = [
            "model": .string(model),
            "input": .array(input),
            "stream": .bool(request.stream),
        ]
        if !request.systemBlocks.isEmpty {
            body["instructions"] = .string(request.flattenedSystemText)
            // GPT-5.6+ 需要显式断点，否则**不产生缓存写入**
            if quirks.cacheStyle.requiresExplicitBreakpoints {
                body["prompt_cache_options"] = .object([
                    "mode": .string("explicit"),
                    "ttl": .string("30m"),
                ])
            }
        }
        body[quirks.maxTokensField] = .int(request.maxOutputTokens)
        if let temperature = request.temperature { body["temperature"] = .double(temperature) }

        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { spec in
                .object([
                    "type": .string("function"),
                    "name": .string(spec.name),
                    "description": .string(spec.description),
                    "parameters": spec.inputSchema.jsonSchemaValue(),
                    "strict": .bool(true),
                ])
            })
            if case .auto = request.toolChoice {} else {
                body["tool_choice"] = request.toolChoice.openAIStyleValue
            }
        }
        if let reasoning = request.reasoning, let effort = reasoning.effortValue {
            body["reasoning"] = .object([
                "effort": .string(effort.rawValue),   // ReasoningEffort.none → "none"
                "summary": .string("auto"),   // 不加这个就不会返回思维摘要
            ])
        }
        removeUnsupported(&body, quirks: quirks)
        return .object(body)
    }

    // MARK: - Anthropic Messages

    static func anthropic(
        _ request: ChatRequest,
        model: String,
        quirks: ProviderQuirks,
        context: RequestEncodingContext
    ) -> JSONValue {
        let breakpoints = CachePlanner.breakpoints(for: request, quirks: quirks)

        // system 是**顶层参数**，不是消息
        var systemBlocks: [JSONValue] = []
        for (index, block) in request.systemBlocks.enumerated() {
            var dict: [String: JSONValue] = ["type": .string("text"), "text": .string(block.text)]
            if breakpoints.contains(index) {
                dict["cache_control"] = .object(["type": .string("ephemeral")])
            }
            systemBlocks.append(.object(dict))
        }

        var messages: [JSONValue] = []
        // ⚠️ Anthropic 只有 user / assistant 两种角色，而运行时的历史是"一个工具结果一条
        //    `.tool` 消息" → 不合并就会出现连续多条 `user`。
        //    Anthropic 服务端会替我们合并，但**中转站不保证**，而且这本来就是我们该做对的事。
        let entries = request.messages.compactMap { message -> (role: String, payload: [JSONValue])? in
            let content = anthropicContent(message, quirks: quirks, context: context)
            return (MessageGrouping.effectiveRole(message.role, family: .anthropicMessages), content)
        }
        for entry in MessageGrouping.applying(.anthropicMessages, to: entries) {
            messages.append(.object(["role": .string(entry.role), "content": .array(entry.payload)]))
        }

        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages),
            "max_tokens": .int(request.maxOutputTokens),
            "stream": .bool(request.stream),
        ]
        if !systemBlocks.isEmpty { body["system"] = .array(systemBlocks) }

        if !request.tools.isEmpty {
            var tools: [JSONValue] = request.tools.map { spec in
                .object([
                    "name": .string(spec.name),
                    "description": .string(spec.description),
                    "input_schema": spec.inputSchema.jsonSchemaValue(),
                ])
            }
            // 工具定义也算一个断点（工具多时它比系统提示更值得缓存）
            if CachePlanner.cacheTools(request, quirks: quirks), !tools.isEmpty {
                if case .object(var last) = tools[tools.count - 1] {
                    last["cache_control"] = .object(["type": .string("ephemeral")])
                    tools[tools.count - 1] = .object(last)
                }
            }
            body["tools"] = .array(tools)
            switch request.toolChoice {
            case .auto: body["tool_choice"] = .object(["type": .string("auto")])
            case .required: body["tool_choice"] = .object(["type": .string("any")])
            case .none: body["tool_choice"] = .object(["type": .string("none")])
            case .specific(let name): body["tool_choice"] = .object(["type": .string("tool"), "name": .string(name)])
            }
        }

        // ⚠️ 手动 `budget_tokens` 在 4.7+ 会直接 400 → 只用自适应思考
        if let reasoning = request.reasoning {
            switch reasoning {
            case .off:
                break     // 不传 thinking 即为关闭
            case .effort, .budget:
                body["thinking"] = .object([
                    "type": .string("adaptive"),
                    "display": .string("omitted"),
                ])
                if let effort = reasoning.effortValue {
                    body["output_config"] = .object(["effort": .string(effort.rawValue)])
                }
            }
        }
        if let temperature = request.temperature { body["temperature"] = .double(temperature) }
        if !request.stopSequences.isEmpty { body["stop_sequences"] = .array(request.stopSequences.map { .string($0) }) }

        removeUnsupported(&body, quirks: quirks)
        return .object(body)
    }

    /// 把一条归一化消息编码成 Anthropic 的 `content` 块数组（**不含角色**）。
    ///
    /// ⚠️ 拆出"只出 content"这一步是为了让**分组**发生在角色层面（见 `MessageGrouping`）：
    ///    合并必须基于"这条消息到底有没有内容"，而空内容只能在算完之后才知道。
    static func anthropicContent(
        _ message: Message,
        quirks: ProviderQuirks,
        context: RequestEncodingContext
    ) -> [JSONValue] {
        var content: [JSONValue] = []
        let hasTools = !message.blocks.compactMap(\.toolCallValue).isEmpty

        // ⚠️ 顺序很关键：thinking 块必须在最前，其次是 text，最后是 tool_use
        if quirks.reasoningReplay.shouldReplay(hasTools: hasTools) {
            for block in message.blocks {
                if case .reasoning(let text, let signature) = block.kind {
                    // 缺 signature 会直接 400 → 保守起见没有签名就不回传
                    guard let signature else { continue }
                    content.append(.object([
                        "type": .string("thinking"),
                        "thinking": .string(text),
                        "signature": .string(signature.base64EncodedString()),
                    ]))
                }
            }
        }

        for block in message.blocks {
            switch block.kind {
            case .text(let text):
                guard !text.isEmpty else { continue }
                content.append(.object(["type": .string("text"), "text": .string(text)]))
            case .image(let ref, _):
                if let resolved = context.resolveImage(ref) {
                    content.append(.object([
                        "type": .string("image"),
                        "source": .object([
                            "type": .string("base64"),
                            "media_type": .string(resolved.mime),
                            "data": .string(resolved.data.base64EncodedString()),
                        ]),
                    ]))
                }
            case .toolCall(let call):
                content.append(.object([
                    "type": .string("tool_use"),
                    "id": .string(call.id),
                    "name": .string(call.name),
                    "input": (try? call.arguments()) ?? .object([:]),
                ]))
            case .toolResult(let result):
                var dict: [String: JSONValue] = [
                    "type": .string("tool_result"),
                    "tool_use_id": .string(result.callID),
                    "content": .string(result.summary),
                ]
                // ⚠️ 失败/被拒的结果必须带 `is_error: true`。
                //    不带的话，模型读到的是一段普通文本 ——「权限被拒，请换方案」看起来
                //    跟一次成功的工具输出没有区别，于是它会以为那一步做完了。
                //    `.truncated` 不算错误：调用成功了，只是输出太长转了制品。
                if result.status != .ok, result.status != .truncated {
                    dict["is_error"] = .bool(true)
                }
                content.append(.object(dict))
            default:
                break
            }
        }

        return content
    }

    static func anthropicMessage(
        _ message: Message,
        quirks: ProviderQuirks,
        context: RequestEncodingContext
    ) -> JSONValue? {
        let content = anthropicContent(message, quirks: quirks, context: context)
        guard !content.isEmpty else { return nil }
        let role = message.role == .assistant ? "assistant" : "user"
        return .object(["role": .string(role), "content": .array(content)])
    }

    // MARK: - Gemini

    static func gemini(
        _ request: ChatRequest,
        model: String,
        quirks: ProviderQuirks,
        context: RequestEncodingContext
    ) -> JSONValue {
        // ⚠️ `functionResponse` 要用**函数名**与 `functionCall` 对上，而 `ToolResult`
        //    只带 `callID` —— 名字得从配对的那条 `toolCall` 里找回来。
        let toolNames = MessageGrouping.toolNames(in: request.messages)

        let entries = request.messages.compactMap { message -> (role: String, payload: [JSONValue])? in
            let parts = geminiParts(message, quirks: quirks, context: context, toolNames: toolNames)
            return (MessageGrouping.effectiveRole(message.role, family: .geminiGenerate), parts)
        }

        // ⚠️ Gemini 的 `contents` **必须 user / model 交替**，相邻同角色直接 INVALID_ARGUMENT。
        //    运行时的历史很容易给出相邻同角色：`[tool, tool, tool]`（同一次波次的结果各一条）
        //    或 `[tool…, user]`（运行时引导语 `injectGuidance` 也是 `.user`）。
        //    两个 gemini 协议族共用同一条规则（规则表测试守着这一点），这里用 `.geminiGenerate`
        //    作代表；哪天两者分叉，那条测试会先失败并把这里指出来。
        var contents: [JSONValue] = []
        for entry in MessageGrouping.applying(.geminiGenerate, to: entries) {
            contents.append(.object(["role": .string(entry.role), "parts": .array(entry.payload)]))
        }

        var body: [String: JSONValue] = ["contents": .array(contents)]
        if !request.systemBlocks.isEmpty {
            body["systemInstruction"] = .object([
                "parts": .array([.object(["text": .string(request.flattenedSystemText)])]),
            ])
        }
        if !request.tools.isEmpty {
            body["tools"] = .array([.object([
                "functionDeclarations": .array(request.tools.map { spec in
                    .object([
                        "name": .string(spec.name),
                        "description": .string(spec.description),
                        "parameters": spec.inputSchema.jsonSchemaValue(),
                    ])
                }),
            ])])
        }
        var generation: [String: JSONValue] = ["maxOutputTokens": .int(request.maxOutputTokens)]
        if let temperature = request.temperature { generation["temperature"] = .double(temperature) }
        body["generationConfig"] = .object(generation)

        removeUnsupported(&body, quirks: quirks)
        return .object(body)
    }

    /// 把一条归一化消息编码成 Gemini 的 `parts` 数组（**不含角色**）。
    ///
    /// ⚠️ 拆出这一步的理由同 Anthropic（见 `anthropicContent`）：合并要基于
    ///    "这条消息到底有没有内容"，而空内容只有算完才知道。
    static func geminiParts(
        _ message: Message,
        quirks: ProviderQuirks,
        context: RequestEncodingContext,
        toolNames: [String: String]
    ) -> [JSONValue] {
        var parts: [JSONValue] = []

        // thoughtSignature 必须**按原顺序**回传，否则报 "at least one thought signature missing"
        if quirks.reasoningReplay.shouldReplay(hasTools: !message.blocks.compactMap(\.toolCallValue).isEmpty) {
            for block in message.blocks {
                if case .reasoning(let text, let signature) = block.kind {
                    var part: [String: JSONValue] = [:]
                    if !text.isEmpty { part["text"] = .string(text) }
                    part["thought"] = .bool(true)
                    if let signature { part["thoughtSignature"] = .string(signature.base64EncodedString()) }
                    if !part.isEmpty { parts.append(.object(part)) }
                }
            }
        }

        for block in message.blocks {
            switch block.kind {
            case .text(let text):
                guard !text.isEmpty else { continue }
                parts.append(.object(["text": .string(text)]))
            case .image(let ref, _):
                if let resolved = context.resolveImage(ref) {
                    parts.append(.object(["inlineData": .object([
                        "mimeType": .string(resolved.mime),
                        "data": .string(resolved.data.base64EncodedString()),
                    ])]))
                }
            case .toolCall(let call):
                parts.append(.object(["functionCall": .object([
                    "name": .string(call.name),
                    "args": (try? call.arguments()) ?? .object([:]),
                ])]))
            case .toolResult(let result):
                // ⚠️ 名字必须与 `functionDeclarations` 里声明的函数名一致。
                //    原来这里硬编码成 `"tool"` —— 那是一个**不存在的函数**，
                //    与调用配不上（新版 API 对"函数响应与调用不匹配"会直接报错）。
                //    找不到配对时**宁可不给名字**：缺字段最多是少一层校验，
                //    给一个错名字会让上游把它配到别的地方去。
                var response: [String: JSONValue] = [:]
                if result.status == .ok || result.status == .truncated {
                    response["content"] = .string(result.summary)
                } else {
                    // 失败/被拒：用 `error` 而不是 `content`。
                    // 否则「权限被拒，请换方案」在模型看来与一次成功输出没有区别。
                    response["error"] = .string(result.summary)
                }
                var dict: [String: JSONValue] = ["response": .object(response)]
                if let name = toolNames[result.callID] { dict["name"] = .string(name) }
                parts.append(.object(["functionResponse": .object(dict)]))
            default:
                break
            }
        }

        return parts
    }

    // MARK: - 公共清理

    /// 剔除该端点不认识的字段（某些兼容端点见到未知字段直接 400）
    static func removeUnsupported(_ body: inout [String: JSONValue], quirks: ProviderQuirks) {
        for field in quirks.unsupportedFields {
            body.removeValue(forKey: field)
        }
    }
}
