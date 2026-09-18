import Foundation

// MARK: - packfile 与 delta 解析
//
// ⚠️ 为什么这一片**不能跳**：
//    `git clone` 下来的仓库，对象**几乎全在** `.git/objects/pack/*.pack` 里，
//    松散对象一个都没有。只支持松散对象的话，`git_log` 在真实仓库上会直接报
//    「对象不存在」—— 而用户明明刚 clone 下来。所以它必须排在写路径之前。
//
// 格式依据（照抄规范）：
//   * `.idx` v2：`\xfftOc` + 版本 2 + fanout[256] + 有序 20 字节 SHA + CRC32[] + 4 字节偏移[]
//                + （可选）8 字节大偏移[] + 两段 SHA-1 校验
//   * `.pack`：`PACK` + 版本(4) + 对象数(4)，随后是首尾相接的 zlib 流
//   * 对象头：1 字节 = `MSB | type(3) | size 低 4 位`，后续字节 `MSB | 7 位`
//   * delta：`ofs-delta` 头里跟**负偏移**（MBZ 变长），`ref-delta` 头里跟 **20 字节基对象 SHA**
//   * delta 数据：源大小(变长) + 目标大小(变长) + 指令流
//        - 指令高位为 1 → **拷贝**：低 7 位是"哪些偏移/长度字节存在"的掩码
//        - 指令非 0 且高位为 0 → **插入**：指令本身就是长度
//        - 指令为 0 → **保留**（无效，必须拒）
//
// ⚠️ 消费方约束：**绝不把整个 pack 解进内存**。手机上 pack 可以是几百 MB，
//    而 iOS 的 jetsam 会直接杀掉整个 App（T38）。所以按需解单个对象 + 带缓存。

/// pack 相关错误。
public enum PackError: Error, Equatable, CustomStringConvertible {
    case badIndexHeader
    case unsupportedIndexVersion(UInt32)
    case badPackHeader
    case unsupportedPackVersion(UInt32)
    case indexChecksumMismatch
    case packChecksumMismatch
    case objectCountMismatch(index: Int, pack: Int)
    case offsetOutOfRange(UInt64)
    case unknownPackObjectType(Int)
    /// delta 链断了（基对象不在这个 pack 里，也没在松散对象里）
    case missingDeltaBase(SHA1)
    case malformedDelta(reason: String)
    case deltaTooDeep(Int)

    public var description: String {
        switch self {
        case .badIndexHeader:              return "pack 索引文件头不合法。"
        case .unsupportedIndexVersion(let v): return "不支持的 pack 索引版本 \(v)（只支持 v2）。"
        case .badPackHeader:               return "pack 文件头不合法。"
        case .unsupportedPackVersion(let v):  return "不支持的 pack 版本 \(v)（只支持 2 或 3）。"
        case .indexChecksumMismatch:       return "pack 索引文件校验和不符 —— 文件被改动过。"
        case .packChecksumMismatch:        return "pack 文件校验和不符 —— 文件被改动过。"
        case .objectCountMismatch(let i, let p):
            return "索引说有 \(i) 个对象，pack 头说有 \(p) 个 —— 两者不配套。"
        case .offsetOutOfRange(let o):     return "对象偏移 \(o) 超出了 pack 文件范围。"
        case .unknownPackObjectType(let t): return "pack 里出现了未知的对象类型 \(t)。"
        case .missingDeltaBase(let id):    return "delta 的基对象 \(id.hex) 找不到（浅克隆或 pack 不完整）。"
        case .malformedDelta(let reason):  return "delta 数据不合法：\(reason)"
        case .deltaTooDeep(let depth):     return "delta 链过深（\(depth) 层），疑似损坏。"
        }
    }
}

/// 一个 pack（`.pack` + `.idx`）。
public struct GitPack: Sendable {
    public let packURL: URL
    public let indexURL: URL

    /// 索引里的对象 ID → pack 内偏移
    private let offsets: [SHA1: UInt64]
    /// pack 头声明的对象数
    public let objectCount: Int

    /// ⚠️ delta 链深度上限。一个手写/损坏的 pack 可以造出**循环**的 delta 链
    ///    （A 依赖 B、B 依赖 A）—— 不设上限就是无限递归，直接把栈打爆。
    public static let maxDeltaDepth = 64

    public init(packURL: URL, indexURL: URL) throws {
        self.packURL = packURL
        self.indexURL = indexURL
        let index = try Self.parseIndex([UInt8](try Data(contentsOf: indexURL)))
        offsets = index.offsets
        let packHeader = try Self.readPackHeader(packURL)
        objectCount = packHeader.count
        guard index.count == packHeader.count else {
            throw PackError.objectCountMismatch(index: index.count, pack: packHeader.count)
        }
    }

    public var objectIDs: [SHA1] { Array(offsets.keys) }
    public func contains(_ id: SHA1) -> Bool { offsets[id] != nil }

    // MARK: .idx 解析

    struct Index {
        let offsets: [SHA1: UInt64]
        var count: Int { offsets.count }
    }

    static func parseIndex(_ bytes: [UInt8]) throws -> Index {
        // 头：\xff t O c + 版本
        guard bytes.count >= 8, bytes[0] == 0xFF, bytes[1] == 0x74, bytes[2] == 0x4F, bytes[3] == 0x63 else {
            throw PackError.badIndexHeader
        }
        let version = Self.be32(bytes, 4)
        guard version == 2 else { throw PackError.unsupportedIndexVersion(version) }

        // fanout[256]：累计计数，最后一项就是对象总数
        var fanout = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 { fanout[i] = Self.be32(bytes, 8 + i * 4) }
        let count = Int(fanout[255])

        let namesStart = 8 + 256 * 4
        let crcStart = namesStart + count * 20
        let offsetStart = crcStart + count * 4
        let largeStart = offsetStart + count * 4
        guard largeStart <= bytes.count else { throw PackError.badIndexHeader }

        var offsets: [SHA1: UInt64] = [:]
        offsets.reserveCapacity(count)
        for i in 0..<count {
            let base = namesStart + i * 20
            let id = SHA1(bytes: Array(bytes[base..<(base + 20)]))
            let raw = Self.be32(bytes, offsetStart + i * 4)
            if raw & 0x8000_0000 == 0 {
                offsets[id] = UInt64(raw)
            } else {
                // ⚠️ 高位为 1 表示"偏移太大，去大偏移表里按低 31 位取下标"。
                //    >2GB 的 pack 才会走到这里 —— 手机上几乎不会，但**不处理就是静默错**：
                //    会把下标当成偏移，于是从 pack 中间开始解。
                let largeIndex = Int(raw & 0x7FFF_FFFF) * 8
                guard largeStart + largeIndex + 8 <= bytes.count else { throw PackError.badIndexHeader }
                offsets[id] = Self.be64(bytes, largeStart + largeIndex)
            }
        }
        return Index(offsets: offsets)
    }

    static func readPackHeader(_ url: URL) throws -> (version: UInt32, count: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = [UInt8](try handle.read(upToCount: 12) ?? Data())
        guard head.count == 12, head[0] == 0x50, head[1] == 0x41, head[2] == 0x43, head[3] == 0x4B else {
            throw PackError.badPackHeader
        }
        let version = Self.be32(head, 4)
        guard version == 2 || version == 3 else { throw PackError.unsupportedPackVersion(version) }
        return (version, Int(Self.be32(head, 8)))
    }

    /// 读一个 pack 内对象（含 delta 还原）。
    ///
    /// - Parameter looseFallback: delta 的基对象可能不在 pack 里（少见但合法），
    ///   此时用它去松散对象里找。传 nil 表示不做兜底。
    public func object(_ id: SHA1, looseFallback: ((SHA1) throws -> GitObject)? = nil) throws -> GitObject {
        guard let offset = offsets[id] else { throw GitError.objectNotFound(id) }
        let cache = DeltaCache()
        let (type, body) = try readAt(offset: offset, cache: cache,
                                      packBytes: Self.loadPack(packURL),
                                      looseFallback: looseFallback, depth: 0)
        return GitObject(type: type, body: body, id: id)
    }

    /// delta 还原过程中的记忆化缓存。
    ///
    /// ⚠️ 没有它，一条 50 层的 delta 链会被解成 O(2ⁿ) 次 —— 手机上表现为卡死。
    ///    有了它每次最多解一遍。
    final class DeltaCache: @unchecked Sendable {
        private var storage: [UInt64: (GitObjectType, [UInt8])] = [:]
        func get(_ offset: UInt64) -> (GitObjectType, [UInt8])? { storage[offset] }
        func set(_ offset: UInt64, _ value: (GitObjectType, [UInt8])) { storage[offset] = value }
    }

    static func loadPack(_ url: URL) -> [UInt8] { (try? [UInt8](Data(contentsOf: url))) ?? [] }

    private func readAt(offset: UInt64, cache: DeltaCache, packBytes: [UInt8],
                        looseFallback: ((SHA1) throws -> GitObject)?,
                        depth: Int) throws -> (GitObjectType, [UInt8]) {
        guard depth <= Self.maxDeltaDepth else { throw PackError.deltaTooDeep(depth) }
        if let hit = cache.get(offset) { return hit }
        guard offset < UInt64(packBytes.count) else { throw PackError.offsetOutOfRange(offset) }

        var cursor = Int(offset)
        let first = packBytes[cursor]; cursor += 1
        let rawType = Int((first >> 4) & 0x07)
        var size = Int(first & 0x0F)
        var shift = 4
        var byte = first
        // 变长 size：每后续字节带 7 位，最高位表示还有
        while byte & 0x80 != 0 {
            guard cursor < packBytes.count else { throw PackError.malformedDelta(reason: "对象头被截断") }
            byte = packBytes[cursor]; cursor += 1
            size |= Int(byte & 0x7F) << shift
            shift += 7
        }

        // ⚠️ delta 的"源"取决于类型：ofs-delta 是**负偏移**（变长，MBZ 编码），
        //    ref-delta 是**基对象的 20 字节 SHA**。两者的解压起点都在它们之后。
        var baseOffset: UInt64?
        var baseID: SHA1?
        switch rawType {
        case 6:
            var byte = packBytes[cursor]; cursor += 1
            var distance = UInt64(byte & 0x7F)
            while byte & 0x80 != 0 {
                byte = packBytes[cursor]; cursor += 1
                // ⚠️ 每一步要 **+1**（git 的 "offset encoding" 约定），
                //    少加这个 1 会算出一个"看起来合理"的偏移 —— 然后解出垃圾。
                distance = ((distance + 1) << 7) | UInt64(byte & 0x7F)
            }
            guard distance <= offset else { throw PackError.malformedDelta(reason: "ofs-delta 的负偏移越过了 pack 开头") }
            baseOffset = offset - distance
        case 7:
            guard cursor + 20 <= packBytes.count else { throw PackError.malformedDelta(reason: "ref-delta 的基对象 SHA 被截断") }
            baseID = SHA1(bytes: Array(packBytes[cursor..<(cursor + 20)]))
            cursor += 20
        default:
            break
        }

        // 正文：一个 zlib 流。⚠️ 传整段尾部、用 consumed 判断边界（见 Inflate.zlibStream）
        let (payload, _) = try Inflate.zlibStream(packBytes, from: cursor)
        guard payload.count == size else {
            throw PackError.malformedDelta(reason: "对象头声明 \(size) 字节，实际解出 \(payload.count) 字节")
        }

        let result: (GitObjectType, [UInt8])
        switch rawType {
        case 1: result = (.commit, payload)
        case 2: result = (.tree, payload)
        case 3: result = (.blob, payload)
        case 4: result = (.tag, payload)
        case 6, 7:
            let base: (GitObjectType, [UInt8])
            if let baseOffset {
                base = try readAt(offset: baseOffset, cache: cache, packBytes: packBytes,
                                  looseFallback: looseFallback, depth: depth + 1)
            } else if let baseID, let baseOffsetInPack = offsets[baseID] {
                base = try readAt(offset: baseOffsetInPack, cache: cache, packBytes: packBytes,
                                  looseFallback: looseFallback, depth: depth + 1)
            } else if let baseID, let looseFallback {
                let object = try looseFallback(baseID)
                base = (object.type, object.body)
            } else {
                throw PackError.missingDeltaBase(baseID ?? SHA1(bytes: [UInt8](repeating: 0, count: 20)))
            }
            // ⚠️ delta 还原出来的类型**继承基对象**：delta 只描述"怎么改字节"，
            //    不描述"这是什么"。写死成 blob 会让 delta 化的 tree 变成 blob。
            result = (base.0, try Delta.apply(base: base.1, delta: payload))
        default:
            throw PackError.unknownPackObjectType(rawType)
        }
        cache.set(offset, result)
        return result
    }

    // MARK: 大端读取（避免依赖 Foundation 的指针 API，跨平台一致）

    static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    static func be64(_ b: [UInt8], _ i: Int) -> UInt64 {
        var value: UInt64 = 0
        for k in 0..<8 { value = (value << 8) | UInt64(b[i + k]) }
        return value
    }
}

// MARK: - delta 指令流

public enum Delta {

    /// 把 delta 指令流作用到基对象上。
    ///
    /// 格式：`源大小(变长) | 目标大小(变长) | 指令流`
    ///   * 指令高位为 1 → **拷贝**：低 7 位是掩码，指示 offset(4 字节) 与 size(3 字节) 各段是否存在
    ///   * 指令非 0 且高位为 0 → **插入**：指令值就是随后要原样插入的字节数
    ///   * 指令为 0 → **保留**，必须拒绝（它会让解析器原地打转）
    public static func apply(base: [UInt8], delta: [UInt8]) throws -> [UInt8] {
        var cursor = 0
        let sourceSize = try readVarint(delta, &cursor)
        let targetSize = try readVarint(delta, &cursor)
        // ⚠️ 源大小必须与基对象**实际长度**一致。不一致说明 delta 用错了基对象
        //    （比如同 ID 前缀碰撞、或 pack 损坏）—— 这时任何"尽力而为"的还原
        //    都会产出一段看似可用、实则错误的字节。
        guard sourceSize == base.count else {
            throw PackError.malformedDelta(reason: "delta 声明的源大小 \(sourceSize) 与基对象实际 \(base.count) 不符")
        }

        var out: [UInt8] = []
        out.reserveCapacity(targetSize)
        while cursor < delta.count {
            let instruction = delta[cursor]; cursor += 1
            if instruction == 0 {
                throw PackError.malformedDelta(reason: "指令 0 是保留值")
            } else if instruction & 0x80 != 0 {
                // 拷贝：低 7 位是掩码
                var copyOffset = 0, copySize = 0
                if instruction & 0x01 != 0 { copyOffset |= Int(delta[cursor]); cursor += 1 }
                if instruction & 0x02 != 0 { copyOffset |= Int(delta[cursor]) << 8; cursor += 1 }
                if instruction & 0x04 != 0 { copyOffset |= Int(delta[cursor]) << 16; cursor += 1 }
                if instruction & 0x08 != 0 { copyOffset |= Int(delta[cursor]) << 24; cursor += 1 }
                if instruction & 0x10 != 0 { copySize |= Int(delta[cursor]); cursor += 1 }
                if instruction & 0x20 != 0 { copySize |= Int(delta[cursor]) << 8; cursor += 1 }
                if instruction & 0x40 != 0 { copySize |= Int(delta[cursor]) << 16; cursor += 1 }
                if copySize == 0 { copySize = 0x10000 }   // ⚠️ 规范：size 全 0 表示 65536
                guard copyOffset + copySize <= base.count else {
                    throw PackError.malformedDelta(reason: "拷贝区间 \(copyOffset)+\(copySize) 超出基对象 \(base.count) 字节")
                }
                out.append(contentsOf: base[copyOffset..<(copyOffset + copySize)])
            } else {
                // 插入：指令值本身就是长度
                let count = Int(instruction)
                guard cursor + count <= delta.count else {
                    throw PackError.malformedDelta(reason: "插入指令要 \(count) 字节，但只剩 \(delta.count - cursor) 字节")
                }
                out.append(contentsOf: delta[cursor..<(cursor + count)])
                cursor += count
            }
        }
        guard out.count == targetSize else {
            throw PackError.malformedDelta(reason: "还原出 \(out.count) 字节，delta 声明 \(targetSize) 字节")
        }
        return out
    }

    /// 变长整数（小端 7 位分组，最高位表示继续）。
    static func readVarint(_ bytes: [UInt8], _ cursor: inout Int) throws -> Int {
        var value = 0
        var shift = 0
        while true {
            guard cursor < bytes.count else { throw PackError.malformedDelta(reason: "变长整数被截断") }
            let byte = bytes[cursor]; cursor += 1
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            guard shift <= 35 else { throw PackError.malformedDelta(reason: "变长整数过长") }
        }
        return value
    }
}
