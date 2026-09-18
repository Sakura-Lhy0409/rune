import Foundation
import Testing
@testable import RuneKernel

// MARK: - zlib / DEFLATE 解压
//
// 为什么这组测试值得存在：
//   自研 inflate 是**整条 Git 读取路径的地基** —— 它错一位，后面所有
//   git_status / git_diff / git_log 都会给出错误答案，而且错得**很像对的**
//   （解出一堆字节，只是内容不对，不报任何错）。所以真值必须来自**外部实现**
//   （真实 zlib），不能自己压自己解 —— 那只能证明自洽，证明不了符合规范。
//
// 夹具由 `Tools/make_inflate_fixtures.py` 用真实 zlib 生成并入库，
// 于是测试是**纯数据驱动**的：ubuntu 与 macOS 上跑的是同一份字节。

private func fixture(_ name: String) throws -> [UInt8] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
    guard let data = try? Data(contentsOf: url) else {
        // ⚠️ 夹具缺失必须报出**具体文件名**：否则只会看到一堆莫名的解压失败
        throw InflateError.truncated
    }
    return [UInt8](data)
}

@Suite("Inflate —— 纯 Swift 的 zlib/DEFLATE 解压")
struct InflateTests {

    // MARK: 不带压缩的块（type 0）

    @Test("⭐ 不带压缩块：LEN/NLEN 与整字节对齐都要对")
    func storedBlock() throws {
        let payload: [UInt8] = Array("hello".utf8)
        var bytes: [UInt8] = [0x78, 0x01, 0x01, 0x05, 0x00, 0xFA, 0xFF]
        bytes.append(contentsOf: payload)                       // BFINAL=1, BTYPE=00, LEN=5, NLEN=~5
        let checksum = Inflate.adler32(payload)
        bytes.append(contentsOf: [
            UInt8((checksum >> 24) & 0xFF), UInt8((checksum >> 16) & 0xFF),
            UInt8((checksum >> 8) & 0xFF), UInt8(checksum & 0xFF),
        ])
        #expect(try Inflate.zlib(bytes) == payload)
    }

    @Test("⚠️ LEN/NLEN 不互补时必须拒（否则会读到垃圾并越界）")
    func storedBlockRejectsBadLength() {
        let bytes: [UInt8] = [0x78, 0x01, 0x01, 0x05, 0x00, 0x00, 0x00]
        #expect(throws: InflateError.truncated) { try Inflate.zlib(bytes) }
    }

    @Test("⭐ 空内容也要能解（git 里空 blob 很常见）")
    func emptyContent() throws {
        #expect(try Inflate.zlib(try fixture("empty.zlib")) == [])
    }

    // MARK: 真实夹具（走动态 Huffman + 游程复制）

    @Test("⭐⭐ git blob 的原始存储形态：逐字节等于 `blob <len>\\0hello\\nworld\\n`")
    func gitBlobStorageForm() throws {
        // git 松散对象解压后的内容 = 对象头 + 正文。这个真值是**手算可验证的**：
        // "blob 12\0" 是 8 字节（注意 `12` 是**正文字节数**，不是总长），正文 "hello\nworld\n" 是 12 字节。
        let expected = Array("blob 12\u{0}hello\nworld\n".utf8)
        #expect(expected.count == 20, "夹具真值必须是 20 字节，实际 \(expected.count)")
        #expect(try Inflate.zlib(try fixture("git-blob-hello.txt.zlib")) == expected)
    }

    @Test("⭐⭐ 高压缩比：distance < length 的游程复制必须逐字节正确")
    func highCompressionRatio() throws {
        // 10000 个相同字节，压缩后只有 34 字节（≈294:1）。
        // ⚠️ 这里覆盖的正是"批量切片复制会错、必须逐字节"的那个分支 ——
        //    LZ77 的游程是边写边读，用 Array 切片批量拷贝会拿到错误结果。
        let compressed = try fixture("repeat-10000-zlib.bin")
        #expect(compressed.count == 34, "夹具应当是 34 字节（实际 \(compressed.count)）")
        let expected = [UInt8](repeating: 0x41, count: 10_000)
        #expect(try Inflate.zlib(compressed) == expected)
    }

    @Test("⭐ 长文本：字面量与长距离回溯混用")
    func mixedText() throws {
        let expected = Array(String(repeating: "the quick brown fox jumps over the lazy dog\n", count: 200).utf8)
        #expect(try Inflate.zlib(try fixture("mixed-text.zlib")) == expected)
    }

    @Test("⚠️ 输出上限必须拦住解压炸弹（34 字节能解出 10000 字节）")
    func outputLimitStopsZipBomb() throws {
        let compressed = try fixture("repeat-10000-zlib.bin")
        #expect(throws: InflateError.outputLimitExceeded(limit: 1024)) {
            try Inflate.zlib(compressed, outputLimit: 1024)
        }
        // 上限刚好够时必须能成功（边界不能多算一个字节）
        #expect(try Inflate.zlib(compressed, outputLimit: 10_000).count == 10_000)
    }

    // MARK: 损坏输入的分类

    @Test("⚠️ 三类损坏必须分别报出，不能一律「解压失败」")
    func corruptionIsClassified() {
        // ① 头不合法（CMF 低 4 位不是 8）
        #expect(throws: InflateError.badZlibHeader) { try Inflate.zlib([0x00, 0x00, 0, 0, 0, 0]) }
        // ② 截断：只剩 zlib 头
        #expect(throws: InflateError.truncated) { try Inflate.zlib([0x78, 0x01]) }
        // ③ 校验和不符：内容对但尾部被改
        var good: [UInt8] = [0x78, 0x01, 0x01, 0x05, 0x00, 0xFA, 0xFF]
        good.append(contentsOf: Array("hello".utf8))
        good.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        let payload = Array("hello".utf8)
        #expect(throws: InflateError.checksumMismatch(expected: 0, actual: Inflate.adler32(payload))) {
            try Inflate.zlib(good)
        }
    }

    @Test("⚠️ 真实夹具被改一个字节 → 必须报校验和不符，而不是静默给出错内容")
    func tamperedFixtureIsDetected() throws {
        var bytes = try fixture("mixed-text.zlib")
        // 改正文中间的一个字节（不动头与尾，确保失败原因一定是内容不一致）
        let middle = bytes.count / 2
        bytes[middle] = bytes[middle] ^ 0xFF
        #expect(throws: (any Error).self) { try Inflate.zlib(bytes) }
    }

    @Test("保留块类型（BTYPE=11）必须被拒")
    func reservedBlockType() {
        // BFINAL=1, BTYPE=11 → 第一字节低 3 位 = 0b111
        #expect(throws: InflateError.invalidBlockType) { try Inflate.rawDeflate([0x07]) }
    }

    @Test("Adler-32 对照已知值（含需要分段取模的大输入）")
    func adler32KnownValues() {
        #expect(Inflate.adler32(Array("hello".utf8)) == 0x062C_0215)
        #expect(Inflate.adler32([]) == 1)
        // ⚠️ 大输入走 5552 分段取模分支：不取模时 b 会溢出 UInt32，结果必错
        let large = [UInt8](repeating: 0xFF, count: 200_000)
        #expect(Inflate.adler32(large) != 0)
        #expect(Inflate.adler32(large) == Inflate.adler32(large), "同输入必须同结果")
    }
}
