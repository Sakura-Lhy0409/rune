import Foundation
import Testing
@testable import RuneKernel

// MARK: - SHA-1 与 Git 的对象寻址
//
// ⚠️ 这里最重要的一条不是「SHA-1 算得对」，而是**Git 的对象 ID 怎么算**：
//    它不是 `SHA1(内容)`，而是 `SHA1("<type> <bytelen>\0" + 内容)`。
//    少一个字节、把长度算成字符串长度、或者漏掉那一个 NUL，算出来的就是
//    另一个 40 位十六进制串 —— **看起来完全像对的**，但 `git log` 里永远找不到它。
//    所以真值必须来自**真实 git 仓库**，不能自己推。

@Suite("SHA-1 —— FIPS 180-1 标准向量")
struct SHA1Tests {

    @Test("⭐ NIST 标准测试向量（空串 / abc / 448 位边界 / 896 位边界）")
    func standardVectors() {
        #expect(SHA1.hash("").hex == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(SHA1.hash("abc").hex == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(SHA1.hash("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq").hex
                == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        // 一百万个 'a' —— 覆盖多块与长度填充的进位
        #expect(SHA1.hash(String(repeating: "a", count: 1_000_000)).hex
                == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    }

    @Test("⚠️ 55 / 56 / 64 字节边界：长度填充要新开一块，不能挤在本块里")
    func paddingBoundaries() {
        // 55 字节：填充后正好塞进一块（1 + 55 + 8 = 64）
        #expect(SHA1.hash(String(repeating: "a", count: 55)).hex
                == "c1c8bbdc22796e28c0e15163d20899b65621d65a")
        // 56 字节：必须新开一块（1 + 56 + 8 = 65 > 64）—— 差一个字节就走另一条路径
        #expect(SHA1.hash(String(repeating: "a", count: 56)).hex
                == "c2db330f6083854c99d4b5bfb6e8f29f201be699")
        // 64 字节：正好一块满，填充再开一块
        #expect(SHA1.hash(String(repeating: "a", count: 64)).hex
                == "0098ba824b5c16427bd7a1122a5a442a25ec644d")
    }

    @Test("⭐ 流式与一次性必须等价（任意切分方式）")
    func streamingMatchesOneShot() {
        let data = Array("the quick brown fox jumps over the lazy dog".utf8)
        let oneShot = SHA1.hash(data)
        for chunkSize in [1, 3, 7, 63, 64, 65, 200] {
            var hasher = SHA1.Streaming()
            var index = 0
            while index < data.count {
                let end = min(index + chunkSize, data.count)
                hasher.update(Array(data[index..<end]))
                index = end
            }
            #expect(hasher.finalize() == oneShot, "按 \(chunkSize) 字节切分时必须得到同一个摘要")
        }
    }

    @Test("十六进制往返与非法输入")
    func hexRoundTrip() {
        let digest = SHA1.hash("rune")
        #expect(SHA1(hex: digest.hex) == digest)
        #expect(SHA1(hex: digest.hex.uppercased()) == digest, "大写十六进制也要能解析")
        #expect(SHA1(hex: "abc") == nil, "长度不对必须返回 nil")
        #expect(SHA1(hex: String(repeating: "z", count: 40)) == nil, "非十六进制字符必须返回 nil")
    }
}

@Suite("Git 对象寻址 —— ID 必须与真实 git 一致")
struct GitObjectIDTests {

    /// 真值来自一个真实 git 仓库（`/tmp` 下 `git hash-object` / `git rev-parse` 的输出）。
    /// ⚠️ 硬编码在这里，是为了让测试**不依赖本机装了 git**（CI 容器里未必有）。
    @Test("⭐⭐ blob：SHA1(\"blob <len>\\0\" + 内容)，不是 SHA1(内容)")
    func blobIDMatchesRealGit() {
        let content = Array("hello\nworld\n".utf8)
        let store = Array("blob \(content.count)\u{0}".utf8) + content
        #expect(store.count == 20, "对象头 8 字节 + 正文 12 字节")
        #expect(SHA1.hash(store).hex == "94954abda49de8615a048f8d2e64b5de848e27a1")

        // ⚠️ 反例：裸内容哈希是另一个值。这一条是防"手滑写成 SHA1(content)"的护栏 ——
        //    那种写法能过所有自洽测试，只是在真实仓库里找不到任何对象。
        #expect(SHA1.hash(content).hex != "94954abda49de8615a048f8d2e64b5de848e27a1")
        #expect(SHA1.hash(content).hex == "58853e8a5e8272b1012f9a52a80758b27bd0d3cb")
    }

    @Test("⭐⭐ 空 blob 的 ID（git 里最常见的一个常量）")
    func emptyBlobID() {
        // `git hash-object -t blob /dev/null` = e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
        let store = Array("blob 0\u{0}".utf8)
        #expect(SHA1.hash(store).hex == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }

    @Test("⭐⭐ 真实 commit 的 ID：正文逐字节来自 `git cat-file commit`（含末尾那个 \\n）")
    func commitIDMatchesRealGit() throws {
        // 夹具是真实 git 仓库里一个提交的**原始正文字节**（Tools 里导出的，120 字节）。
        // 真值由 `git rev-parse HEAD` 给出 —— 也就是 git 自己的答案。
        //
        // ⚠️ commit 正文的最后一个换行也算进哈希。手工拼正文时少一个 \n，
        //    算出来的 40 位十六进制串**看起来完全正常**，只是在仓库里找不到它。
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/commit-body.bin")
        let content = [UInt8](try Data(contentsOf: url))
        #expect(content.count == 120, "commit 正文应当是 120 字节，实际 \(content.count)")
        #expect(content.last == 0x0A, "正文必须以换行结尾")

        let store = Array("commit \(content.count)\u{0}".utf8) + content
        #expect(SHA1.hash(store).hex == "745d8ddc2755eafc81cf4590e68af34cf02987c1",
                "必须与 `git rev-parse HEAD` 的输出一致")
    }

    @Test("⚠️ 长度写错一个字节 → ID 就完全不同（这是最隐蔽的一类错误）")
    func wrongLengthProducesDifferentID() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/commit-body.bin")
        let content = [UInt8](try Data(contentsOf: url))
        // 故意把长度写成 119（少算一个字节）
        let wrong = Array("commit \(content.count - 1)\u{0}".utf8) + content
        #expect(SHA1.hash(wrong).hex != "745d8ddc2755eafc81cf4590e68af34cf02987c1")
    }
}
