import Foundation
import Testing
@testable import RuneKernel

// MARK: - Git 工具（git_status / git_diff / git_log / git_show）端到端
//
// ⚠️ 这一组测的是**模型看到的东西**，不是内部函数：
//    同一个真实仓库，走完整条 `ToolCall → GitToolExecutor → ToolResult`。
//    理由是内核里已经有一组"模块自己是对的"测试（GitStatusTests 等），
//    而项目栽过好几次「模块全绿但根本没被调用」（T48/T49/T54）——
//    所以**工具层必须有一条端到端**，断言的是"发出去的那段文本里有什么"。

private func toolRepo() throws -> (URL, any GitWorkspaceResolving) {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/status-repo")
        .resolvingSymlinksInPath()
    let target = FileManager.default.temporaryDirectory.appendingPathComponent("rune-gittool-\(UUID().uuidString)")
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
    for name in ["README.md", "run.sh", "staged.txt", "brand-new.txt"] {
        try? FileManager.default.copyItem(at: source.appendingPathComponent(name),
                                          to: target.appendingPathComponent(name))
    }
    let linkPath = target.appendingPathComponent("link.md").path
    if FileManager.default.fileExists(atPath: linkPath) { try? FileManager.default.removeItem(atPath: linkPath) }
    try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: "README.md")
    try? FileManager.default.createDirectory(at: target.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
    for name in ["src/a.py", "src/deep/b.txt"] {
        try? FileManager.default.copyItem(at: source.appendingPathComponent(name),
                                          to: target.appendingPathComponent(name))
    }
    return (target, FileManagerVFS(baseURL: target))
}

private func run(_ name: String, _ arguments: JSONValue, resolver: any GitWorkspaceResolving) throws -> ToolResult {
    let executor = GitToolExecutor(resolver: resolver)
    let call = ToolCall(id: "c1", name: name, argumentsJSON: Data(arguments.canonicalString().utf8))
    return try executor.execute(call)
}

@Suite("Git 工具 —— git_status 端到端")
struct GitStatusToolTests {

    @Test("⭐⭐ 工具真的能用：报告里同时出现已暂存 / 未暂存 / 未跟踪")
    func statusReportsAllThree() throws {
        let (repo, resolver) = try toolRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let result = try run(ToolName.gitStatus, .object([:]), resolver: resolver)
        let text = result.summary
        #expect(result.status == .ok, "工具应当成功，实际：\(text)")
        #expect(text.contains(" M README.md"), "未暂存改动要在报告里，实际：\n\(text)")
        #expect(text.contains("A  staged.txt"), "已暂存改动要在报告里，实际：\n\(text)")
        #expect(text.contains("?? brand-new.txt"), "未跟踪文件要在报告里，实际：\n\(text)")
        #expect(text.contains("main"), "要报出当前分支")
        // 没改过的文件不该出现（否则报告全是噪音）
        #expect(!text.contains("src/a.py"), "没改过的文件不该出现在报告里")
    }

    @Test("⚠️ 不是仓库时给的是**可执行建议**，不是一句底层错误")
    func notARepositoryGivesActionableAdvice() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("rune-notrepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let executor = GitToolExecutor(resolver: FileManagerVFS(baseURL: empty))
        let result = try executor.execute(ToolCall(id: "c1", name: ToolName.gitStatus,
                                                   argumentsJSON: Data("{}".utf8)))
        #expect(result.status != .ok)
        let message = result.summary
        #expect(message.contains("不是") || message.contains("仓库"), "实际：\(message)")
        // ⚠️ 关键：必须给出下一步。否则模型只会换个路径再试一遍，白烧 token。
        #expect(message.contains("建议") || message.contains(".git"), "错误里必须带可执行的建议，实际：\(message)")
    }
}

@Suite("Git 工具 —— git_diff 的两侧语义")
struct GitDiffToolTests {

    @Test("⭐⭐ staged 参数决定比哪两侧（搞反会让模型提交错东西）")
    func stagedSelectsSides() throws {
        let (repo, resolver) = try toolRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        // staged=false → index ↔ 工作区：只该看到 README.md 的改动
        let unstaged = try run(ToolName.gitDiff, .object(["staged": .bool(false)]), resolver: resolver)
        #expect(unstaged.summary.contains("README.md"), "未暂存 diff 应当含 README.md，实际：\n\(unstaged.summary)")
        #expect(!unstaged.summary.contains("staged.txt"),
                "staged.txt 已与 index 一致，不该出现在未暂存 diff 里，实际：\n\(unstaged.summary)")

        // staged=true → HEAD ↔ index：只该看到 staged.txt（新文件）
        let staged = try run(ToolName.gitDiff, .object(["staged": .bool(true)]), resolver: resolver)
        #expect(staged.summary.contains("staged.txt"), "已暂存 diff 应当含 staged.txt，实际：\n\(staged.summary)")
        #expect(!staged.summary.contains("README.md"),
                "README.md 的改动还没 add，不该出现在已暂存 diff 里，实际：\n\(staged.summary)")
        // 新文件的 hunk 头应当是 -0,0（git 约定）
        #expect(staged.summary.contains("@@ -0,0"), "新文件按 git 约定应当是 -0,0，实际：\n\(staged.summary)")
    }

    @Test("⭐ file 参数可以只看一个文件")
    func fileParameterNarrowsOutput() throws {
        let (repo, resolver) = try toolRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let result = try run(ToolName.gitDiff,
                             .object(["staged": .bool(false), "file": .string("README.md")]),
                             resolver: resolver)
        #expect(result.summary.contains("README.md"))
        #expect(!result.summary.contains("staged.txt"))
    }
}

@Suite("Git 工具 —— git_log 与 git_show")
struct GitLogShowToolTests {

    @Test("⭐⭐ git_log：输出新的在前，且带短 SHA")
    func logOutput() throws {
        let (repo, resolver) = try toolRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let result = try run(ToolName.gitLog, .object(["limit": .int(10)]), resolver: resolver)
        let lines = result.summary.split(separator: "\n").map(String.init)
        #expect(lines.count == 2, "夹具仓库有 2 个提交，实际：\n\(result.summary)")
        #expect(lines[0].contains("second commit with parent"), "最新的必须在最前，实际：\n\(result.summary)")
        #expect(lines[1].contains("initial layout"))
        // 短 SHA 是 7 位（与 `git log --oneline` 一致的习惯）
        #expect(lines[0].hasPrefix("dd398da"), "应当以 7 位短 SHA 开头，实际：\(lines[0])")
    }

    @Test("⭐ git_log 的 limit 真的生效")
    func logLimit() throws {
        let (repo, resolver) = try toolRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let result = try run(ToolName.gitLog, .object(["limit": .int(1)]), resolver: resolver)
        #expect(result.summary.split(separator: "\n").count == 1, "实际：\n\(result.summary)")
    }

    @Test("⭐⭐ git_show：提交信息 + 该提交引入的改动")
    func showOutput() throws {
        let (repo, resolver) = try toolRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let result = try run(ToolName.gitShow, .object(["revision": .string("HEAD")]), resolver: resolver)
        let text = result.summary
        #expect(result.status == .ok, "实际：\(text)")
        #expect(text.contains("second commit with parent"), "要含提交信息")
        #expect(text.contains("Rune Dev"), "要含作者")
        #expect(text.contains("父提交"), "有父提交时要标明")
        // ⚠️ HEAD 那次提交改的是 README.md（真值来自 `git show --stat HEAD`）。
        //    staged.txt 只是**已暂存、还没提交**，所以它不该出现在 git_show 里 ——
        //    这正是"已暂存 ≠ 已提交"的现场证明，写错断言会把这条测试变成假的。
        #expect(text.contains("README.md"), "要含这次提交改动的文件，实际：\n\(text)")
        #expect(!text.contains("staged.txt"), "未提交的暂存内容不该出现在 git_show 里，实际：\n\(text)")
    }

    @Test("⭐ git_show 根提交：标成「根提交」，且不崩")
    func showRootCommit() throws {
        let (repo, resolver) = try toolRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let result = try run(ToolName.gitShow, .object(["revision": .string("HEAD~1")]), resolver: resolver)
        #expect(result.summary.contains("根提交"), "实际：\n\(result.summary)")
        #expect(result.summary.contains("initial layout"))
    }

    @Test("⚠️ 解析不了的 revision 要给可用的写法，不是一句「失败」")
    func badRevisionGivesAlternatives() throws {
        let (repo, resolver) = try toolRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let result = try run(ToolName.gitShow, .object(["revision": .string("no-such-branch")]), resolver: resolver)
        #expect(result.status != .ok)
        let message = result.summary
        #expect(message.contains("HEAD"), "错误里要列出可用写法，实际：\(message)")
    }

    @Test("⚠️ 缺少 revision 要被挡下（schema 层就该拦）")
    func missingRevisionIsRejected() throws {
        let (repo, resolver) = try toolRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let result = try run(ToolName.gitShow, .object([:]), resolver: resolver)
        #expect(result.status != .ok)
    }
}
