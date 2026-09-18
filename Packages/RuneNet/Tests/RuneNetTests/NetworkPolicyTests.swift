import Foundation
import Testing
import RuneKernel
@testable import RuneNet

@Suite("网络出口与响应元数据")
struct NetworkPolicyTests {
    @Test("默认拒绝；地址、端口、方法与请求体预算都必须匹配")
    func explicitAuthorization() throws {
        let request = ModelHTTPRequest(url: "https://api.example.com/v1", body: Data("123".utf8))
        #expect(throws: NetworkTransportError.denied) { try NetworkEgressPolicy().validate(request) }
        let policy = try NetworkEgressPolicy(allowedOrigins: ["https://API.example.com"], maxRequestBytes: 3)
        #expect(try policy.validate(request).host == "api.example.com")
        for url in ["https://api.example.com.evil.test", "https://evil-api.example.com", "https://api.example.com:444"] {
            #expect(throws: NetworkTransportError.denied) {
                try policy.validate(ModelHTTPRequest(url: url, body: Data()))
            }
        }
        #expect(throws: NetworkTransportError.denied) {
            try policy.validate(ModelHTTPRequest(url: request.url, method: "DELETE", body: Data()))
        }
        #expect(throws: NetworkTransportError.denied) {
            try policy.validate(ModelHTTPRequest(url: request.url, body: Data("1234".utf8)))
        }
    }

    @Test("明文仅限显式授权的局域网；白名单不自动打开私网")
    func localNetwork() throws {
        let local = ModelHTTPRequest(url: "http://127.0.0.1:8000/chat", body: Data())
        let denied = try NetworkEgressPolicy(allowedOrigins: [local.url])
        #expect(throws: NetworkTransportError.denied) { try denied.validate(local) }
        let allowed = try NetworkEgressPolicy(allowedOrigins: [local.url], allowPrivateNetwork: true)
        #expect(try allowed.validate(local).port == 8000)
        let publicHTTP = ModelHTTPRequest(url: "http://example.com", body: Data())
        #expect(throws: NetworkTransportError.denied) {
            try NetworkEgressPolicy(allowedOrigins: [publicHTTP.url], allowPrivateNetwork: true).validate(publicHTTP)
        }
    }

    @Test("拒绝 URL 凭据、fragment、非 HTTP 协议和非法超时")
    func invalidRequests() throws {
        for value in ["file:///tmp/key", "https://user:secret@example.com", "https://example.com/#secret", "relative/path"] {
            #expect(throws: NetworkTransportError.invalidRequest) {
                try NetworkEgressPolicy(allowedOrigins: [value])
            }
        }
        let policy = try NetworkEgressPolicy(allowedOrigins: ["https://example.com"])
        for timeout in [0, -1, Double.infinity, Double.nan, 86_401] {
            #expect(throws: NetworkTransportError.invalidRequest) {
                try policy.validate(.init(url: "https://example.com", body: Data(), timeoutSeconds: timeout))
            }
        }
    }

    @Test("禁止覆盖 Host/长度或注入换行；允许正常自定义鉴权头")
    func headerValidation() throws {
        let policy = try NetworkEgressPolicy(allowedOrigins: ["https://example.com"])
        for headers in [["Host": "evil.test"], ["Content-Length": "5"], ["X-Key": "a\r\nb"],
                        ["X-Key": "a", "x-key": "b"], ["Bad Header": "a"]] {
            #expect(throws: NetworkTransportError.invalidRequest) {
                try policy.validate(.init(url: "https://example.com", headers: headers, body: Data()))
            }
        }
        #expect(try policy.validate(.init(url: "https://example.com", headers: ["X-Relay-Key": "secret"], body: Data())).host == "example.com")
    }

    @Test("IPv6 私网与映射地址不能绕过局域网开关")
    func privateIPv6() throws {
        for host in ["[::1]", "[0:0:0:0:0:0:0:1]", "[::ffff:127.0.0.1]", "[::ffff:7f00:1]", "[fd00::1]", "[fe80::1]"] {
            let address = "https://\(host)"
            let policy = try NetworkEgressPolicy(allowedOrigins: [address])
            #expect(throws: NetworkTransportError.denied) {
                try policy.validate(.init(url: address, body: Data()))
            }
        }
    }

    @Test("拒绝模糊数字 IP，正常 fc/fd 开头域名不能被误判为私网")
    func addressNormalization() throws {
        for host in ["127.1", "2130706433", "0177.0.0.1", "0x7f000001"] {
            let address = "https://\(host)"
            let policy = try NetworkEgressPolicy(allowedOrigins: [address])
            #expect(throws: NetworkTransportError.invalidRequest) {
                try policy.validate(.init(url: address, body: Data()))
            }
        }
        for host in ["fcorp.example.com", "fdocs.example.com", "[2606:4700:4700::1111]"] {
            let address = "https://\(host)"
            let policy = try NetworkEgressPolicy(allowedOrigins: [address])
            #expect(throws: Never.self) { try policy.validate(.init(url: address, body: Data())) }
        }
    }

    @Test("Retry-After 支持秒数和 HTTP 日期，过去日期取零")
    func retryAfter() {
        let now = Date(timeIntervalSince1970: 1_445_412_470)
        #expect(RetryAfter.seconds("12", now: now) == 12)
        #expect(RetryAfter.seconds("Wed, 21 Oct 2015 07:28:00 GMT", now: now) == 10)
        #expect(RetryAfter.seconds("Wed, 21 Oct 2015 07:28:00 GMT", now: now.addingTimeInterval(11)) == 0)
        for value in ["-1", "NaN", "1.2", "999999999999999999999999999", "garbage"] {
            #expect(RetryAfter.seconds(value) == nil)
        }
    }
}
