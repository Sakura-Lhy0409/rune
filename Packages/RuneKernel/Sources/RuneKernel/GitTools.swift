import Foundation

// MARK: - Git 工具的只读实现（git_status / git_diff / git_log / git_show）
//
// ⚠️ 为什么单独一层而不塞进 `LocalToolExecutor`：
//    Git 工具需要一个**真实文件系统路径**（`.git` 就在磁盘上），而 `LocalToolExecutor`
//    面向 `VFS` 抽象（内存实现也在用）。把两者混在一起，会让"内存 VFS"也必须
//    假装有一个 `.git` —— 那是把测试用的便利泄漏进了产品语义。
//    所以这里显式声明依赖：**能给出真实路径才提供 Git 工具**，否则如实报告不可用。
//
// ⚠️ 本层**只读**。`git_add` / `git_commit` 等写操作需要额外的能力令牌与审批语义，
//    不在这一片（它们的风险级是 `.modifying`/`.dangerous`，走的是另一条审批路径）。

/// 把 `VFS` 映射到真实路径的能力。Git 工具必须要有它。
public protocol GitWorkspaceResolving: Sendable {
    /// 把 VFS 路径解析成磁盘上的目录 URL。解析不到返回 nil。
    func fileSystemURL(for path: VFSPath) -> URL?
}

extension FileManagerVFS: GitWorkspaceResolving {
    public func fileSystemURL(for path: VFSPath) -> URL? {
        // ⚠️ 只支持工作区挂载：`.rune/libs` 之类的其他挂载点不该被当成 git 仓库。
        guard path.mount == .workspace else { return nil }
        var candidate = baseURL
        for component in path.components {
            // ⚠️ 逐段拼接时必须挡住 `..`：放过去就等于让模型用一个相对路径逃出工作区
            //    （项目记过的 T24/T25 是同一类：**被检查的路径 ≠ 实际操作的路径**）。
            guard component != "..", component != "." , !component.isEmpty else { return nil }
            candidate.appendPathComponent(component)
        }
        return candidate
    }
}

public struct GitToolExecutor: ToolExecuting {
    public let resolver: any GitWorkspaceResolving
    /// 默认仓库路径（工具没给 `path` 时用）
    public let defaultPath: VFSPath
    public let diffOptions: GitDiffOptions
    /// 允许一次列出的最大条目数（防止把整段历史灌进上下文）
    public let maxLogEntries: Int

    public static let names: Set<String> = [
        ToolName.gitStatus, ToolName.gitDiff, ToolName.gitLog, ToolName.gitShow,
    ]

    public init(resolver: any GitWorkspaceResolving,
                defaultPath: VFSPath = VFSPath(mount: .workspace),
                diffOptions: GitDiffOptions = .default,
                maxLogEntries: Int = 200) {
        self.resolver = resolver
        self.defaultPath = defaultPath
        self.diffOptions = diffOptions
        self.maxLogEntries = maxLogEntries
    }

    public func execute(_ call: ToolCall) throws -> ToolResult {
        let args: JSONValue
        do { args = try call.arguments() }
        catch {
            return .failure(callID: call.id, error: ToolError(
                kind: .invalidArguments, modelFacingMessage: "参数不是合法 JSON。"))
        }
        // ⚠️ 错误必须**返回 `.failure` 结果**，不能抛出去：
        //    `ToolExecuting` 的约定是"工具失败也是一种结果"（`LocalToolExecutor` 就是这么做的），
        //    抛异常会让调用方（TurnRunner / AgentRuntime）把它当成"工具实现崩了"，
        //    而模型则完全看不到失败原因与建议 —— 它只会换个参数再试一遍，白烧 token。
        do {
            switch call.name {
            case ToolName.gitStatus: return try status(call, args)
            case ToolName.gitDiff:   return try diff(call, args)
            case ToolName.gitLog:    return try log(call, args)
            case ToolName.gitShow:   return try show(call, args)
            default:
                return .failure(callID: call.id, error: ToolError(
                    kind: .unknownTool, modelFacingMessage: "GitToolExecutor 不认识工具 `\(call.name)`。"))
            }
        } catch let error as ToolError {
            return .failure(callID: call.id, error: error)
        } catch let error as GitError {
            return .failure(callID: call.id, error: ToolError(
                kind: .invalidArguments,
                modelFacingMessage: "Git 操作失败：\(error.description)",
                suggestion: "确认仓库状态与 revision 写法；`git_log` 不依赖 revision，可以先看历史。"))
        } catch {
            // ⚠️ 兜底分支**必须给出可执行的建议**，不能只说"失败了"。
            //    模型看到没有下一步的错误，只会原样重发 —— 而 `git_log` 不需要 revision，
            //    是它在 Git 工具里唯一"一定能跑"的那个，所以把它作为建议给出。
            return .failure(callID: call.id, error: ToolError(
                kind: .other,
                modelFacingMessage: "Git 操作失败：\(error)",
                suggestion: "先用 `git_log(limit: 5)` 确认仓库能读、HEAD 指向哪里；"
                    + "再检查路径是否在仓库内、revision 是否是 `HEAD` / `HEAD~1` / 分支名 / ≥4 位 SHA。"))
        }
    }

    // MARK: 公共

    /// 取仓库路径（工具参数里的 `path`，缺省用工作区根）。
    private func repository(_ args: JSONValue) throws -> GitObjectStore {
        let option = args.value(at: ["path"])?.stringValue
        var path = defaultPath
        if let option, !option.isEmpty, option != "." {
            // ⚠️ 走**与策略引擎同一个** `CallPaths.resolve` ——
            //    "被检查的路径"和"实际操作的路径"必须一致（T24/T25）。
            guard let parsed = CallPaths.resolve([option], base: defaultPath).paths.first else {
                throw ToolError(kind: .invalidArguments,
                                modelFacingMessage: "`path` 解析失败：\(option)",
                                suggestion: "用工作区相对路径，例如 `path: \".\"` 或 `path: \"src\"`。")
            }
            path = parsed
        }
        guard let url = resolver.fileSystemURL(for: path) else {
            throw ToolError(kind: .capabilityDenied,
                            modelFacingMessage: "这个工作区没有真实文件系统路径，无法执行 Git 操作。",
                            suggestion: "Git 工具只在磁盘工作区可用；内存工作区请改用文件工具。")
        }
        do {
            return try GitObjectStore(workTreeURL: url)
        } catch let error as GitError {
            // ⚠️ 「不是仓库」要给出**可执行的建议**，而不是把底层错误原样抛出去：
            //    模型看到"not a repository"只会换个路径再试一遍，白烧 token。
            throw ToolError(kind: .invalidArguments,
                            modelFacingMessage: "\(path.description) 不是一个 git 仓库。",
                            suggestion: "确认这个目录下有 `.git`；如果是新建项目，还没有初始化过 Git。（\(error.description)）")
        }
    }

    // MARK: git_status

    private func status(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        let store = try repository(args)
        let headTree = try store.headTreeFlat()
        let files = try GitWorktree.status(store: store, headTree: headTree)
        let head: SHA1? = try? store.headCommitID()
        let report = GitStatusReport(branch: store.currentBranch(), headCommit: head, files: files)
        return .ok(callID: call.id, summary: report.modelFacingText)
    }

    // MARK: git_diff

    private func diff(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        let store = try repository(args)
        let staged = args.value(at: ["staged"])?.boolValue ?? false
        let onlyFile = args.value(at: ["file"])?.stringValue

        // 两两比较的哪两侧，取决于 `staged`：
        //   staged=false → index ↔ 工作区（"我还没 add 的改动"）
        //   staged=true  → HEAD  ↔ index （"我已经 add、准备提交的改动"）
        // ⚠️ 搞反了会让模型提交它没打算提交的东西 —— 所以这一条在文档与测试里都写死。
        let index = try store.index()
        var indexByPath: [String: SHA1] = [:]
        for entry in index { indexByPath[entry.path] = entry.id }
        let headTree = try store.headTreeFlat()

        let oldSide: [String: SHA1] = staged ? headTree : indexByPath
        let newSide: [String: SHA1]
        if staged {
            newSide = indexByPath
        } else {
            newSide = try GitWorktree.scanWorkingTree(store: store)
        }

        var paths = Set(oldSide.keys).union(newSide.keys)
        if let onlyFile, !onlyFile.isEmpty { paths = paths.filter { $0 == onlyFile || $0.hasSuffix("/" + onlyFile) } }
        guard !paths.isEmpty else {
            let what = staged ? "暂存区与 HEAD 之间没有差异。" : "工作区与暂存区之间没有差异。"
            return .ok(callID: call.id, summary: what)
        }

        var sections: [String] = []
        var totalBytes = 0
        /// ⚠️ 一次 diff 的输出必须封顶：一个改动巨大的文件能产出几 MB 文本，
        ///    直接灌进上下文会撑爆窗口并烧掉用户的钱。
        let maxBytes = 256 * 1024
        for path in paths.sorted() {
            let oldID = oldSide[path]
            let newID = newSide[path]
            if oldID == newID { continue }
            let oldBytes = oldID.flatMap { try? store.object($0).body }
            let newBytes: [UInt8]?
            if staged {
                newBytes = newID.flatMap { try? store.object($0).body }
            } else {
                // 未暂存时新侧是**磁盘上的文件**，不是对象
                newBytes = try? readWorkingFile(store: store, relativePath: path)
            }
            let text = GitObjectStore.blobDiff(old: oldBytes, new: newBytes,
                                               oldLabel: staged ? "HEAD:\(path)" : "index:\(path)",
                                               newLabel: staged ? "index:\(path)" : "工作区:\(path)",
                                               options: diffOptions)
            guard !text.isEmpty else { continue }
            if totalBytes + text.utf8.count > maxBytes {
                sections.append("…（其余文件因输出上限未显示；请用 `file` 参数逐个查看）")
                break
            }
            totalBytes += text.utf8.count
            sections.append(text)
        }
        if sections.isEmpty { return .ok(callID: call.id, summary: "没有可显示的差异。") }
        return .ok(callID: call.id, summary: sections.joined(separator: "\n"))
    }

    private func readWorkingFile(store: GitObjectStore, relativePath: String) throws -> [UInt8]? {
        let url = store.workTreeURL.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return [UInt8](data)
    }

    // MARK: git_log

    private func log(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        let store = try repository(args)
        let limit = min(args.value(at: ["limit"])?.intValue ?? 20, maxLogEntries)
        let onlyFile = args.value(at: ["file"])?.stringValue
        let start = try store.headCommitID()
        let commits = try store.log(from: start, limit: limit)

        var lines: [String] = []
        for commit in commits {
            // 有 `file` 时只列**碰过这个文件**的提交（git log -- path 的语义）
            if let onlyFile, !onlyFile.isEmpty {
                let changed = try commitTouches(store: store, commit: commit, path: onlyFile)
                if !changed { continue }
            }
            lines.append("\(commit.id.hex.prefix(7)) \(commit.committer.date.formatted(.iso8601.year().month().day())) \(commit.summary)")
        }
        if lines.isEmpty {
            return .ok(callID: call.id, summary: onlyFile.map { "没有提交碰过 \($0)。" } ?? "没有提交。")
        }
        return .ok(callID: call.id, summary: lines.joined(separator: "\n"))
    }

    /// 这个提交有没有碰过某个路径（`git log -- <path>` 的核心）。
    ///
    /// ⚠️ 判据是"**与任一父提交相比**该路径的 blob 变了"，
    ///    不是"该路径存在于这棵树里" —— 后者会把"文件一直都在、这次没改"也算进来。
    ///    根提交则只要文件存在就算（它确实"引入"了这些文件）。
    private func commitTouches(store: GitObjectStore, commit: GitCommit, path: String) throws -> Bool {
        let current = try GitWorktree.flatten(store: store, tree: commit.tree)
        let target = current[path] ?? current.first { $0.key.hasSuffix("/" + path) }?.value
        if commit.parents.isEmpty { return target != nil }
        for parentID in commit.parents {
            let parent = try GitRevision.commit(parentID, store: store)
            let parentFlat = try GitWorktree.flatten(store: store, tree: parent.tree)
            let parentTarget = parentFlat[path] ?? parentFlat.first { $0.key.hasSuffix("/" + path) }?.value
            if parentTarget != target { return true }
        }
        return false
    }

    // MARK: git_show

    private func show(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        let store = try repository(args)
        guard let revision = args.value(at: ["revision"])?.stringValue, !revision.isEmpty else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `revision`。",
                            suggestion: "例如 `revision: \"HEAD\"` 或 `revision: \"HEAD~1\"`。")
        }
        let id: SHA1
        do {
            id = try GitRevision.resolve(revision, store: store)
        } catch let error as GitError {
            throw ToolError(kind: .invalidArguments,
                            modelFacingMessage: "解析不了 `\(revision)`：\(error.description)",
                            suggestion: "可用的写法：`HEAD`、`HEAD~2`、`HEAD^`、分支名、或提交 SHA（≥4 位）。")
        }
        let object = try store.object(id)

        // 非 commit（tag 等）先解引用一层
        guard object.type == .commit else {
            throw ToolError(kind: .invalidArguments,
                            modelFacingMessage: "`\(revision)` 指向的是 \(object.type.rawValue)，不是提交。",
                            suggestion: "换一个提交 SHA 或分支名。")
        }
        let commit = try object.commit(id: id)

        var lines: [String] = []
        lines.append("提交 \(commit.id.hex)")
        lines.append("作者 \(commit.author.name) <\(commit.author.email)>")
        lines.append("时间 \(commit.committer.date.formatted(.iso8601))")
        if commit.parents.count > 1 {
            lines.append("合并提交，父提交：\(commit.parents.map { $0.hex.prefix(7) }.joined(separator: " "))")
        } else if let parent = commit.parents.first {
            lines.append("父提交 \(parent.hex.prefix(7))")
        } else {
            lines.append("根提交（没有父提交）")
        }
        lines.append("")
        lines.append(commit.message.trimmingCharacters(in: .newlines))

        // 与第一个父提交比较，给出改动
        let currentFlat = try GitWorktree.flatten(store: store, tree: commit.tree)
        let parentFlat: [String: SHA1]
        if let parent = commit.parents.first {
            let parentCommit = try GitRevision.commit(parent, store: store)
            parentFlat = try GitWorktree.flatten(store: store, tree: parentCommit.tree)
        } else {
            parentFlat = [:]
        }

        var sections: [String] = []
        var totalBytes = 0
        let maxBytes = 256 * 1024
        for path in Set(currentFlat.keys).union(parentFlat.keys).sorted() {
            if currentFlat[path] == parentFlat[path] { continue }
            let oldBytes = parentFlat[path].flatMap { try? store.object($0).body }
            let newBytes = currentFlat[path].flatMap { try? store.object($0).body }
            let text = GitObjectStore.blobDiff(old: oldBytes, new: newBytes,
                                               oldLabel: "a/\(path)", newLabel: "b/\(path)",
                                               options: diffOptions)
            guard !text.isEmpty else { continue }
            if totalBytes + text.utf8.count > maxBytes {
                sections.append("…（其余文件因输出上限未显示）")
                break
            }
            totalBytes += text.utf8.count
            sections.append(text)
        }
        if !sections.isEmpty {
            lines.append("")
            lines.append(contentsOf: sections)
        }
        return .ok(callID: call.id, summary: lines.joined(separator: "\n"))
    }
}
