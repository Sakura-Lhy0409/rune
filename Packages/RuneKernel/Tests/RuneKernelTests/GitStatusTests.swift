import Foundation
import Testing
@testable import RuneKernel

// MARK: - Git 读取路径：index / 三方状态 / revision / 历史
//
// 夹具是一个**真实 git 仓库**，而且刻意做成了**三方各不相同的状态**：
//
//     $ git status --short
//      M README.md        ← 工作区改了，没 add（未暂存）
//     A  staged.txt       ← 已 add（已暂存）
//     ?? brand-new.txt    ← 未跟踪
//
// ⚠️ 为什么这个夹具值得单独造：`git_status` 的价值**全在"分得清三方"**上。
//    一个只比"HEAD ↔ 工作区"的实现，会把 `staged.txt` 与 `brand-new.txt`
//    报成同一类（都是"HEAD 里没有"）—— 而用户要做的下一步完全不同：
//    前者该 `commit`，后者该先 `add`。分不清就会让模型重复 add、或者
//    以为已经提交了。所以下面的断言逐条钉死这三类。

private func statusRepo() throws -> URL {
    // ⚠️ 夹具内层目录叫 `git` 而不是 `.git`（避免被当成嵌套仓库，见 C50/C51 教训）
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/status-repo")
        .resolvingSymlinksInPath()
    let target = FileManager.default.temporaryDirectory.appendingPathComponent("rune-status-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source.appendingPathComponent("git"),
                                     to: target.appendingPathComponent(".git"))
    if let enumerator = FileManager.default.enumerator(at: target, includingPropertiesForKeys: [.isDirectoryKey]) {
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            try? FileManager.default.setAttributes([.posixPermissions: isDirectory ? 0o755 : 0o644],
                                                   ofItemAtPath: url.path)
        }
    }
    // 工作区文件（夹具里那几个源文件放在 git/ 旁边，拷过来）
    //
    // ⚠️ `link.md` 是一个**符号链接**，必须用 `copyItem` 单独处理：
    //    `cp -R` 会把符号链接**解引用**成普通文件，于是它的内容变成链接目标的内容，
    //    与 index 里 mode=120000 的 blob（内容是"README.md"这 9 个字节）不符 ——
    //    `git_status` 于是正确地把它报成"未暂存修改"。**测试夹具自己造出来的噪音**，
    //    会被误读成实现有 bug。我第一版就是这么被绊了一下。
    for name in ["README.md", "run.sh", "staged.txt", "brand-new.txt"] {
        try? FileManager.default.copyItem(at: source.appendingPathComponent(name),
                                          to: target.appendingPathComponent(name))
    }
    // ⚠️ 不吞错误：静默失败会让"夹具缺了链接"表现成"实现把链接报成已删除"，
    //    排查方向会被彻底带偏（我第一版就吞了，白查一轮）。
    let linkPath = target.appendingPathComponent("link.md").path
    if FileManager.default.fileExists(atPath: linkPath) {
        try? FileManager.default.removeItem(atPath: linkPath)
    }
    do {
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: "README.md")
    } catch {
        Issue.record("夹具建符号链接失败：\(error)")
    }
    let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) != nil
    #expect(isLink, "夹具的 link.md 必须真的是符号链接，否则这条测试测的不是它想测的东西")
    try? FileManager.default.createDirectory(at: target.appendingPathComponent("src/deep"),
                                             withIntermediateDirectories: true)
    for name in ["src/a.py", "src/deep/b.txt"] {
        try? FileManager.default.copyItem(at: source.appendingPathComponent(name),
                                          to: target.appendingPathComponent(name))
    }
    return target
}

@Suite("Git index —— 暂存区解析")
struct GitIndexParsingTests {

    @Test("⭐ 真实 index：条目、blob ID、mode 都要对")
    func parsesRealIndex() throws {
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        let entries = try store.index()

        #expect(entries.count == 6, "真值来自 git ls-files -s（6 个条目）")
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })

        // 普通文件
        #expect(byPath["README.md"]?.id.hex == "778d24d1a3af4370a7872c7017ab22abfcd5d283")
        #expect(byPath["README.md"]?.mode == "100644")
        // 可执行位
        #expect(byPath["run.sh"]?.mode == "100755")
        // 符号链接
        #expect(byPath["link.md"]?.mode == "120000")
        // 子目录里的文件（路径带 `/`，不是只有 basename）
        #expect(byPath["src/a.py"] != nil)
        #expect(byPath["src/deep/b.txt"] != nil)
        // 刚 add 的那个
        #expect(byPath["staged.txt"]?.id.hex == "19d9cc8584ac2c7dcf57d2680375e80f099dc481")
    }

    @Test("⚠️ 没有 index 的新仓库返回空数组，而不是抛错")
    func missingIndexIsNotAnError() throws {
        // 这是**合法状态**：刚 `git init`、还没 add 过。
        // 抛错的话，`git_status` 在一个空仓库上会直接失败 —— 而那是用户最可能的第一步。
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("rune-noidx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/refs/heads"),
                                                withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: repo.appendingPathComponent(".git/HEAD"),
                                           atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        #expect(try store.index().isEmpty)
    }

    @Test("⚠️ index 头不合法必须报错")
    func badIndexHeaderIsRejected() {
        #expect(throws: GitIndexError.self) { try GitIndex.parse(Array("NOPE\u{0}\u{0}\u{0}\u{2}".utf8)) }
    }

    @Test("⚠️ 不支持的 index 版本必须明确拒绝（而不是按 v2 硬解出乱码路径）")
    func unsupportedIndexVersionIsRejected() {
        var bytes: [UInt8] = Array("DIRC".utf8)
        bytes += [0, 0, 0, 9]      // 版本 9
        bytes += [0, 0, 0, 0]      // 0 个条目
        #expect(throws: GitIndexError.unsupportedVersion(9)) { try GitIndex.parse(bytes) }
    }
}

@Suite("Git 三方状态 —— 这是 git_status 的全部价值")
struct GitStatusTests {

    @Test("⭐⭐⭐ 已暂存 / 未暂存 / 未跟踪 三者必须分得清")
    func threeWayStatus() throws {
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        let report = try GitStatusReport(
            branch: store.currentBranch(),
            headCommit: store.headCommitID(),
            files: GitWorktree.status(store: store, headTree: try store.headTreeFlat()))

        let byPath = Dictionary(uniqueKeysWithValues: report.files.map { ($0.path, $0) })

        // ① 工作区改了、没 add → 未暂存，不是已暂存
        let readme = try #require(byPath["README.md"])
        #expect(readme.unstaged == .modified, "改过但没 add 的必须是「未暂存」")
        #expect(readme.staged == nil, "它**没有**被暂存 —— 报成已暂存会让模型以为可以直接 commit")
        #expect(!readme.isUntracked)
        #expect(readme.shortLine == " M README.md")

        // ② 已 add → 已暂存，且**不再是未暂存**
        let staged = try #require(byPath["staged.txt"])
        #expect(staged.staged == .added, "add 过的必须是「已暂存」")
        #expect(staged.unstaged == nil, "已暂存且工作区与 index 一致时，不该再有未暂存改动")
        #expect(staged.shortLine == "A  staged.txt")

        // ③ 全新文件 → 未跟踪，既不是已暂存也不是未暂存
        let fresh = try #require(byPath["brand-new.txt"])
        #expect(fresh.isUntracked)
        #expect(fresh.staged == nil && fresh.unstaged == nil)
        #expect(fresh.shortLine == "?? brand-new.txt")

        // ④ 没被动过的文件不该出现在报告里
        #expect(byPath["src/a.py"] == nil, "没改过的文件不该出现（否则报告全是噪音）")
        #expect(byPath["run.sh"] == nil)

        // ⚠️ 失败信息里必须带**实际值**：只报"计数不等"会让人只能猜。
        let observed = report.files.map { "\($0.shortLine)" }.joined(separator: " | ")
        #expect(report.stagedCount == 1, "实际报告：\(observed)")
        #expect(report.unstagedCount == 1, "实际报告：\(observed)")
        #expect(report.untrackedCount == 1, "实际报告：\(observed)")
        #expect(!report.isClean)
    }

    @Test("⭐ 报告文本要说清「干净」，而不是给一片空白")
    func modelFacingTextForCleanTree() throws {
        // 空白会让模型以为工具坏了，于是换个方式再试一遍 —— 白烧 token
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        let clean = GitStatusReport(branch: "main", headCommit: nil, files: [])
        #expect(clean.modelFacingText.contains("干净"))
        #expect(clean.isClean)
    }

    @Test("⭐ 报告里必须写明两列的语义（写反会让模型提交错东西）")
    func reportExplainsColumns() throws {
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        let report = try GitStatusReport(branch: store.currentBranch(),
                                         headCommit: store.headCommitID(),
                                         files: GitWorktree.status(store: store, headTree: try store.headTreeFlat()))
        #expect(report.modelFacingText.contains("左列=已暂存"), "必须解释两列，否则模型会读反")
        #expect(report.modelFacingText.contains("main"))
    }

    @Test("⭐⭐ 忽略规则必须真的生效（否则报告里全是构建产物）")
    func ignoreRulesApply() throws {
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // 造两个"扫了也没用"的目录
        for path in ["node_modules", ".build"] {
            let dir = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "junk".write(to: dir.appendingPathComponent("junk.js"), atomically: true, encoding: .utf8)
        }
        let store = try GitObjectStore(workTreeURL: repo)
        let scanned = try GitWorktree.scanWorkingTree(store: store)
        #expect(scanned["node_modules/junk.js"] == nil, "node_modules 必须被忽略")
        #expect(scanned[".build/junk.js"] == nil, "构建产物必须被忽略")
        #expect(scanned["README.md"] != nil, "正常文件不能被误忽略")
    }

    @Test("⭐ 工作区 blob ID 必须与 git 算的一致（含对象头）")
    func worktreeBlobIDsMatchGit() throws {
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        let scanned = try GitWorktree.scanWorkingTree(store: store)
        // staged.txt 的内容与 index 里的一致，所以哈希必须相同
        #expect(scanned["staged.txt"]?.hex == "19d9cc8584ac2c7dcf57d2680375e80f099dc481")
        // README.md 被改过，所以**不**等于 index 里那个哈希
        #expect(scanned["README.md"]?.hex != "778d24d1a3af4370a7872c7017ab22abfcd5d283")
    }
}

@Suite("Git revision 解析")
struct GitRevisionTests {

    @Test("⭐ HEAD / HEAD~1 / HEAD^ 都能解，且指向正确的提交")
    func resolvesCommonForms() throws {
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)

        let head = try GitRevision.resolve("HEAD", store: store)
        #expect(head.hex == "dd398dac2ae5dfaefe0b95420677626de71abf84")

        let parent = try GitRevision.resolve("HEAD~1", store: store)
        #expect(parent.hex == "f3ee7494402134df9caa88f7526a4072cf6a47a8")

        // `HEAD^` 等价于 `HEAD^1`
        #expect(try GitRevision.resolve("HEAD^", store: store) == parent)
        #expect(try GitRevision.resolve("HEAD^1", store: store) == parent)
    }

    @Test("⭐ 分支名与 refs/heads/ 前缀都能解")
    func resolvesBranchNames() throws {
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        let viaName = try GitRevision.resolve("main", store: store)
        let viaFull = try GitRevision.resolve("refs/heads/main", store: store)
        #expect(viaName == viaFull)
        #expect(viaName.hex == "dd398dac2ae5dfaefe0b95420677626de71abf84")
    }

    @Test("⭐ 缩写 SHA：唯一时可解")
    func resolvesAbbreviatedSHA() throws {
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        let short = try GitRevision.resolve("dd398d", store: store)
        #expect(short.hex == "dd398dac2ae5dfaefe0b95420677626de71abf84")
        // 全 40 位当然也行
        #expect(try GitRevision.resolve("dd398dac2ae5dfaefe0b95420677626de71abf84", store: store) == short)
    }

    @Test("⚠️ 太短的前缀必须拒（4 位以下歧义概率太高）")
    func tooShortPrefixIsRejected() throws {
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        #expect(throws: (any Error).self) { try GitRevision.resolve("dd", store: store) }
    }

    @Test("⚠️ 不认识的引用必须报 referenceNotFound，而不是猜一个")
    func unknownReferenceIsRejected() throws {
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        #expect(throws: GitError.referenceNotFound("nope")) {
            try GitRevision.resolve("nope", store: store)
        }
    }

    @Test("⚠️ 根提交上没有父提交：HEAD~1 必须明确报错，不能说「就是它自己」")
    func parentOfRootIsRejected() throws {
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        // HEAD~1 是根提交，再 ~1 就没有了
        #expect(throws: (any Error).self) { try GitRevision.resolve("HEAD~2", store: store) }
        // ^0 是"它自己"（git 约定），必须仍然可用
        let head = try GitRevision.resolve("HEAD", store: store)
        #expect(try GitRevision.resolve("HEAD^0", store: store) == head)
    }
}

@Suite("Git 历史遍历")
struct GitHistoryTests {

    @Test("⭐⭐ git_log：新的在前，且父提交链完整")
    func logIsNewestFirst() throws {
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        let head = try store.headCommitID()
        let commits = try store.log(from: head, limit: 10)

        #expect(commits.count == 2, "夹具仓库有 2 个提交")
        #expect(commits[0].summary == "second commit with parent", "最新的必须在最前面")
        #expect(commits[1].summary == "initial layout")
        #expect(commits[0].parents.first == commits[1].id, "父提交链必须接上")
        #expect(commits[1].parents.isEmpty, "根提交没有父提交")
    }

    @Test("⚠️ limit 必须真的生效（模型不该拉整段历史）")
    func limitIsHonored() throws {
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        let head = try store.headCommitID()
        #expect(try store.log(from: head, limit: 1).count == 1)
        #expect(try store.log(from: head, limit: 0).isEmpty)
    }

    @Test("⚠️ 合并历史不能重复输出同一个提交（多路径引用同一祖先）")
    func logDoesNotRepeatCommits() throws {
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        let head = try store.headCommitID()
        let commits = try store.log(from: head, limit: 50)
        let ids = commits.map(\.id)
        #expect(Set(ids).count == ids.count, "同一个提交出现了两次")
    }

    @Test("⭐ tree 扁平化：嵌套路径要用 / 连起来，子模块要跳过")
    func flattenNestedTree() throws {
        let repo = try statusRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = try GitObjectStore(workTreeURL: repo)
        let flat = try store.headTreeFlat()
        #expect(flat["README.md"] != nil)
        #expect(flat["src/a.py"] != nil, "嵌套路径必须用 / 连接")
        #expect(flat["src/deep/b.txt"] != nil, "更深的嵌套也要出来")
        #expect(flat["link.md"] != nil, "符号链接也是 blob")
        #expect(flat.count == 5, "HEAD 的 tree 里有 5 个 blob")
    }
}
