import Foundation

// MARK: - SHA-1（Git 的对象寻址）
//
// ⚠️ 为什么这里要 SHA-1，而项目别处用的是 SHA-256：
//    事件日志的哈希链用 SHA-256（自研，防篡改）；但 **Git 的对象 ID 是 SHA-1**，
//    这是 git 仓库格式的一部分，不是我们的选择 —— 要让模型看到与 `git log`
//    完全一致的提交号（`745d8dd…`），就必须算出 SHA-1，不能换成别的。
//
// ⚠️ 与 SHA256.swift 同样的立场：**用于完整性校验与寻址，不用于加密**。
//    SHA-1 的碰撞攻击已实用化（SHAttered），所以这里绝不能用它做任何安全断言 ——
//    它只是"git 用什么我就用什么"。凡是要防篡改的地方仍然走 SHA-256。

/// SHA-1 摘要（20 字节）。
public struct SHA1: Sendable, Hashable, CustomStringConvertible {
    public let bytes: [UInt8]

    /// 40 位小写十六进制 —— 与 `git log --format=%H` 的输出格式一致。
    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    public var description: String { hex }

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 20, "SHA-1 摘要必须是 20 字节")
        self.bytes = bytes
    }

    /// 从十六进制字符串解析（大小写都可）。长度不对或含非十六进制字符时返回 nil。
    public init?(hex: String) {
        guard hex.count == 40 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(20)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self.init(bytes: out)
    }

    /// 计算一段数据的 SHA-1。
    public static func hash(_ data: [UInt8]) -> SHA1 {
        var hasher = Streaming()
        hasher.update(data)
        return hasher.finalize()
    }

    public static func hash(_ text: String) -> SHA1 { hash(Array(text.utf8)) }

    /// 流式实现（与 SHA256.Streaming 同一个形状，便于调用方一致地使用）。
    public struct Streaming {
        private var h0: UInt32 = 0x6745_2301
        private var h1: UInt32 = 0xEFCD_AB89
        private var h2: UInt32 = 0x98BA_DCFE
        private var h3: UInt32 = 0x1032_5476
        private var h4: UInt32 = 0xC3D2_E1F0
        private var buffer: [UInt8] = []
        private var totalBytes: UInt64 = 0

        public init() {}

        public mutating func update(_ data: [UInt8]) {
            totalBytes &+= UInt64(data.count)
            buffer.append(contentsOf: data)
            // 只在攒够一个整块时压缩，避免每个字节都进一轮
            while buffer.count >= 64 {
                compress(Array(buffer[0..<64]))
                buffer.removeFirst(64)
            }
        }

        public mutating func update(_ text: String) { update(Array(text.utf8)) }

        public mutating func finalize() -> SHA1 {
            let bitLength = totalBytes &* 8
            var tail = buffer
            tail.append(0x80)
            // 补到 56 mod 64，再补 8 字节大端长度
            while tail.count % 64 != 56 { tail.append(0) }
            for shift in stride(from: 56, through: 0, by: -8) {
                tail.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
            }
            var index = 0
            while index < tail.count {
                compress(Array(tail[index..<(index + 64)]))
                index += 64
            }

            var out: [UInt8] = []
            for word in [h0, h1, h2, h3, h4] {
                out.append(UInt8((word >> 24) & 0xFF))
                out.append(UInt8((word >> 16) & 0xFF))
                out.append(UInt8((word >> 8) & 0xFF))
                out.append(UInt8(word & 0xFF))
            }
            return SHA1(bytes: out)
        }

        private mutating func compress(_ block: [UInt8]) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let base = i * 4
                w[i] = UInt32(block[base]) << 24 | UInt32(block[base + 1]) << 16
                    | UInt32(block[base + 2]) << 8 | UInt32(block[base + 3])
            }
            for i in 16..<80 {
                let value = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (value << 1) | (value >> 31)   // 循环左移 1
            }

            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20:  f = (b & c) | (~b & d);          k = 0x5A82_7999
                case 20..<40: f = b ^ c ^ d;                   k = 0x6ED9_EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
                default:      f = b ^ c ^ d;                   k = 0xCA62_C1D6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = temp
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
        }
    }
}
