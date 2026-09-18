import Foundation
import RuneKernel

/// 一个实例对应一个已配置渠道；复用 ephemeral URLSession，不共享 cookie、缓存或凭据。
/// 只发一次请求，不自动重放模型 POST。是否重试由 ModelClient/上层调度决定。
public final class URLSessionModelTransport: ModelTransport, @unchecked Sendable {
    private let policy: NetworkEgressPolicy
    private let audit: @Sendable (NetworkAuditEvent) -> Void
    private let delegate: TransportDelegate
    private let queue: OperationQueue
    private let session: URLSession
    private let onSSE: (@Sendable (SSEEvent) -> Void)?

    public convenience init(policy: NetworkEgressPolicy,
                            audit: @escaping @Sendable (NetworkAuditEvent) -> Void = { _ in }) {
        self.init(policy: policy, onSSE: nil, audit: audit)
    }

    public init(policy: NetworkEgressPolicy,
                onSSE: (@Sendable (SSEEvent) -> Void)?,
                audit: @escaping @Sendable (NetworkAuditEvent) -> Void = { _ in }) {
        self.policy = policy
        self.onSSE = onSSE
        self.audit = audit
        delegate = TransportDelegate()
        queue = OperationQueue()
        queue.name = "RuneNet.callbacks"
        queue.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 每个请求还有独立的总时限；不能由心跳无限延长。
        config.timeoutIntervalForResource = 86_400
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
    }

    deinit { session.invalidateAndCancel() }

    /// 一个运行时独占一个传输实例；取消不会失效 session，后续用户恢复可以再次使用。
    public func cancelAll() { delegate.cancelAll() }

    /// 兼容现有同步 ModelClient。生产 UI 应调用 sendAsync，不能阻塞主线程。
    public func send(_ request: ModelHTTPRequest) throws -> ModelHTTPResponse {
        try send(request, cancellation: NetworkRequestCancellation())
    }
    public func send(_ request: ModelHTTPRequest, cancellation: NetworkRequestCancellation) throws -> ModelHTTPResponse {
        guard !Thread.isMainThread, OperationQueue.current !== queue else {
            throw NetworkTransportError.blockingCallNotAllowed.providerError
        }
        let result = BlockingResult()
        start(request, cancellation: cancellation, onSSE: onSSE) { result.complete($0) }
        do { return try result.wait() }
        catch let error as NetworkTransportError { throw error.providerError }
    }

    /// onSSE 在串行网络回调队列增量调用；回调须快速返回，UI 更新自行切换到 MainActor。
    /// 仅 2xx 响应进入 SSE 消费；HTTP 错误体原样返回给网关分类。取消不会重放请求。
    public func sendAsync(_ request: ModelHTTPRequest,
                          onSSE: (@Sendable (SSEEvent) -> Void)? = nil) async throws -> ModelHTTPResponse {
        let cancellation = NetworkRequestCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                start(request, cancellation: cancellation, onSSE: onSSE) {
                    continuation.resume(with: $0)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func start(_ request: ModelHTTPRequest, cancellation: NetworkRequestCancellation,
                       onSSE: (@Sendable (SSEEvent) -> Void)?,
                       completion: @escaping @Sendable (Result<ModelHTTPResponse, Error>) -> Void) {
        let id = UUID()
        do {
            let url = try policy.validate(request)
            var http = URLRequest(url: url, timeoutInterval: request.timeoutSeconds)
            http.httpMethod = request.method.uppercased()
            http.httpBody = request.body
            http.allHTTPHeaderFields = request.headers
            let transfer = Transfer(id: id, request: request, url: url, policy: policy,
                                    audit: audit, onSSE: onSSE, completion: completion)
            let task = session.dataTask(with: http)
            transfer.attach(task)
            delegate.register(transfer, for: task)
            cancellation.install { transfer.abort(.cancelled) }
            transfer.start()
        } catch {
            let failure = (error as? NetworkTransportError) ?? .invalidRequest
            audit(.init(requestID: id, timestamp: Date(), phase: .failed, host: nil, method: request.method,
                        requestBytes: request.body.count, responseBytes: 0, statusCode: nil, error: failure))
            completion(.failure(failure))
        }
    }
}

public final class NetworkRequestCancellation: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private var cancelled = false
    private var action: (@Sendable () -> Void)?
    func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        let run = cancelled
        self.action = action
        lock.unlock()
        if run { action() }
    }
    public func cancel() {
        lock.lock()
        cancelled = true
        let action = action
        lock.unlock()
        action?()
    }
}

private final class BlockingResult: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<ModelHTTPResponse, Error>?
    func complete(_ result: Result<ModelHTTPResponse, Error>) {
        condition.lock()
        self.result = result
        condition.signal()
        condition.unlock()
    }
    func wait() throws -> ModelHTTPResponse {
        condition.lock()
        while result == nil { condition.wait() }
        let value = result!
        condition.unlock()
        return try value.get()
    }
}

private final class TransportDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    func cancelAll() {
        lock.lock(); let current = Array(transfers.values); lock.unlock()
        for transfer in current { transfer.abort(.cancelled) }
    }
    func register(_ transfer: Transfer, for task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        transfers[task.taskIdentifier] = transfer
    }
    private func transfer(_ task: URLSessionTask, remove: Bool = false) -> Transfer? {
        lock.lock(); defer { lock.unlock() }
        if remove { return transfers.removeValue(forKey: task.taskIdentifier) }
        return transfers[task.taskIdentifier]
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let accepted = transfer(dataTask)?.receive(response) ?? false
        completionHandler(accepted ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        transfer(dataTask)?.receive(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        transfer(task, remove: true)?.finish(error)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(transfer(task)?.redirect(response, request: request))
    }
}

/// URLSession 回调串行；取消和超时来自任意线程。所有共享状态由 lock 保护，用户回调始终在锁外。
private final class Transfer: @unchecked Sendable {
    private let lock = NSLock()
    private let id: UUID
    private let request: ModelHTTPRequest
    private let url: URL
    private let policy: NetworkEgressPolicy
    private let audit: @Sendable (NetworkAuditEvent) -> Void
    private let onSSE: (@Sendable (SSEEvent) -> Void)?
    private let completion: @Sendable (Result<ModelHTTPResponse, Error>) -> Void
    private let started = ContinuousClock.now
    private var task: URLSessionDataTask?
    private var timer: DispatchWorkItem?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var parser = SSEParser()
    private var redirects = 0
    private var failure: NetworkTransportError?
    private var finished = false

    init(id: UUID, request: ModelHTTPRequest, url: URL, policy: NetworkEgressPolicy,
         audit: @escaping @Sendable (NetworkAuditEvent) -> Void,
         onSSE: (@Sendable (SSEEvent) -> Void)?,
         completion: @escaping @Sendable (Result<ModelHTTPResponse, Error>) -> Void) {
        self.id = id; self.request = request; self.url = url; self.policy = policy
        self.audit = audit; self.onSSE = onSSE; self.completion = completion
    }

    func attach(_ task: URLSessionDataTask) { self.task = task }

    func start() {
        let timer = DispatchWorkItem { [weak self] in self?.abort(.timedOut) }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        self.timer = timer
        let task = task
        lock.unlock()
        audit(event(.started))
        DispatchQueue.global().asyncAfter(deadline: .now() + request.timeoutSeconds, execute: timer)
        task?.resume()
    }

    func abort(_ error: NetworkTransportError) {
        lock.lock()
        if !finished, failure == nil { failure = error }
        let task = finished ? nil : task
        lock.unlock()
        task?.cancel()
    }

    func receive(_ value: URLResponse) -> Bool {
        guard let http = value as? HTTPURLResponse else { abort(.invalidResponse); return false }
        lock.lock()
        response = http
        let overLimit = http.expectedContentLength > Int64(policy.maxResponseBytes)
        let active = failure == nil
        lock.unlock()
        if overLimit { abort(.responseTooLarge) }
        return active && !overLimit
    }

    func receive(_ data: Data) {
        lock.lock()
        guard !finished, failure == nil else { lock.unlock(); return }
        guard data.count <= policy.maxResponseBytes - body.count else {
            lock.unlock(); abort(.responseTooLarge); return
        }
        body.append(data)
        let events = shouldParse ? parser.ingest(data) : []
        lock.unlock()
        for event in events { onSSE?(event) }
    }

    private var shouldParse: Bool {
        onSSE != nil && response.map { (200...299).contains($0.statusCode) } == true
    }

    func redirect(_ response: HTTPURLResponse, request next: URLRequest) -> URLRequest? {
        do {
            guard let target = next.url, [307, 308].contains(response.statusCode),
                  next.httpMethod?.uppercased() == request.method.uppercased(),
                  try NetworkEgressPolicy.origin(of: target) == NetworkEgressPolicy.origin(of: url) else {
                throw NetworkTransportError.redirectDenied
            }
            try policy.validate(url: target, method: request.method, bytes: request.body.count)
            lock.lock()
            redirects += 1
            let allowed = failure == nil && redirects <= policy.maxRedirects
            lock.unlock()
            guard allowed else { throw NetworkTransportError.redirectDenied }
            // 同源且语义不变时显式恢复请求体/自定义鉴权；不依赖系统是否保留这些字段。
            var approved = next
            approved.httpBody = request.body
            approved.allHTTPHeaderFields = request.headers
            audit(event(.redirected, statusCode: response.statusCode))
            return approved
        } catch {
            abort(.redirectDenied)
            return nil
        }
    }

    func finish(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        timer?.cancel()
        timer = nil
        if failure == nil, let error {
            let code = (error as NSError).code
            failure = code == URLError.cancelled.rawValue ? .cancelled
                : code == URLError.timedOut.rawValue ? .timedOut : .network(code)
        }
        if failure == nil, response == nil { failure = .invalidResponse }
        let events = failure == nil && shouldParse ? parser.finish() : []
        let result: Result<ModelHTTPResponse, Error>
        if let failure { result = .failure(failure) }
        else {
            let elapsed = started.duration(to: .now).components
            let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
            result = .success(.init(statusCode: response!.statusCode, body: body,
                                    retryAfterSeconds: RetryAfter.seconds(response?.value(forHTTPHeaderField: "Retry-After")),
                                    latencyMS: milliseconds))
        }
        task = nil
        lock.unlock()
        for event in events { onSSE?(event) }
        audit(event(failure == nil ? .completed : .failed))
        completion(result)
    }

    private func event(_ phase: NetworkAuditEvent.Phase, statusCode: Int? = nil) -> NetworkAuditEvent {
        lock.lock(); defer { lock.unlock() }
        return .init(requestID: id, timestamp: Date(), phase: phase, host: url.host, method: request.method.uppercased(),
                     requestBytes: request.body.count, responseBytes: body.count,
                     statusCode: statusCode ?? response?.statusCode, error: failure)
    }
}
