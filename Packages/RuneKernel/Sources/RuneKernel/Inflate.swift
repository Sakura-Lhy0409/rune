import Foundation

// MARK: - 纯 Swift 的 zlib（RFC 1950）+ DEFLATE（RFC 1951）解压
//
// 为什么自己写而不用系统 zlib：
//   ① iOS 上没有可直接 `import` 的 zlib 模块（Foundation 只暴露 gzip 的
//      `NSData.decompressed(using: .zlib)`，而 git 松散对象用的是**裸 zlib 流**，
//      带 2 字节头 + 4 字节 Adler-32，不是 gzip 容器；且那个 API 只在较新系统可用、
//      对损坏输入的诊断能力为零）；
//   ② `RuneKernel` 的架构承诺是**零依赖、可在任意平台验证**（Linux 也能跑测试）。
//      引一个 C 模块就破坏了这条，而这条正是 CI 能在 ubuntu 上守住的东西。
//
// ⚠️ 只实现**解压**。写入端（git 需要 deflate）用「stored 块」也能生成合法 zlib 流，
//    但那会让仓库体积失控，所以写路径另做（见 GitObjects 的文件头说明）。

/// DEFLATE 解压失败的原因。
///
/// ⚠️ 这些错误**必须分类报出**，不能一律 "解压失败"：git 对象损坏时，
///    用户要能分清"文件被截断了"和"这不是一个 zlib 流"——两者的下一步完全不同。
public enum InflateError: Error, Equatable, CustomStringConvertible {
    /// 输入在流结束前就用完了（常见于对象文件被截断）
    case truncated
    /// zlib 头不合法（CMF/FLG 校验失败）
    case badZlibHeader
    /// 解出的内容与流尾的 Adler-32 不符（内容被改过）
    case checksumMismatch(expected: UInt32, actual: UInt32)
    /// 块类型 3 是保留值
    case invalidBlockType
    /// 动态 Huffman 表的码长代码本身不合法
    case invalidCodeLengths
    /// 一个块里出现了不完整的 Huffman 表（有码长全为 0 的符号被引用）
    case incompleteHuffmanTable
    /// 距离指向了已输出窗口之外
    case invalidDistance(Int)
    /// 码长/距离符号超出规范表范围
    case invalidSymbol(Int)
    /// 输出超过调用方给的上限（**防解压炸弹**：一个 1KB 的对象能解出几个 GB）
    case outputLimitExceeded(limit: Int)

    public var description: String {
        switch self {
        case .truncated:                  return "数据在结束前就被截断了。"
        case .badZlibHeader:              return "这不是一个合法的 zlib 流（头部校验失败）。"
        case .checksumMismatch(let e, let a):
            return "内容与流尾的校验和不符（期望 \(String(e, radix: 16))，实际 \(String(a, radix: 16))）—— 文件被改动过。"
        case .invalidBlockType:           return "出现了保留的块类型（数据已损坏）。"
        case .invalidCodeLengths:         return "动态 Huffman 表的码长定义不合法。"
        case .incompleteHuffmanTable:     return "Huffman 表不完整（数据已损坏）。"
        case .invalidDistance(let d):     return "回溯距离 \(d) 超出了已解出的内容范围。"
        case .invalidSymbol(let s):       return "出现了规范之外的压缩符号（\(s)）。"
        case .outputLimitExceeded(let l): return "解压结果超过 \(l) 字节上限，已停止（防止解压炸弹）。"
        }
    }
}

public enum Inflate {

    /// 默认输出上限 64MB。
    ///
    /// ⚠️ 必须有上限：DEFLATE 的压缩比可以到 1000:1，一个 64KB 的 git 对象文件
    ///    能解出 64MB；没有上限时，一个恶意/损坏的仓库就能把 App 的内存吃光，
    ///    而 iOS 的 jetsam 会**直接杀掉整个 App**（连同用户没保存的东西）——见 T38。
    public static let defaultOutputLimit = 64 * 1024 * 1024

    /// 解压一个 **zlib** 流（2 字节头 + DEFLATE + 4 字节 Adler-32）。
    public static func zlib(_ input: [UInt8], outputLimit: Int = defaultOutputLimit) throws -> [UInt8] {
        guard input.count >= 6 else { throw InflateError.truncated }
        // CMF/FLG：低 4 位必须是 8（deflate），且 (CMF<<8|FLG) 必须是 31 的倍数
        let cmf = UInt32(input[0]), flg = UInt32(input[1])
        guard cmf & 0x0F == 8, (cmf << 8 | flg) % 31 == 0 else { throw InflateError.badZlibHeader }
        guard flg & 0x20 == 0 else { throw InflateError.badZlibHeader }   // 预置字典：git 不用，直接拒

        // 尾部 4 字节是 Adler-32（大端）；中间是 DEFLATE 数据
        let body = Array(input[2..<(input.count - 4)])
        let out = try rawDeflate(body, outputLimit: outputLimit)

        let expected = UInt32(input[input.count - 4]) << 24 | UInt32(input[input.count - 3]) << 16
            | UInt32(input[input.count - 2]) << 8 | UInt32(input[input.count - 1])
        let actual = adler32(out)
        guard expected == actual else { throw InflateError.checksumMismatch(expected: expected, actual: actual) }
        return out
    }

    /// 解压裸 DEFLATE 数据（无 zlib 头与校验和）。
    public static func rawDeflate(_ input: [UInt8], outputLimit: Int = defaultOutputLimit) throws -> [UInt8] {
        var reader = BitReader(input)
        var out: [UInt8] = []
        out.reserveCapacity(min(input.count * 4, outputLimit))

        while true {
            let isFinal = try reader.bits(1) == 1
            let type = try reader.bits(2)
            switch type {
            case 0: try copyStored(&reader, into: &out, limit: outputLimit)
            case 1: try inflateBlock(fixedLiteralTable, fixedDistanceTable, &reader, &out, outputLimit)
            case 2:
                let (literal, distance) = try readDynamicTables(&reader)
                try inflateBlock(literal, distance, &reader, &out, outputLimit)
            default: throw InflateError.invalidBlockType
            }
            if isFinal { break }
        }
        return out
    }

    // MARK: 不带压缩的块（type 0）

    private static func copyStored(_ reader: inout BitReader, into out: inout [UInt8], limit: Int) throws {
        reader.alignToByte()
        let len = Int(try reader.bits(16))
        let nlen = Int(try reader.bits(16))
        // ⚠️ LEN 与 NLEN 必须互为反码；不检查的话，损坏的长度会让下面读到垃圾并越界
        guard len ^ nlen == 0xFFFF else { throw InflateError.truncated }
        guard out.count + len <= limit else { throw InflateError.outputLimitExceeded(limit: limit) }
        out.append(contentsOf: try reader.bytes(len))
    }

    // MARK: Huffman 表

    /// 规范 Huffman 解码表：按码长分桶，桶内按符号值升序。
    private struct HuffmanTable {
        /// counts[1...15] = 该码长的符号个数
        var counts: [Int]
        /// 按（码长, 符号）顺序展开的符号列表
        var symbols: [Int]

        /// 用「码长数组」建表（RFC 1951 §3.2.2 的经典算法）。
        static func build(codeLengths: [Int]) throws -> HuffmanTable {
            var counts = [Int](repeating: 0, count: 16)
            for length in codeLengths {
                guard length >= 0, length <= 15 else { throw InflateError.invalidCodeLengths }
                if length > 0 { counts[length] += 1 }
            }
            // 检查前缀码的完整性：left 是还能挂多少个叶子
            var left = 1
            for length in 1...15 {
                left <<= 1
                left -= counts[length]
                if left < 0 { throw InflateError.invalidCodeLengths }
            }
            // ⚠️ left > 0 表示"码不完整"（有码位没被占用）。规范允许**只有一个符号**的
            //    退化情况（此时 left>0 但合法），其余不完整表一律拒绝 —— 否则解码时
            //    会走到一个没有符号的码位，只能靠猜。
            let used = codeLengths.filter { $0 > 0 }.count
            if left > 0 && used > 1 { throw InflateError.incompleteHuffmanTable }

            var offsets = [Int](repeating: 0, count: 16)
            for length in 1...14 { offsets[length + 1] = offsets[length] + counts[length] }
            var symbols = [Int](repeating: 0, count: codeLengths.filter { $0 > 0 }.count)
            for (symbol, length) in codeLengths.enumerated() where length > 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
            return HuffmanTable(counts: counts, symbols: symbols)
        }

        /// 逐位读码：先累加，再在对应码长的桶里按偏移取符号。
        func decode(_ reader: inout BitReader) throws -> Int {
            var code = 0, first = 0, index = 0
            for length in 1...15 {
                code |= try reader.bits(1)
                let count = counts[length]
                if code - first < count { return symbols[index + code - first] }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            throw InflateError.invalidSymbol(code)
        }
    }

    // MARK: 固定 Huffman 表（RFC 1951 §3.2.6）

    private static let fixedLiteralTable: HuffmanTable = {
        // 0-143:8位, 144-255:9位, 256-279:7位, 280-287:8位
        var lengths = [Int](repeating: 8, count: 288)
        for i in 144...255 { lengths[i] = 9 }
        for i in 256...279 { lengths[i] = 7 }
        return try! HuffmanTable.build(codeLengths: lengths)
    }()

    private static let fixedDistanceTable: HuffmanTable = {
        return try! HuffmanTable.build(codeLengths: [Int](repeating: 5, count: 32))
    }()

    // MARK: 动态 Huffman 表（RFC 1951 §3.2.7）

    /// 码长表本身用的传输顺序（注意不是 0..18 的自然序）
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static func readDynamicTables(_ reader: inout BitReader) throws -> (HuffmanTable, HuffmanTable) {
        let hlit = Int(try reader.bits(5)) + 257
        let hdist = Int(try reader.bits(5)) + 1
        let hclen = Int(try reader.bits(4)) + 4
        guard hlit <= 286, hdist <= 30 else { throw InflateError.invalidCodeLengths }

        var clLengths = [Int](repeating: 0, count: 19)
        for i in 0..<hclen { clLengths[codeLengthOrder[i]] = Int(try reader.bits(3)) }
        let clTable = try HuffmanTable.build(codeLengths: clLengths)

        // 展开 literal+distance 的码长（用 16/17/18 做游程编码）
        var lengths: [Int] = []
        lengths.reserveCapacity(hlit + hdist)
        while lengths.count < hlit + hdist {
            let symbol = try clTable.decode(&reader)
            switch symbol {
            case 0...15:
                lengths.append(symbol)
            case 16:
                // 复制上一个码长 3-6 次
                guard let last = lengths.last else { throw InflateError.invalidCodeLengths }
                let repeatCount = 3 + Int(try reader.bits(2))
                guard lengths.count + repeatCount <= hlit + hdist else { throw InflateError.invalidCodeLengths }
                lengths.append(contentsOf: [Int](repeating: last, count: repeatCount))
            case 17:
                let repeatCount = 3 + Int(try reader.bits(3))
                guard lengths.count + repeatCount <= hlit + hdist else { throw InflateError.invalidCodeLengths }
                lengths.append(contentsOf: [Int](repeating: 0, count: repeatCount))
            case 18:
                let repeatCount = 11 + Int(try reader.bits(7))
                guard lengths.count + repeatCount <= hlit + hdist else { throw InflateError.invalidCodeLengths }
                lengths.append(contentsOf: [Int](repeating: 0, count: repeatCount))
            default:
                throw InflateError.invalidSymbol(symbol)
            }
        }

        let literal = try HuffmanTable.build(codeLengths: Array(lengths[0..<hlit]))
        let distance = try HuffmanTable.build(codeLengths: Array(lengths[hlit...]))
        return (literal, distance)
    }

    // MARK: 压缩块解码

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                     35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                      3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                       257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                       8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    private static func inflateBlock(_ literal: HuffmanTable, _ distance: HuffmanTable,
                                     _ reader: inout BitReader, _ out: inout [UInt8], _ limit: Int) throws {
        while true {
            let symbol = try literal.decode(&reader)
            if symbol < 256 {
                guard out.count < limit else { throw InflateError.outputLimitExceeded(limit: limit) }
                out.append(UInt8(symbol))
                continue
            }
            if symbol == 256 { return }   // 块结束
            let lengthIndex = symbol - 257
            guard lengthIndex < lengthBase.count else { throw InflateError.invalidSymbol(symbol) }
            var length = lengthBase[lengthIndex]
            let lengthBits = lengthExtra[lengthIndex]
            if lengthBits > 0 { length += Int(try reader.bits(lengthBits)) }

            let distanceSymbol = try distance.decode(&reader)
            guard distanceSymbol < distanceBase.count else { throw InflateError.invalidSymbol(distanceSymbol) }
            var back = distanceBase[distanceSymbol]
            let distanceBits = distanceExtra[distanceSymbol]
            if distanceBits > 0 { back += Int(try reader.bits(distanceBits)) }
            // ⚠️ 距离必须落在已解出的内容内；不检查会下标为负 → 崩 App（T31 同类）
            guard back <= out.count else { throw InflateError.invalidDistance(back) }
            guard out.count + length <= limit else { throw InflateError.outputLimitExceeded(limit: limit) }

            // ⚠️ 逐字节复制，**不能用批量切片**：当 back < length 时源区间与目标区间重叠，
            //    语义是"边写边读"（LZ77 的游程），批量复制会得到错误结果。
            //    这是 inflate 最经典的一处陷阱，且只在特定数据上才暴露。
            var source = out.count - back
            for _ in 0..<length {
                out.append(out[source])
                source += 1
            }
        }
    }

    // MARK: Adler-32

    /// zlib 流尾的 Adler-32（RFC 1950 §9）。
    public static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        // ⚠️ 必须按 5552 字节分段取模：不取模时 b 会溢出 UInt32（大文件必现）
        let modulus: UInt32 = 65521
        var index = 0
        while index < data.count {
            let end = min(index + 5552, data.count)
            for i in index..<end {
                a += UInt32(data[i])
                b += a
            }
            a %= modulus
            b %= modulus
            index = end
        }
        return (b << 16) | a
    }
}

/// 按位读取（DEFLATE 的位序是**低位在前**）。
struct BitReader {
    private let input: [UInt8]
    private var position = 0      // 已消耗的位数

    init(_ input: [UInt8]) { self.input = input }

    /// 读 n 位（1...24），低位在前。
    mutating func bits(_ count: Int) throws -> Int {
        guard count >= 0, count <= 24 else { throw InflateError.invalidSymbol(count) }
        var result = 0
        for i in 0..<count {
            let byteIndex = position >> 3
            guard byteIndex < input.count else { throw InflateError.truncated }
            let bit = (input[byteIndex] >> UInt8(position & 7)) & 1
            result |= Int(bit) << i
            position += 1
        }
        return result
    }

    /// 跳到字节边界（不带压缩的块要求）。
    mutating func alignToByte() {
        if position & 7 != 0 { position = (position + 7) & ~7 }
    }

    /// 读 n 个整字节（仅在字节对齐后调用）。
    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard position & 7 == 0 else { throw InflateError.truncated }
        let start = position >> 3
        guard start + count <= input.count else { throw InflateError.truncated }
        position += count * 8
        return Array(input[start..<(start + count)])
    }
}
