import Foundation
import Testing
@testable import RuneKernel

// MARK: - packfile 与 delta
//
// ⚠️ 这一片为什么不能跳：`git clone` 下来的仓库对象**几乎全在 pack 里**，
//    松散对象一个都没有。只支持松散对象的话，`git_log` 在真实仓库上会直接报
//    「对象不存在」—— 而用户明明刚 clone 下来。
//
// 夹具是一个**真实 git 仓库** repack 之后的 `.pack` + `.idx`（23 个对象，
// 含 4 级 delta 链和一个 delta 化的 tree）。真值来自 `git verify-pack -v`
// 与 `git rev-parse`，已硬编码在断言里 —— 所以测试**不依赖本机装 git**。

private let packSHA = "8ae4408c566ab2d83b0434a5a4865f7b44d8b14a"

private func packFixtureURLs() throws -> (pack: URL, index: URL) {
    let base = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/pack-repo/git/objects/pack")
        .resolvingSymlinksInPath()
    return (base.appendingPathComponent("pack-\(packSHA).pack"),
            base.appendingPathComponent("pack-\(packSHA).idx"))
}

private func pack() throws -> GitPack {
    let urls = try packFixtureURLs()
    return try GitPack(packURL: urls.pack, indexURL: urls.index)
}

@Suite("Git pack —— 索引与对象读取")
struct GitPackTests {

    @Test("⭐ 索引解析：对象数与 pack 头声明一致")
    func indexParses() throws {
        let pack = try pack()
        #expect(pack.objectCount == 23, "真值来自 git verify-pack -v")
        #expect(pack.objectIDs.count == 23)
    }

    @Test("⭐⭐ 每个对象还原后**哈希必须等于它在索引里的 ID**")
    func everyObjectHashesToItsID() throws {
        // ⚠️ 这是最强的一条断言，也是最划算的一条：
        //    它对**全部 23 个对象**同时验证了「pack 头解析 + zlib 边界定位 +
        //    delta 还原 + 类型继承」整条链路。delta 只要错一个字节，
        //    还原出来的对象就算不出原来的 SHA-1，这条立刻红。
        //
        //    它还是"正确性"而非"无崩溃"的判据：一个把 delta 还原成垃圾的实现
        //    可能不报任何错、只是给出错的字节 —— 那种实现过不了这一条。
        let pack = try pack()
        let store = try GitObjectStore(workTreeURL: try packWorkTree())
        var checked = 0
        for id in pack.objectIDs {
            let object = try pack.object(id) { try store.looseObject($0) }
            let recomputed = SHA1.hash(Array("\(object.type.rawValue) \(object.body.count)\u{0}".utf8) + object.body)
            #expect(recomputed == id,
                    "对象 \(id.hex) 还原后算出 \(recomputed.hex)（类型 \(object.type.rawValue)，\(object.body.count) 字节）")
            checked += 1
        }
        #expect(checked == 23)
    }

    @Test("⭐ 底层 blob（未 delta，20290 字节）内容正确")
    func baseBlob() throws {
        let pack = try pack()
        let id = SHA1(hex: "e7004471bc0fba116064d4b7d25e1a2c407fe34f")!
        let object = try pack.object(id)
        #expect(object.type == .blob)
        #expect(object.body.count == 20290)
        #expect(SHA1.hash(object.body).hex == "591fa233847b2e98e731c9ed23b4ece49a274a52")
        #expect(object.text.hasPrefix("line 0: "))
        #expect(object.text.contains("line 399: "))
    }

    @Test("⭐⭐⭐ delta 链 4 层：还原出的内容必须与**非 delta 路径**读到的一模一样")
    func deepDeltaChain() throws {
        // a5c0c026… 的 delta 链长 4（base→…→它自己），是这份夹具里最深的一条。
        // 它是 big.txt 在 HEAD 的版本 —— 而同一个文件在 HEAD~5 的版本（e7004471…）
        // **恰好是未 delta 的基对象**。
        //
        // ⚠️ 所以这里能做一条特别强的断言：**两条完全不同的代码路径读同一个文件**，
        //    一条走"基对象直读"，一条走"4 层 delta 还原"，两者必须给出**逐字节相同**的结果。
        //    单看任何一条都能自洽地错，但两条一起错成同一个结果几乎不可能。
        let pack = try pack()
        let viaDelta = try pack.object(SHA1(hex: "a5c0c02667b45674210a18f36d53cb49e5ce0093")!)
        #expect(viaDelta.type == .blob)
        #expect(viaDelta.body.count == 20141, "真值来自 git cat-file -s")

        // 内容哈希（真值来自 git cat-file blob … | shasum）
        #expect(SHA1.hash(viaDelta.body).hex == "68ddc87f962b97a9ddfa65fe60a147956bb81c10",
                "4 层 delta 还原后的内容与 git 给出的必须逐字节一致")

        // 语义检查：这是 400 行的 big.txt，第 250 行被第 5 次提交改过
        let lines = viaDelta.text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 401, "400 行 + 末尾换行切出的空段")
        #expect(lines[250] == "modified at commit 5")
        #expect(viaDelta.text.hasPrefix("line 0: "))

        // 而**基对象**（未 delta）是同一个文件的早期版本，更长（改动把长行改短了）
        let base = try pack.object(SHA1(hex: "e7004471bc0fba116064d4b7d25e1a2c407fe34f")!)
        #expect(base.body.count == 20290)
        #expect(SHA1.hash(base.body).hex == "591fa233847b2e98e731c9ed23b4ece49a274a52")
    }

    @Test("⭐ 中间层 delta（链长 1）也要对")
    func singleLevelDelta() throws {
        let pack = try pack()
        // b5f635ac… 的 delta 链长 1，内容哈希真值来自 git
        let object = try pack.object(SHA1(hex: "b5f635ac6422213d61559e6db66408e48d01fcde")!)
        #expect(object.type == .blob)
        #expect(object.body.count == 20261)
        #expect(SHA1.hash(object.body).hex == "702bb568dbc83b16d20f9ce12b57780de00a9c89")
    }

    @Test("⚠️ delta 化的 tree：类型必须**继承基对象**，不能被写死成 blob")
    func deltaTreeKeepsItsType() throws {
        let pack = try pack()
        // be009c73… 是一个 delta 化的 tree（base 是 eef4694d…）
        let id = SHA1(hex: "be009c7375dea7e2926c754bab91d23231ba9f86")!
        let object = try pack.object(id)
        #expect(object.type == .tree, "delta 只描述'怎么改字节'，不描述'这是什么' —— 类型必须继承")
        #expect(try object.treeEntries().isEmpty == false)
    }

    @Test("⭐ commit 与 tree 都能从 pack 里读出来")
    func commitAndTreeFromPack() throws {
        let pack = try pack()
        let headID = SHA1(hex: "70c4b319a857b8009b554bbe9c038e8d7961775d")!
        let commit = try pack.object(headID).commit(id: headID)
        #expect(commit.summary == "c6")
        #expect(commit.parents.count == 1)

        let rootTreeID = SHA1(hex: "eef4694d0fb7c9ee4357423e2140072bd16e291a")!
        let entries = try pack.object(rootTreeID).treeEntries()
        #expect(entries.contains { $0.name == "big.txt" }, "根 tree 里应当有 big.txt")
    }

    @Test("⚠️ 不在 pack 里的对象必须报 objectNotFound（不能返回空内容）")
    func missingObjectIsReported() throws {
        let pack = try pack()
        let absent = SHA1(hex: String(repeating: "a", count: 40))!
        #expect(throws: GitError.objectNotFound(absent)) { try pack.object(absent) }
    }

    @Test("⚠️ 索引与 pack 不配套时必须拒（对象数不符）")
    func mismatchedPackAndIndexAreRejected() throws {
        let urls = try packFixtureURLs()
        // 拿一个 pack 配另一个索引：对象数必然不符
        let otherIndex = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/loose-dotgit/git/HEAD")   // 任意非索引文件
        #expect(throws: (any Error).self) { try GitPack(packURL: urls.pack, indexURL: otherIndex) }
    }
}

@Suite("Git pack —— delta 指令流")
struct GitDeltaTests {

    @Test("⭐ 插入指令：指令值本身就是长度（必须**不含** 0x80 位）")
    func insertInstruction() throws {
        // delta: 源大小=4, 目标大小=7, 插入 7 字节
        let delta: [UInt8] = [4, 7, 7] + Array("ABCDEFG".utf8)
        let out = try Delta.apply(base: Array("wxyz".utf8), delta: delta)
        #expect(out == Array("ABCDEFG".utf8))
    }

    @Test("⭐ 拷贝指令：低 7 位是掩码，决定 offset/size 各段是否存在")
    func copyInstruction() throws {
        // 源大小=4, 目标大小=2；指令 0x91 = 拷贝 + 掩码 0x11（offset 低字节 + size 低字节）
        //   offset = 1, size = 2
        let delta: [UInt8] = [4, 2, 0x91, 1, 2]
        let out = try Delta.apply(base: Array("wxyz".utf8), delta: delta)
        #expect(out == Array("xy".utf8))
    }

    @Test("⚠️ 拷贝 size 全 0 表示 65536（规范里最容易漏的一条）")
    func copySizeZeroMeans65536() throws {
        let base = [UInt8](repeating: 0x41, count: 65_536)
        // 源=65536, 目标=65536；指令 0x80 = 拷贝但掩码为 0（offset=0, size=0 → 65536）
        var encoded: [UInt8] = []
        func varint(_ value: Int) -> [UInt8] {
            var v = value, out: [UInt8] = []
            repeat { var byte = UInt8(v & 0x7F); v >>= 7; if v != 0 { byte |= 0x80 }; out.append(byte) } while v != 0
            return out
        }
        encoded += varint(65_536)
        encoded += varint(65_536)
        encoded.append(0x80)          // 拷贝，掩码 0 → offset=0, size=0 → 65536
        let out = try Delta.apply(base: base, delta: encoded)
        #expect(out.count == 65_536, "size=0 必须解释成 65536，否则这里会得到 0 字节")
    }

    @Test("⚠️ 源大小与基对象实际长度不符必须拒（用错基对象时会产出看似可用的错内容）")
    func sourceSizeMismatchIsRejected() {
        let delta: [UInt8] = [99, 1, 1, 0x41]   // 声称源 99 字节，实际基对象只有 4
        #expect(throws: PackError.self) { try Delta.apply(base: Array("wxyz".utf8), delta: delta) }
    }

    @Test("⚠️ 指令 0 是保留值，必须拒（不拒会让解析器原地打转）")
    func zeroInstructionIsRejected() {
        let delta: [UInt8] = [4, 1, 0]
        #expect(throws: PackError.self) { try Delta.apply(base: Array("wxyz".utf8), delta: delta) }
    }

    @Test("⚠️ 拷贝区间越界必须拒（否则会读到基对象之外）")
    func copyOutOfRangeIsRejected() {
        // 源=4, 目标=2；拷贝 offset=3, size=2 → 3+2 > 4
        let delta: [UInt8] = [4, 2, 0x91, 3, 2]
        #expect(throws: PackError.self) { try Delta.apply(base: Array("wxyz".utf8), delta: delta) }
    }

    @Test("⚠️ 还原出的长度与声明的目标大小不符必须拒")
    func targetSizeMismatchIsRejected() {
        // 声明目标 5 字节，实际只插入 2 字节
        let delta: [UInt8] = [4, 5, 2] + Array("AB".utf8)
        #expect(throws: PackError.self) { try Delta.apply(base: Array("wxyz".utf8), delta: delta) }
    }
}

/// 给 pack 测试用的工作区（只需要 `.git` 存在，用于 looseFallback）。
private func packWorkTree() throws -> URL {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/pack-repo")
        .resolvingSymlinksInPath()
    let target = FileManager.default.temporaryDirectory.appendingPathComponent("rune-pack-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    // 夹具内层叫 `git`（不是 `.git`），避免被当成嵌套仓库 —— 见 C50
    try FileManager.default.copyItem(at: source.appendingPathComponent("git"),
                                     to: target.appendingPathComponent(".git"))
    return target
}
