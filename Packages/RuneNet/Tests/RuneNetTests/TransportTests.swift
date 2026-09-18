import Foundation
import Testing
import RuneKernel
@testable import RuneNet

private func transport(_ server: LoopbackServer, maxResponseBytes: Int = 8_388_608,
                       extraOrigins: [String] = [],
                       audit: @escaping @Sendable (NetworkAuditEvent) -> Void = { _ in }) throws -> URLSessionModelTransport {
    try URLSessionModelTransport(policy: NetworkEgressPolicy(
        allowedOrigins: [server.origin] + extraOrigins, allowPrivateNetwork: true,
        maxResponseBytes: maxResponseBytes), audit: audit)
}

@Suite("真实 URLSession 与本地 HTTP/SSE")
struct TransportTests {
    @Test("请求正文与鉴权真实送达，响应字节和状态完整返回")
    func roundTrip() async throws {
        let server = try LoopbackServer()
        try await server.start(); defer { server.stop() }
        let response = try await transport(server).sendAsync(.init(
            url: server.origin + "/chat", headers: ["Authorization": "Bearer test-only"], body: Data("你好".utf8)))
        #expect(response.statusCode == 200)
        #expect(response.body == Data("data: hello\n\n".utf8))
        #expect(response.latencyMS >= 0)
        #expect(server.requests.count == 1)
        #expect(server.requests.first?.headers["authorization"] == "Bearer test-only")
        #expect(server.requests.first?.body == Data("你好".utf8))
    }

    @Test("SSE 分片穿过真实连接，中文跨字节边界也无损且首帧不等连接结束")
    func incrementalSSE() async throws {
        let bytes = Array("data: 你好\n\n".utf8)
        let server = try LoopbackServer { _ in
            .init(chunks: [Data(bytes.prefix(7)), Data(bytes.dropFirst(7)), Data("data: 尾帧".utf8)], interval: 0.15, chunked: true)
        }
        try await server.start(); defer { server.stop() }
        let events = LockedValues<SSEEvent>()
        let times = LockedValues<Date>()
        let response = try await transport(server).sendAsync(.init(url: server.origin, body: Data())) {
            events.append($0); times.append(Date())
        }
        #expect(events.values.map(\.data) == ["你好", "尾帧"])
        #expect(response.body == Data("data: 你好\n\ndata: 尾帧".utf8))
        #expect(Date().timeIntervalSince(try #require(times.values.first)) >= 0.20)
    }

    @Test("429 原样返回 Retry-After，错误正文不进入 SSE，传输层不擅自重试")
    func httpError() async throws {
        let server = try LoopbackServer { _ in
            .init(status: 429, headers: ["Retry-After": "7"], chunks: [Data("data: 不应作为模型回复\n\n".utf8)])
        }
        try await server.start(); defer { server.stop() }
        let events = LockedValues<SSEEvent>()
        let response = try await transport(server).sendAsync(.init(url: server.origin, body: Data())) { events.append($0) }
        #expect(response.statusCode == 429)
        #expect(response.retryAfterSeconds == 7)
        #expect(!response.body.isEmpty)
        #expect(events.values.isEmpty)
        #expect(server.requests.count == 1)
    }

    @Test("同源 307 保留 POST 的正文和自定义鉴权")
    func sameOriginRedirect() async throws {
        let server = try LoopbackServer { request in
            request.path == "/first" ? .init(status: 307, headers: ["Location": "/final"], chunks: []) : .init()
        }
        try await server.start(); defer { server.stop() }
        let response = try await transport(server).sendAsync(.init(url: server.origin + "/first",
            headers: ["X-Relay-Key": "test-secret"], body: Data("payload".utf8)))
        #expect(response.statusCode == 200)
        #expect(server.requests.map(\.path) == ["/first", "/final"])
        #expect(server.requests.last?.headers["x-relay-key"] == "test-secret")
        #expect(server.requests.last?.body == Data("payload".utf8))
    }

    @Test("跨端口重定向即使目标也在白名单仍不能携带密钥或正文过去")
    func crossOriginRedirect() async throws {
        let target = try LoopbackServer()
        try await target.start(); defer { target.stop() }
        let server = try LoopbackServer { _ in .init(status: 307, headers: ["Location": target.origin], chunks: []) }
        try await server.start(); defer { server.stop() }
        let client = try transport(server, extraOrigins: [target.origin])
        await #expect(throws: NetworkTransportError.redirectDenied) {
            try await client.sendAsync(.init(url: server.origin, headers: ["X-Relay-Key": "secret"], body: Data("private".utf8)))
        }
        #expect(target.requests.isEmpty)
    }

    @Test("重定向循环最多跟随三跳，改变 POST 语义的 302 直接拒绝", arguments: [302, 307])
    func redirectLimits(status: Int) async throws {
        let server = try LoopbackServer { _ in .init(status: status, headers: ["Location": "/again"], chunks: []) }
        try await server.start(); defer { server.stop() }
        let client = try transport(server)
        await #expect(throws: NetworkTransportError.redirectDenied) {
            try await client.sendAsync(.init(url: server.origin, body: Data()))
        }
        #expect(server.requests.count == (status == 302 ? 1 : 4))
    }

    @Test("白名单拒绝发生在发送前；审计不含查询密钥和正文")
    func deniedBeforeSending() async throws {
        let server = try LoopbackServer()
        try await server.start(); defer { server.stop() }
        let audits = LockedValues<NetworkAuditEvent>()
        let client = URLSessionModelTransport(policy: try NetworkEgressPolicy()) { audits.append($0) }
        await #expect(throws: NetworkTransportError.denied) {
            try await client.sendAsync(.init(url: server.origin + "/?key=secret-123", body: Data("private-payload".utf8)))
        }
        #expect(server.requests.isEmpty)
        #expect(audits.values.map(\.phase) == [.failed])
        #expect(!String(describing: audits.values).contains("secret-123"))
        #expect(!String(describing: audits.values).contains("private-payload"))
    }

    @Test("Content-Length 和 chunked 两条路径都守住响应大小预算", arguments: [false, true])
    func responseLimit(chunked: Bool) async throws {
        let server = try LoopbackServer { _ in .init(chunks: [Data(repeating: 65, count: 200)], chunked: chunked) }
        try await server.start(); defer { server.stop() }
        let client = try transport(server, maxResponseBytes: 100)
        await #expect(throws: NetworkTransportError.responseTooLarge) {
            try await client.sendAsync(.init(url: server.origin, body: Data()))
        }
    }

    @Test("服务端持续发心跳也不能延长请求总时限")
    func totalDeadline() async throws {
        let server = try LoopbackServer { _ in
            .init(chunks: Array(repeating: Data(": ping\n\n".utf8), count: 30), interval: 0.05, chunked: true)
        }
        try await server.start(); defer { server.stop() }
        let client = try transport(server)
        let start = ContinuousClock.now
        await #expect(throws: NetworkTransportError.timedOut) {
            try await client.sendAsync(.init(url: server.origin, body: Data(), timeoutSeconds: 0.25))
        }
        #expect(start.duration(to: .now) < .seconds(1.5))
    }

    @Test("取消挂起连接能及时返回且不会重发 POST")
    func cancellation() async throws {
        let server = try LoopbackServer { _ in .init(initialDelay: 5) }
        try await server.start(); defer { server.stop() }
        let client = try transport(server)
        let task = Task { try await client.sendAsync(.init(url: server.origin, body: Data())) }
        for _ in 0..<2_000 {
            if !server.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(server.requests.count == 1)
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: NetworkTransportError.cancelled) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(server.requests.count == 1)
    }

    @Test("同一 session 并发请求的响应与审计互不串线")
    func concurrentRequests() async throws {
        let server = try LoopbackServer { request in .init(chunks: [request.body]) }
        try await server.start(); defer { server.stop() }
        let audits = LockedValues<NetworkAuditEvent>()
        let client = try transport(server, audit: { audits.append($0) })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    let payload = Data("request-\(i)".utf8)
                    let response = try await client.sendAsync(.init(url: server.origin, body: payload))
                    #expect(response.body == payload)
                }
            }
            try await group.waitForAll()
        }
        #expect(server.requests.count == 8)
        #expect(audits.values.filter { $0.phase == .completed }.count == 8)
        #expect(Set(audits.values.map(\.requestID)).count == 8)
    }

    @Test("同步兼容接口能把真实 SSE 交给现有 ModelClient 解码")
    func modelClientIntegration() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"已接通\"}}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        let server = try LoopbackServer { _ in .init(chunks: [Data(body.utf8)]) }
        try await server.start(); defer { server.stop() }
        let transport = try transport(server)
        let outcome = await callOnWorker(transport, origin: server.origin)
        #expect(outcome.succeeded)
        #expect(outcome.events.contains { if case .textDelta("已接通") = $0 { return true }; return false })
        #expect(server.requests.count == 1)
    }

    @Test("真实 429 重试确实等待 Retry-After，而非立即连发")
    func realRetryDelay() async throws {
        let times = LockedValues<Date>()
        let server = try LoopbackServer { _ in
            times.append(Date())
            return times.values.count == 1
                ? .init(status: 429, headers: ["Retry-After": "1"], chunks: [])
                : .init(chunks: [Data("data: [DONE]\n\n".utf8)])
        }
        try await server.start(); defer { server.stop() }
        let outcome = await callOnWorker(try transport(server), origin: server.origin)
        #expect(outcome.succeeded)
        #expect(times.values.count == 2)
        let values = times.values
        if values.count == 2 { #expect(values[1].timeIntervalSince(values[0]) >= 0.95) }
    }

    @Test("真实出口拒绝经过 ModelClient 仍只尝试一次")
    func policyFailureIsNotRetried() async throws {
        let server = try LoopbackServer()
        try await server.start(); defer { server.stop() }
        let client = URLSessionModelTransport(policy: try NetworkEgressPolicy())
        let outcome = await callOnWorker(client, origin: server.origin)
        #expect(outcome.error?.kind == .configuration)
        #expect(outcome.report.attempts.count == 1)
        #expect(server.requests.isEmpty)
    }

    @Test("调用前已经取消的任务不建立连接")
    func preCancelled() async throws {
        let server = try LoopbackServer()
        try await server.start(); defer { server.stop() }
        let client = try transport(server)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.sendAsync(.init(url: server.origin, body: Data()))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(server.requests.isEmpty)
    }

    @Test("响应中途断开不能被当成成功，也不能 flush 未完成 SSE 帧")
    func truncatedConnection() async throws {
        let server = try LoopbackServer { _ in
            .init(chunks: [Data("data: unfinished".utf8)], advertisedLength: 100)
        }
        try await server.start(); defer { server.stop() }
        let client = try transport(server)
        let events = LockedValues<SSEEvent>()
        await #expect(throws: NetworkTransportError.self) {
            try await client.sendAsync(.init(url: server.origin, body: Data())) { events.append($0) }
        }
        #expect(events.values.isEmpty)
        #expect(server.requests.count == 1)
    }

    @MainActor @Test("同步接口在主线程快速拒绝，避免阻塞 UI")
    func rejectMainThread() throws {
        let client = URLSessionModelTransport(policy: try NetworkEgressPolicy())
        #expect(throws: ProviderError.self) { try client.send(.init(url: "https://example.com", body: Data())) }
    }
}

private func callOnWorker(_ transport: URLSessionModelTransport, origin: String) async -> ModelCallOutcome {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let provider = ProviderConfig(id: "local", displayName: "本地测试", protocolFamily: .openAIChat,
                baseURL: origin, auth: .none, models: [ModelDescriptor(id: "test", alias: "default", contextWindow: 8192)])
            var client = ModelClient(transport: transport, channels: [provider],
                rules: [RouteRule(task: .code, model: "local:default")])
            continuation.resume(returning: client.call(ChatRequest(messages: [], maxOutputTokens: 128), task: .code, now: Date()))
        }
    }
}
