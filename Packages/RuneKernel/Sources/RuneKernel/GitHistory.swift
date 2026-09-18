import Foundation

// MARK: - revision 解析与提交图遍历
//
// `git_log` / `git_show` / `git_diff` 都要先回答同一个问题：
// **"HEAD~2" 到底指哪个提交？**
//
// ⚠️ 这里最重要的一条设计：**只支持能确定解释的写法**。
//    git 的 revision 语法极其宽松（`HEAD@{2}`、`:/regex`、`A...B`…），
//    宽松解析的代价是**歧义**：`HEAD~1` 与一个恰好叫 `HEAD~1` 的分支名
//    在宽松实现里会撞车，而我们无法判断用户想要哪个。
//    所以不认识的写法一律**明确拒绝并给出可用的替代**，而不是猜 ——
//    猜错会让模型基于一个错误的提交继续推理，而它不会察觉。

public enum GitRevision {
    /// 解析成提交 ID。
    ///
    /// 支持的写法（其余一律抛 `unsupportedRevision`）：
    ///   * `HEAD` · `<分支名>` · `refs/heads/<分支名>`
    ///   * `HEAD~N`（沿第一父提交回溯 N 步）
    ///   * `HEAD^N`（第 N 个父提交，`HEAD^` == `HEAD^1`）
    ///   * 16…40 位十六进制（缩写 SHA，**歧义时必须拒绝**）
    public static func resolve(_ text: String, store: GitObjectStore) throws -> SHA1 {
        let expression = text.trimmingCharacters(in: .whitespaces)
        guard !expression.isEmpty else { throw GitError.unsupportedRevision(text) }

        // ① 先取基底（HEAD / 分支 / SHA）
        var base: SHA1
        var rest: Substring
        if expression.hasPrefix("HEAD") {
            base = try store.headCommitID()
            rest = expression.dropFirst(4)
        } else if let tilde = expression.firstIndex(where: { $0 == "~" || $0 == "^" }) {
            // 有修饰符但没有 HEAD 前缀：形如 `main~2`
            let name = String(expression[..<tilde])
            base = try resolveBase(name, store: store)
            rest = expression[tilde...]
        } else {
            base = try resolveBase(expression, store: store)
            rest = ""
        }

        // ② 再逐个应用修饰符
        var cursor = rest.startIndex
        while cursor < rest.endIndex {
            let symbol = rest[cursor]
            cursor = rest.index(after: cursor)
            // 取数字（缺省为 1）
            var digits = ""
            while cursor < rest.endIndex, rest[cursor].isNumber {
                digits.append(rest[cursor])
                cursor = rest.index(after: cursor)
            }
            let count = Int(digits) ?? 1
            switch symbol {
            case "~":
                for _ in 0..<count { base = try firstParent(of: base, store: store) }
            case "^":
                base = try nthParent(of: base, store: store, index: count)
            default:
                throw GitError.unsupportedRevision(text)
            }
        }
        return base
    }

    static func resolveBase(_ name: String, store: GitObjectStore) throws -> SHA1 {
        if name == "HEAD" { return try store.headCommitID() }
        // 引用优先（分支名/标签），再退回 SHA
        if let id = try? store.readReference("refs/heads/\(name)") { return id }
        if let id = try? store.readReference("refs/tags/\(name)") { return id }
        if let id = try? store.readReference(name) { return id }
        if let id = try resolveAbbreviatedSHA(name, store: store) { return id }
        throw GitError.referenceNotFound(name)
    }

    /// 缩写 SHA：**长度 ≥ 4 且唯一**才接受。
    ///
    /// ⚠️ 歧义（多个对象同前缀）时必须拒绝，不能"取第一个"：
    ///    取第一个的实现在大多数仓库上都能跑，只在某个仓库上某一天给出错误的提交 ——
    ///    这是最难复现、也最难归因的一类 bug。
    static func resolveAbbreviatedSHA(_ text: String, store: GitObjectStore) throws -> SHA1? {
        guard text.count >= 4, text.count <= 40,
              text.allSatisfy({ $0.isHexDigit }) else { return nil }
        if text.count == 40, let id = SHA1(hex: text) { return id }

        let lower = text.lowercased()
        var matches: [SHA1] = []
        // 先查松散对象
        let objectsDir = store.gitDirectoryURL.appendingPathComponent("objects")
        if let prefixDirs = try? FileManager.default.contentsOfDirectory(atPath: objectsDir.path) {
            for directory in prefixDirs where directory.count == 2 && directory.allSatisfy({ $0.isHexDigit }) {
                let directoryURL = objectsDir.appendingPathComponent(directory)
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else { continue }
                for file in files where file.count == 38 {
                    let hex = directory + file
                    if hex.hasPrefix(lower), let id = SHA1(hex: hex) { matches.append(id) }
                }
            }
        }
        // 再查 pack
        for pack in store.packs() {
            for id in pack.objectIDs where id.hex.hasPrefix(lower) { matches.append(id) }
        }
        if matches.count > 1 {
            throw GitError.ambiguousRevision("\(text)（匹配到 \(matches.count) 个对象）")
        }
        return matches.first
    }

    static func commit(_ id: SHA1, store: GitObjectStore) throws -> GitCommit {
        try store.object(id).commit(id: id)
    }

    /// `~N`：沿**第一父提交**回溯 N 步。
    static func firstParent(of id: SHA1, store: GitObjectStore) throws -> SHA1 {
        let commit = try commit(id, store: store)
        guard let parent = commit.parents.first else {
            throw GitError.unsupportedRevision("\(id.hex.prefix(7)) 没有父提交（~ 走不过去）")
        }
        return parent
    }

    /// `^N`：第 N 个父提交。`^0` 表示"这个提交自己"（git 的约定）。
    static func nthParent(of id: SHA1, store: GitObjectStore, index: Int) throws -> SHA1 {
        if index == 0 { return id }
        let commit = try commit(id, store: store)
        guard commit.parents.count >= index else {
            throw GitError.unsupportedRevision("\(id.hex.prefix(7)) 只有 \(commit.parents.count) 个父提交，要不了第 \(index) 个")
        }
        return commit.parents[index - 1]
    }
}

extension GitObjectStore {

    /// 从某个提交出发，按**提交时间倒序**遍历历史。
    ///
    /// ⚠️ 用优先队列按 committer 时间排序，而不是简单 DFS：
    ///    合并历史里 DFS 会给出"时间上跳来跳去"的顺序，而 `git log` 的用户预期是
    ///    **新的在前**。同时用一个已访问集合防重复（合并提交会把同一个祖先
    ///    从多条路径引到 —— 不去重就会重复输出，甚至在有循环的损坏仓库里死循环）。
    public func log(from start: SHA1, limit: Int = 20) throws -> [GitCommit] {
        guard limit > 0 else { return [] }
        var pending: [(date: Int, id: SHA1)] = [(Int.max, start)]
        var seen: Set<SHA1> = []
        var result: [GitCommit] = []
        while !pending.isEmpty, result.count < limit {
            // 取时间最大的（新→旧）。仓库规模有限，线性取最大足够，且不引入堆的复杂度。
            var bestIndex = 0
            for (index, item) in pending.enumerated() where item.date > pending[bestIndex].date { bestIndex = index }
            let item = pending.remove(at: bestIndex)
            if seen.contains(item.id) { continue }
            seen.insert(item.id)

            let commit = try GitRevision.commit(item.id, store: self)
            result.append(commit)
            for parent in commit.parents {
                if !seen.contains(parent) { pending.append((commit.committer.timestamp, parent)) }
            }
        }
        return result
    }

    /// HEAD 提交的 tree 扁平化成 `path → blob ID`（空仓库返回空字典）。
    public func headTreeFlat() throws -> [String: SHA1] {
        do {
            let head = try headCommitID()
            let commit = try GitRevision.commit(head, store: self)
            return try GitWorktree.flatten(store: self, tree: commit.tree)
        } catch GitError.emptyRepository {
            return [:]
        }
    }

    /// 某个提交的 tree 扁平化。
    public func treeFlat(ofCommit id: SHA1) throws -> [String: SHA1] {
        let commit = try GitRevision.commit(id, store: self)
        return try GitWorktree.flatten(store: self, tree: commit.tree)
    }
}
