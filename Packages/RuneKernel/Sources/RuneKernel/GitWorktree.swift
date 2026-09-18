import Foundation

// MARK: - 工作区比较（git_status / git_diff 的数据面）
//
// 这里的核心不是"读文件"，而是**三方比较**：
//   HEAD（最后一次提交） ↔ index（暂存区） ↔ 工作区（磁盘上的真实文件）
//
// ⚠️ 为什么必须三方：
//   "文件被改了"与"改动已暂存"是**两件独立的事**，而用户/模型要做的下一步
//   完全不同（一个要 `add`，一个要 `commit`）。只比两方就永远分不清 ——
//   而分不清的代价是模型会重复 add、或者以为已经提交了。
//
// ⚠️ 另一条纪律：**忽略规则**（`.gitignore`）必须生效，否则 `git_status` 会把
//   `node_modules/`、`.build/` 之类几千个文件全列出来 —— 那既烧 token 又毫无信息量。
//   这里复用项目已有的 `IgnoreRules`（内核里为 grep/glob 写的那套），不另造一份。

/// 一个文件在三方里的状态。
public struct GitFileStatus: Sendable, Hashable {
    public enum Change: String, Sendable {
        case added
        case modified
        case deleted
        /// 只在 HEAD 里、index 与工作区都没有
        case removed
    }

    /// 仓库内相对路径
    public let path: String
    /// 已暂存的改动（index 相对 HEAD）
    public let staged: Change?
    /// 未暂存的改动（工作区相对 index）
    public let unstaged: Change?
    /// 未跟踪（不在 HEAD、也不在 index）
    public let isUntracked: Bool

    public init(path: String, staged: Change?, unstaged: Change?, isUntracked: Bool) {
        self.path = path
        self.staged = staged
        self.unstaged = unstaged
        self.isUntracked = isUntracked
    }

    /// 面向模型的一行描述（像 `git status --short` 的两列）。
    ///
    /// ⚠️ 两列的语义不能混：左列是**已暂存**、右列是**未暂存**。
    ///    写反了会让模型"提交了它以为还没 add 的东西"。
    public var shortLine: String {
        let left = staged.map(Self.letter) ?? " "
        let right = unstaged.map(Self.letter) ?? " "
        if isUntracked { return "?? \(path)" }
        return "\(left)\(right) \(path)"
    }

    static func letter(_ change: Change) -> String {
        switch change {
        case .added:    return "A"
        case .modified: return "M"
        case .deleted:  return "D"
        case .removed:  return "D"
        }
    }
}

public struct GitStatusReport: Sendable {
    public let branch: String?
    public let headCommit: SHA1?
    public let files: [GitFileStatus]

    public var isClean: Bool { files.isEmpty }
    public var stagedCount: Int { files.filter { $0.staged != nil }.count }
    public var unstagedCount: Int { files.filter { $0.unstaged != nil }.count }
    public var untrackedCount: Int { files.filter(\.isUntracked).count }

    /// 给模型看的文本。
    ///
    /// ⚠️ 空工作区要说清「干净」，而不是给一片空白 —— 空白会让模型以为工具坏了、
    ///    于是换个方式再试一遍（白烧 token）。
    public var modelFacingText: String {
        var lines: [String] = []
        lines.append("分支：\(branch ?? "(detached HEAD)")")
        if let headCommit {
            lines.append("HEAD：\(headCommit.hex.prefix(7))")
        } else {
            lines.append("HEAD：还没有提交")
        }
        if files.isEmpty {
            lines.append("工作区干净：没有已暂存、未暂存或未跟踪的改动。")
            return lines.joined(separator: "\n")
        }
        lines.append("已暂存 \(stagedCount) · 未暂存 \(unstagedCount) · 未跟踪 \(untrackedCount)")
        lines.append("")
        lines.append("（左列=已暂存，右列=未暂存；?? = 未跟踪）")
        for file in files { lines.append(file.shortLine) }
        return lines.joined(separator: "\n")
    }
}

public enum GitWorktree {

    /// 计算三方状态。
    ///
    /// - Parameters:
    ///   - headTree: HEAD 提交对应的**扁平化** path → blob ID（空仓库传空字典）
    ///   - ignore: 忽略规则（复用内核的 `IgnoreRules`）
    public static func status(store: GitObjectStore,
                              headTree: [String: SHA1],
                              ignore: IgnoreRules = .runeDefaults) throws -> [GitFileStatus] {
        let index = try store.index()
        var indexByPath: [String: GitIndexEntry] = [:]
        for entry in index { indexByPath[entry.path] = entry }

        let working = try scanWorkingTree(store: store, ignore: ignore)
        var allPaths = Set<String>()
        allPaths.formUnion(headTree.keys)
        allPaths.formUnion(indexByPath.keys)
        allPaths.formUnion(working.keys)

        var result: [GitFileStatus] = []
        for path in allPaths.sorted() {
            let inHead = headTree[path]
            let inIndex = indexByPath[path]
            let onDisk = working[path]

            // 已暂存：index 相对 HEAD
            var staged: GitFileStatus.Change?
            if let inIndex {
                if let inHead {
                    if inHead != inIndex.id { staged = .modified }
                } else {
                    staged = .added
                }
            } else if inHead != nil {
                staged = .removed        // HEAD 里有、index 里没有 = 已暂存删除
            }

            // 未暂存：工作区相对 index
            var unstaged: GitFileStatus.Change?
            if let inIndex {
                if let onDisk {
                    if onDisk != inIndex.id { unstaged = .modified }
                } else {
                    unstaged = .deleted
                }
            }

            let untracked = inHead == nil && inIndex == nil && onDisk != nil
            if staged == nil && unstaged == nil && !untracked { continue }
            result.append(GitFileStatus(path: path, staged: staged, unstaged: unstaged, isUntracked: untracked))
        }
        return result
    }

    /// 扫描工作区，算出每个文件的 blob ID（跳过 `.git` 与被忽略的路径）。
    ///
    /// ⚠️ 用**内容哈希**而不是 mtime/size 判断"改没改"：
    ///    index 里的 mtime 精度有限（秒级）、且 `touch` 会让它变而内容没变；
    ///    反过来，同秒内的改动可能 mtime 相同。内容哈希慢一点，但**不会骗人**。
    ///    手机上仓库规模有限，这个代价可以接受；而且它天然覆盖"改回原样"的情形。
    public static func scanWorkingTree(store: GitObjectStore,
                                       ignore: IgnoreRules = .runeDefaults) throws -> [String: SHA1] {
        let root = store.workTreeURL
        var result: [String: SHA1] = [:]
        // ⚠️ 项目自己的 `.gitignore` **必须叠加在内置默认之上**：
        //    只认内置默认的话，用户写的忽略规则会被无视（`.build/` 挡得住，
        //    但用户自己的 `generated/` 挡不住）—— 于是 `git_status` 列出一堆噪音。
        var rules = IgnoreRules.runeDefaults
        let gitignoreURL = root.appendingPathComponent(".gitignore")
        if let text = try? String(contentsOf: gitignoreURL, encoding: .utf8) {
            rules = rules.appending(IgnoreRules.parse(text, source: "工作区 .gitignore"))
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: [], errorHandler: { _, _ in true }
        ) else { return result }

        // ⚠️⚠️ 边界基准用的是**解析过软链的仓库根**（macOS 上 /var 与 /private/var 是同一个目录，T55），
        //      但**文件路径必须用原始 URL 算** —— 这两件事不能混。
        //
        //      踩过的坑：一开始我对文件也调 `standardizedFileURL.resolvingSymlinksInPath()`，
        //      于是 `link.md -> README.md` 的相对路径被算成了 **`README.md`**：
        //      符号链接自己从结果里消失、还覆盖了真 README 的条目。
        //      现象是 `git_status` 报 ` D link.md`（"链接被删了"）—— 而它明明就在那里。
        //      **解析软链只该用于判断"在不在仓库里"，绝不能用于得出"它叫什么名字"。**
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        for case let url as URL in enumerator {
            // ⚠️ 必须用 `attributesOfItem`（**不跟随**符号链接）而不是 `url.resourceValues`：
            //    `resourceValues` 会跟随链接，于是指向目录的符号链接会被看成目录。
            //    git 把符号链接当成一个普通条目（mode 120000）对待，我们也必须这样看它。
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let fileType = attributes[.type] as? FileAttributeType else { continue }
            let isSymlink = fileType == .typeSymbolicLink
            let isDirectory = fileType == .typeDirectory
            let isRegular = fileType == .typeRegular

            let base = root.standardizedFileURL.pathComponents
            let full = url.standardizedFileURL.pathComponents
            guard full.count > base.count, Array(full.prefix(base.count)) == base else { continue }
            let components = Array(full.dropFirst(base.count))
            let relative = components.joined(separator: "/")
            // ⚠️ `decide` 按**路径分段**判断，所以 `build/` 这类"只匹配目录"的规则
            //    才能真正生效。直接拿整串路径去匹配会漏掉它们。
            if rules.decide(components: components, isDirectory: isDirectory).isIgnored {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            guard isRegular || isSymlink else { continue }

            // ⚠️ 符号链接必须**读链接本身**，不能读它指向的文件：
            //    git 的 `120000` blob 存的是**链接目标字符串**（例如 `README.md` 这 9 个字节），
            //    而 `Data(contentsOf:)` 会**跟随链接**读到目标内容。
            //    于是每个符号链接都会被误报成"已修改"（即使它一个字节都没动），
            //    而用户看到的现象是"我什么都没改，git_status 却说改了"。
            let bytes: [UInt8]
            if isSymlink {
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { continue }
                bytes = Array(destination.utf8)
            } else {
                guard let data = try? Data(contentsOf: url) else { continue }
                bytes = [UInt8](data)
            }
            // ⚠️ blob ID 走"对象头 + 正文"，不是裸内容哈希（C48 记过的那条）
            result[relative] = SHA1.hash(Array("blob \(bytes.count)\u{0}".utf8) + bytes)
        }
        return result
    }

    /// 把一棵 tree 递归**扁平化**成 `path → blob ID`。
    public static func flatten(store: GitObjectStore, tree: SHA1, prefix: String = "") throws -> [String: SHA1] {
        var result: [String: SHA1] = [:]
        for entry in try store.object(tree).treeEntries() {
            let path = prefix.isEmpty ? entry.name : "\(prefix)/\(entry.name)"
            if entry.isTree {
                result.merge(try flatten(store: store, tree: entry.id, prefix: path)) { _, new in new }
            } else if entry.isGitlink {
                continue     // 子模块：内容不在这个仓库里
            } else {
                result[path] = entry.id
            }
        }
        return result
    }
}
