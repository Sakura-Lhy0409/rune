import Testing
import Foundation
@testable import RuneKernel

// MARK: - JSONValue

@Suite("JSONValue 解析与规范化")
struct JSONValueTests {

    @Test("解析基本类型并保留 Int/Double 区别")
    func basicTypes() throws {
        #expect(try JSONValue.parse("null") == .null)
        #expect(try JSONValue.parse("true") == .bool(true))
        #expect(try JSONValue.parse("false") == .bool(false))
        #expect(try JSONValue.parse("\"hi\"") == .string("hi"))
        #expect(try JSONValue.parse("42") == .int(42))
        #expect(try JSONValue.parse("-7") == .int(-7))

        // 关键：带小数点的必须是 double，否则某些 API 会拒绝或语义不同
        #expect(try JSONValue.parse("1.0") == .double(1.0))
        #expect(try JSONValue.parse("1e3") == .double(1000.0))

        // 超出 Int 范围的超大整数不能崩，退化为 double
        if case .double = try JSONValue.parse("99999999999999999999999999") {} else {
            Issue.record("超大整数应退化为 double")
        }
    }

    @Test("解析嵌套结构")
    func nested() throws {
        let text = #"{"a":{"b":[1,2,{"c":"d"}]},"e":null}"#
        let v = try JSONValue.parse(text)
        #expect(v.value(at: ["a", "b", "0"]) == .int(1))
        #expect(v.value(at: ["a", "b", "2", "c"]) == .string("d"))
        #expect(v.value(at: ["e"]) == .null)
        #expect(v.value(at: ["missing"]) == nil)
        #expect(v.value(at: ["a", "b", "99"]) == nil)
        // 对非容器取路径不崩
        #expect(v.value(at: ["a", "b", "0", "x"]) == nil)
    }

    @Test("字符串转义：引号、反斜杠、控制字符、unicode、代理对")
    func escapes() throws {
        #expect(try JSONValue.parse(#""a\"b""#) == .string(#"a"b"#))
        #expect(try JSONValue.parse(#""a\\b""#) == .string(#"a\b"#))
        #expect(try JSONValue.parse(#""a\nb""#) == .string("a\nb"))
        #expect(try JSONValue.parse(#""\u4e2d\u6587""#) == .string("中文"))
        // 代理对：U+1F600 😀
        #expect(try JSONValue.parse(#""\ud83d\ude00""#) == .string("😀"))
        // 直接写 UTF-8（模型经常直接吐中文，不做转义）
        #expect(try JSONValue.parse(#""中文直接写""#) == .string("中文直接写"))
    }

    @Test("canonicalString 是确定性的（键排序）—— 这是请求指纹去重的前提")
    func canonicalDeterminism() throws {
        let a = try JSONValue.parse(#"{"b":1,"a":2,"c":{"z":1,"y":2}}"#)
        let b = try JSONValue.parse(#"{"c":{"y":2,"z":1},"a":2,"b":1}"#)
        #expect(a.canonicalString() == b.canonicalString())
        #expect(a.canonicalString() == #"{"a":2,"b":1,"c":{"y":2,"z":1}}"#)

        // 数组顺序必须保留（顺序有语义，不能排序）
        let arr1 = try JSONValue.parse("[3,1,2]")
        #expect(arr1.canonicalString() == "[3,1,2]")
    }

    @Test("canonicalString 的数字格式稳定")
    func canonicalNumbers() {
        #expect(JSONValue.int(42).canonicalString() == "42")
        #expect(JSONValue.double(1.0).canonicalString() == "1.0")
        #expect(JSONValue.bool(true).canonicalString() == "true")
        #expect(JSONValue.null.canonicalString() == "null")
        // JSON 无 NaN/Infinity —— 不能产出非法 JSON
        #expect(JSONValue.double(.nan).canonicalString() == "null")
        #expect(JSONValue.double(.infinity).canonicalString() == "1e999")
    }

    @Test("坏 JSON 必须抛出可诊断的错误（带偏移量）")
    func parseErrors() {
        #expect(throws: JSONParseError.self) { try JSONValue.parse("{") }
        #expect(throws: JSONParseError.self) { try JSONValue.parse(#"{"a":}"#) }
        #expect(throws: JSONParseError.self) { try JSONValue.parse(#"{"a":1,}"#) }
        #expect(throws: JSONParseError.self) { try JSONValue.parse(#""unterminated"#) }

        // 尾部多余内容必须被发现（模型经常吐 "{} 说明文字"）
        do {
            _ = try JSONValue.parse(#"{"a":1} extra"#)
            Issue.record("应因尾部内容报错")
        } catch let e as JSONParseError {
            if case .trailingContent = e {} else { Issue.record("期望 trailingContent，实际 \(e)") }
        } catch {
            Issue.record("期望 JSONParseError，实际 \(error)")
        }
    }

    @Test("深度限制防止栈溢出")
    func depthLimit() {
        let deep = String(repeating: "[", count: 500) + String(repeating: "]", count: 500)
        #expect(throws: JSONParseError.self) { try JSONValue.parse(deep) }
    }

    @Test("Codable 往返保真")
    func codableRoundTrip() throws {
        let original = try JSONValue.parse(#"{"i":9007199254740993,"d":1.5,"s":"中文","a":[1,null,true]}"#)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == original)
        // 大整数不能因 JSONEncoder 的默认行为丢精度
        #expect(decoded.value(at: ["i"])?.intValue == 9007199254740993)
    }

    @Test("便捷访问器")
    func accessors() {
        #expect(JSONValue.string("x").stringValue == "x")
        #expect(JSONValue.int(3).intValue == 3)
        #expect(JSONValue.double(3.0).intValue == 3)      // 整数值的 double 可转 int
        #expect(JSONValue.double(3.5).intValue == nil)
        #expect(JSONValue.bool(true).boolValue == true)
        #expect(JSONValue.array([.int(1)]).arrayValue?.count == 1)
        #expect(JSONValue.object(["a": .int(1)]).objectValue?["a"] == .int(1))
        #expect(JSONValue.null.isNull)
    }

    @Test("字面量构造（让内置配置与测试可读）")
    func literals() {
        let v: JSONValue = ["name": "rune", "count": 3, "tags": ["a", "b"], "ok": true, "n": nil]
        #expect(v.value(at: ["name"]) == .string("rune"))
        #expect(v.value(at: ["count"]) == .int(3))
        #expect(v.value(at: ["tags", "1"]) == .string("b"))
        #expect(v.value(at: ["n"]) == .null)
    }
}

// MARK: - SHA256

@Suite("SHA-256 与指纹")
struct HashingTests {

    @Test("标准测试向量")
    func knownVectors() {
        #expect(SHA256.hexDigest("") ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.hexDigest("abc") ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256.hexDigest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // 448 bit 边界（正好触发一次额外分组）
        let block = String(repeating: "a", count: 64)
        #expect(SHA256.hexDigest(block) ==
            "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
    }

    @Test("流式与一次性结果一致（大文件分块哈希的正确性）")
    func streamingMatchesOneShot() {
        for size in [0, 1, 55, 56, 63, 64, 65, 127, 128, 1000, 10_000] {
            let bytes = (0..<size).map { UInt8($0 % 251) }
            var h = SHA256.Streaming()
            // 故意用不规则分块
            var i = 0
            while i < bytes.count {
                let take = min(7, bytes.count - i)
                h.update(bytes[i..<(i + take)])
                i += take
            }
            #expect(h.finalize() == SHA256.hash(bytes), "size=\(size) 流式与一次性不一致")
        }
    }

    @Test("请求指纹：同内容同指纹，异内容异指纹")
    func requestFingerprint() {
        let body = Data(#"{"model":"x","messages":[]}"#.utf8)
        let a = Fingerprint.request(providerID: "anthropic", modelID: "opus", serializedBody: body)
        let b = Fingerprint.request(providerID: "anthropic", modelID: "opus", serializedBody: body)
        let c = Fingerprint.request(providerID: "openai", modelID: "opus", serializedBody: body)
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 32)
    }

    @Test("执行指纹：输入哈希顺序不影响结果（排序后）")
    func executionFingerprintOrderIndependent() {
        let h1 = SHA256.hash("file-a")
        let h2 = SHA256.hash("file-b")
        let a = Fingerprint.execution(runtime: .python, invocation: "print(1)", inputHashes: [h1, h2])
        let b = Fingerprint.execution(runtime: .python, invocation: "print(1)", inputHashes: [h2, h1])
        #expect(a == b)
        let c = Fingerprint.execution(runtime: .shell, invocation: "print(1)", inputHashes: [h1, h2])
        #expect(a != c)
    }
}
