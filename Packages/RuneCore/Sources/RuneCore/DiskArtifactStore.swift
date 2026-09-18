import Foundation
import RuneKernel

/// 制品与工作区隔离，恢复后 read_artifact 仍能读到全文。
public struct DiskArtifactStore: ArtifactStore, Sendable {
    private let vfs: FileManagerVFS
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vfs = FileManagerVFS(baseURL: directory)
    }
    public func store(_ text: String, suggestedName: String, kind: ArtifactRef.ArtifactKind) throws -> ArtifactRef {
        let name = UUID().uuidString + ".txt"
        _ = try vfs.write(VFSPath(mount: .workspace, components: [name]), content: text)
        return ArtifactRef(relPath: "artifacts/" + name, kind: kind, displayName: suggestedName, mime: "text/plain",
                           byteSize: Int64(text.utf8.count), lineCount: LineTable.parse(text).count, sha256: SHA256.hash(text))
    }
    public func readAll(handle: String) throws -> String? {
        let components = handle.split(separator: "/").map(String.init)
        guard components.count == 2, components[0] == "artifacts", components[1].hasSuffix(".txt"),
              UUID(uuidString: String(components[1].dropLast(4))) != nil else { throw RuntimeFailure("无效的制品句柄。") }
        let content = try vfs.read(VFSPath(mount: .workspace, components: [components[1]]), options: ReadOptions(maxBytes: 8_388_608))
        guard !content.wasTruncated else { throw RuntimeFailure("制品超过读取上限。") }
        return content.text
    }
    public func read(handle: String, keyword: String?, startLine: Int?, maxBytes: Int) throws -> (text: String, totalLines: Int) {
        guard let text = try readAll(handle: handle) else { throw RuntimeFailure("制品不存在。") }
        let table = LineTable.parse(text)
        var start = max(0, (startLine ?? 1) - 1)
        var end = table.lines.count
        if let keyword, !keyword.isEmpty {
            guard let hit = table.lines.firstIndex(where: { $0.contains(keyword) }) else { throw RuntimeFailure("制品中没有匹配内容。") }
            start = max(0, hit - 5); end = min(end, hit + 26)
        }
        guard start < end else { return ("", table.count) }
        let result = table.lines[start..<end].joined(separator: "\n")
        return (String(decoding: result.utf8.prefix(max(0, maxBytes)), as: UTF8.self), table.count)
    }
}
