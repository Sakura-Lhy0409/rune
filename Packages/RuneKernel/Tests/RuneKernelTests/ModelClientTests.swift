import Testing
import Foundation
@testable import RuneKernel

// MARK: - 模型调用客户端：网关那一层唯一的执行入口
//
// 这一组守的是**之前根本不存在的行为**。在此之前：
//   `GatewayRouter.route` / `RetryPolicy.decide` / `Degradation.plan` / `HealthTracker.record*`
//   在 `Sources/` 里是**零调用点** —— 913 行有测试的代码，没有任何东西会执行它。
//   于是 Rune 的实际行为是：不路由、不重试、不记健康、不降级、不去重。
//
// 所以下面每一条测试都在问同一个问题：**这条规则真的会被执行吗？**

/// 脚本化传输：按顺序吐出预设响应，并记录所有真实发出的请求
final class ScriptedTransport: ModelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ModelHTTPRequest] = []
    private var queue: [Result<ModelHTTPResponse, Error>]

    init(_ responses: [Result<ModelHTTPResponse, Error>]) {
        self.queue = responses
    }

    convenience init(_ bodies: [String], status: Int = 200) {
        self.init(bodies.map { .success(ModelHTTPResponse(statusCode: status, body: Data($0.utf8), latencyMS: 12)) })
    }

    var requests: [ModelHTTPRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var requestCount: Int { requests.count }

    func send(_ request: ModelHTTPRequest) throws -> ModelHTTPResponse {
        lock.lock()
        _requests.append(request)
        let next = queue.isEmpty ? nil : queue.removeFirst()
        lock.unlock()
        guard let next else {
            // 脚本用完了还发 → 是测试写错了，明确报出来（而不是假装成功）
            throw ProviderError(kind: .unknown, providerID: "script",
                                message: "脚本响应已用完（第 \(requests.count) 次发送）",
                                userFacingMessage: "测试脚本没准备好这一次响应")
        }
        return try next.get()
    }
}

// MARK: 夹具

private func model(_ id: String, alias: String? = nil, context: Int = 128_000) -> ModelDescriptor {
    ModelDescriptor(id: id, alias: alias, contextWindow: context,
                    supportsTools: true, supportsVision: false, supportsReasoning: false)
}

private func channel(
    _ id: String,
    _ family: ProtocolFamily = .openAIChat,
    category: ProviderCategory = .official,
    models: [ModelDescriptor],
    auth: AuthConfig? = nil,
    extraHeaders: [String: String] = [:],
    enabled: Bool = true
) -> ProviderConfig {
    ProviderConfig(
        id: id, displayName: id.uppercased(), protocolFamily: family,
        baseURL: "https://\(id).example.com/v1",
        auth: auth ?? .bearer(keyRef: "keychain://\(id)"),
        extraHeaders: extraHeaders, category: category,
        isEnabled: enabled, models: models
    )
}

/// 一个"两个渠道"的典型配置：主渠道 + 备用渠道
private func twoChannels() -> [ProviderConfig] {
    [
        channel("main", models: [model("main-model", alias: "default")]),
        channel("backup", .anthropicMessages, models: [model("backup-model", alias: "strong")]),
    ]
}

private let twoRules: [RouteRule] = [
    RouteRule(task: .code, model: "main:default", fallback: ["backup:strong"]),
]

private func chatRequest(_ objective: String = "看一下 notes.md") -> ChatRequest {
    ChatRequest(
        messages: [Message(role: .user, blocks: [.text(objective, origin: .userInstruction)],
                           origin: .userInstruction)],
        maxOutputTokens: 4096
    )
}

private let okOpenAI = #"data: {"choices":[{"delta":{"content":"看完了"}}]}"# + "\n\n"
    + #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":10}}"# + "\n\n"
    + "data: [DONE]\n\n"

private let okAnthropic = "event: message_start\ndata: {\"message\":{\"usage\":{\"input_tokens\":100}}}\n\n"
    + "event: content_block_start\ndata: {\"index\":0,\"content_block\":{\"type\":\"text\"}}\n\n"
    + "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"看完了\"}}\n\n"
    + "event: message_delta\ndata: {\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":10}}\n\n"
    + "event: message_stop\ndata: {}\n\n"

private func client(_ transport: ScriptedTransport,
                    channels: [ProviderConfig] = twoChannels(),
                    rules: [RouteRule] = twoRules,
                    credentials: [String: String] = ["keychain://main": "sk-main",
                                                     "keychain://backup": "sk-backup"],
                    maxAttempts: Int = 4) -> ModelClient {
    ModelClient(transport: transport, channels: channels, rules: rules,
                credentials: credentials, maxAttempts: maxAttempts, waitBeforeRetry: { _ in })
}

private func texts(_ events: [ModelEvent]) -> String {
    events.compactMap { if case .textDelta(let t) = $0 { return t }; return nil }.joined()
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("⭐⭐ 路由真的会被执行（在此之前零调用点）")

struct ModelClientRoutingTests {

    @Test("按任务类型选渠道：规则里指定的主渠道就是真的用的那个")
    func routesToTheConfiguredPrimary() {
        let transport = ScriptedTransport([okOpenAI])
        var c = client(transport)
        let outcome = c.call(chatRequest(), task: .code, now: t0)

        #expect(outcome.succeeded)
        #expect(texts(outcome.events) == "看完了")
        #expect(transport.requests.first?.url.contains("main.example.com") == true,
                "实际发到了：\(transport.requests.first?.url ?? "nil")")
        #expect(transport.requestCount == 1)
        #expect(outcome.report.attempts.count == 1)
    }

    @Test("⭐ 鉴权头来自 Keychain 引用，**配置里没有密钥**")
    func authHeaderComesFromCredentials() {
        let transport = ScriptedTransport([okOpenAI])
        var c = client(transport)
        _ = c.call(chatRequest(), task: .code, now: t0)
        let sent = transport.requests.first
        #expect(sent?.headers["Authorization"] == "Bearer sk-main")

        // 没有凭据时不能假装有：既不发空头，也不泄露引用
        let bare = ScriptedTransport([okOpenAI])
        var c2 = client(bare, credentials: [:])
        _ = c2.call(chatRequest(), task: .code, now: t0)
        #expect(bare.requests.first?.headers["Authorization"] == nil)
        #expect(bare.requests.first?.url.contains("keychain") == false)
    }

    @Test("自定义头与查询参数两种鉴权也能用（中转站常见）")
    func customAuthStyles() {
        let headerTransport = ScriptedTransport([okOpenAI])
        var c = client(headerTransport, channels: [
            channel("main", models: [model("m", alias: "default")],
                    auth: .header(name: "X-Relay-Token", keyRef: "keychain://main")),
        ], rules: [RouteRule(task: .code, model: "main:default")])
        _ = c.call(chatRequest(), task: .code, now: t0)
        #expect(headerTransport.requests.first?.headers["X-Relay-Token"] == "sk-main")

        let queryTransport = ScriptedTransport([okOpenAI])
        var c2 = client(queryTransport, channels: [
            channel("main", models: [model("m", alias: "default")],
                    auth: .query(name: "api_key", keyRef: "keychain://main")),
        ], rules: [RouteRule(task: .code, model: "main:default")])
        _ = c2.call(chatRequest(), task: .code, now: t0)
        #expect(queryTransport.requests.first?.url.contains("api_key=sk-main") == true)
    }

    @Test("⚠️ 一个候选都没有时，把「为什么」如实说出来（不是只说失败）")
    func noCandidateExplainsWhy() {
        var health = HealthTracker()
        for _ in 0..<HealthTracker.failureThreshold {
            health.recordFailure("main", error: "挂了", now: t0)
            health.recordFailure("backup", error: "也挂了", now: t0)
        }
        let transport = ScriptedTransport([])
        var c = client(transport)
        c.health = health
        let outcome = c.call(chatRequest(), task: .code, now: t0)

        #expect(!outcome.succeeded)
        #expect(transport.requestCount == 0, "没有可用渠道时一枪都不该发")
        #expect(outcome.error?.kind == .configuration)
        #expect(outcome.error?.userFacingMessage.contains("挂了") == true,
                "要带上真实的失败原因：\(outcome.error?.userFacingMessage ?? "")")
    }
}

@Suite("⭐⭐ 重试真的会被执行")

struct ModelClientRetryTests {

    private func rateLimited(_ retryAfter: Int? = nil) -> Result<ModelHTTPResponse, Error> {
        .success(ModelHTTPResponse(statusCode: 429, body: Data(#"{"error":{"message":"slow down"}}"#.utf8),
                                   retryAfterSeconds: retryAfter, latencyMS: 5))
    }

    @Test("⭐ 429 之后同渠道再来一枪，成功即止")
    func retriesOnRateLimit() {
        let transport = ScriptedTransport([rateLimited(3), .success(
            ModelHTTPResponse(statusCode: 200, body: Data(okOpenAI.utf8), latencyMS: 20))])
        var c = client(transport)
        let outcome = c.call(chatRequest(), task: .code, now: t0)

        #expect(outcome.succeeded, "第二次该成功：\(String(describing: outcome.error))")
        #expect(transport.requestCount == 2, "实际发了 \(transport.requestCount) 枪")
        #expect(outcome.report.retryCount == 1)
        #expect(outcome.report.attempts.first?.action.contains("退避") == true,
                "要说明这一枪之后打算做什么：\(outcome.report.attempts.first?.action ?? "")")
        #expect(outcome.report.attempts.first?.statusCode == 429)
    }

    @Test("⭐⭐ 余额不足（402）**一次都不重试**，直接停下让用户去改")
    func neverRetriesConfigurationErrors() {
        let transport = ScriptedTransport([
            .success(ModelHTTPResponse(statusCode: 402,
                                       body: Data(#"{"error":{"message":"Insufficient credits"}}"#.utf8))),
        ])
        var c = client(transport)
        let outcome = c.call(chatRequest(), task: .code, now: t0)

        #expect(!outcome.succeeded)
        #expect(transport.requestCount == 1, "配置类错误重试只会让用户看到反复失败")
        #expect(outcome.error?.kind == .configuration)
        #expect(outcome.error?.userFacingMessage.contains("余额") == true)
        #expect(outcome.report.attempts.first?.action.contains("等你改配置") == true)
    }

    @Test("⚠️ 网络抛错按瞬时问题处理（可重试）")
    func transportThrowIsRetryable() {
        let transport = ScriptedTransport([
            .failure(URLError(.timedOut)),
            .success(ModelHTTPResponse(statusCode: 200, body: Data(okOpenAI.utf8), latencyMS: 9)),
        ])
        var c = client(transport)
        let outcome = c.call(chatRequest(), task: .code, now: t0)
        #expect(outcome.succeeded)
        #expect(transport.requestCount == 2)
    }

    @Test("⚠️ 打光次数上限就如实放弃（不能无限重试烧钱）")
    func stopsAtMaxAttempts() {
        let transport = ScriptedTransport(Array(repeating: rateLimited(), count: 10))
        var c = client(transport, maxAttempts: 3)
        let outcome = c.call(chatRequest(), task: .code, now: t0)
        #expect(!outcome.succeeded)
        #expect(transport.requestCount <= 3, "实际 \(transport.requestCount) 枪 —— 上限没起作用")
    }
}

@Suite("⭐⭐ 降级真的会被执行，而且可见（禁止静默降级）")

struct ModelClientDegradationTests {

    @Test("⭐ 主渠道 5xx 打到重试上限 → 换到备用渠道 → 生成**可见的**降级说明")
    func switchesChannelAndReportsDegradation() {
        // ⚠️ 5xx 的规则是「同渠道重试 2 次**之后**才换渠道」（RetryPolicy.maxGatewayRetries），
        //    所以前三枪都落在主渠道上，第四枪才去备用渠道 —— 这个顺序本身就是要守的行为。
        let busy = Result<ModelHTTPResponse, Error>.success(
            ModelHTTPResponse(statusCode: 503, body: Data("upstream busy".utf8)))
        let transport = ScriptedTransport([
            busy, busy, busy,
            .success(ModelHTTPResponse(statusCode: 200, body: Data(okAnthropic.utf8), latencyMS: 30)),
        ])
        var c = client(transport)
        let outcome = c.call(chatRequest(), task: .code, now: t0)

        #expect(outcome.succeeded, "换渠道之后该成功：\(String(describing: outcome.error))")
        let attempts = outcome.report.attempts
        // ⚠️ 必须 `guard` 而不是只 `#expect`：swift-testing 的 `#expect` **不会中断执行**，
        //    后面 `attempts[2]` 会直接越界 —— 而 Windows 上那会表现成"测试崩了"（0xC000001D），
        //    不是一条干净的失败（见 E9）。断言之后还要继续用下标时，先 guard。
        guard attempts.count == 4 else {
            Issue.record("应当打 4 枪，实际 \(attempts.count)：\(attempts.map(\.action))")
            return
        }
        #expect(attempts[0].action.contains("退避 1 秒") == true)
        #expect(attempts[1].action.contains("退避 2 秒") == true)
        #expect(attempts[2].action.contains("换下一个渠道") == true,
                "第三次失败之后才换渠道：\(attempts[2].action)")
        #expect(attempts[0].providerID == "main" && attempts[3].providerID == "backup")

        #expect(outcome.report.didDegrade, "换了渠道却没有降级说明 = 静默降级")
        let degradation = outcome.report.degradation
        // ⚠️ 这一位存在的意义就是让"禁止静默降级"是代码里显式的一行
        #expect(degradation?.isVisibleToUser == true)
        #expect(degradation?.notice.contains("降级") == true)
        #expect(degradation?.notice.contains("MAIN") == true, "要说清从哪来：\(degradation?.notice ?? "")")
        #expect(degradation?.notice.contains("BACKUP") == true, "以及到哪去")
        // 协议族从 openAIChat 换成 anthropicMessages → 能力变了，必须说出来
        #expect(degradation?.capabilityChanged == true)
        #expect(degradation?.notice.contains("能力可能变化") == true)
        // 真的打到了备用渠道，且事件里的 provider 是新的那个
        #expect(transport.requests.contains { $0.url.contains("backup.example.com") })
        let started = outcome.events.compactMap { if case .started(_, let p) = $0 { return p }; return nil }
        #expect(started.contains("backup"), "事件里要体现换过渠道：\(started)")
    }

    @Test("⭐ 每一枪都记健康：连续失败之后那个渠道会被路由摘掉")
    func healthAccumulatesAcrossCalls() {
        let transport = ScriptedTransport(Array(repeating:
            .success(ModelHTTPResponse(statusCode: 500, body: Data("boom".utf8))), count: 20))
        var c = client(transport, maxAttempts: 2)

        // 打若干轮，让主渠道连续失败到阈值
        for _ in 0..<3 { _ = c.call(chatRequest(), task: .code, now: t0) }
        #expect(c.health.isUsable("main") == false,
                "连续失败后必须被摘掉，否则一个挂掉的渠道会永远留在列表里")
        #expect(c.health.health("main").lastError != nil, "要记住最后一次是为什么挂的")

        // 之后的路由应当不再把 main 当主选
        let decision = GatewayRouter.route(task: .code, requirements: .init(),
                                          channels: twoChannels(), rules: twoRules, health: c.health)
        #expect(decision.primary?.providerID == "backup")
        #expect(decision.rejections.contains { $0.reason.contains("已暂时摘掉") })
    }

    @Test("⚠️ 成功之后健康要恢复（否则一次抖动会永久摘掉一个渠道）")
    func healthRecoversOnSuccess() {
        let transport = ScriptedTransport([
            .success(ModelHTTPResponse(statusCode: 500, body: Data("boom".utf8))),
            .success(ModelHTTPResponse(statusCode: 200, body: Data(okOpenAI.utf8))),
        ])
        var c = client(transport)
        _ = c.call(chatRequest(), task: .code, now: t0)
        #expect(c.health.isUsable("main"))
        #expect(c.health.health("main").consecutiveFailures == 0)
    }
}

@Suite("⭐⭐ 请求去重真的会被执行")

struct ModelClientDedupTests {

    @Test("⭐ 同一个请求第二次**不再发出去**（省一次计费）")
    func secondIdenticalRequestIsNotResent() {
        let transport = ScriptedTransport([
            .success(ModelHTTPResponse(statusCode: 200, body: Data(okOpenAI.utf8))),
        ])
        var c = client(transport)
        let first = c.call(chatRequest(), task: .code, now: t0)
        #expect(first.succeeded)
        #expect(transport.requestCount == 1)

        let second = c.call(chatRequest(), task: .code, now: t0)
        #expect(second.report.wasDeduplicated, "第二次必须认出这是同一个请求")
        #expect(texts(second.events) == texts(first.events))
        #expect(!second.events.contains { if case .usage = $0 { return true }; return false })

        #expect(transport.requestCount == 1, "不该真的再发一次（实际 \(transport.requestCount) 次）")
    }

    @Test("⚠️ 内容不同的请求不能被误判成同一个")
    func differentRequestsAreSentAgain() {
        let transport = ScriptedTransport([
            .success(ModelHTTPResponse(statusCode: 200, body: Data(okOpenAI.utf8))),
            .success(ModelHTTPResponse(statusCode: 200, body: Data(okOpenAI.utf8))),
        ])
        var c = client(transport)
        _ = c.call(chatRequest("看第一个文件"), task: .code, now: t0)
        _ = c.call(chatRequest("看第二个文件"), task: .code, now: t0)
        #expect(transport.requestCount == 2)
    }
}

@Suite("端到端：客户端解出来的字节能喂给 TurnRunner")

struct ModelClientRuntimeIntegrationTests {

    @Test("⭐⭐ 客户端驱动一整轮：真的路由 → 真的编码 → 真的解字节 → 工具真的被执行")
    func drivesAFullTurn() {
        // 第一轮：模型要求读文件；第二轮：收工
        let firstRound = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read_file","arguments":"{\"path\":\"/workspace/notes.md\"}"}}]}}]}"# + "\n\n"
            + #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":900,"completion_tokens":40}}"# + "\n\n"
            + "data: [DONE]\n\n"
        let transport = ScriptedTransport([
            .success(ModelHTTPResponse(statusCode: 200, body: Data(firstRound.utf8))),
            .success(ModelHTTPResponse(statusCode: 200, body: Data(okOpenAI.utf8))),
        ])

        let schema = JSONSchema.object(properties: ["path": .string(enumValues: nil, minLength: nil, maxLength: nil)],
                                       required: ["path"], additionalProperties: false)
        let specs: [String: ToolSpec] = [
            ToolName.readFile: ToolSpec(name: ToolName.readFile, description: "读文件", inputSchema: schema,
                                        pathParameters: ["path"], riskLevel: .safe,
                                        needsApproval: .never, requirements: [.fsRead]),
        ]

        // 用一个持有客户端的驱动器把它接进运行时（真实实现将来在 RuneCore 里长这样）
        final class Driver: @unchecked Sendable {
            private let lock = NSLock()
            private var client: ModelClient
            init(client: ModelClient) { self.client = client }
            func events(_ state: TurnState) -> [ModelEvent] {
                lock.lock(); defer { lock.unlock() }
                let outcome = client.call(
                    ChatRequest(messages: state.messages, maxOutputTokens: 4096),
                    task: .code, now: t0
                )
                return outcome.events
            }
        }
        let driver = Driver(client: client(transport))

        let token = CapabilityToken(
            issuedForTurn: UUID(), scopes: [.fsRead(VFSPath(mount: .workspace))],
            expiresAt: t0.addingTimeInterval(3600), grantedBy: .planApproval, reason: "端到端"
        )
        var config = TurnRunner.Config(maxRounds: 6, maxToolCalls: 8, toolRegistry: specs)
        config.maxCostMicroUSD = 0
        let (state, _, _) = TurnRunner.run(
            TurnState(objective: "看一下 notes.md 里写了什么"),
            deps: TurnRunner.Dependencies(
                modelEvents: { driver.events($0) },
                executor: StubEchoReader(),
                policy: PolicyEngine(),
                policyContext: PolicyEngine.Context(trustDial: .collaborate, token: token, planApproved: true),
                now: { t0 }
            ),
            config: config
        )

        #expect(state.status == .completed, "没跑完：\(state.status)")
        #expect(state.toolCallCount == 1, "工具必须真的被执行（不是被补记）")
        #expect(transport.requestCount == 2, "两轮模型调用")
        #expect(state.messages.contains { message in
            message.blocks.contains { $0.toolResultValue?.status == .ok }
        }, "要有一次成功执行的工具结果")
    }
}

private struct StubEchoReader: ToolExecuting {
    func execute(_ call: ToolCall) throws -> ToolResult {
        .ok(callID: call.id, summary: "notes.md: 部署步骤 1. 构建 2. 上传")
    }
}

@Suite("真实传输接入后的重试边界")
struct ModelClientTransportBoundaryTests {
    @Test("传输已经分类的配置错误不能被改成瞬时错误重试")
    func preserveFailureClassification() {
        let failure = ProviderError(kind: .configuration, providerID: "network",
                                    message: "出口未授权", userFacingMessage: "请配置渠道出口")
        let transport = ScriptedTransport([.failure(failure)])
        var c = client(transport)
        let outcome = c.call(chatRequest(), task: .code, now: t0)
        #expect(outcome.error == failure)
        #expect(transport.requestCount == 1)
    }

    @Test("重试必须经过等待点，且最后一次失败不再空等")
    func invokesDelay() {
        let transport = ScriptedTransport([
            .success(ModelHTTPResponse(statusCode: 429, body: Data(), retryAfterSeconds: 7)),
            .success(ModelHTTPResponse(statusCode: 429, body: Data(), retryAfterSeconds: 9)),
        ])
        let delays = RetryDelays()
        var c = client(transport, maxAttempts: 2)
        c.waitBeforeRetry = { delays.record($0) }
        let outcome = c.call(chatRequest(), task: .code, now: t0)
        #expect(!outcome.succeeded)
        #expect(delays.values == [7])
        #expect(transport.requestCount == 2)
    }

    @Test("等待被取消时不能继续发请求")
    func cancelledDelay() {
        let transport = ScriptedTransport([
            .success(ModelHTTPResponse(statusCode: 429, body: Data())),
            .success(ModelHTTPResponse(statusCode: 200, body: Data(okOpenAI.utf8))),
        ])
        var c = client(transport)
        c.waitBeforeRetry = { _ in throw CancellationError() }
        let outcome = c.call(chatRequest(), task: .code, now: t0)
        #expect(!outcome.succeeded)
        #expect(outcome.error?.kind == .unknown)
        #expect(transport.requestCount == 1)
    }
}

private final class RetryDelays: @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [Int] = []
    func record(_ value: Int) { lock.lock(); delays.append(value); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return delays }
}
