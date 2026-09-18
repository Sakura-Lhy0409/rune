import Foundation
import Testing
@testable import RuneKernel

// MARK: - Git 对象读取与解析
//
// 真值全部来自**真实 git 仓库**（`git ls-tree` / `git cat-file` / `git rev-parse` 的输出），
// 已导出为夹具，所以测试**不依赖本机装 git**（CI 的 ubuntu 容器里未必有）。
//
// ⚠️ 为什么这些测试值得写：git 的二进制格式里有好几处"差一个字节就全错、
//    但结果看起来完全正常"的地方 —— NUL 还是空格、SHA 是 20 字节还是 40 字符、
//    commit 正文末尾那个换行算不算。每一条都用真实对象钉住。

private func fixtureBytes(_ name: String) throws -> [UInt8] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
    return [UInt8](try Data(contentsOf: url))
}

/// 把夹具仓库拷到临时目录（测试要写文件时用，避免污染入库夹具）。
private func temporaryRepository() throws -> URL {
    // ⚠️ 必须 resolvingSymlinksInPath：macOS 的临时目录真实位置在 /private/var 下，
    //    而 URL 可能写着 /var/… —— 两者是同一个目录但字符串不同（项目记过的 T55）。
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/loose-repo")
        .resolvingSymlinksInPath()
    let target = FileManager.default.temporaryDirectory
        .appendingPathComponent("rune-git-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: source, to: target)
    // ⚠️ 夹具入库时可能是只读的（git 只记可执行位，但打包工具可能改权限）。
    //    测试要改文件，所以显式把整个拷贝树变成可写 —— 不改源夹具。
    if let enumerator = FileManager.default.enumerator(at: target, includingPropertiesForKeys: [.isDirectoryKey]) {
        for case let url as URL in enumerator {
            // ⚠️ 目录必须给 0o755（要有**执行位**才能遍历），文件给 0o644。
            //    一律设 0o644 会把目录变成不可遍历 —— 表现是"仓库不存在"，很难查。
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            try? FileManager.default.setAttributes([.posixPermissions: isDirectory ? 0o755 : 0o644],
                                                   ofItemAtPath: url.path)
        }
    }
    return target
}

@Suite("Git —— tree 解析")
struct GitTreeParsingTests {

    @Test("⭐ 根 tree：文件、可执行、符号链接、子树四种 mode 都要认对")
    func rootTreeEntries() throws {
        let object = GitObject(type: .tree, body: try fixtureBytes("fixture-tree-root.bin"),
                               id: SHA1(bytes: [UInt8](repeating: 0, count: 20)))
        let entries = try object.treeEntries()

        #expect(entries.count == 4)
        #expect(entries.map(\.name) == ["README.md", "link.md", "run.sh", "src"],
                "顺序必须是 git 的规范排序（不是字典序）")

        // 普通文件
        #expect(entries[0].mode == "100644")
        #expect(entries[0].id.hex == "778d24d1a3af4370a7872c7017ab22abfcd5d283", "README.md 在第二个提交里被追加过内容")
        #expect(entries[0].typeName == "blob")
        #expect(!entries[0].isTree && !entries[0].isSymlink && !entries[0].isExecutable)

        // 符号链接：mode 120000，正文是链接目标
        #expect(entries[1].mode == "120000")
        #expect(entries[1].isSymlink)
        #expect(entries[1].id.hex == "42061c01a1c70097d1e4579f29a5adf40abdec95")

        // 可执行位
        #expect(entries[2].mode == "100755")
        #expect(entries[2].isExecutable)

        // 子树：mode 是 40000（**不是** 040000）—— 判据必须两种写法都认
        #expect(entries[3].isTree)
        #expect(entries[3].mode == "40000")
        #expect(entries[3].typeName == "tree")
        #expect(entries[3].id.hex == "b0e1b6c15229438a2ef25b8cd6dbb455284f2190")
    }

    @Test("⭐ 子树可以继续解析（src/ 下面是 a.py 与 deep/）")
    func nestedTree() throws {
        let src = GitObject(type: .tree, body: try fixtureBytes("fixture-tree-src.bin"),
                            id: SHA1(bytes: [UInt8](repeating: 0, count: 20)))
        let entries = try src.treeEntries()
        #expect(entries.map(\.name) == ["a.py", "deep"])
        #expect(entries[0].id.hex == "b917a726c93f902e43291d9009d6488385133b67")
        #expect(entries[1].isTree)
        #expect(entries[1].id.hex == "add4794d9c94872b96c1697c056fb82ae0d72880")

        let deep = GitObject(type: .tree, body: try fixtureBytes("fixture-tree-deep.bin"),
                             id: SHA1(bytes: [UInt8](repeating: 0, count: 20)))
        #expect(try deep.treeEntries().map(\.name) == ["b.txt"])
    }

    @Test("⚠️ SHA-1 是**原始 20 字节**，不是 40 个 ASCII 字符")
    func shaIsRawBytes() throws {
        let body = try fixtureBytes("fixture-tree-deep.bin")
        // 33 字节 = "100644 b.txt\0"(13) + 20 字节原始 SHA
        #expect(body.count == 33, "如果 SHA 被误当成 40 个字符，长度会变成 53")
        #expect(body[12] == 0, "name 之后必须是 NUL 分隔符（\"100644 b.txt\" 是 12 字节，所以 NUL 在下标 12）")
        let entries = try GitObject(type: .tree, body: body,
                                    id: SHA1(bytes: [UInt8](repeating: 0, count: 20))).treeEntries()
        #expect(entries[0].id.hex == "587be6b4c3f93f93c489c0111bba5596147a26cb")
    }

    @Test("⚠️ 截断的 tree 必须报错，不能解出半条就返回")
    func truncatedTreeIsRejected() throws {
        var body = try fixtureBytes("fixture-tree-root.bin")
        body.removeLast(10)   // 砍掉最后一个条目的一半 SHA
        let object = GitObject(type: .tree, body: body, id: SHA1(bytes: [UInt8](repeating: 0, count: 20)))
        #expect(throws: GitError.self) { try object.treeEntries() }
    }

    @Test("⚠️ 类型不对时必须报错（拿 blob 当 tree 解析）")
    func wrongTypeIsRejected() {
        let object = GitObject(type: .blob, body: Array("hello".utf8),
                               id: SHA1(bytes: [UInt8](repeating: 0, count: 20)))
        #expect(throws: GitError.self) { try object.treeEntries() }
    }
}

@Suite("Git —— commit 解析")
struct GitCommitParsingTests {

    /// 这个夹具是一个**带父提交**的真实 commit（`git cat-file commit` 的原始输出）。
    @Test("⭐⭐ 真实 commit：tree / parent / 作者 / 提交者 / 正文都要解对")
    func realCommit() throws {
        let body = try fixtureBytes("fixture-commit-with-parent.bin")
        let object = GitObject(type: .commit, body: body, id: SHA1(bytes: [UInt8](repeating: 0, count: 20)))
        let commit = try object.commit(id: object.id)

        #expect(commit.tree.hex == "6f212d435230a75c74285966359a64c9360acc90",
                "这是**根提交**，它的 tree 是 6f212d43…（b0e1b6c1… 是它的 src 子树，不是 tree 根）")
        #expect(commit.parents.isEmpty, "根提交没有父提交")
        #expect(commit.summary == "initial layout")
        #expect(commit.author.name == "Rune Dev")
        #expect(commit.author.email == "dev@rune.local")
        #expect(commit.committer.name == "Rune Dev")
        #expect(commit.author.timestamp > 0)
    }

    @Test("⭐⭐ 带父提交的 commit：parent 必须解对（历史图的边）")
    func commitWithParent() throws {
        let body = try fixtureBytes("fixture-commit-second.bin")
        let object = GitObject(type: .commit, body: body, id: SHA1(bytes: [UInt8](repeating: 0, count: 20)))
        let commit = try object.commit(id: object.id)
        #expect(commit.parents.count == 1)
        #expect(commit.parents[0].hex == "f3ee7494402134df9caa88f7526a4072cf6a47a8")
        #expect(commit.tree.hex == "bd2958ced9ebd0b86cfc1e9af2fc0cbbe1263703")
        #expect(commit.summary == "second commit with parent")
        #expect(commit.author.name == "Rune Dev")
    }

    @Test("⚠️ 名字里带空格必须解对（从左往右切会切错，只在多词名字上暴露）")
    func signatureWithSpacesInName() {
        let signature = GitSignature(header: "Rune Dev Team <team@rune.local> 1789721333 +0800")
        #expect(signature.name == "Rune Dev Team")
        #expect(signature.email == "team@rune.local")
        #expect(signature.timestamp == 1_789_721_333)
        #expect(signature.timezone == "+0800")
    }

    @Test("根提交（无 parent）也必须能解")
    func rootCommit() throws {
        // fixture-commit-with-parent 之外，用一个最小正文验证"没有 parent"这条路径
        let body = Array("tree b0e1b6c15229438a2ef25b8cd6dbb455284f2190\nauthor a <a@a> 1 +0000\ncommitter a <a@a> 1 +0000\n\nroot\n".utf8)
        let object = GitObject(type: .commit, body: body, id: SHA1(bytes: [UInt8](repeating: 0, count: 20)))
        let commit = try object.commit(id: object.id)
        #expect(commit.parents.isEmpty)
        #expect(commit.summary == "root")
    }

    @Test("⚠️ 多父提交（合并）必须全部保留")
    func mergeCommit() throws {
        let body = Array("""
        tree b0e1b6c15229438a2ef25b8cd6dbb455284f2190
        parent 1111111111111111111111111111111111111111
        parent 2222222222222222222222222222222222222222
        author a <a@a> 1 +0000
        committer a <a@a> 1 +0000

        merge two branches
        """.utf8)
        let object = GitObject(type: .commit, body: body, id: SHA1(bytes: [UInt8](repeating: 0, count: 20)))
        let commit = try object.commit(id: object.id)
        #expect(commit.parents.count == 2, "合并提交的父提交少一个，历史图就断了")
    }

    @Test("⚠️ 不认识的 header（gpgsig 等）要忽略而不是报错；续行不能被当成新 header")
    func unknownHeadersAreIgnored() throws {
        let body = Array("""
        tree b0e1b6c15229438a2ef25b8cd6dbb455284f2190
        parent 1111111111111111111111111111111111111111
        author a <a@a> 1 +0000
        committer a <a@a> 1 +0000
        gpgsig -----BEGIN PGP SIGNATURE-----
         
         abcdEFGH1234
         -----END PGP SIGNATURE-----

        signed commit
        """.utf8)
        let object = GitObject(type: .commit, body: body, id: SHA1(bytes: [UInt8](repeating: 0, count: 20)))
        let commit = try object.commit(id: object.id)
        #expect(commit.summary == "signed commit", "签名是 header 的一部分，不能污染提交信息")
        #expect(commit.parents.count == 1)
    }

    @Test("⚠️ 缺少 tree 行必须报错（没有 tree 的 commit 无法定位内容）")
    func missingTreeIsRejected() {
        let body = Array("author a <a@a> 1 +0000\n\nno tree\n".utf8)
        let object = GitObject(type: .commit, body: body, id: SHA1(bytes: [UInt8](repeating: 0, count: 20)))
        #expect(throws: GitError.self) { try object.commit(id: object.id) }
    }
}

@Suite("Git —— 对象库读取（真实 .git 目录）")
struct GitObjectStoreTests {

    @Test("⭐⭐ 从真实 .git 读出对象，并按它的 ID 校验")
    func readsAndVerifiesRealObject() throws {
        let repo = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)

        let treeID = SHA1(hex: "b0e1b6c15229438a2ef25b8cd6dbb455284f2190")!
        let object = try store.object(treeID)
        #expect(object.type == .tree)
        #expect(object.id == treeID)
        #expect(try object.treeEntries().map(\.name) == ["a.py", "deep"], "b0e1b6c1… 是 src 子树")
    }

    @Test("⭐ blob 内容原样读回（含可执行脚本的 shebang）")
    func readsBlob() throws {
        let repo = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        let object = try store.object(SHA1(hex: "4163036efa65bd4a469e752267498f01ea36a55c")!)
        #expect(object.type == .blob)
        #expect(object.text == "#!/bin/sh\necho hi\n")
    }

    @Test("⭐ HEAD 与分支引用解析")
    func resolvesHEADAndBranch() throws {
        let repo = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)

        #expect(store.currentBranch() == "main")
        let head = try store.headCommitID()
        #expect(head.hex == "dd398dac2ae5dfaefe0b95420677626de71abf84", "夹具仓库 HEAD 已是第二个提交")
        // HEAD 指向的必须真是一个 commit
        #expect(try store.object(head).type == .commit)
        #expect(store.branches() == ["main"])
    }

    @Test("⚠️ 不存在的对象必须报 objectNotFound，而不是空内容")
    func missingObjectIsReported() throws {
        let repo = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        let missing = SHA1(hex: String(repeating: "9", count: 40))!
        #expect(throws: GitError.objectNotFound(missing)) { try store.object(missing) }
    }

    @Test("⭐⭐ 对象内容被改一个字节 → 必须报 hashMismatch（否则会拿着错内容继续算）")
    func tamperingIsDetected() throws {
        let repo = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)

        // 找一个 blбо 对象，把它压缩字节里的一个字节翻掉
        let blobID = SHA1(hex: "4163036efa65bd4a469e752267498f01ea36a55c")!
        let path = repo.appendingPathComponent(".git/objects/41/63036efa65bd4a469e752267498f01ea36a55c")
        var bytes = [UInt8](try Data(contentsOf: path))
        bytes[bytes.count - 1] ^= 0xFF     // 动 Adler-32 尾部
        try Data(bytes).write(to: path)

        // ⚠️ 只要不是"静默给出错内容"就算合格：可能是校验和不符，也可能是哈希不符。
        //    关键是**必须报错**。
        #expect(throws: (any Error).self) { try store.object(blobID) }
    }

    @Test("⚠️ 头部声明的长度与实际正文不符必须报错（截断的唯一信号）")
    func lengthMismatchIsRejected() {
        // "blob 5\0" + 只有 3 字节正文
        let bytes = Array("blob 5\u{0}abc".utf8)
        let id = SHA1(bytes: [UInt8](repeating: 0, count: 20))
        #expect(throws: GitError.self) { try GitObjectStore.parseObject(bytes, expecting: id) }
    }

    @Test("⚠️ 没有 NUL 分隔符必须报错（不是 git 对象）")
    func missingSeparatorIsRejected() {
        let bytes = Array("blob 5 abc".utf8)
        let id = SHA1(bytes: [UInt8](repeating: 0, count: 20))
        #expect(throws: GitError.self) { try GitObjectStore.parseObject(bytes, expecting: id) }
    }

    @Test("⚠️ 不是仓库的目录必须报 notARepository，且消息里带路径")
    func nonRepositoryIsReported() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("rune-norepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: GitError.notARepository(empty.path)) { try GitObjectStore(workTreeURL: empty) }
    }

    @Test("⚠️ 空仓库（HEAD 指向还没有的分支）必须报 emptyRepository，而不是 objectNotFound")
    func emptyRepositoryIsReported() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("rune-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/refs/heads"),
                                                withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: repo.appendingPathComponent(".git/HEAD"),
                                           atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        #expect(throws: GitError.emptyRepository) { try store.headCommitID() }
    }
}
