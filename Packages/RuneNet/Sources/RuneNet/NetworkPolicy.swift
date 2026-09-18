import Foundation
import Darwin
import RuneKernel

public enum NetworkTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRequest
    case denied
    case redirectDenied
    case responseTooLarge
    case invalidResponse
    case timedOut
    case cancelled
    case network(Int)
    case blockingCallNotAllowed

    // 错误不能包含原始 URL：查询参数里可能带着渠道密钥。
    public var description: String {
        switch self {
        case .invalidRequest: return "请求地址、请求头或超时配置不合法。"
        case .denied: return "网络请求超出已授权的地址、方法或大小范围。"
        case .redirectDenied: return "重定向改变了授权目标、请求语义或超过跳数限制。"
        case .responseTooLarge: return "网络响应超过内存预算，连接已取消。"
        case .invalidResponse: return "服务端没有返回有效的 HTTP 响应。"
        case .timedOut: return "网络请求超过总时限，连接已取消。"
        case .cancelled: return "网络请求已取消。"
        case .network(let code): return "网络连接失败（错误码 \(code)）。"
        case .blockingCallNotAllowed: return "请使用异步网络接口；主线程和网络回调线程不能同步等待。"
        }
    }

    var providerError: ProviderError {
        let kind: ProviderError.Kind
        switch self {
        case .network, .timedOut: kind = .transient
        case .cancelled: kind = .unknown
        default: kind = .configuration
        }
        return ProviderError(kind: kind, providerID: "network", message: description,
                             userFacingMessage: description)
    }
}

/// 已由用户/上层策略批准的渠道地址。按 scheme + host + port 精确匹配，默认全部拒绝。
/// 不接受通配地址；不代替能力令牌、污点审批或 DNS 地址固定。
public struct NetworkEgressPolicy: Sendable {
    private let origins: Set<String>
    public let allowPrivateNetwork: Bool
    public let methods: Set<String>
    public let maxRequestBytes: Int
    public let maxResponseBytes: Int
    public let maxRedirects: Int

    public init(allowedOrigins: [String] = [], allowPrivateNetwork: Bool = false,
                methods: Set<String> = ["POST"], maxRequestBytes: Int = 1_048_576,
                maxResponseBytes: Int = 8_388_608, maxRedirects: Int = 3) throws {
        guard maxRequestBytes >= 0, maxResponseBytes > 0, (0...3).contains(maxRedirects) else {
            throw NetworkTransportError.invalidRequest
        }
        self.origins = try Set(allowedOrigins.map { try Self.origin(of: Self.url($0)) })
        self.allowPrivateNetwork = allowPrivateNetwork
        self.methods = Set(methods.map { $0.uppercased() })
        self.maxRequestBytes = maxRequestBytes
        self.maxResponseBytes = maxResponseBytes
        self.maxRedirects = maxRedirects
    }

    public func validate(_ request: ModelHTTPRequest) throws -> URL {
        guard request.timeoutSeconds.isFinite, request.timeoutSeconds > 0,
              request.timeoutSeconds <= 86_400 else { throw NetworkTransportError.invalidRequest }
        let url = try Self.url(request.url)
        try validate(url: url, method: request.method, bytes: request.body.count)
        var names: Set<String> = []
        let reserved: Set<String> = ["host", "content-length", "transfer-encoding", "connection"]
        for (name, value) in request.headers {
            let lower = name.lowercased()
            let token = name.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || "!#$%&'*+-.^_`|~".utf8.contains($0)
            }
            guard !name.isEmpty, token, !reserved.contains(lower), names.insert(lower).inserted,
                  !value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 || $0.value == 127 }) else {
                throw NetworkTransportError.invalidRequest
            }
        }
        return url
    }

    func validate(url: URL, method: String, bytes: Int) throws {
        let origin = try Self.origin(of: url)
        guard origins.contains(origin), methods.contains(method.uppercased()),
              bytes <= maxRequestBytes else { throw NetworkTransportError.denied }
        let host = url.host?.lowercased() ?? ""
        let isPrivate = try Self.isPrivateHost(host)
        guard allowPrivateNetwork || !isPrivate else { throw NetworkTransportError.denied }
        // 明文只允许明确开启的本地网络，不能因勾选局域网而放开整个公网。
        if url.scheme?.lowercased() == "http" {
            guard allowPrivateNetwork, isPrivate else {
                throw NetworkTransportError.denied
            }
        }
    }

    /// 用系统 IP 解析器识别等价 IPv6 写法；不能把以 fc/fd 开头的普通域名当作私网。
    /// 不做 DNS 解析/绑定：已批准域名的 DNS 重绑定防护仍需专门的连接层方案。
    private static func isPrivateHost(_ value: String) throws -> Bool {
        let host = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            guard host == bytes.map(String.init).joined(separator: ".") else {
                throw NetworkTransportError.invalidRequest
            }
            return privateIPv4(bytes)
        }
        // 拒绝 127.1、十进制整数、八进制等非标准 IPv4，防止 URLSession 和策略解释不一致。
        if inet_aton(host, &ipv4) == 1 { throw NetworkTransportError.invalidRequest }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            if bytes.prefix(12).allSatisfy({ $0 == 0 }) { return true } // 未指定、loopback、旧式 IPv4-compatible
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
                return privateIPv4(Array(bytes.suffix(4)))
            }
            return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
                || bytes[0] == 0xff
        }
        guard !host.contains(":"), !host.contains("%") else { throw NetworkTransportError.invalidRequest }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        return name == "localhost" || name == "localhost.localdomain"
            || [".localhost", ".local", ".internal", ".lan"].contains { name.hasSuffix($0) }
    }

    private static func privateIPv4(_ bytes: [UInt8]) -> Bool {
        let canonical = bytes.map(String.init).joined(separator: ".")
        return EgressGuard.isPrivateAddress(canonical) || bytes[0] >= 224
    }

    static func url(_ value: String) throws -> URL {
        guard let url = URL(string: value) else { throw NetworkTransportError.invalidRequest }
        _ = try origin(of: url)
        return url
    }

    static func origin(of url: URL) throws -> String {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || (1...65535).contains(url.port!) else {
            throw NetworkTransportError.invalidRequest
        }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
}

/// 不含路径、查询参数、请求头或正文；存储层通过注入的 sink 持久化。
public struct NetworkAuditEvent: Sendable {
    public enum Phase: String, Sendable { case started, redirected, completed, failed }
    public let requestID: UUID
    public let timestamp: Date
    public let phase: Phase
    public let host: String?
    public let method: String
    public let requestBytes: Int
    public let responseBytes: Int
    public let statusCode: Int?
    public let error: NetworkTransportError?
}

public enum RetryAfter {
    /// 支持 delay-seconds 与 HTTP-date；无效值交给网关的默认退避。
    public static func seconds(_ value: String?, now: Date = Date()) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.utf8.allSatisfy({ (48...57).contains($0) }) { return Int(value) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return nil }
        let seconds = ceil(date.timeIntervalSince(now))
        guard seconds.isFinite, seconds < Double(Int.max) else { return nil }
        return max(0, Int(seconds))
    }
}
