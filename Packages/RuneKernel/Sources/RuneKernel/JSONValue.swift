import Foundation

/// 一个极小的 JSON 值类型。
///
/// 为什么不用 `[String: Any]` / `Any`：
///   * `Any` 不是 `Sendable`，在 Swift 6 严格并发下无法跨 Actor 传递
///   * 工具参数需要**确定性序列化**（用于请求指纹去重与幂等键），字典无序会导致两次相同的
///     请求算出不同的哈希 → 无法去重。本类型提供**键排序**的 canonical 序列化。
///   * 需要区分 `Int` 与 `Double`（`1` 和 `1.0` 在某些 API 里语义不同）
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - 便捷访问

extension JSONValue {
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && d.magnitude < Double(Int.max): return Int(d)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// 按路径取值，例如 `value(at: ["choices", "0", "message"])`。
    /// 数字段用于数组下标；非法路径返回 nil（不抛错——查询语义，不是解析语义）。
    public func value(at path: [String]) -> JSONValue? {
        var current = self
        for key in path {
            switch current {
            case .object(let dict):
                guard let next = dict[key] else { return nil }
                current = next
            case .array(let arr):
                guard let idx = Int(key), arr.indices.contains(idx) else { return nil }
                current = arr[idx]
            default:
                return nil
            }
        }
        return current
    }
}

// MARK: - Codable（保留 Int/Double 区别）

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "不是合法的 JSON 值"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - 确定性文本表示

extension JSONValue {
    /// **确定性的**序列化：对象键按字典序排序，数字格式固定。
    ///
    /// 用途：请求指纹（`requestFingerprint`）、幂等键、缓存键。
    /// ⚠️ 绝不要用 `JSONSerialization` 做这件事——它的键序不稳定。
    public func canonicalString() -> String {
        switch self {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return String(i)
        case .double(let d):
            // 整数形式的 double 也写成整数字面量？不——保留小数点，避免与 .int 混淆
            if d.isNaN { return "null" }          // JSON 无 NaN
            if d.isInfinite { return d > 0 ? "1e999" : "-1e999" }
            if d == d.rounded(), d.magnitude < 1e15 {
                return String(format: "%.1f", d)
            }
            return String(d)
        case .string(let s):
            return Self.escape(s)
        case .array(let a):
            return "[" + a.map { $0.canonicalString() }.joined(separator: ",") + "]"
        case .object(let o):
            let keys = o.keys.sorted()
            let pairs = keys.map { key in
                Self.escape(key) + ":" + (o[key]?.canonicalString() ?? "null")
            }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }

    private static func escape(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - 从 Data / String 解析

extension JSONValue {
    /// 解析 JSON 文本。失败时抛出带位置的错误（模型生成的参数经常是坏 JSON，需要可诊断的错误）。
    public static func parse(_ text: String) throws -> JSONValue {
        let bytes = Array(text.utf8)
        var parser = JSONParser(bytes: bytes)
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.atEnd else {
            throw JSONParseError.trailingContent(atOffset: parser.offset)
        }
        return value
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        guard let text = String(data: data, encoding: .utf8) else {
            throw JSONParseError.invalidUTF8
        }
        return try parse(text)
    }
}

public enum JSONParseError: Error, Equatable, Sendable {
    case unexpectedEnd
    case unexpectedCharacter(Character, atOffset: Int)
    case invalidNumber(String, atOffset: Int)
    case invalidEscape(atOffset: Int)
    case invalidUTF8
    case trailingContent(atOffset: Int)
    case depthExceeded(limit: Int)
}

// MARK: - 手写解析器
//
// 为什么手写而不复用 Foundation 的 JSONSerialization：
//   1. 需要 Int/Double 区分（JSONSerialization 会把大整数变成 Double 丢精度）
//   2. 需要**带偏移量**的错误（模型生成的坏 JSON 需要能定位）
//   3. 需要深度限制（防止恶意/异常的深层嵌套导致栈溢出）
//   4. FoundationNetworking 在非 Apple 平台行为有差异，减少依赖面
private struct JSONParser {
    let bytes: [UInt8]
    var offset: Int = 0
    var depth: Int = 0
    static let maxDepth = 128

    var atEnd: Bool { offset >= bytes.count }

    mutating func skipWhitespace() {
        while offset < bytes.count {
            switch bytes[offset] {
            case 0x20, 0x09, 0x0A, 0x0D: offset += 1
            default: return
            }
        }
    }

    mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard offset < bytes.count else { throw JSONParseError.unexpectedEnd }
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else { throw JSONParseError.depthExceeded(limit: Self.maxDepth) }

        switch bytes[offset] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"):
            try expect("true"); return .bool(true)
        case UInt8(ascii: "f"):
            try expect("false"); return .bool(false)
        case UInt8(ascii: "n"):
            try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    private mutating func expect(_ literal: String) throws {
        for ch in literal.utf8 {
            guard offset < bytes.count, bytes[offset] == ch else {
                let c = offset < bytes.count ? Character(UnicodeScalar(bytes[offset])) : " "
                throw JSONParseError.unexpectedCharacter(c, atOffset: offset)
            }
            offset += 1
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        offset += 1  // {
        var dict: [String: JSONValue] = [:]
        skipWhitespace()
        if offset < bytes.count, bytes[offset] == UInt8(ascii: "}") {
            offset += 1
            return .object(dict)
        }
        while true {
            skipWhitespace()
            let key = try parseString()
            skipWhitespace()
            guard offset < bytes.count, bytes[offset] == UInt8(ascii: ":") else {
                throw JSONParseError.unexpectedCharacter(":", atOffset: offset)
            }
            offset += 1
            dict[key] = try parseValue()
            skipWhitespace()
            guard offset < bytes.count else { throw JSONParseError.unexpectedEnd }
            if bytes[offset] == UInt8(ascii: ",") { offset += 1; continue }
            if bytes[offset] == UInt8(ascii: "}") { offset += 1; return .object(dict) }
            throw JSONParseError.unexpectedCharacter(Character(UnicodeScalar(bytes[offset])), atOffset: offset)
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        offset += 1  // [
        var arr: [JSONValue] = []
        skipWhitespace()
        if offset < bytes.count, bytes[offset] == UInt8(ascii: "]") {
            offset += 1
            return .array(arr)
        }
        while true {
            arr.append(try parseValue())
            skipWhitespace()
            guard offset < bytes.count else { throw JSONParseError.unexpectedEnd }
            if bytes[offset] == UInt8(ascii: ",") { offset += 1; continue }
            if bytes[offset] == UInt8(ascii: "]") { offset += 1; return .array(arr) }
            throw JSONParseError.unexpectedCharacter(Character(UnicodeScalar(bytes[offset])), atOffset: offset)
        }
    }

    private mutating func parseString() throws -> String {
        guard offset < bytes.count, bytes[offset] == UInt8(ascii: "\"") else {
            throw JSONParseError.unexpectedCharacter("\"", atOffset: offset)
        }
        offset += 1
        var out: [UInt8] = []
        while offset < bytes.count {
            let b = bytes[offset]
            if b == UInt8(ascii: "\"") {
                offset += 1
                guard let s = String(bytes: out, encoding: .utf8) else { throw JSONParseError.invalidUTF8 }
                return s
            }
            if b == UInt8(ascii: "\\") {
                offset += 1
                guard offset < bytes.count else { throw JSONParseError.unexpectedEnd }
                switch bytes[offset] {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\"")); offset += 1
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\")); offset += 1
                case UInt8(ascii: "/"):  out.append(UInt8(ascii: "/")); offset += 1
                case UInt8(ascii: "b"):  out.append(0x08); offset += 1
                case UInt8(ascii: "f"):  out.append(0x0C); offset += 1
                case UInt8(ascii: "n"):  out.append(0x0A); offset += 1
                case UInt8(ascii: "r"):  out.append(0x0D); offset += 1
                case UInt8(ascii: "t"):  out.append(0x09); offset += 1
                case UInt8(ascii: "u"):
                    offset += 1
                    let scalar = try parseUnicodeEscape()
                    out.append(contentsOf: Array(String(scalar).utf8))
                default:
                    throw JSONParseError.invalidEscape(atOffset: offset)
                }
                continue
            }
            out.append(b)
            offset += 1
        }
        throw JSONParseError.unexpectedEnd
    }

    private mutating func parseUnicodeEscape() throws -> UnicodeScalar {
        func hex4() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw JSONParseError.unexpectedEnd }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let b = bytes[offset]
                let d: UInt32
                switch b {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(b - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(b - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(b - UInt8(ascii: "A") + 10)
                default: throw JSONParseError.invalidEscape(atOffset: offset)
                }
                v = v << 4 | d
                offset += 1
            }
            return v
        }
        let first = try hex4()
        // 代理对
        if first >= 0xD800, first <= 0xDBFF,
           offset + 1 < bytes.count,
           bytes[offset] == UInt8(ascii: "\\"), bytes[offset + 1] == UInt8(ascii: "u") {
            offset += 2
            let second = try hex4()
            let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            guard let s = UnicodeScalar(combined) else { throw JSONParseError.invalidEscape(atOffset: offset) }
            return s
        }
        guard let s = UnicodeScalar(first) else { throw JSONParseError.invalidEscape(atOffset: offset) }
        return s
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = offset
        var isDouble = false
        if offset < bytes.count, bytes[offset] == UInt8(ascii: "-") { offset += 1 }
        while offset < bytes.count {
            let b = bytes[offset]
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): offset += 1
            case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
                isDouble = true; offset += 1
            case UInt8(ascii: "+"), UInt8(ascii: "-"):
                // 只允许出现在指数部分
                guard offset > start,
                      bytes[offset - 1] == UInt8(ascii: "e") || bytes[offset - 1] == UInt8(ascii: "E") else {
                    let text = String(decoding: bytes[start..<offset], as: UTF8.self)
                    throw JSONParseError.invalidNumber(text, atOffset: start)
                }
                offset += 1
            default:
                let text = String(decoding: bytes[start..<offset], as: UTF8.self)
                guard !text.isEmpty else {
                    throw JSONParseError.unexpectedCharacter(Character(UnicodeScalar(b)), atOffset: offset)
                }
                return try Self.makeNumber(text, isDouble: isDouble, at: start)
            }
        }
        let text = String(decoding: bytes[start..<offset], as: UTF8.self)
        guard !text.isEmpty, text != "-" else { throw JSONParseError.unexpectedEnd }
        return try Self.makeNumber(text, isDouble: isDouble, at: start)
    }

    private static func makeNumber(_ text: String, isDouble: Bool, at offset: Int) throws -> JSONValue {
        if !isDouble, let i = Int(text) { return .int(i) }
        guard let d = Double(text) else { throw JSONParseError.invalidNumber(text, atOffset: offset) }
        // 超出 Int 范围但没写小数点的，保留为 double（例如 1e30 或 99999999999999999999）
        return .double(d)
    }
}

// MARK: - 字面量构造（让测试与内置配置写得干净）

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}
extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}
extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
