import Foundation

// MARK: - Git 对象模型与读取
//
// ⚠️ 为什么 Rune 要自己实现 Git：
//    iOS **不允许 fork/exec**（`Process` 在 iOS 上不存在），所以手机上**没有系统 git 可用**。
//    要兑现「工具循环、文件系统、Git 全在设备上完成」这条铁律，就只有一条路：
//    自己读 `.git` 的字节。这不是"重复造轮子"，是平台约束下唯一的实现方式。
//
// 仓库格式的依据（照抄规范，不凭直觉）：
//   * 松散对象：`.git/objects/<sha1 前2位>/<后38位>`，内容是 `zlib("<type> <len>\0" + 正文)`
//   * tree 条目：`<mode> <name>\0<20 字节原始 SHA-1>`（⚠️ name 与 SHA 之间是 **NUL**，不是空格）
//   * mode 是 ASCII 八进制：`100644` 普通文件、`100755` 可执行、`120000` 符号链接、`40000` 子树
//   * commit 正文：`tree <id>\n(parent <id>\n)*author …\ncommitter …\n\n<message>`
//   * 引用：`.git/refs/heads/<branch>` 存 40 位十六进制；`.git/HEAD` 可能是 `ref: <路径>`（符号引用）

/// Git 对象的类型（四种之一）。
public enum GitObjectType: String, Sendable, Hashable {
    case blob
    case tree
    case commit
    /// 注解标签（`git tag -a`）。**不指向 tree**，要解引用后才能用。
    case tag

    /// 该类型能否被 tree 直接引用（gitlink 是 commit，由子模块使用）
    var isTreeReachable: Bool { self == .blob || self == .tree || self == .commit }
}

/// 一个解出来的 git 对象。
public struct GitObject: Sendable {
    public let type: GitObjectType
    /// 正文（不含 `"<type> <len>\0"` 头）
    public let body: [UInt8]
    /// 计算出来的对象 ID（已在读取时校验过与路径一致）
    public let id: SHA1

    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// tree 里的一个条目。
///
/// ⚠️ `mode` 保留成**原始字符串**而不是转成整数：
///    git 的 mode 允许 `040000` 与 `40000` 两种写法（前导零），
///    转成整数会丢掉"原始写的是什么"，而写回 tree 时必须逐字节还原 ——
///    否则同一个目录会因为 mode 表示不同而产生不同的 tree ID（T35 同类：比的是字节）。
public struct GitTreeEntry: Sendable, Hashable {
    public let mode: String
    public let name: String
    public let id: SHA1

    /// 子树（mode `40000`）
    public var isTree: Bool { mode == "40000" || mode == "040000" }
    /// 符号链接（mode `120000`）—— 正文是链接目标
    public var isSymlink: Bool { mode == "120000" }
    /// 可执行位（mode `100755`）
    public var isExecutable: Bool { mode == "100755" }
    /// 子模块（mode `160000`）—— 引用的是一个 commit，不是 blob
    public var isGitlink: Bool { mode == "160000" }

    /// 面向模型/UI 的类型名（`git ls-tree` 的第三列）
    public var typeName: String {
        if isTree { return "tree" }
        if isGitlink { return "commit" }
        return "blob"
    }
}

/// 一个提交。
public struct GitCommit: Sendable {
    public let id: SHA1
    public let tree: SHA1
    /// 父提交（合并提交会有多个；根提交为空）
    public let parents: [SHA1]
    public let author: GitSignature
    public let committer: GitSignature
    public let message: String

    /// 标题行（第一个空行之前的第一行）
    public var summary: String {
        message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
    }

    /// 正文（标题之后的部分）
    public var body: String {
        let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count > 1 else { return "" }
        return String(parts[1]).trimmingCharacters(in: .newlines)
    }
}

/// `Name <email> <unix 秒> <±HHMM>`。
public struct GitSignature: Sendable, Hashable {
    public let name: String
    public let email: String
    /// Unix 时间戳（秒）
    public let timestamp: Int
    /// 时区偏移，例如 `+0800`
    public let timezone: String

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
}

/// Git 操作的失败原因。
///
/// ⚠️ 与 InflateError 同样的立场：**分别报出**。
///    「对象不存在」与「对象损坏」对用户是完全不同的两件事 ——
///    前者是"你写错了 revision"，后者是"仓库坏了，别乱动"。
public enum GitError: Error, Equatable, CustomStringConvertible {
    case notARepository(String)
    case objectNotFound(SHA1)
    case malformedObject(reason: String)
    /// 对象内容与它的 ID 不符（内容被改过）
    case objectHashMismatch(expected: SHA1, actual: SHA1)
    case unsupportedRevision(String)
    case ambiguousRevision(String)
    case referenceNotFound(String)
    case emptyRepository

    public var description: String {
        switch self {
        case .notARepository(let path):
            return "\(path) 不是一个 git 仓库（没有找到 .git 目录）。"
        case .objectNotFound(let id):
            return "仓库里没有对象 \(id.hex)（可能 revision 写错了，或是浅克隆）。"
        case .malformedObject(let reason):
            return "对象内容不合法：\(reason)"
        case .objectHashMismatch(let expected, let actual):
            return "对象 \(expected.hex) 的内容与 ID 不符（实际算出 \(actual.hex)）—— 仓库已损坏。"
        case .unsupportedRevision(let text):
            return "暂不支持这种 revision 写法：\(text)"
        case .ambiguousRevision(let text):
            return "revision \(text) 有歧义。"
        case .referenceNotFound(let name):
            return "找不到引用 \(name)。"
        case .emptyRepository:
            return "这是一个还没有任何提交的空仓库。"
        }
    }
}

// MARK: - 对象读取

/// 只读的 git 对象库（松松散对象）。
///
/// ⚠️ **只支持松散对象，不支持 packfile**。这不是疏忽，是刻意的分期：
///    `git clone` 下来的仓库对象几乎全在 `.git/objects/pack/*.pack` 里，
///    所以 packfile + delta 解析必须排在写路径之前 —— 见 PROJECT_STATE §6。
///    当前能力足以处理"本地仓库刚提交的几个对象"，不足以处理克隆来的历史。
public struct GitObjectStore: Sendable {
    /// 仓库根目录（含 `.git` 的目录）
    public let workTreeURL: URL
    /// `.git` 目录（可能是文件，见 worktree/gitdir 情形）
    public let gitDirectoryURL: URL

    /// 单个对象解压后的上限。
    ///
    /// ⚠️ 比 Inflate 的默认值小得多：git 单个对象超过 100MB 已经很不正常，
    ///    而移动端内存是共享的（iOS jetsam 会杀掉整个 App，T38）。
    public static let maxObjectBytes = 100 * 1024 * 1024

    public init(workTreeURL: URL) throws {
        self.workTreeURL = workTreeURL
        let dotGit = workTreeURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            throw GitError.notARepository(workTreeURL.path)
        }
        if isDirectory.boolValue {
            gitDirectoryURL = dotGit
        } else {
            // `.git` 是个文件：`gitdir: <路径>`（worktree / submodule 的情形）。
            // ⚠️ 不处理它的话，`git_status` 在工作区里会报"不是仓库"，而用户明明在仓库里。
            let content = (try? String(contentsOf: dotGit, encoding: .utf8)) ?? ""
            let line = content.split(separator: "\n").first.map(String.init) ?? ""
            guard line.hasPrefix("gitdir:") else { throw GitError.notARepository(workTreeURL.path) }
            let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDirectoryURL = raw.hasPrefix("/")
                ? URL(fileURLWithPath: raw)
                : workTreeURL.appendingPathComponent(raw).standardizedFileURL
        }
    }

    /// 读一个对象并**校验它的 ID**。
    ///
    /// ⚠️ 校验不是可选项：`.git` 里的字节可能被改过（用户手改、磁盘损坏、同步冲突）。
    ///    不校验的话，我们会拿着"ID 说是 A、内容是 B"的对象继续往下算，
    ///    最后给出的 diff / log 全是错的，而且**不报任何错**。
    ///
    /// ⚠️ 查找顺序：**先松散对象，再 pack**。反过来的话，一个刚 `git add` 进来的对象
    ///    会被 pack 里的旧版本盖住 —— 那正是"模型刚改完、我们却看到旧内容"这类最难查的错。
    public func object(_ id: SHA1) throws -> GitObject {
        if let loose = try? looseObject(id) { return loose }
        if let packed = try? packedObject(id) { return packed }
        throw GitError.objectNotFound(id)
    }

    /// 读松散对象（`.git/objects/xx/yyyy…`）。
    func looseObject(_ id: SHA1) throws -> GitObject {
        let raw = try compressedObjectBytes(id)
        let inflated = try Inflate.zlib(raw, outputLimit: Self.maxObjectBytes)
        return try Self.parseObject(inflated, expecting: id)
    }

    /// 从 `.git/objects/pack/*.pack` 里读 —— **clone 下来的仓库对象几乎全在这**。
    func packedObject(_ id: SHA1) throws -> GitObject {
        for pack in packs() where pack.contains(id) {
            return try pack.object(id) { [self] base in try looseObject(base) }
        }
        throw GitError.objectNotFound(id)
    }

    /// 仓库里的 pack 列表。
    ///
    /// ⚠️ 每次调用都重新枚举目录，**刻意不缓存**：`git fetch` 之后会新增 pack 文件，
    ///    缓存住的话新拉下来的对象会"看不见"，而用户会以为 fetch 失败了。
    ///    枚举一个目录的代价，远小于排查这类问题。
    public func packs() -> [GitPack] {
        let directory = gitDirectoryURL.appendingPathComponent("objects/pack")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var result: [GitPack] = []
        for name in names.sorted() where name.hasSuffix(".idx") {
            let indexURL = directory.appendingPathComponent(name)
            let packURL = directory.appendingPathComponent(String(name.dropLast(4)) + ".pack")
            guard FileManager.default.fileExists(atPath: packURL.path) else { continue }
            if let pack = try? GitPack(packURL: packURL, indexURL: indexURL) { result.append(pack) }
        }
        return result
    }

    /// 只读松散对象文件（不解压）。
    func compressedObjectBytes(_ id: SHA1) throws -> [UInt8] {
        let hex = id.hex
        let directory = gitDirectoryURL.appendingPathComponent("objects/\(hex.prefix(2))")
        let file = directory.appendingPathComponent(String(hex.dropFirst(2)))
        guard let data = try? Data(contentsOf: file) else { throw GitError.objectNotFound(id) }
        return [UInt8](data)
    }

    /// 解析 `"<type> <bytelen>\0" + 正文`，并核对长度与 ID。
    static func parseObject(_ bytes: [UInt8], expecting id: SHA1) throws -> GitObject {
        // 头与正文之间是第一个 NUL。⚠️ 用 NUL 而不是空格定位：正文里可以有空格与换行。
        guard let separator = bytes.firstIndex(of: 0) else {
            throw GitError.malformedObject(reason: "缺少对象头与正文之间的 NUL 分隔符")
        }
        let header = String(decoding: bytes[0..<separator], as: UTF8.self)
        // 头是 "<type> <len>"，正好一个空格
        let parts = header.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, let type = GitObjectType(rawValue: String(parts[0])),
              let length = Int(parts[1]) else {
            throw GitError.malformedObject(reason: "对象头不是「<type> <len>」：\(header)")
        }
        let body = Array(bytes[(separator + 1)...])
        // ⚠️ 长度不符必须拒：它是"内容被截断/多出来"的唯一信号。
        //    git 自己也校验这个（否则 pack 里的 delta 链会悄悄错位）。
        guard body.count == length else {
            throw GitError.malformedObject(reason: "头部声明长度 \(length)，实际正文 \(body.count) 字节")
        }
        // ⚠️ ID 必须等于 SHA1(整个字节序列)，不只是正文
        let actual = SHA1.hash(bytes)
        guard actual == id else { throw GitError.objectHashMismatch(expected: id, actual: actual) }
        return GitObject(type: type, body: body, id: id)
    }
}

// MARK: - tree / commit 解析

extension GitObject {

    /// 解析 tree 正文。
    ///
    /// 格式：`<mode> <name>\0<20 字节原始 SHA-1>` 重复，直到正文用完。
    /// ⚠️ 两个易错点：
    ///    ① mode 与 name 之间是**空格**，name 与 SHA 之间是 **NUL** —— 搞反就全错；
    ///    ② SHA 是**原始 20 字节**，不是 40 个 ASCII 字符。按文本处理会得到长度翻倍的垃圾。
    public func treeEntries() throws -> [GitTreeEntry] {
        guard type == .tree else {
            throw GitError.malformedObject(reason: "期望 tree，实际是 \(type.rawValue)")
        }
        var entries: [GitTreeEntry] = []
        var index = 0
        while index < body.count {
            guard let space = body[index...].firstIndex(of: 0x20) else {
                throw GitError.malformedObject(reason: "tree 条目缺少 mode 与 name 之间的空格（偏移 \(index)）")
            }
            let mode = String(decoding: body[index..<space], as: UTF8.self)
            guard let nul = body[space...].firstIndex(of: 0) else {
                throw GitError.malformedObject(reason: "tree 条目缺少 name 之后的 NUL（偏移 \(space)）")
            }
            let nameBytes = body[(space + 1)..<nul]
            let name = String(decoding: nameBytes, as: UTF8.self)
            let hashStart = nul + 1
            guard hashStart + 20 <= body.count else {
                throw GitError.malformedObject(reason: "tree 条目 \(name) 的 SHA-1 不完整（被截断）")
            }
            let id = SHA1(bytes: Array(body[hashStart..<(hashStart + 20)]))
            entries.append(GitTreeEntry(mode: mode, name: name, id: id))
            index = hashStart + 20
        }
        return entries
    }

    /// 解析 commit 正文。
    public func commit(id: SHA1) throws -> GitCommit {
        guard type == .commit else {
            throw GitError.malformedObject(reason: "期望 commit，实际是 \(type.rawValue)")
        }
        var tree: SHA1?
        var parents: [SHA1] = []
        var author: GitSignature?
        var committer: GitSignature?

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var messageStart = lines.count
        for (offset, line) in lines.enumerated() {
            if line.isEmpty { messageStart = offset + 1; break }   // 空行之后是提交信息
            // ⚠️ 续行（以空格开头）属于上一条 header；gpgsig 是多行的，必须跳过而不是报错
            if line.hasPrefix(" ") { continue }
            let pieces = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let key = String(pieces[0]), value = String(pieces[1])
            switch key {
            case "tree":
                tree = SHA1(hex: value)
            case "parent":
                if let parsed = SHA1(hex: value) { parents.append(parsed) }
            case "author":
                author = GitSignature(header: value)
            case "committer":
                committer = GitSignature(header: value)
            default:
                break   // gpgsig / mergetag / encoding 等：不认识的 header 一律忽略，不报错
            }
        }
        guard let tree else { throw GitError.malformedObject(reason: "commit 缺少 tree 行") }
        let message = lines.dropFirst(messageStart).joined(separator: "\n")
        // ⚠️ 作者/提交者缺失时用占位而不是报错：git 允许极少数畸形提交存在，
        //    而我们只是要显示历史 —— 因为一个字段缺失就让整个 git_log 失败是不划算的。
        return GitCommit(id: id, tree: tree, parents: parents,
                         author: author ?? GitSignature(name: "", email: "", timestamp: 0, timezone: "+0000"),
                         committer: committer ?? GitSignature(name: "", email: "", timestamp: 0, timezone: "+0000"),
                         message: message)
    }
}

extension GitSignature {
    /// 解析 `Name <email> 1700000000 +0800`。
    ///
    /// ⚠️ 名字里可以含空格（`Rune Dev`），所以必须**从右往左**取：
    ///    最后两段是时间与时区，`<...>` 是邮箱，剩下的是名字。
    ///    从左往右切会把名字切错，而那种错误只在多词名字上暴露。
    init(header: String) {
        var rest = header
        var timezone = "+0000", timestamp = 0
        let tail = rest.split(separator: " ")
        if tail.count >= 2 {
            timezone = String(tail[tail.count - 1])
            timestamp = Int(tail[tail.count - 2]) ?? 0
            rest = tail.dropLast(2).joined(separator: " ")
        }
        var name = rest, email = ""
        if let open = rest.firstIndex(of: "<"), let close = rest.firstIndex(of: ">"), open < close {
            email = String(rest[rest.index(after: open)..<close])
            name = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
        }
        self.init(name: name, email: email, timestamp: timestamp, timezone: timezone)
    }
}

// MARK: - 引用解析

extension GitObjectStore {

    /// 读一个引用文件的内容（`refs/heads/main` → SHA-1）。
    func readReference(_ name: String) throws -> SHA1 {
        let url = gitDirectoryURL.appendingPathComponent(name)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            // 打包引用：`.git/packed-refs` 里可能有它（clone 之后分支通常在这）
            if let packed = try? String(contentsOf: gitDirectoryURL.appendingPathComponent("packed-refs"), encoding: .utf8) {
                for line in packed.split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("^") {
                    let parts = line.split(separator: " ")
                    if parts.count == 2, parts[1] == Substring(name), let id = SHA1(hex: String(parts[0])) {
                        return id
                    }
                }
            }
            throw GitError.referenceNotFound(name)
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // 符号引用（`ref: refs/heads/main`）—— 递归解一层就够（git 不允许更深的链）
        if trimmed.hasPrefix("ref:") {
            let target = trimmed.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            return try readReference(target)
        }
        guard let id = SHA1(hex: trimmed) else {
            throw GitError.malformedObject(reason: "引用 \(name) 的内容不是 40 位十六进制：\(trimmed)")
        }
        return id
    }

    /// HEAD 指向的提交 ID（解符号引用后）。空仓库抛 `.emptyRepository`。
    public func headCommitID() throws -> SHA1 {
        let head = gitDirectoryURL.appendingPathComponent("HEAD")
        guard let content = try? String(contentsOf: head, encoding: .utf8) else {
            throw GitError.notARepository(workTreeURL.path)
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref:") {
            let target = trimmed.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            do { return try readReference(target) }
            catch { throw GitError.emptyRepository }   // 分支还没创建 = 空仓库
        }
        guard let id = SHA1(hex: trimmed) else { throw GitError.emptyRepository }
        return id
    }

    /// 当前分支名（HEAD 是符号引用时）。detached HEAD 返回 nil。
    public func currentBranch() -> String? {
        let head = gitDirectoryURL.appendingPathComponent("HEAD")
        guard let content = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref:") else { return nil }
        let target = trimmed.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
        guard target.hasPrefix("refs/heads/") else { return nil }
        return String(target.dropFirst("refs/heads/".count))
    }

    /// 本地分支名列表。
    public func branches() -> [String] {
        let heads = gitDirectoryURL.appendingPathComponent("refs/heads")
        var names: [String] = []
        if let enumerator = FileManager.default.enumerator(at: heads, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                // ⚠️ 相对路径必须**分段取**，不能用字符串替换拼出来 ——
                //    `path.replacingOccurrences(of: heads.path + "/", with: "")` 在
                //    临时目录下会得到 `/privatemain` 这种东西（macOS 上同一目录有
                //    `/var/…` 与 `/private/var/…` 两种写法，前缀对不上就切不掉）。
                //    这正是项目记过的 T55：**相对路径交给文件系统给，不要自己切字符串**。
                let base = heads.standardizedFileURL.pathComponents
                let full = url.standardizedFileURL.pathComponents
                guard full.count > base.count, Array(full.prefix(base.count)) == base else { continue }
                names.append(full.dropFirst(base.count).joined(separator: "/"))
            }
        }
        return names.sorted()
    }
}
