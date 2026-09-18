import Foundation

// MARK: - 模型调用客户端：把网关那一层真正接到一次调用上
//
// ## 为什么必须补这一层
//
// `Gateway.swift` 里有 913 行、几十项测试的东西：路由、降级、重试、健康、去重。
// 而**它们一个调用点都没有** —— `GatewayRouter.route`、`RetryPolicy.decide`、
// `Degradation.plan`、`HealthTracker.record*` 在 `Sources/` 里都是零引用。
//
// 也就是说，在此之前 Rune 的实际行为是：
//   · **不路由**（没有多渠道路由这回事）
//   · **不重试**（一次 429 就把这一轮打死）
//   · **不记健康**（挂掉的渠道永远留在列表里）
//   · **不降级**（"禁止静默降级"写得再漂亮也没有东西会降级）
//   · **不去重**（同一个请求重发两次就付两次钱）
//
// 这不是"少个功能"，是**一个完整的子系统只以声明的形式存在**（T48/T49 那一类，这是最大的一次）。
// 修法同理：给它一个**唯一执行入口** —— 就是下面这个 `ModelClient`。
//
// ## 为什么传输层是一个协议而不是 URLSession
//
// 内核是零依赖的，`URLSession` 属于 RuneNet。把传输抽象成一个**同步**协议，
// 换来的是：整条链路（路由 → 编码 → 发送 → 解码 → 重试 → 降级 → 记账）都能在没有网络、
// 没有 macOS 的条件下被完整验证 —— 脚本化传输返回真实字节即可。
// 真正的 URLSession 实现挂在 `RuneNet`，它自己负责把异步流攒成一次响应。

// MARK: - 传输

/// 一次 HTTP 请求（内核不关心它怎么发出去）
public struct ModelHTTPRequest: Sendable, Hashable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data
    public var timeoutSeconds: Double

    public init(url: String, method: String = "POST", headers: [String: String] = [:],
                body: Data, timeoutSeconds: Double = 120) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeoutSeconds = timeoutSeconds
    }
}

/// 一次 HTTP 响应。**流已经在里面了**（传输层负责把 SSE 攒完）。
public struct ModelHTTPResponse: Sendable, Hashable {
    public var statusCode: Int
    public var body: Data
    /// `Retry-After`（厂商给的退避建议，优先于我们自己的指数退避）
    public var retryAfterSeconds: Int?
    public var latencyMS: Int

    public init(statusCode: Int, body: Data, retryAfterSeconds: Int? = nil, latencyMS: Int = 0) {
        self.statusCode = statusCode
        self.body = body
        self.retryAfterSeconds = retryAfterSeconds
        self.latencyMS = latencyMS
    }
}

public protocol ModelTransport: Sendable {
    func send(_ request: ModelHTTPRequest) throws -> ModelHTTPResponse
}

// MARK: - 报告

/// 这一次调用到底发生了什么（**用户可见的那部分体验全靠它**）
public struct ModelCallReport: Sendable {
    public struct Attempt: Sendable, Hashable {
        public var providerID: String
        public var modelID: String
        public var statusCode: Int?
        /// 这一枪为什么没成（成了就是 nil）
        public var error: String?
        /// 打完这一枪之后决定做什么
        public var action: String
    }

    public var attempts: [Attempt] = []
    /// 被排除的候选与原因（"为什么没用那个渠道"）
    public var rejections: [RoutingDecision.Rejection] = []
    /// 换渠道时的降级说明（nil = 没降级）
    public var degradation: DegradationPlan?
    /// 是否用上了缓存（没有真的发出去）
    public var wasDeduplicated = false
    /// 一个候选都没有时的解释
    public var routingExplanation: String = ""

    public var didDegrade: Bool { degradation != nil }
    public var retryCount: Int { max(0, attempts.count - 1) }

    /// 给时间轴用的一行（只在真的发生了值得说的事时非空）
    public var notice: String? {
        if let degradation { return degradation.notice }
        return nil
    }
}

public struct ModelCallOutcome: Sendable {
    public var events: [ModelEvent]
    public var report: ModelCallReport
    /// 彻底失败时的错误（`events` 里也会带一个 `.providerError`）
    public var error: ProviderError?

    public var succeeded: Bool { error == nil }
}

// MARK: - 客户端

public struct ModelClient: Sendable {

    /// 凭据：`keyRef` → 真值。⚠️ 真值只从 Keychain 来，**不进配置、不进日志**。
    public var credentials: [String: String]
    public var channels: [ProviderConfig]
    public var rules: [RouteRule]
    /// 健康状态（跨轮次累积，所以要由调用方持有）
    public var health: HealthTracker
    public var dedupe: RequestDeduplicator
    private var cachedEvents: [Data: [ModelEvent]] = [:]
    public let transport: any ModelTransport
    /// 每次调用最多打几枪（含换渠道）；超过就如实告诉用户
    public var maxAttempts: Int
    /// 同步客户端的等待点。真实调用在工作队列运行；测试可注入虚拟时钟。
    /// 抛错表示取消等待，不得继续发送下一枪。
    public var waitBeforeRetry: @Sendable (Int) throws -> Void

    public init(
        transport: any ModelTransport,
        channels: [ProviderConfig],
        rules: [RouteRule] = RouteRule.defaults,
        credentials: [String: String] = [:],
        health: HealthTracker = HealthTracker(),
        dedupe: RequestDeduplicator = RequestDeduplicator(),
        maxAttempts: Int = 4,
        waitBeforeRetry: @escaping @Sendable (Int) throws -> Void = { seconds in
            Thread.sleep(forTimeInterval: Double(seconds))
        }
    ) {
        self.transport = transport
        self.channels = channels
        self.rules = rules
        self.credentials = credentials
        self.health = health
        self.dedupe = dedupe
        self.maxAttempts = max(1, maxAttempts)
        self.waitBeforeRetry = waitBeforeRetry
    }

    /// 发一次请求。**这是网关那一层唯一的执行入口。**
    ///
    /// 顺序刻意如此：
    ///   ① **先路由**（谁可用、为什么不用别的）—— 而不是"抄起第一个渠道就发"
    ///   ② **再查去重**（同一个请求指纹已经有完整响应 → 直接复用，省一次计费）
    ///   ③ 然后才编码、发送、解码
    ///   ④ 失败时按 `RetryPolicy` 决定：**退避重试 / 换渠道 / 让用户去改配置 / 放弃**
    ///   ⑤ 每一枪都记健康；换渠道时生成**降级说明**（不许静默降级）
    public mutating func call(
        _ request: ChatRequest,
        task: TaskKind,
        requirements: RoutingRequirements = RoutingRequirements(),
        now: Date
    ) -> ModelCallOutcome {
        var report = ModelCallReport()

        // ① 路由：按任务类型选主渠道 + 降级链
        let decision = GatewayRouter.route(
            task: task, requirements: requirements,
            channels: channels, rules: rules, health: health
        )
        report.rejections = decision.rejections
        report.routingExplanation = decision.explanation

        guard !decision.isEmpty else {
            // 一个都没得用 → 把"为什么"原样告诉用户，别只说"失败"
            let error = ProviderError(
                kind: .configuration, providerID: "-",
                message: decision.explanation,
                userFacingMessage: "没有可用的渠道：\n\(decision.explanation)"
            )
            return ModelCallOutcome(events: [.providerError(error)], report: report, error: error)
        }

        var executor = decision.primary
        var attempt = 1
        var lastError: ProviderError?

        while attempt <= maxAttempts, let current = executor {
            guard let channel = channels.first(where: { $0.id == current.providerID }) else { break }
            let modelID = current.modelID

            // ② 去重：同一个请求指纹已经有完整响应 → 直接复用（省一次计费）
            let encodedBody = Data(RequestEncoder
                .encode(request, family: channel.protocolFamily, model: modelID, quirks: channel.quirks)
                .canonicalString().utf8)
            let fingerprint = dedupe.begin(providerID: channel.id, modelID: modelID, body: encodedBody)
            if let answeredBy = dedupe.cachedResponder(for: fingerprint), let replay = cachedEvents[fingerprint] {
                report.wasDeduplicated = true
                report.attempts.append(.init(providerID: answeredBy.providerID, modelID: answeredBy.modelID,
                                             statusCode: nil, error: nil,
                                             action: "命中缓存，没有再发一次（省一次计费）"))
                // 缓存重放不产生新用量，不能再次扣费。
                let events = replay.filter { if case .usage = $0 { return false }; return true }
                return ModelCallOutcome(events: events, report: report, error: nil)
            }

            // ③ 真的发出去
            let httpRequest = buildHTTPRequest(channel: channel, model: modelID, body: encodedBody)
            var response: ModelHTTPResponse?
            var decoded: [ModelEvent] = []
            var failure: ProviderError?

            do {
                let sent = try transport.send(httpRequest)
                response = sent
                if sent.statusCode >= 400 {
                    let raw = String(decoding: sent.body.prefix(2_000), as: UTF8.self)
                    let kind = ProviderError.classify(statusCode: sent.statusCode, message: raw)
                    failure = ProviderError(
                        kind: kind, providerID: channel.id, statusCode: sent.statusCode,
                        message: raw,
                        userFacingMessage: ProviderError.userFacing(kind: kind, statusCode: sent.statusCode, raw: raw),
                        retryAfterSeconds: sent.retryAfterSeconds
                    )
                } else {
                    decoded = decode(sent.body, channel: channel, model: modelID)
                    failure = decoded.compactMap { event -> ProviderError? in
                        if case .providerError(let error) = event { return error }; return nil
                    }.first
                    if decoded.isEmpty {
                        failure = ProviderError(kind: .request, providerID: channel.id,
                            message: "响应没有可识别的模型事件", userFacingMessage: "渠道返回了空响应或不匹配的协议，请检查渠道协议配置。")
                    }
                }
            } catch let error as ProviderError {
                // 真实传输已经分类的出口/配置错误不能被重新归为瞬时错误并重试。
                failure = error
            } catch {
                failure = ProviderError(
                    kind: .transient, providerID: channel.id,
                    message: "\(error)",
                    userFacingMessage: "网络请求没发出去：\(error)"
                )
            }

            if let failure {
                lastError = failure
                // ⑤ 健康：每次都记（连续失败会被路由摘掉）
                health.recordFailure(channel.id, error: failure.userFacingMessage, now: now)

                let retry = RetryPolicy.decide(
                    error: failure, attempt: attempt,
                    isStreaming: failure.kind == .truncated
                )
                let action = describe(retry.action)

                switch retry.action {
                case .retrySameChannel(let seconds):
                    report.attempts.append(.init(providerID: channel.id, modelID: modelID,
                                                 statusCode: failure.statusCode,
                                                 error: failure.userFacingMessage, action: action))
                    // 最后一枪失败后没有下一次发送，也不应该白等一次退避。
                    if attempt < maxAttempts {
                        do { try waitBeforeRetry(seconds) }
                        catch {
                            let stopped = ProviderError(kind: .unknown, providerID: channel.id,
                                message: "重试等待已取消", userFacingMessage: "已停止重试，没有再次发送请求。")
                            return ModelCallOutcome(events: [.providerError(stopped)], report: report, error: stopped)
                        }
                    }
                    attempt += 1
                    continue

                case .switchChannel, .recompressAndRetry:
                    report.attempts.append(.init(providerID: channel.id, modelID: modelID,
                                                 statusCode: failure.statusCode,
                                                 error: failure.userFacingMessage, action: action))
                    // 换下一个候选，并生成**可见的**降级说明
                    guard let next = nextExecutor(after: current, in: decision) else {
                        executor = nil
                        continue
                    }
                    report.degradation = Degradation.plan(from: current, to: next)
                    executor = next
                    attempt += 1
                    continue

                case .askUserToFixConfig, .giveUp:
                    report.attempts.append(.init(providerID: channel.id, modelID: modelID,
                                                 statusCode: failure.statusCode,
                                                 error: failure.userFacingMessage, action: action))
                    return ModelCallOutcome(events: [.providerError(failure)], report: report, error: failure)
                }
            }

            // ④ 成功：解码（**真的把字节解回来**）
            guard let response else { break }
            var events = decoded
            health.recordSuccess(channel.id, latencyMS: response.latencyMS, now: now)
            dedupe.record(fingerprint: fingerprint, answeredBy: current)
            if cachedEvents.count >= 32 { cachedEvents.removeAll(); dedupe.reset(); dedupe.record(fingerprint: fingerprint, answeredBy: current) }
            cachedEvents[fingerprint] = events

            report.attempts.append(.init(providerID: channel.id, modelID: modelID,
                                         statusCode: response.statusCode, error: nil, action: "成功"))

            // 降级过的这一轮必须让模型**知道**自己在哪个渠道上（能力可能不同）
            if let degradation = report.degradation {
                events.insert(.started(modelID: degradation.to.modelID,
                                       providerID: degradation.to.providerID), at: 0)
            }
            return ModelCallOutcome(events: events, report: report, error: nil)
        }

        // 打光了还是不行 → 如实说（含每一枪的失败原因）
        let fallback = lastError ?? ProviderError(
            kind: .unknown, providerID: "-", message: report.routingExplanation,
            userFacingMessage: "尝试了 \(report.attempts.count) 次都没能成功。"
        )
        return ModelCallOutcome(events: [.providerError(fallback)], report: report, error: fallback)
    }

    // MARK: 内部

    /// 候选链里 `current` 之后的下一个（**顺序就是降级链的顺序**）
    private func nextExecutor(after current: ModelRef, in decision: RoutingDecision) -> ModelRef? {
        guard let index = decision.chain.firstIndex(where: { $0.providerID == current.providerID
            && $0.modelID == current.modelID }) else { return nil }
        let next = index + 1
        return next < decision.chain.count ? decision.chain[next] : nil
    }

    /// 拼 HTTP 请求：baseURL + 协议族路径 + 鉴权头。
    ///
    /// ⚠️ 鉴权真值来自 `credentials`（Keychain），而**配置里只有引用** ——
    ///    所以日志里永远不会出现密钥。
    func buildHTTPRequest(channel: ProviderConfig, model: String, body: Data) -> ModelHTTPRequest {
        let path = RequestEncoder.path(family: channel.protocolFamily, model: model)
        var url = channel.baseURL
        while url.hasSuffix("/") { url.removeLast() }
        var headers: [String: String] = ["Content-Type": "application/json"]
        for (key, value) in channel.extraHeaders { headers[key] = value }

        if let keyRef = channel.auth.keyRef, let secret = credentials[keyRef] {
            switch channel.auth {
            case .bearer:
                headers["Authorization"] = "Bearer \(secret)"
            case .header(let name, _):
                headers[name] = secret
            case .query, .none:
                break
            }
        }
        var finalURL = url + path
        if case .query(let name, let keyRef) = channel.auth,
           let secret = credentials[keyRef] {
            let separator = finalURL.contains("?") ? "&" : "?"
            finalURL += "\(separator)\(name)=\(secret)"
        }
        return ModelHTTPRequest(url: finalURL, headers: headers, body: body)
    }

    /// 按协议族的**数据流形态**选解析器：SSE 还是 NDJSON（Ollama 原生端点返回 NDJSON）
    func decode(_ body: Data, channel: ProviderConfig, model: String) -> [ModelEvent] {
        var decoder = AnyStreamDecoder.make(family: channel.protocolFamily,
                                           quirks: channel.quirks, model: model)
        var out: [ModelEvent] = []
        switch channel.protocolFamily.streamShape {
        case .serverSentEvents:
            var parser = SSEParser()
            for event in parser.ingest(body) { out.append(contentsOf: decoder.ingest(event)) }
            for event in parser.finish() { out.append(contentsOf: decoder.ingest(event)) }
        case .ndjson:
            // Ollama 原生端点返回的是 NDJSON，不是 SSE —— 用错解析器会得到零事件
            var parser = NDJSONParser()
            for line in parser.ingest(body) { out.append(contentsOf: decoder.ingestLine(line)) }
            for line in parser.finish() { out.append(contentsOf: decoder.ingestLine(line)) }
        }
        out.append(contentsOf: decoder.finish())
        return out
    }

    private func describe(_ action: RetryPolicy.Decision.Action) -> String {
        switch action {
        case .retrySameChannel(let after): return "退避 \(after) 秒后重试"
        case .switchChannel:               return "换下一个渠道"
        case .recompressAndRetry:          return "压缩上下文后重试"
        case .askUserToFixConfig:          return "停下，等你改配置"
        case .giveUp:                      return "放弃并如实说明"
        }
    }
}
