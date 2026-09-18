import Foundation
import RuneKernel

/// 模型的文件视图：凭据与受管目录不可读，也不能通过 grep/copy 绕过限制。
/// 人类 UI 仍能查看自己的文件；只有模型工具使用此视图。
struct ModelWorkspace: VFS {
    let base: FileManagerVFS
    var root: VFSPath { base.root }
    private func permitted(_ path: VFSPath) -> Bool {
        guard path.mount == .workspace else { return false }
        for end in 1...max(1, path.components.count) {
            let prefix = VFSPath(mount: path.mount, components: Array(path.components.prefix(end)))
            if HumanOnlyZoneDetector.zone(for: prefix) != nil { return false }
        }
        return !path.components.contains { [".git", ".rune", ".ssh"].contains($0.lowercased()) }
    }
    private func require(_ path: VFSPath) throws {
        guard permitted(path), permitted(try base.resolvedPath(path)) else { throw ToolError(kind: .capabilityDenied, modelFacingMessage: "此路径属于凭据或受管区域，不向模型暴露。") }
    }
    func stat(_ path: VFSPath) throws -> VFSEntry { try require(path); return try base.stat(path) }
    func exists(_ path: VFSPath) -> Bool { (try? require(path)) != nil && base.exists(path) }
    func list(_ path: VFSPath, options: ListOptions) throws -> [VFSEntry] {
        try require(path)
        return try base.list(path, options: options).filter { (try? require($0.path)) != nil }
    }
    func readData(_ path: VFSPath, maxBytes: Int) throws -> Data { try require(path); return try base.readData(path, maxBytes: maxBytes) }
    func read(_ path: VFSPath, options: ReadOptions) throws -> VFSContent { try require(path); return try base.read(path, options: options) }
    func write(_ path: VFSPath, content: String, options: WriteOptions) throws -> WriteReport { try require(path); return try base.write(path, content: content, options: options) }
    func delete(_ path: VFSPath, options: DeleteOptions) throws -> DeleteReport { try requireFile(path); return try base.delete(path, options: options) }
    func move(_ from: VFSPath, to: VFSPath, overwrite: Bool) throws {
        try requireFile(from); try require(to); try base.move(from, to: to, overwrite: overwrite)
    }
    func copy(_ from: VFSPath, to: VFSPath, overwrite: Bool) throws {
        try requireFile(from); try require(to); try base.copy(from, to: to, overwrite: overwrite)
    }
    private func requireFile(_ path: VFSPath) throws {
        try require(path)
        guard try base.stat(path).kind == .file else { throw RuntimeFailure("模型当前只能对单个文件执行删除/复制/移动；目录操作请由用户在文件管理中完成。") }
    }
    func makeDirectory(_ path: VFSPath, intermediates: Bool) throws { try require(path); try base.makeDirectory(path, intermediates: intermediates) }
    func snapshot(label: String, now: Date) throws -> VFSSnapshot { throw RuntimeFailure("模型不能直接创建全目录快照。") }
    func restore(_ snapshot: VFSSnapshot) throws { throw RuntimeFailure("恢复快照需要运行时与用户共同确认。") }
}

/// Git 工具的路径解析器。
///
/// ⚠️ 它**刻意不复用 `ModelWorkspace` 的 `permitted`**，而是只做一件事：
///    把**工作区内的目录**映射到磁盘 URL，好让自研 Git 引擎去读 `.git`。
///
/// ⚠️ 为什么这道门不能照搬：`ModelWorkspace` 明确禁止模型触碰 `.git`
///    （"凭据与受管目录不可读"），而 Git 工具**就是要读 `.git`**。
///    两条规则看起来冲突，实际上不冲突 —— 因为**模型的入口不同**：
///      * 文件工具（read_file/grep）拿到的是模型给的任意路径 → 必须挡住 `.git`
///      * Git 工具拿到的是**仓库根**，它自己去读 `.git` → 那是它唯一的工作方式
///    所以这里仍然显式拒绝任何**指向 `.git` / `.rune` / `.ssh` 的路径**：
///    模型不能通过 `git_status(path: ".git/config")` 把凭据读出来。
struct GitWorkspaceResolver: GitWorkspaceResolving {
    let base: FileManagerVFS
    private static let forbidden = [".git", ".rune", ".ssh"]
    func fileSystemURL(for path: VFSPath) -> URL? {
        guard path.mount == .workspace else { return nil }
        // 反向路径（`..`）一律拒 —— 放过去等于让模型用相对路径逃出工作区（T24/T25）
        guard !path.components.contains("..") else { return nil }
        // ⚠️ 只拒绝**最后一段**是受管名（那才是"进到 .git 里面去"）；
        //    中间段出现同样要拒，避免 `foo/.git/config` 这种绕法。
        guard !path.components.contains(where: { Self.forbidden.contains($0.lowercased()) }) else { return nil }
        return base.fileSystemURL(for: path)
    }
}
