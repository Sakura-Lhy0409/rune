import Foundation

/// 纯 Swift SHA-256。
///
/// 为什么自己写而不依赖 CryptoKit / swift-crypto：
///   * `CryptoKit` 是 Apple 专属 → 会让 `RuneKernel` 无法在 Windows/Linux 上测试
///   * `swift-crypto` 是外部依赖 → 违背"Kernel 零依赖"的架构决策（docs/03 §3）
///   * 我们只需要 SHA-256（哈希链、请求指纹、文件完整性），不需要通用密码学库
///
/// ⚠️ 本实现仅用于**完整性校验与指纹**，不用于加密。密钥加密走 Keychain / Secure Enclave。
public enum SHA256 {
    // MARK: 常量

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static let initialState: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    // MARK: 增量哈希（大文件分块，避免整读进内存）

    public struct Streaming {
        private var state: [UInt32] = SHA256.initialState
        private var buffer = [UInt8]()
        private var totalBytes: UInt64 = 0

        public init() {
            buffer.reserveCapacity(64 * 4)
        }

        public mutating func update(_ bytes: some Sequence<UInt8>) {
            for b in bytes {
                buffer.append(b)
                totalBytes &+= 1
                if buffer.count == 64 {
                    SHA256.compress(&state, block: buffer, offset: 0)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }

        public mutating func update(_ data: Data) {
            // 注意：不能用 `data as [UInt8]`（Foundation 的桥接在跨平台下不可靠），
            // 用 withUnsafeBytes 逐块喂入，同时也避免为超大文件复制整块内存。
            data.withUnsafeBytes { raw in
                update(raw)
            }
        }

        public mutating func finalize() -> Data {
            var padded = buffer
            let bitLength = totalBytes &* 8
            padded.append(0x80)
            while padded.count % 64 != 56 { padded.append(0) }
            for shift in stride(from: 56, through: 0, by: -8) {
                padded.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
            }
            var index = 0
            while index < padded.count {
                SHA256.compress(&state, block: padded, offset: index)
                index += 64
            }
            var out = Data()
            out.reserveCapacity(32)
            for word in state {
                out.append(UInt8((word >> 24) & 0xFF))
                out.append(UInt8((word >> 16) & 0xFF))
                out.append(UInt8((word >> 8) & 0xFF))
                out.append(UInt8(word & 0xFF))
            }
            return out
        }
    }

    // MARK: 一次性接口

    public static func hash(_ data: Data) -> Data {
        var h = Streaming()
        h.update(data)
        return h.finalize()
    }

    public static func hash(_ bytes: [UInt8]) -> Data {
        var h = Streaming()
        h.update(bytes)
        return h.finalize()
    }

    public static func hash(_ string: String) -> Data {
        hash(Array(string.utf8))
    }

    /// 十六进制字符串形式（日志、UI 展示、文件名）
    public static func hexDigest(_ data: Data) -> String {
        hash(data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hexDigest(_ string: String) -> String {
        hexDigest(Data(string.utf8))
    }

    // MARK: 压缩函数

    private static func compress(_ state: inout [UInt32], block: [UInt8], offset: Int) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let j = offset + i * 4
            w[i] = (UInt32(block[j]) << 24)
                | (UInt32(block[j + 1]) << 16)
                | (UInt32(block[j + 2]) << 8)
                | UInt32(block[j + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]

        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj

            h = g; g = f; f = e
            e = d &+ temp1
            d = c; c = b; b = a
            a = temp1 &+ temp2
        }

        state[0] = state[0] &+ a
        state[1] = state[1] &+ b
        state[2] = state[2] &+ c
        state[3] = state[3] &+ d
        state[4] = state[4] &+ e
        state[5] = state[5] &+ f
        state[6] = state[6] &+ g
        state[7] = state[7] &+ h
    }

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}

// MARK: - 指纹（请求去重与幂等）

public enum Fingerprint {
    /// 模型请求指纹：同一 Turn 内出现相同指纹且已有完整响应时**直接复用**，不再发请求。
    /// 这是 Rune 在没有厂商幂等键的情况下避免重复计费的第一个手段（docs/06 §8.3）。
    public static func request(
        providerID: String,
        modelID: String,
        serializedBody: Data
    ) -> Data {
        var h = SHA256.Streaming()
        h.update(Array("v1|\(providerID)|\(modelID)|".utf8))
        h.update(serializedBody)
        return h.finalize()
    }

    /// 沙箱执行指纹：`execFingerprint(cmd + inputs)` —— 输入不变则输出不变，可复用上次结果。
    public static func execution(
        runtime: SandboxRuntime,
        invocation: String,
        inputHashes: [Data]
    ) -> Data {
        var h = SHA256.Streaming()
        h.update(Array("\(runtime.rawValue)|\(invocation)".utf8))
        for input in inputHashes.sorted(by: { $0.base64EncodedString() < $1.base64EncodedString() }) {
            h.update(input)
        }
        return h.finalize()
    }

    /// 事件日志哈希链：`hash = SHA256(prev_hash ‖ id ‖ kind ‖ payload ‖ created_at)`
    ///
    /// 用途：检测审计日志被篡改（docs/09 威胁 T11）。每 1000 条存一次锚点，
    /// 校验时只验锚点 + 尾部，避免全量重算。
    public static func event(
        previousHash: Data?,
        id: UUID,
        kind: String,
        payload: Data,
        createdAt: Date
    ) -> Data {
        var h = SHA256.Streaming()
        if let previousHash { h.update(previousHash) }
        h.update(Array(id.uuidString.utf8))
        h.update(Array(kind.utf8))
        h.update(SHA256.hash(payload))
        h.update(Array(String(Int(createdAt.timeIntervalSince1970 * 1000)).utf8))
        return h.finalize()
    }
}
