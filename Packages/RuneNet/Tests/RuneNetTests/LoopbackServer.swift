import Foundation
import Network

/// 真实 TCP/HTTP 测试服务器：仅绑定 loopback，每个测试用系统分配的端口。
/// 不访问外部渠道，不使用模型密钥，不依赖 Python 或额外守护进程。
final class LoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        let path: String
        let headers: [String: String]
        let body: Data
    }
    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = ["Content-Type": "text/event-stream"]
        var chunks: [Data] = [Data("data: hello\n\n".utf8)]
        var interval: Double = 0
        var initialDelay: Double = 0
        var advertisedLength: Int? = nil
        var chunked = false
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "RuneNetTests.loopback")
    private let lock = NSLock()
    private var captured: [Request] = []
    private var connections: [NWConnection] = []
    private let handler: @Sendable (Request) -> Response
    private var port: UInt16 = 0

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return captured }
    var origin: String { "http://127.0.0.1:\(port)" }

    init(handler: @escaping @Sendable (Request) -> Response = { _ in Response() }) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock(); self.connections.append(connection); self.lock.unlock()
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // 首次 ready/failed 后移除处理器，确保 continuation 只完成一次。
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = self.listener.port!.rawValue
                    self.listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.lock(); let active = connections; connections = []; lock.unlock()
        for connection in active { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, error == nil else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count < 2_000_000 else { connection.cancel(); return }
            if let request = Self.parse(buffer) {
                self.lock.lock(); self.captured.append(request); self.lock.unlock()
                let response = self.handler(request)
                self.queue.asyncAfter(deadline: .now() + response.initialDelay) {
                    self.respond(response, on: connection)
                }
            } else if !complete {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private static func parse(_ buffer: Data) -> Request? {
        guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = Data(buffer[boundary.upperBound...])
        guard body.count >= length else { return nil }
        return Request(path: first.split(separator: " ").dropFirst().first.map(String.init) ?? "/",
                       headers: headers, body: Data(body.prefix(length)))
    }

    private func respond(_ response: Response, on connection: NWConnection) {
        var headers = response.headers
        if response.chunked { headers["Transfer-Encoding"] = "chunked" }
        else { headers["Content-Length"] = String(response.advertisedLength ?? response.chunks.reduce(0) { $0 + $1.count }) }
        headers["Connection"] = "close"
        let head = "HTTP/1.1 \(response.status) Test\r\n"
            + headers.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            if error == nil { self?.sendChunk(0, response: response, on: connection) }
        })
    }

    private func sendChunk(_ index: Int, response: Response, on connection: NWConnection) {
        guard index < response.chunks.count else {
            connection.send(content: response.chunked ? Data("0\r\n\r\n".utf8) : nil,
                            contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let chunk = response.chunks[index]
        var wire = chunk
        if response.chunked { wire = Data("\(String(chunk.count, radix: 16))\r\n".utf8) + chunk + Data("\r\n".utf8) }
        connection.send(content: wire, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }
            self.queue.asyncAfter(deadline: .now() + response.interval) {
                self.sendChunk(index + 1, response: response, on: connection)
            }
        })
    }
}

final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    func append(_ value: Value) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return stored }
}
