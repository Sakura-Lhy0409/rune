import Foundation

// MARK: - 虚拟文件系统（VFS）
//
// 设计依据（docs/05 §4）。VFS 是**所有文件访问的唯一入口**：
// 工具、检查点、快照回滚、策略引擎的路径判定，全都建立在它的语义上。
//
// ## 为什么它必须是一个有契约的抽象，而不是到处调 FileManager
//
// 因为下面这些语义**只有在一个地方实现才可能一致**：
//
//   * **写不蕴含删**：写一个文件绝不允许顺手清掉别的路径（docs/05 §4.2）
//   * **原子替换**：先写临时文件再改名 —— 否则 App 被杀会留下半个文件，
//     而模型下次读到的就是坏内容
//   * **换行保真**：写回去的换行风格必须跟随原文件（T8/T9 那两个坑的直接后果）
//   * **二进制要识别并拒绝**：`read_file` 读到一个 20MB 的 PNG 会白烧上下文
//   * **删除默认进回收站**，不是真删（可回滚是一切的前提）
//   * **文件名规范化**：⚠️ APFS/HFS+ 会把文件名存成 **NFD** 变体，
//     而模型与用户给的是 **NFC**。同一个文件名，两种字节序列 ——
//     不处理的话，iOS 上"文件明明在那儿却读不到"，而 Windows/Linux 上一切正常。
//
// 这一层放在 `RuneKernel` 而不是等 macOS：**它可以用真实文件系统在任意平台上验证**，
// 而上面每一条错了都不会报错、只会静默地做错事。

// MARK: - 条目

public struct VFSEntry: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case file
        case directory
        /// ⚠️ 符号链接**永远不跟随**：它是指出沙箱的经典手法
        case symlink
        case other
    }

    public var path: VFSPath
    public var kind: Kind
    public var byteSize: Int64
    public var modifiedAt: Date?
    public var createdAt: Date?
    /// 文件名（最后一段）
    public var name: String { path.components.last ?? path.mount.rawValue }

    public init(path: VFSPath, kind: Kind, byteSize: Int64 = 0,
                modifiedAt: Date? = nil, createdAt: Date? = nil) {
        self.path = path
        self.kind = kind
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
    }

    public var isDirectory: Bool { kind == .directory }
}

public struct ListOptions: Sendable, Codable, Hashable {
    public var recursive: Bool
    public var maxDepth: Int
    public var includeHidden: Bool
    public var limit: Int
    /// 是否跟随符号链接（**默认 false**；真需要时由调用方显式打开并承担后果）
    public var followSymlinks: Bool

    public init(recursive: Bool = false, maxDepth: Int = 1, includeHidden: Bool = false,
                limit: Int = 2_000, followSymlinks: Bool = false) {
        self.recursive = recursive
        self.maxDepth = max(1, maxDepth)
        self.includeHidden = includeHidden
        self.limit = max(1, limit)
        self.followSymlinks = followSymlinks
    }
}

public struct ReadOptions: Sendable, Codable, Hashable {
    /// 从第几行开始（1 起，含）
    public var startLine: Int?
    /// 到第几行结束（1 起，含）
    public var endLine: Int?
    /// 只读末尾 N 行（与 start/end 互斥，优先级更高）
    public var tailLines: Int?
    /// 单次读取的字节上限（超过就截断并如实告知）
    public var maxBytes: Int
    /// 是否允许读二进制（默认不允许 —— 读了也是白烧上下文）
    public var allowBinary: Bool

    public init(startLine: Int? = nil, endLine: Int? = nil, tailLines: Int? = nil,
                maxBytes: Int = 256 * 1024, allowBinary: Bool = false) {
        self.startLine = startLine
        self.endLine = endLine
        self.tailLines = tailLines
        self.maxBytes = max(1, maxBytes)
        self.allowBinary = allowBinary
    }
}

public struct VFSContent: Sendable, Codable, Hashable {
    public var path: VFSPath
    public var text: String
    /// 文件总行数（**即使只取了一段也要给出**，模型靠它决定要不要继续读）
    public var totalLines: Int
    /// 实际返回的行范围（1 起、闭区间）
    public var returnedLines: ClosedRange<Int>?
    public var byteSize: Int64
    /// 是否因为字节上限被截断
    public var wasTruncated: Bool
    public var encoding: String
    /// 原本的换行风格（写回去时要沿用）
    public var newline: String

    public init(path: VFSPath, text: String, totalLines: Int, returnedLines: ClosedRange<Int>?,
                byteSize: Int64, wasTruncated: Bool, encoding: String = "utf-8", newline: String = "\n") {
        self.path = path
        self.text = text
        self.totalLines = totalLines
        self.returnedLines = returnedLines
        self.byteSize = byteSize
        self.wasTruncated = wasTruncated
        self.encoding = encoding
        self.newline = newline
    }

    /// 带行号的文本（`read_file` 直接返回它）。
    ///
    /// 行号从 `returnedLines.lowerBound` 开始 —— 部分读取时行号必须对应**文件里的真实行号**，
    /// 否则模型会拿着错误的行号去打补丁。
    public var numberedText: String {
        let start = returnedLines?.lowerBound ?? 1
        let width = String(totalLines).count
        return text.components(separatedBy: "\n").enumerated().map { offset, line in
            let number = start + offset
            return String(repeating: " ", count: max(0, width - String(number).count)) + "\(number)│\(line)"
        }.joined(separator: "\n")
    }
}

public struct WriteOptions: Sendable, Codable, Hashable {
    public var createParents: Bool
    /// 换行风格：`.preserve` 表示跟随目标文件原本的风格（新建文件时用 `\n`）
    public enum NewlineStyle: String, Sendable, Codable, Hashable {
        case preserve
        case lf
        case crlf
    }
    public var newlineStyle: NewlineStyle
    /// 是否要原子替换（**默认 true**；只有明确知道自己在做什么时才关掉）
    public var atomic: Bool

    public init(createParents: Bool = true, newlineStyle: NewlineStyle = .preserve, atomic: Bool = true) {
        self.createParents = createParents
        self.newlineStyle = newlineStyle
        self.atomic = atomic
    }
}

public struct WriteReport: Sendable, Codable, Hashable {
    public var path: VFSPath
    public var bytesWritten: Int
    public var wasCreated: Bool
    public var newline: String

    public init(path: VFSPath, bytesWritten: Int, wasCreated: Bool, newline: String) {
        self.path = path
        self.bytesWritten = bytesWritten
        self.wasCreated = wasCreated
        self.newline = newline
    }
}

public struct DeleteOptions: Sendable, Codable, Hashable {
    /// ⚠️ **默认 false**：删除默认进回收站（保留 N 天），不是真删。
    /// 手机上没有"撤销"，真删是不可逆的 —— 而不可逆正是最该避免的东西。
    public var permanent: Bool
    public var recursive: Bool

    public init(permanent: Bool = false, recursive: Bool = false) {
        self.permanent = permanent
        self.recursive = recursive
    }
}

public struct DeleteReport: Sendable, Codable, Hashable {
    public var path: VFSPath
    public var movedToTrash: Bool
    public var trashPath: VFSPath?

    public init(path: VFSPath, movedToTrash: Bool, trashPath: VFSPath? = nil) {
        self.path = path
        self.movedToTrash = movedToTrash
        self.trashPath = trashPath
    }
}

/// 一次沙箱快照（`sandbox_snapshot` 的产物）
public struct VFSSnapshot: Sendable, Codable, Hashable {
    public var id: String
    public var label: String
    public var createdAt: Date
    /// 快照落盘的位置（内存实现里为空）
    public var storagePath: VFSPath?
    /// 快照时的文件数（用于 UI 显示"回滚会影响 N 个文件"）
    public var fileCount: Int

    public init(id: String, label: String, createdAt: Date, storagePath: VFSPath? = nil, fileCount: Int = 0) {
        self.id = id
        self.label = label
        self.createdAt = createdAt
        self.storagePath = storagePath
        self.fileCount = fileCount
    }
}

// MARK: - 失败

/// VFS 的结构化失败。
///
/// ⚠️ 每个 case 都要能**回灌给模型并指导它下一步怎么做** ——
/// 只说"失败了"等于让模型再猜一次（见 docs/04 §4.4 的修正性重试）。
public struct VFSFailure: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        case notFound
        case notAFile
        case notADirectory
        case alreadyExists
        case parentMissing
        /// 二进制文件（读了也是白烧上下文）
        case isBinary
        case tooLarge
        case notEmpty
        /// **越出挂载点** —— 必须拒绝，不能"当作没有路径"
        case outsideRoot
        /// 符号链接指到了挂载点之外（沙箱逃逸）
        case symlinkEscape
        case ioError
    }

    public var kind: Kind
    public var path: VFSPath?
    public var detail: String
    /// 相似路径候选（让模型能自己改对）
    public var candidates: [String]

    public init(kind: Kind, path: VFSPath? = nil, detail: String, candidates: [String] = []) {
        self.kind = kind
        self.path = path
        self.detail = detail
        self.candidates = candidates
    }

    public var description: String { detail }

    /// 给模型看的完整文本（分类 + 原因 + 下一步）
    public var modelFacingText: String {
        var lines = [detail]
        if !candidates.isEmpty { lines.append("候选：\(candidates.joined(separator: "、"))") }
        return lines.joined(separator: "\n")
    }

    /// 值得让模型自己改一次再试吗
    public var isSelfCorrectable: Bool {
        switch kind {
        case .notFound, .parentMissing, .notADirectory, .alreadyExists: return true
        case .outsideRoot, .symlinkEscape, .isBinary, .tooLarge, .ioError, .notAFile, .notEmpty: return false
        }
    }
}

// MARK: - 契约

/// 文件系统的唯一入口。
///
/// ⚠️ 实现必须保证的四条语义（conformance 测试会逐条验证**每一个实现**）：
///   1. 一切路径都被钳制在 `root` 之内，符号链接不得逃逸；
///   2. 写入是原子替换，且**换行风格跟随原文件**；
///   3. 删除默认进回收站；
///   4. 写一个文件**绝不影响**任何别的路径。
public protocol VFS: Sendable {
    var root: VFSPath { get }

    func stat(_ path: VFSPath) throws -> VFSEntry
    func exists(_ path: VFSPath) -> Bool
    func list(_ path: VFSPath, options: ListOptions) throws -> [VFSEntry]
    func read(_ path: VFSPath, options: ReadOptions) throws -> VFSContent
    func write(_ path: VFSPath, content: String, options: WriteOptions) throws -> WriteReport
    func delete(_ path: VFSPath, options: DeleteOptions) throws -> DeleteReport
    func move(_ from: VFSPath, to: VFSPath, overwrite: Bool) throws
    func copy(_ from: VFSPath, to: VFSPath, overwrite: Bool) throws
    func makeDirectory(_ path: VFSPath, intermediates: Bool) throws
    func snapshot(label: String, now: Date) throws -> VFSSnapshot
    func restore(_ snapshot: VFSSnapshot) throws
}

public extension VFS {
    func read(_ path: VFSPath) throws -> VFSContent { try read(path, options: ReadOptions()) }
    func write(_ path: VFSPath, content: String) throws -> WriteReport {
        try write(path, content: content, options: WriteOptions())
    }
    func exists(_ path: VFSPath) -> Bool { (try? stat(path)) != nil }

    /// 便捷：把整棵树列出来（用于上下文里的工作区摘要）
    func listAll(includeHidden: Bool = false, limit: Int = 2_000) throws -> [VFSEntry] {
        try list(root, options: ListOptions(recursive: true, maxDepth: 32,
                                           includeHidden: includeHidden, limit: limit))
    }
}

// MARK: - 二进制识别

public enum BinaryDetector {
    /// 前多少个字节里出现 NUL 就判为二进制（git 用的是同样的启发式）
    public static let probeLength = 8_000

    public static func isBinary(_ data: Data) -> Bool {
        data.prefix(probeLength).contains(0)
    }

    public static func isBinary(_ text: String) -> Bool {
        text.unicodeScalars.prefix(probeLength).contains { $0.value == 0 }
    }
}

// MARK: - 文件名规范化与比较
//
// ⚠️ **先纠正一个我一开始搞错的判断，免得后人跟着错。**
//
// 我原以为"iOS 上的文件名坑"指的是 NFC/NFD：APFS 存 NFD、模型给 NFC、字节不同就找不到文件。
// 写测试时才发现这个说法**基本不成立**：
//
//   * Swift 的 `String ==` **本身就是按 Unicode 规范等价比较的** ——
//     `"café" == "cafe\u{0301}"` 在 Swift 里是 **true**。
//     所以 `Set<String>` 去重、路径相等判定这类我们自己的比较**天生就没有这个问题**；
//   * APFS / HFS+ 是**规范化不敏感**的：查 `café`（NFC）能命中磁盘上存的 NFD 形式。
//     操作系统已经替我们兜住了。
//
// 所以 `FilenameNormalization` 留在这里是**纵深防御**，不是主要矛盾 ——
// 它挡的是外接卷、网络共享（SMB/NFS）、以及"名字在别的平台上被存成了 NFD"这些情况。
//
// ⚠️ **iOS 上真正会咬人的是「大小写不敏感」**：
// APFS 默认大小写不敏感，`README.md` 与 `readme.md` 在 iOS 上是**同一个文件**，
// 而在 Windows/Linux 上是两个。后果：
//   * 模型"新建" `README.md` 时磁盘上已有 `readme.md` → 实际是**覆盖**，不是新建；
//   * 去重、忽略规则、冲突检测里"两个不同路径就是两个文件"的假设，在 iOS 上不成立；
//   * 这类 bug 在 Windows 上开发时**永远看不到**。
//
// 所以它必须是一个**显式的、可注入的**属性，而不是"靠平台差异自己蒙对"。

public enum FilenameNormalization: String, Sendable, Codable, Hashable {
    /// 文件系统不做规范化（Windows / Linux）
    case none
    /// 文件系统按规范化不敏感处理（iOS / macOS）—— 查找时多试几种形式作为兜底
    case normalizationInsensitive

    public static var platformDefault: FilenameNormalization {
        #if canImport(Darwin)
        return .normalizationInsensitive
        #else
        return .none
        #endif
    }

    /// 查找时该依次尝试哪些形式。
    ///
    /// ⚠️ **去重必须按 UTF-8 字节，不能按 `==`。**
    ///
    ///    这里踩过一次，而且踩得很典型：Swift 的 `String ==` 是**规范等价**的，
    ///    所以 `forms.contains(decomposed)` 对 NFC 形式**永远返回 true** ——
    ///    于是分解形式永远加不进去，这个"多试几种形式"的兜底**从来没生效过**。
    ///    代码看上去完全正确，测试也只断言了 `forms.first`，一路绿灯。
    ///
    ///    这个坑之所以阴，恰恰是因为上一条注释里说的"Swift 比较是规范等价的" ——
    ///    同一个性质，在"判断两个名字是不是同一个文件"时是**帮手**，
    ///    在"判断两个字节形式是不是同一个候选"时是**陷阱**。
    ///    凡是"我要的是不同字节形式"的地方，都必须按字节比。
    public func lookupForms(_ name: String) -> [String] {
        switch self {
        case .none:
            return [name]
        case .normalizationInsensitive:
            var forms: [String] = []
            var seen = Set<[UInt8]>()
            for candidate in [
                name,
                name.decomposedStringWithCanonicalMapping,
                name.precomposedStringWithCanonicalMapping,
            ] where seen.insert(Array(candidate.utf8)).inserted {
                forms.append(candidate)
            }
            return forms
        }
    }

    /// 比较用的规范形式。
    ///
    /// ⚠️ 对 Swift 的 `String ==` 来说这是多余的（它已按规范等价比较）。
    /// 保留它是为了**跨语言/跨平台的一致性**：名字写进 JSON、日志、SQLite 时
    /// 需要一个确定的字节形式，否则同一个文件在两次运行里会有两种"身份"。
    public func canonical(_ name: String) -> String {
        switch self {
        case .none: return name
        case .normalizationInsensitive: return name.decomposedStringWithCanonicalMapping
        }
    }
}

/// 文件系统怎么比较**文件名**（iOS 上真正会咬人的那一条）。
public enum FilenameComparison: String, Sendable, Codable, Hashable {
    case caseSensitive
    /// iOS / macOS 的默认卷：`README.md` 与 `readme.md` 是同一个文件
    case caseInsensitive

    public static var platformDefault: FilenameComparison {
        #if canImport(Darwin)
        return .caseInsensitive
        #else
        return .caseSensitive
        #endif
    }

    public func matches(_ a: String, _ b: String) -> Bool {
        switch self {
        case .caseSensitive: return a == b
        case .caseInsensitive: return a.lowercased() == b.lowercased()
        }
    }

    /// 在**同一个目录**里找出与 `name` 指向同一文件的既有条目。
    ///
    /// ⚠️ 用途很具体：**大小写不敏感时「新建」可能是「覆盖」**。
    /// 写文件之前必须先问一句"这个目录里是不是已经有一个只有大小写不同的同名文件"，
    /// 否则模型会以为自己新建了一个文件，实际上覆盖掉了别人的东西 —— 而且不可撤销。
    public func collidingEntry(named name: String, among existing: [String]) -> String? {
        switch self {
        case .caseSensitive:
            return existing.first { $0 == name }
        case .caseInsensitive:
            let lowered = name.lowercased()
            return existing.first { $0.lowercased() == lowered }
        }
    }
}
// MARK: - 内存实现（测试与沙箱快照用）

/// 纯内存的 VFS。用于测试、以及"只改内存里的副本"的沙箱场景。
public final class MemoryVFS: VFS, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String]
    /// **显式**创建的目录（`make_directory`）。其余目录由文件路径推导 —— 见 `allDirectories`。
    private var explicitDirectories: Set<String>
    private var snapshots: [String: [String: String]] = [:]
    private var trash: [String: (content: String, at: Date)] = [:]
    private let clock: @Sendable () -> Date
    private let normalization: FilenameNormalization

    public let root: VFSPath

    public init(
        files: [String: String] = [:],
        directories: [String] = [],
        root: VFSPath = VFSPath(mount: .workspace),
        normalization: FilenameNormalization = .none,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        // 键统一成"相对路径"形式，避免 `/workspace/a` 与 `a` 被当成两个文件
        self.files = Dictionary(uniqueKeysWithValues: files.map { (Self.key($0.key), $0.value) })
        self.explicitDirectories = Set(directories.map(Self.key))
        self.root = root
        self.normalization = normalization
        self.clock = clock
    }

    static func key(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\\", with: "/")
        if text.hasPrefix("/workspace/") { text = String(text.dropFirst("/workspace/".count)) }
        while text.hasPrefix("/") { text = String(text.dropFirst()) }
        while text.hasPrefix("./") { text = String(text.dropFirst(2)) }
        return text
    }

    /// 所有存在的目录 = 显式创建的 ∪ 有文件的路径的各级父目录
    private var allDirectories: Set<String> {
        var result = explicitDirectories
        for key in files.keys {
            var components = key.split(separator: "/").map(String.init)
            while components.count > 1 {
                components.removeLast()
                result.insert(components.joined(separator: "/"))
            }
        }
        return result
    }

    private func key(_ path: VFSPath) throws -> String {
        guard path.mount == root.mount else {
            throw VFSFailure(kind: .outsideRoot, path: path,
                             detail: "路径 \(path.description) 不在挂载点 \(root.description) 内")
        }
        let base = root.components.joined(separator: "/")
        let full = path.components.joined(separator: "/")
        if base.isEmpty { return full }
        guard full == base || full.hasPrefix(base + "/") else {
            throw VFSFailure(kind: .outsideRoot, path: path,
                             detail: "路径 \(path.description) 越出了根目录 \(root.description)")
        }
        return full == base ? "" : String(full.dropFirst(base.count + 1))
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    public func stat(_ path: VFSPath) throws -> VFSEntry {
        try withLock {
            let k = try key(path)
            if let content = files[k] {
                return VFSEntry(path: path, kind: .file,
                                byteSize: Int64(content.utf8.count),
                                modifiedAt: clock())
            }
            if k.isEmpty || allDirectories.contains(k) {
                return VFSEntry(path: path, kind: .directory, modifiedAt: clock())
            }
            throw VFSFailure(kind: .notFound, path: path,
                             detail: "路径不存在：\(path.description)",
                             candidates: similar(k))
        }
    }

    private func similar(_ k: String) -> [String] {
        VFSCandidates.similar(to: k, among: Array(files.keys)).map { "/workspace/" + $0 }
    }

    public func list(_ path: VFSPath, options: ListOptions) throws -> [VFSEntry] {
        try withLock {
            let k = try key(path)
            guard k.isEmpty || allDirectories.contains(k) else {
                if files[k] != nil {
                    throw VFSFailure(kind: .notADirectory, path: path, detail: "\(path.description) 是文件，不是目录")
                }
                throw VFSFailure(kind: .notFound, path: path, detail: "目录不存在：\(path.description)")
            }

            let prefix = k.isEmpty ? "" : k + "/"
            var results: [VFSEntry] = []
            var seen = Set<String>()

            func add(_ relative: String) {
                let remainder = String(relative.dropFirst(prefix.count))
                guard !remainder.isEmpty else { return }
                let depth = remainder.split(separator: "/").count
                if !options.recursive && depth > 1 { return }
                if options.recursive && depth > options.maxDepth { return }
                let name = remainder.split(separator: "/").first.map(String.init) ?? remainder
                if !options.includeHidden && name.hasPrefix(".") { return }
                let canonical = normalization.canonical(remainder)
                guard seen.insert(canonical).inserted else { return }
                let childPath = path.appending(components: remainder.split(separator: "/").map(String.init))
                if let content = files[relative] {
                    results.append(VFSEntry(path: childPath, kind: .file,
                                            byteSize: Int64(content.utf8.count), modifiedAt: clock()))
                } else {
                    results.append(VFSEntry(path: childPath, kind: .directory, modifiedAt: clock()))
                }
            }

            for dir in allDirectories.sorted() where dir.hasPrefix(prefix) && !dir.isEmpty { add(dir) }
            for file in files.keys.sorted() where file.hasPrefix(prefix) { add(file) }

            return Array(results.sorted { $0.path.description < $1.path.description }.prefix(options.limit))
        }
    }

    public func read(_ path: VFSPath, options: ReadOptions) throws -> VFSContent {
        try withLock {
            let k = try key(path)
            guard let content = files[k] else {
                if allDirectories.contains(k) {
                    throw VFSFailure(kind: .notAFile, path: path, detail: "\(path.description) 是目录")
                }
                throw VFSFailure(kind: .notFound, path: path, detail: "文件不存在：\(path.description)",
                                 candidates: similar(k))
            }
            return try VFSSlicing.slice(content: content, path: path, options: options, byteSize: Int64(content.utf8.count))
        }
    }

    public func write(_ path: VFSPath, content: String, options: WriteOptions) throws -> WriteReport {
        try withLock {
            let k = try key(path)
            guard !k.isEmpty else {
                throw VFSFailure(kind: .notAFile, path: path, detail: "不能把根目录当文件写")
            }
            let existing = files[k]
            let newline: String
            switch options.newlineStyle {
            case .lf: newline = "\n"
            case .crlf: newline = "\r\n"
            case .preserve:
                newline = existing.map { LineTable.parse($0).newline } ?? "\n"
            }
            // ⚠️ 换行风格跟随原文件：不然在 CRLF 文件里插进 LF 行，diff 会出现整文件噪音（T9）
            let normalized = TextEdit.normalizeNewlines(content, to: newline)

            // `createParents: false` 时父目录必须已经存在 —— 这是与真实文件系统一致的行为，
            // 不能因为"内存实现里目录是推导出来的"就放过。
            if !options.createParents {
                var components = k.split(separator: "/").map(String.init)
                components.removeLast()
                let parent = components.joined(separator: "/")
                guard parent.isEmpty || allDirectories.contains(parent) else {
                    throw VFSFailure(kind: .parentMissing, path: path,
                                     detail: "父目录不存在：\(parent)")
                }
            }
            files[k] = normalized
            return WriteReport(path: path, bytesWritten: normalized.utf8.count,
                               wasCreated: existing == nil, newline: newline)
        }
    }

    public func delete(_ path: VFSPath, options: DeleteOptions) throws -> DeleteReport {
        try withLock {
            let k = try key(path)
            guard files[k] != nil || allDirectories.contains(k) else {
                throw VFSFailure(kind: .notFound, path: path, detail: "路径不存在：\(path.description)")
            }
            if !options.permanent {
                let stamp = Int(clock().timeIntervalSince1970)
                let flat = k.isEmpty ? "root" : k.replacingOccurrences(of: "/", with: "_")
                let trashKey = ".rune/trash/\(stamp)-\(flat)"
                let moved = files[k] ?? ""
                files[trashKey] = moved
                files.removeValue(forKey: k)
                trash[trashKey] = (moved, clock())
                return DeleteReport(path: path, movedToTrash: true,
                                    trashPath: VFSPath.parseOrNil("/workspace/" + trashKey))
            }
            if files[k] != nil {
                files.removeValue(forKey: k)
            } else {
                explicitDirectories.remove(k)
                // 目录必须显式递归
                let prefix = k + "/"
                let hasChildren = files.keys.contains { $0.hasPrefix(prefix) }
                guard !hasChildren || options.recursive else {
                    throw VFSFailure(kind: .notEmpty, path: path,
                                     detail: "目录 \(path.description) 非空；要删除请明确要求递归")
                }
                files = files.filter { !$0.key.hasPrefix(prefix) }
                explicitDirectories = explicitDirectories.filter { !$0.hasPrefix(prefix) && $0 != k }
            }
            return DeleteReport(path: path, movedToTrash: false)
        }
    }

    public func move(_ from: VFSPath, to: VFSPath, overwrite: Bool) throws {
        try withLock {
            let source = try key(from)
            let destination = try key(to)
            guard let content = files[source] else {
                throw VFSFailure(kind: .notFound, path: from, detail: "文件不存在：\(from.description)")
            }
            if files[destination] != nil && !overwrite {
                throw VFSFailure(kind: .alreadyExists, path: to,
                                 detail: "目标已存在：\(to.description)。要覆盖请明确说明。")
            }
            files[destination] = content
            files.removeValue(forKey: source)
        }
    }

    public func copy(_ from: VFSPath, to: VFSPath, overwrite: Bool) throws {
        try withLock {
            let source = try key(from)
            let destination = try key(to)
            guard let content = files[source] else {
                throw VFSFailure(kind: .notFound, path: from, detail: "文件不存在：\(from.description)")
            }
            if files[destination] != nil && !overwrite {
                throw VFSFailure(kind: .alreadyExists, path: to,
                                 detail: "目标已存在：\(to.description)。要覆盖请明确说明。")
            }
            files[destination] = content
        }
    }

    public func makeDirectory(_ path: VFSPath, intermediates: Bool) throws {
        try withLock {
            let k = try key(path)
            guard !k.isEmpty else { return }        // 根目录永远存在（幂等）
            if files[k] != nil {
                throw VFSFailure(kind: .notADirectory, path: path, detail: "\(path.description) 已经是文件")
            }
            var components = k.split(separator: "/").map(String.init)
            if !intermediates, components.count > 1 {
                components.removeLast()
                let parent = components.joined(separator: "/")
                guard allDirectories.contains(parent) else {
                    throw VFSFailure(kind: .parentMissing, path: path,
                                     detail: "父目录不存在：\(parent)")
                }
            }
            explicitDirectories.insert(k)
        }
    }

    public func snapshot(label: String, now: Date) throws -> VFSSnapshot {
        try withLock {
            let id = "snap-\(Int(now.timeIntervalSince1970))-\(files.count)"
            snapshots[id] = files
            return VFSSnapshot(id: id, label: label, createdAt: now,
                               storagePath: VFSPath.parseOrNil("/workspace/.rune/snapshots/\(id)"),
                               fileCount: files.count)
        }
    }

    public func restore(_ snapshot: VFSSnapshot) throws {
        try withLock {
            guard let saved = snapshots[snapshot.id] else {
                throw VFSFailure(kind: .notFound, detail: "找不到快照 \(snapshot.id)")
            }
            files = saved
        }
    }

    // MARK: 测试辅助

    public func allFiles() -> [String: String] {
        withLock { files }
    }
    public func trashContents() -> [String] {
        withLock { trash.keys.sorted() }
    }
}

// MARK: - 真实文件系统实现

/// 以某个真实目录为根的 VFS。
///
/// ⚠️ **安全要点**（每一条都有对应的测试）：
///   * 一切路径先过 `VFSPath`（拒绝 `..` 逃逸），再拼接成真实路径；
///   * 拼接之后**再解析一次符号链接**，确认仍在根目录内 —— 否则工作区里一个
///     指向 `/etc` 的链接就能把整个沙箱架空；
///   * 写入走"临时文件 + 改名"，避免 App 被杀时留下半个文件。
public final class FileManagerVFS: VFS, @unchecked Sendable {
    public let root: VFSPath
    /// 真实根目录。`internal` 是为了让测试能构造符号链接、直接往磁盘上放东西。
    let baseURL: URL
    private let fileManager: FileManager
    private let normalization: FilenameNormalization
    /// 回收站保留天数（UI 上要能告诉用户"还能恢复多久"）
    public let trashRetentionDays: Int

    public init(
        baseURL: URL,
        mount: MountPoint = .workspace,
        normalization: FilenameNormalization = .platformDefault,
        trashRetentionDays: Int = 7,
        fileManager: FileManager = .default
    ) {
        self.baseURL = baseURL.standardizedFileURL.resolvingSymlinksInPath()
        self.root = VFSPath(mount: mount)
        self.fileManager = fileManager
        self.normalization = normalization
        self.trashRetentionDays = max(1, trashRetentionDays)
    }

    // MARK: 路径映射（**全部安全逻辑都在这里**）

    /// 把 VFS 路径映射成真实 URL，并**再次确认**解析符号链接之后没有跑出根目录。
    private func url(for path: VFSPath, mustExist: Bool) throws -> URL {
        guard path.mount == root.mount else {
            throw VFSFailure(kind: .outsideRoot, path: path,
                             detail: "路径 \(path.description) 不在挂载点 \(root.description) 内")
        }
        var candidate = baseURL
        for component in path.components {
            // ⚠️ 组件里不可能再出现分隔符或 `..`（VFSPath 已经拦过），这里只做防御
            guard component != "..", !component.contains("/"), !component.isEmpty else {
                throw VFSFailure(kind: .outsideRoot, path: path, detail: "路径含非法组件：\(component)")
            }
            candidate.appendPathComponent(component)
        }

        if mustExist {
            candidate = try resolveExisting(candidate, path: path)
        } else {
            // 目标可能还不存在 → 解析**父目录**的符号链接
            let resolvedParent = try resolveExisting(candidate.deletingLastPathComponent(), path: path)
            candidate = resolvedParent.appendingPathComponent(candidate.lastPathComponent)
        }

        // 最终确认（`resolvingSymlinksInPath` 在不同平台上完成度不同，
        // 这里做成"能解析就一定要在根内，解析不了也不放行可疑形态")
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard isInsideRoot(resolved) else {
            throw VFSFailure(kind: .symlinkEscape, path: path,
                             detail: "路径 \(path.description) 经过符号链接后指到了根目录之外，已拒绝。")
        }
        return resolved
    }

    private func resolveExisting(_ url: URL, path: VFSPath) throws -> URL {
        guard fileManager.fileExists(atPath: url.path) else {
            // 不存在 → 逐级往上找最近的存在的祖先（父目录可能也不存在）
            var ancestor = url.deletingLastPathComponent()
            while !fileManager.fileExists(atPath: ancestor.path), ancestor.path != baseURL.path {
                let parent = ancestor.deletingLastPathComponent()
                if parent.path == ancestor.path { break }
                ancestor = parent
            }
            let resolved = ancestor.standardizedFileURL.resolvingSymlinksInPath()
            guard isInsideRoot(resolved) else {
                throw VFSFailure(kind: .symlinkEscape, path: path, detail: "路径越出了根目录，已拒绝。")
            }
            return url
        }
        return url
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        let rootPath = baseURL.path
        let target = url.standardizedFileURL.path
        if target == rootPath { return true }
        return target.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private func vfsPath(for url: URL) -> VFSPath {
        let rootPath = baseURL.path
        var relative = url.standardizedFileURL.path
        if relative.hasPrefix(rootPath) { relative = String(relative.dropFirst(rootPath.count)) }
        let components = relative.split(separator: "/").map(String.init)
        return VFSPath(mount: root.mount, components: components)
    }

    // MARK: 读

    public func stat(_ path: VFSPath) throws -> VFSEntry {
        let target = try url(for: path, mustExist: true)
        guard let attributes = try? fileManager.attributesOfItem(atPath: target.path) else {
            throw VFSFailure(kind: .notFound, path: path, detail: "路径不存在：\(path.description)",
                             candidates: (try? nearbyNames(of: target, path: path)) ?? [])
        }
        let type = (attributes[.type] as? FileAttributeType) ?? .typeUnknown
        let kind: VFSEntry.Kind
        switch type {
        case .typeRegular: kind = .file
        case .typeDirectory: kind = .directory
        case .typeSymbolicLink: kind = .symlink
        default: kind = .other
        }
        return VFSEntry(
            path: path, kind: kind,
            byteSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAt: attributes[.modificationDate] as? Date,
            createdAt: attributes[.creationDate] as? Date
        )
    }

    public func list(_ path: VFSPath, options: ListOptions) throws -> [VFSEntry] {
        let target = try url(for: path, mustExist: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VFSFailure(kind: .notADirectory, path: path, detail: "\(path.description) 不是目录")
        }

        var results: [VFSEntry] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]

        func walk(_ directory: URL, depth: Int) {
            guard results.count < options.limit else { return }
            guard let children = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys,
                options: options.includeHidden ? [] : [.skipsHiddenFiles]
            ) else { return }

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard results.count < options.limit else { return }
                let name = child.lastPathComponent
                let relative = directory == target ? name : "\(vfsPath(for: directory).components.joined(separator: "/"))/\(name)"
                guard seen.insert(normalization.canonical(relative)).inserted else { continue }

                let values = try? child.resourceValues(forKeys: Set(keys))
                let isLink = values?.isSymbolicLink ?? false
                let isDir = values?.isDirectory ?? false
                // ⚠️ 符号链接**永远不跟随**（`followSymlinks` 只影响是否继续往下走，
                //    不影响我们是否把它当链接报告出来）
                let kind: VFSEntry.Kind = isLink ? .symlink : (isDir ? .directory : .file)
                results.append(VFSEntry(
                    path: vfsPath(for: child), kind: kind,
                    byteSize: Int64(values?.fileSize ?? 0),
                    modifiedAt: values?.contentModificationDate
                ))
                if isDir, options.recursive, depth + 1 < options.maxDepth {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(target, depth: 0)
        return results
    }

    public func read(_ path: VFSPath, options: ReadOptions) throws -> VFSContent {
        var target = try url(for: path, mustExist: true)

        // ⚠️ 文件名规范化：文件系统存的是 NFD，模型给的是 NFC → 直接拼出来的路径找不到。
        //    依次尝试几种形式，命中之后就用命中的那个（后续写入也走它，避免又建出一个新文件）。
        if !fileManager.fileExists(atPath: target.path) {
            target = try resolveWithNormalization(path, target: target)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            throw VFSFailure(kind: .notFound, path: path, detail: "文件不存在：\(path.description)",
                             candidates: (try? nearbyNames(of: target, path: path)) ?? [])
        }
        guard !isDirectory.boolValue else {
            throw VFSFailure(kind: .notAFile, path: path, detail: "\(path.description) 是目录")
        }

        guard let data = try? Data(contentsOf: target) else {
            throw VFSFailure(kind: .ioError, path: path, detail: "读取失败：\(path.description)")
        }
        guard !BinaryDetector.isBinary(data) || options.allowBinary else {
            throw VFSFailure(kind: .isBinary, path: path,
                             detail: "\(path.description) 看起来是二进制文件（\(data.count) 字节），没有读取。需要内容请用专门工具（如 ocr_image / read_pdf）。")
        }
        guard data.count <= options.maxBytes || options.allowBinary else {
            // 超上限时**不报错**，截断并如实告知（模型可以再取一段）
            let head = data.prefix(options.maxBytes)
            let text = String(decoding: head, as: UTF8.self)
            let table = LineTable.parse(text)
            return VFSContent(path: path, text: table.text, totalLines: table.count,
                              returnedLines: 1...max(1, table.count), byteSize: Int64(data.count),
                              wasTruncated: true, newline: table.newline)
        }

        let text = String(decoding: data, as: UTF8.self)
        return try VFSSlicing.slice(content: text, path: path, options: options, byteSize: Int64(data.count))
    }

    private func resolveWithNormalization(_ path: VFSPath, target: URL) throws -> URL {
        let parent = target.deletingLastPathComponent()
        let name = target.lastPathComponent
        // ⚠️ **不要写 `where form != name`。**
        //
        //    这是同一个坑的第二次出现（第一次在 `lookupForms` 的去重里）：
        //    Swift 的 `==` 是规范等价的，所以 `form != name` 对分解形式**永远是 false**，
        //    于是"备选形式"一个都不会被试 —— 兜底逻辑又一次静默失效。
        //
        //    第一个形式本来就是 `name`，重复试一次没有代价；宁可多试一次，
        //    也不要用一个看起来更聪明的过滤把整段逻辑废掉。
        for form in normalization.lookupForms(name) {
            let candidate = parent.appendingPathComponent(form)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return target
    }

    /// 相似名字（给模型的候选）—— 与内存实现共用同一套相似度判定
    private func nearbyNames(of url: URL, path: VFSPath) throws -> [String] {
        let parent = url.deletingLastPathComponent()
        guard let siblings = try? fileManager.contentsOfDirectory(atPath: parent.path) else { return [] }
        return VFSCandidates.similarNames(to: url.lastPathComponent, among: siblings)
            .map { vfsPath(for: parent.appendingPathComponent($0)).description }
    }

    // MARK: 写

    public func write(_ path: VFSPath, content: String, options: WriteOptions) throws -> WriteReport {
        let target = try url(for: path, mustExist: false)
        let existed = fileManager.fileExists(atPath: target.path)

        // ⚠️ 换行风格跟随原文件
        let newline: String
        switch options.newlineStyle {
        case .lf: newline = "\n"
        case .crlf: newline = "\r\n"
        case .preserve:
            if existed, let data = try? Data(contentsOf: target) {
                newline = LineTable.parse(String(decoding: data, as: UTF8.self)).newline
            } else {
                newline = "\n"
            }
        }
        let normalized = TextEdit.normalizeNewlines(content, to: newline)
        let payload = Data(normalized.utf8)

        let parent = target.deletingLastPathComponent()
        if options.createParents {
            try? fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        guard fileManager.fileExists(atPath: parent.path) else {
            throw VFSFailure(kind: .parentMissing, path: path, detail: "父目录不存在：\(vfsPath(for: parent).description)")
        }

        guard options.atomic else {
            guard fileManager.createFile(atPath: target.path, contents: payload) else {
                throw VFSFailure(kind: .ioError, path: path, detail: "写入失败：\(path.description)")
            }
            return WriteReport(path: path, bytesWritten: payload.count, wasCreated: !existed, newline: newline)
        }

        // ⚠️ 原子替换：先写同目录下的临时文件，再改名。
        //    临时文件必须与目标**同目录**（跨文件系统的 rename 不是原子的）。
        let temp = parent.appendingPathComponent(".\(target.lastPathComponent).rune-tmp-\(UUID().uuidString)")
        do {
            try payload.write(to: temp)
        } catch {
            throw VFSFailure(kind: .ioError, path: path, detail: "写入临时文件失败：\(error)")
        }
        do {
            #if canImport(Darwin)
            if existed {
                _ = try fileManager.replaceItemAt(target, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: target)
            }
            #else
            // corelibs-foundation 上没有可靠的同目录原子替换，退化成"删掉再改名"。
            // 窗口极小但不为零 —— 这是本机验证的局限，iOS 上走的是上面那条。
            if existed { try fileManager.removeItem(at: target) }
            try fileManager.moveItem(at: temp, to: target)
            #endif
        } catch {
            try? fileManager.removeItem(at: temp)
            throw VFSFailure(kind: .ioError, path: path, detail: "替换失败：\(error)")
        }
        return WriteReport(path: path, bytesWritten: payload.count, wasCreated: !existed, newline: newline)
    }

    // MARK: 删 / 移 / 拷 / 建目录

    public func delete(_ path: VFSPath, options: DeleteOptions) throws -> DeleteReport {
        let target = try url(for: path, mustExist: true)
        guard fileManager.fileExists(atPath: target.path) else {
            throw VFSFailure(kind: .notFound, path: path, detail: "路径不存在：\(path.description)")
        }

        if !options.permanent {
            let trashDirectory = baseURL.appendingPathComponent(".rune/trash", isDirectory: true)
            try? fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970)
            let flatName = path.components.joined(separator: "_")
            let destination = trashDirectory.appendingPathComponent("\(stamp)-\(flatName.isEmpty ? "root" : flatName)")
            do {
                try fileManager.moveItem(at: target, to: destination)
            } catch {
                throw VFSFailure(kind: .ioError, path: path,
                                 detail: "移入回收站失败：\(error)。目标可能占用中。")
            }
            return DeleteReport(path: path, movedToTrash: true, trashPath: vfsPath(for: destination))
        }

        var isDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            let children = (try? fileManager.contentsOfDirectory(atPath: target.path)) ?? []
            guard children.isEmpty || options.recursive else {
                throw VFSFailure(kind: .notEmpty, path: path,
                                 detail: "目录 \(path.description) 非空（\(children.count) 项）；要删除请明确要求递归。")
            }
        }
        do {
            try fileManager.removeItem(at: target)
        } catch {
            throw VFSFailure(kind: .ioError, path: path, detail: "删除失败：\(error)")
        }
        return DeleteReport(path: path, movedToTrash: false)
    }

    public func move(_ from: VFSPath, to: VFSPath, overwrite: Bool) throws {
        let source = try url(for: from, mustExist: true)
        let destination = try url(for: to, mustExist: false)
        if fileManager.fileExists(atPath: destination.path), !overwrite {
            throw VFSFailure(kind: .alreadyExists, path: to,
                             detail: "目标已存在：\(to.description)。要覆盖请明确说明。")
        }
        try? fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        do {
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            throw VFSFailure(kind: .ioError, path: from, detail: "移动失败：\(error)")
        }
    }

    public func copy(_ from: VFSPath, to: VFSPath, overwrite: Bool) throws {
        let source = try url(for: from, mustExist: true)
        let destination = try url(for: to, mustExist: false)
        if fileManager.fileExists(atPath: destination.path), !overwrite {
            throw VFSFailure(kind: .alreadyExists, path: to,
                             detail: "目标已存在：\(to.description)。要覆盖请明确说明。")
        }
        try? fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        do {
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw VFSFailure(kind: .ioError, path: from, detail: "复制失败：\(error)")
        }
    }

    public func makeDirectory(_ path: VFSPath, intermediates: Bool) throws {
        let target = try url(for: path, mustExist: false)
        if fileManager.fileExists(atPath: target.path) { return }   // 幂等
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: intermediates)
        } catch {
            throw VFSFailure(kind: .parentMissing, path: path,
                             detail: intermediates ? "建目录失败：\(error)" : "父目录不存在")
        }
    }

    // MARK: 快照

    /// 快照 = 把整棵树复制一份。
    ///
    /// ⚠️ 手机上这会很贵（几百 MB 的仓库复制一次要好几秒、还要占双份磁盘）。
    /// 真正的做法是 APFS 的 **`clonefile`（写时复制，几乎零成本）** ——
    /// 那是 Apple 专有 API，等 macOS 阶段接上；这一版先把**语义**定死，
    /// 并把"贵"如实告诉调用方（`fileCount` 让 UI 能说清影响面）。
    public func snapshot(label: String, now: Date) throws -> VFSSnapshot {
        let id = "snap-\(Int(now.timeIntervalSince1970))"
        let directory = baseURL.appendingPathComponent(".rune/snapshots/\(id)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var count = 0
        // ⚠️ **相对路径必须由文件系统自己给，不要去切字符串。**
        //
        //    这里原来是 `item.path.dropFirst(directory.path.count)` —— 两个路径**各自推导**，
        //    只要其中一侧的写法与另一侧不同，切出来的就是垃圾。
        //    而 macOS 上恰好就有这种"同一个目录的两种写法"：`/var/...` 与 `/private/var/...`
        //    （临时目录的真实位置在 `/private/var` 下）。CI 在 macOS 上抓到的就是这个：
        //    切错之后文件被复制到了**别的地方**，而 `try?` 让整件事**完全静默**。
        //    `subpathsOfDirectory` 直接返回相对路径，从根上消除这类错。
        for relative in try fileManager.subpathsOfDirectory(atPath: baseURL.path) {
            // 快照自己不能被装进快照里
            if relative == ".rune" || relative.hasPrefix(".rune/") { continue }
            let source = baseURL.appendingPathComponent(relative)
            let destination = directory.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: source, to: destination)
                count += 1
            }
        }
        return VFSSnapshot(id: id, label: label, createdAt: now,
                           storagePath: vfsPath(for: directory), fileCount: count)
    }

    public func restore(_ snapshot: VFSSnapshot) throws {
        guard let storage = snapshot.storagePath else {
            throw VFSFailure(kind: .notFound, detail: "快照 \(snapshot.id) 没有存储位置")
        }
        let directory = try url(for: storage, mustExist: true)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw VFSFailure(kind: .notFound, detail: "快照内容已不存在：\(snapshot.id)")
        }

        // ⚠️ **回滚不许静默失败。**
        //    一个"看起来成功了、其实一个字都没回滚"的回滚，比一个直接报错的回滚危险得多 ——
        //    用户会以为工作区已经安全了，然后继续在上面干活。
        //    所以这里一律 `try`（原来全是 `try?`，正是它把上面那个路径 bug 掩盖了）。
        for relative in try fileManager.subpathsOfDirectory(atPath: directory.path) {
            let source = directory.appendingPathComponent(relative)
            let destination = baseURL.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: source, to: destination)
            }
        }
    }
}

// MARK: - 共用逻辑（两个实现必须行为一致）

/// 找不到路径时给出候选。
///
/// ⚠️ 两个实现必须给出**同样质量**的候选：这是"修正性重试"能不能救回来的关键 ——
/// 模型看到 `src/monye.py` 不存在、候选里有 `src/money.py`，它下一轮就改对了。
/// 只给"文件不存在"四个字，它只能再猜一次。
enum VFSCandidates {

    /// 从一批**完整路径**里挑出与 `missing` 最像的几个
    static func similar(to missing: String, among existing: [String], limit: Int = 5) -> [String] {
        let wantedName = missing.split(separator: "/").last.map(String.init) ?? missing
        return existing
            .compactMap { candidate -> (String, Int)? in
                let name = candidate.split(separator: "/").last.map(String.init) ?? candidate
                let distance = SkillSearch.editDistance(wantedName.lowercased(), name.lowercased())
                // 同名不同目录 → 一定是好候选
                if name == wantedName && candidate != missing { return (candidate, 0) }
                // 名字差太远就不给（宁可不给建议，也不要给错建议）
                let limit = max(3, wantedName.count / 2)
                guard distance <= limit else { return nil }
                return (candidate, distance)
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                return a.0 < b.0
            }
            .prefix(limit)
            .map(\.0)
    }

    /// 从一批**同目录下的文件名**里挑
    static func similarNames(to missing: String, among siblings: [String], limit: Int = 5) -> [String] {
        similar(to: missing, among: siblings, limit: limit)
    }
}

enum VFSSlicing {

    /// 按行范围切一段内容。**两个 VFS 实现共用它**，这样"部分读取"的语义只有一份实现。
    static func slice(content: String, path: VFSPath, options: ReadOptions, byteSize: Int64) throws -> VFSContent {
        // ⚠️ 二进制检查放在这里（而不是各自实现里）：两个实现对同一次调用的判定
        //    必须一致，否则"内存实现能读、真实实现拒绝"这种事会一直藏着。
        guard !BinaryDetector.isBinary(content) || options.allowBinary else {
            throw VFSFailure(kind: .isBinary, path: path,
                             detail: "\(path.description) 看起来是二进制文件（\(byteSize) 字节），没有读取。需要内容请用专门工具（如 ocr_image / read_pdf）。")
        }
        let table = LineTable.parse(content)
        let total = max(0, table.count)
        guard total > 0 else {
            return VFSContent(path: path, text: "", totalLines: 0, returnedLines: nil,
                              byteSize: byteSize, wasTruncated: false, newline: table.newline)
        }

        var lower = 1
        var upper = total
        if let tail = options.tailLines, tail > 0 {
            lower = max(1, total - tail + 1)
        } else {
            if let start = options.startLine { lower = min(max(1, start), total) }
            if let end = options.endLine { upper = min(max(lower, end), total) }
        }

        let slice = Array(table.lines[(lower - 1)..<upper])
        // ⚠️ **末尾换行必须保住。**
        //
        //    这里踩过一次：直接 `slice.joined(separator: "\n")` 会丢掉 `endsWithNewline`，
        //    于是"读出来再写回去"与原文**差一个字节** ——
        //    后果是每一次往返都在改文件（spurious diff），而"补丁只实际改动一次"这类
        //    崩溃一致性断言也会莫名其妙地失败。
        //    只有切片真的取到文件最后一行时才补回换行；中间段落不该凭空多一个。
        let reachesEnd = upper >= total
        var text = LineTable(
            lines: slice,
            endsWithNewline: reachesEnd && table.endsWithNewline,
            newline: "\n"
        ).text

        // 行范围够了，但字节可能还是超上限 → 再按字节截一次，并如实告知
        var truncated = false
        if text.utf8.count > options.maxBytes {
            text = String(decoding: Array(text.utf8.prefix(options.maxBytes)), as: UTF8.self)
            truncated = true
            upper = lower + max(0, text.components(separatedBy: "\n").count - 1)
        }

        return VFSContent(
            path: path, text: text, totalLines: total,
            returnedLines: lower...max(lower, upper),
            byteSize: byteSize, wasTruncated: truncated, newline: table.newline
        )
    }
}










