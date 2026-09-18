import Foundation

// MARK: - Git index（`.git/index`）解析
//
// `git_status` 与 `git_diff` 都离不开它：**没有 index 就分不清"已暂存"与"未暂存"**，
// 而这两者的下一步动作完全不同（前者要 commit，后者要 add）。
//
// 格式依据（照抄规范）：
//   * 头：`DIRC` + 版本(4) + 条目数(4)
//   * 条目：ctime(8) + mtime(8) + dev(4) + ino(4) + mode(4) + uid(4) + gid(4)
//           + size(4) + 20 字节 SHA + flags(2) + path(NUL 结尾，按 8 字节对齐补 NUL)
//   * 尾部：扩展段（可选）+ 20 字节 SHA-1 校验
//   * flags 低 12 位是**路径长度**；等于 0xFFF 时表示"长度超过 4095，要自己找 NUL"

/// index 里的一条记录。
public struct GitIndexEntry: Sendable, Hashable {
    /// 仓库内相对路径（`src/a.py`）
    public let path: String
    /// 已暂存内容的 blob ID
    public let id: SHA1
    /// 文件模式（八进制字符串，如 `100644`）
    public let mode: String
    /// 工作区文件的 mtime（用于快速判断"有没有被动过"）
    public let mtimeSeconds: Int
    public let size: Int
}

public enum GitIndexError: Error, Equatable, CustomStringConvertible {
    case badHeader
    case unsupportedVersion(UInt32)

    public var description: String {
        switch self {
        case .badHeader: return "git index 文件头不合法。"
        case .unsupportedVersion(let v): return "不支持的 git index 版本 \(v)。"
        }
    }
}

public enum GitIndex {

    /// 解析 `.git/index`。
    ///
    /// ⚠️ 版本 2 与 3 都能解（4 会明确拒绝）：v3 的差别只是**扩展 flags**（多 2 字节），
    ///    靠最高位 `0x4000` 判断。不处理它的话，v3 仓库的路径会整体错位 ——
    ///    而错位后读出来的"文件名"看起来像乱码，很难联想到是 flags 的问题。
    public static func parse(_ bytes: [UInt8]) throws -> [GitIndexEntry] {
        guard bytes.count >= 12, bytes[0] == 0x44, bytes[1] == 0x49, bytes[2] == 0x52, bytes[3] == 0x43 else {
            throw GitIndexError.badHeader
        }
        let version = GitPack.be32(bytes, 4)
        guard version == 2 || version == 3 else { throw GitIndexError.unsupportedVersion(version) }
        let count = Int(GitPack.be32(bytes, 8))

        var entries: [GitIndexEntry] = []
        entries.reserveCapacity(count)
        var cursor = 12
        for _ in 0..<count {
            guard cursor + 62 <= bytes.count else { throw GitIndexError.badHeader }
            let mtime = Int(GitPack.be32(bytes, cursor + 8))
            let mode = GitPack.be32(bytes, cursor + 24)
            let size = Int(GitPack.be32(bytes, cursor + 36))
            let id = SHA1(bytes: Array(bytes[(cursor + 40)..<(cursor + 60)]))
            var flags = UInt16(bytes[cursor + 60]) << 8 | UInt16(bytes[cursor + 61])
            cursor += 62

            // v3 的扩展 flags：最高位为 1 时多 2 字节
            if version >= 3, flags & 0x4000 != 0 {
                guard cursor + 2 <= bytes.count else { throw GitIndexError.badHeader }
                cursor += 2
                flags &= ~0x4000
            }

            // ⚠️ 低 12 位是路径长度，但 0xFFF 表示"超过 4095，实际长度要自己找 NUL"。
            //    直接用它当长度会读出一个包含后续条目的巨大字符串。
            let declaredLength = Int(flags & 0x0FFF)
            let nameStart = cursor
            let nameEnd: Int
            if declaredLength < 0x0FFF, nameStart + declaredLength <= bytes.count {
                nameEnd = nameStart + declaredLength
            } else {
                guard let nul = bytes[nameStart...].firstIndex(of: 0) else { throw GitIndexError.badHeader }
                nameEnd = nul
            }
            let path = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)

            // 条目按 8 字节对齐（在**整条记录的起点**上度量，起点是 12 + 已消耗）
            let recordEnd = nameEnd + 1                 // 含 path 后的那个 NUL
            let padding = (8 - ((recordEnd - 12) % 8)) % 8
            cursor = recordEnd + padding
            guard cursor <= bytes.count else { throw GitIndexError.badHeader }

            entries.append(GitIndexEntry(path: path, id: id, mode: modeString(mode),
                                         mtimeSeconds: mtime, size: size))
        }
        return entries
    }

    /// mode → 八进制字符串（与 tree 里的写法一致）。
    ///
    /// ⚠️ 只保留 git 真正会用的几种；其余原样转八进制，
    ///    因为写回时**必须逐字节还原**（T35 同类：比的是字节，不是语义）。
    static func modeString(_ mode: UInt32) -> String {
        switch mode {
        case 0o100644: return "100644"
        case 0o100755: return "100755"
        case 0o120000: return "120000"
        case 0o160000: return "160000"
        case 0o040000: return "40000"
        default: return String(mode, radix: 8)
        }
    }
}

extension GitObjectStore {
    /// 读并解析 index；没有 index（新仓库、还没 add 过）返回空数组。
    ///
    /// ⚠️ 返回空数组而不是抛错：`git_status` 在一个刚 `init` 的空仓库上必须能正常工作，
    ///    而"没有 index"是**合法状态**，不是错误。
    public func index() throws -> [GitIndexEntry] {
        let url = gitDirectoryURL.appendingPathComponent("index")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return try GitIndex.parse([UInt8](data))
    }
}
