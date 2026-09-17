import Foundation

// MARK: - 本机工具实现（文件与检索）
//
// 这一层把 `ToolRegistry` 里的**契约**变成**真能干活的工具**。
//
// ## 为什么放在 `RuneKernel` 而不是等 `RuneTools`
//
// 因为 `RuneTools` 里真正需要 macOS 的只有三类：**执行类**（CPython / JSC / WASM）、
// **网络类**（URLSession + 出口代理）、**iOS 原生类**（相册 / 日历 / 定位）。
// 而**文件与检索这一大类（14 个工具，占真实任务的大部分）只需要 Foundation + VFS** ——
// 而 VFS 已经在 `RuneKernel` 里、且有两份实现与一致性断言（C23）。
//
// 把它留在这里的直接好处：**它能在任何平台上被完整验证**。
// 在没有 Mac 的开发路径下（`docs/16`），这一点不是"顺便"，而是"唯一能保证它是对的"的办法。
//
// ⚠️ 契约不变：所有文件访问走 `VFS`，**绝不直接调 `FileManager`** ——
// 否则路径钳制、符号链接拒绝、原子写、换行保真这几条一起失效。

// MARK: - 制品存储

/// 大输出的落点。
///
/// ⚠️ 这是 `docs/05 §7` 那条纪律的**另一半**：限额只是不让它进上下文，
/// 而用户与模型仍然要能拿到全文。所以"截断"必须配一个"去哪儿读"。
public protocol ArtifactStore: Sendable {
    func store(_ text: String, suggestedName: String, kind: ArtifactRef.ArtifactKind) throws -> ArtifactRef
    /// 按需读取（支持关键字定位）
    func read(handle: String, keyword: String?, startLine: Int?, maxBytes: Int) throws -> (text: String, totalLines: Int)
    func readAll(handle: String) throws -> String?
}

/// 内存实现（测试与预览用；真实现落盘到 `artifacts/`）
public final class InMemoryArtifactStore: ArtifactStore, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String] = [:]
    private var counter = 0

    public init() {}

    public func store(_ text: String, suggestedName: String, kind: ArtifactRef.ArtifactKind) throws -> ArtifactRef {
        lock.lock()
        counter += 1
        let safe = suggestedName.replacingOccurrences(of: "/", with: "_")
        let handle = "artifacts/\(counter)-\(safe)"
        files[handle] = text
        lock.unlock()

        let lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        return ArtifactRef(
            relPath: handle,
            kind: kind,
            displayName: suggestedName,
            mime: "text/plain",
            byteSize: Int64(text.utf8.count),
            lineCount: lines,
            sha256: SHA256.hash(text)
        )
    }

    public func read(handle: String, keyword: String?, startLine: Int?, maxBytes: Int) throws -> (text: String, totalLines: Int) {
        lock.lock()
        let content = files[handle]
        lock.unlock()
        guard let content else {
            throw VFSFailure(kind: .notFound, detail: "找不到制品 \(handle)。",
                             candidates: Array(files.keys).sorted())
        }
        let table = LineTable.parse(content)
        let total = table.count

        var start = max(1, startLine ?? 1)
        var end = total
        if let keyword, !keyword.isEmpty {
            // 关键字定位：找第一条命中的行，然后从它前面几行开始给
            if let hit = table.lines.firstIndex(where: { $0.contains(keyword) }) {
                start = max(1, hit + 1 - 5)
                end = min(total, hit + 1 + 25)
            } else {
                throw VFSFailure(kind: .notFound, detail: "制品里没有找到「\(keyword)」。")
            }
        }
        guard total > 0 else { return ("", 0) }
        end = min(end, total)
        var text = table.lines[(start - 1)..<end].joined(separator: "\n")
        if text.utf8.count > maxBytes {
            text = String(decoding: Array(text.utf8.prefix(maxBytes)), as: UTF8.self)
        }
        return (text, total)
    }

    public func readAll(handle: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return files[handle]
    }
}

// MARK: - 执行器

/// 文件与检索工具的真实实现。
public struct LocalToolExecutor: ToolExecuting, @unchecked Sendable {
    public var vfs: any VFS
    public var registry: [String: ToolSpec]
    public var artifacts: any ArtifactStore
    public var now: @Sendable () -> Date
    /// 工作区根（相对路径的解析基准）
    public var base: VFSPath

    public init(
        vfs: any VFS,
        registry: [String: ToolSpec] = ToolRegistry.byName,
        artifacts: any ArtifactStore = InMemoryArtifactStore(),
        base: VFSPath = VFSPath(mount: .workspace),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.vfs = vfs
        self.registry = registry
        self.artifacts = artifacts
        self.base = base
        self.now = now
    }

    // MARK: 入口

    public func execute(_ call: ToolCall) throws -> ToolResult {
        guard let spec = registry[call.name] else {
            let suggestion = TurnRunner.nearestToolName(to: call.name, in: Array(registry.keys))
            return .failure(callID: call.id, error: ToolError(
                kind: .unknownTool,
                modelFacingMessage: "没有名为 `\(call.name)` 的工具。",
                suggestion: suggestion.map { "你是不是想用 `\($0)`？" },
                candidates: suggestion.map { [$0] } ?? []
            ))
        }

        let args: JSONValue
        do {
            args = try call.arguments()
        } catch {
            return .failure(callID: call.id, error: ToolError(
                kind: .invalidArguments,
                modelFacingMessage: "参数不是合法 JSON：\(error)",
                suggestion: "重新发一次这个调用，注意 JSON 的引号与括号要闭合。"
            ))
        }

        // ⚠️ 先按 schema 校验，再动手。**校验必须在执行之前** ——
        //    否则一个参数写错的 delete_path 会先把文件删了再报"参数不合法"。
        if !SchemaValidator.validate(args, against: spec.inputSchema) {
            return .failure(callID: call.id, error: ToolError(
                kind: .invalidArguments,
                modelFacingMessage: "参数不符合 `\(call.name)` 的要求。",
                suggestion: "它的参数是：\(Correction.signature(of: spec))",
                candidates: requiredMissing(args: args, spec: spec)
            ))
        }

        do {
            switch call.name {
            case ToolName.listDir:      return try listDir(call, args)
            case ToolName.readFile:     return try readFile(call, args)
            case ToolName.readArtifact: return try readArtifact(call, args)
            case ToolName.writeFile:    return try writeFile(call, args)
            case ToolName.editFile:     return try editFile(call, args)
            case ToolName.applyPatch:   return try applyPatch(call, args)
            case ToolName.deletePath:   return try deletePath(call, args)
            case ToolName.movePath:     return try movePath(call, args)
            case ToolName.copyPath:     return try copyPath(call, args)
            case ToolName.statPath:     return try statPath(call, args)
            case ToolName.makeDir:      return try makeDir(call, args)
            case ToolName.glob:         return try glob(call, args)
            case ToolName.grepSearch:   return try grepSearch(call, args)
            case ToolName.outlineFile:  return try outlineFile(call, args)
            case ToolName.hashFile:     return try hashFile(call, args)
            default:
                return .failure(callID: call.id, error: ToolError(
                    kind: .other,
                    modelFacingMessage: "`\(call.name)` 不属于本机文件/检索工具集。",
                    suggestion: "这一类工具由平台层提供（执行 / 网络 / iOS 原生能力），在设备上才会注册。"
                ))
            }
        } catch let failure as VFSFailure {
            return .failure(callID: call.id, error: failure.asToolError(path: pathArg(args)))
        } catch let error as ToolError {
            return .failure(callID: call.id, error: error)
        } catch let error as PatchError {
            return .failure(callID: call.id, error: ToolError(
                kind: .invalidArguments,
                modelFacingMessage: error.modelFacingMessage,
                suggestion: error.suggestion
            ))
        } catch let error as TextEdit.EditError {
            return .failure(callID: call.id, error: ToolError(
                kind: .invalidArguments,
                modelFacingMessage: error.modelFacingMessage,
                suggestion: "先 `read_file` 看清楚当前内容，再用足够长的上下文重发。"
            ))
        } catch {
            return .failure(callID: call.id, error: ToolError(
                kind: .other,
                modelFacingMessage: "工具执行出错：\(error)",
                suggestion: "换个做法，或先确认路径与权限。"
            ))
        }
    }

    // MARK: 参数小工具

    private func pathArg(_ args: JSONValue) -> VFSPath? {
        guard let raw = args.value(at: ["path"])?.stringValue else { return nil }
        return resolve(raw)
    }

    /// 把模型给的路径解析成 VFS 路径。
    ///
    /// ⚠️ 走的是**与策略引擎同一个** `CallPaths.resolve` ——
    /// "被检查的路径"和"实际操作的路径"必须是同一个（见 T24/T25）。
    private func resolve(_ raw: String) -> VFSPath? {
        CallPaths.resolve([raw], base: base).paths.first
    }

    private func requiredMissing(args: JSONValue, spec: ToolSpec) -> [String] {
        guard case .object(let properties, let required, _) = spec.inputSchema else { return [] }
        return required.filter { key in
            args.value(at: [key]) == nil
                || (properties[key] != nil && args.value(at: [key]) == .null)
        }.sorted()
    }

    // MARK: 读

    private func listDir(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        let path = resolve(args.value(at: ["path"])?.stringValue ?? "/workspace") ?? base
        let recursive = args.value(at: ["recursive"])?.boolValue ?? false
        let maxDepth = args.value(at: ["max_depth"])?.intValue ?? 2
        let includeHidden = args.value(at: ["include_hidden"])?.boolValue ?? false

        let entries = try vfs.list(path, options: ListOptions(
            recursive: recursive, maxDepth: maxDepth, includeHidden: includeHidden, limit: 2_000
        ))
        let lines = entries.map { entry -> String in
            let suffix = entry.kind == .directory ? "/" : ""
            let size = entry.kind == .file ? "  \(OutputBudget.humanBytes(Int(entry.byteSize)))" : ""
            let link = entry.kind == .symlink ? "  →（符号链接，不跟随）" : ""
            return "\(entry.path.description)\(suffix)\(size)\(link)"
        }
        let summary = lines.isEmpty
            ? "（空目录）"
            : "\(entries.count) 项：\n" + lines.joined(separator: "\n")
        return deliver(summary, call: call, name: "目录列表")
    }

    private func readFile(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        guard let raw = args.value(at: ["path"])?.stringValue, let path = resolve(raw) else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `path`。",
                            suggestion: "给出要读的文件路径，例如 `src/a.py`。")
        }
        let options = ReadOptions(
            startLine: args.value(at: ["start_line"])?.intValue,
            endLine: args.value(at: ["end_line"])?.intValue,
            tailLines: args.value(at: ["tail_lines"])?.intValue,
            maxBytes: 256 * 1024
        )
        let content = try vfs.read(path, options: options)

        // ⚠️ 行号用**文件里的真实行号**：模型要拿它去打补丁
        var header = "\(path.description)（共 \(content.totalLines) 行"
        if let range = content.returnedLines, range.lowerBound != 1 || range.upperBound != content.totalLines {
            header += "，本次给了第 \(range.lowerBound)–\(range.upperBound) 行"
        }
        if content.wasTruncated { header += "，**已被截断**" }
        header += "，\(content.newline == "\r\n" ? "CRLF" : "LF")）"

        return deliver(header + "\n" + content.numberedText, call: call, name: "文件内容")
    }

    private func readArtifact(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        guard let handle = args.value(at: ["handle"])?.stringValue else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `handle`。",
                            suggestion: "用工具结果里给出的制品句柄，例如 `artifacts/ci-log.txt`。")
        }
        let result = try artifacts.read(
            handle: handle,
            keyword: args.value(at: ["keyword"])?.stringValue,
            startLine: args.value(at: ["start_line"])?.intValue,
            maxBytes: args.value(at: ["max_bytes"])?.intValue ?? 64 * 1024
        )
        let text = "\(handle)（共 \(result.totalLines) 行）\n\(result.text)"
        return deliver(text, call: call, name: "制品片段")
    }

    // MARK: 写

    private func writeFile(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        guard let raw = args.value(at: ["path"])?.stringValue, let path = resolve(raw) else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `path`。",
                            suggestion: "给出要写的文件路径。")
        }
        guard let content = args.value(at: ["content"])?.stringValue else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `content`。",
                            suggestion: "给出文件内容（整份内容，不是片段）。")
        }
        let createDirs = args.value(at: ["create_dirs"])?.boolValue ?? true
        let report = try vfs.write(path, content: content, options: WriteOptions(
            createParents: createDirs, newlineStyle: .preserve, atomic: true
        ))
        // ⚠️ 报"新建"还是"覆盖"很重要：覆盖可能已经毁掉了用户原有的内容
        let verb = report.wasCreated ? "新建" : "覆盖"
        return .ok(callID: call.id,
                   summary: "\(verb) \(path.description)（\(OutputBudget.humanBytes(report.bytesWritten))，\(report.newline == "\r\n" ? "CRLF" : "LF")）")
    }

    private func editFile(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        guard let raw = args.value(at: ["path"])?.stringValue, let path = resolve(raw) else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `path`。")
        }
        guard let oldString = args.value(at: ["old_string"])?.stringValue else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `old_string`。",
                            suggestion: "给出要被替换掉的那段原文（要足够长，保证唯一）。")
        }
        guard let newString = args.value(at: ["new_string"])?.stringValue else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `new_string`。")
        }
        let replaceAll = args.value(at: ["replace_all"])?.boolValue ?? false

        let original = try vfs.read(path, options: ReadOptions(maxBytes: 4 * 1024 * 1024))
        let updated: String
        if replaceAll {
            guard original.text.contains(oldString) else {
                // ⚠️ `notFound` 要带上"最接近的位置"——模型靠它自己改对，
                //    而不是只知道"找不到"然后瞎猜（docs/04 §4.4 的修正性重试）。
                let table = LineTable.parse(original.text)
                let needle = oldString.components(separatedBy: "\n").first ?? oldString
                let nearest = table.lines.enumerated()
                    .filter { $0.element.contains(needle.prefix(min(20, needle.count))) }
                    .prefix(5)
                    .map { MatchCandidate(line: $0.offset + 1, preview: [$0.element]) }
                throw TextEdit.EditError.notFound(find: oldString, nearest: Array(nearest))
            }
            updated = original.text.replacingOccurrences(of: oldString, with: newString)
        } else {
            // ⚠️ `replaceUnique` 在匹配到多处时会**拒绝**（绝不悄悄全改）
            updated = try TextEdit.replaceUnique(in: original.text, find: oldString, replace: newString)
        }
        let report = try vfs.write(path, content: updated, options: WriteOptions(newlineStyle: .preserve))
        let occurrences = replaceAll ? original.text.components(separatedBy: oldString).count - 1 : 1
        return .ok(callID: call.id,
                   summary: "已改 \(path.description)（替换 \(occurrences) 处，\(OutputBudget.humanBytes(report.bytesWritten))）")
    }

    private func applyPatch(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        guard let patchText = args.value(at: ["patch"])?.stringValue else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `patch`。",
                            suggestion: "补丁要包含 `*** File: 路径` 与 `@@` 段。")
        }
        let patch = try Patch.parse(patchText)

        // 一次性算出所有改动 —— 任何一处失败就整体不落地（docs/05 §2.1）
        let applied = try patch.apply { absolute in
            let parsed = VFSPath.parseOrNil(absolute.description) ?? absolute
            return (try? vfs.read(parsed, options: ReadOptions(maxBytes: 8 * 1024 * 1024)))?.text
        }

        var written: [String] = []
        var deleted: [String] = []

        // ⚠️ 先**全部写成功**再报告：中途失败时前面已经写进去的无法回滚，
        //    所以这里把错误如实带出来（含"已经改了几个"），而不是假装原子。
        for change in applied.changes {
            switch change.pathAction {
            case .delete:
                _ = try vfs.delete(change.path, options: DeleteOptions(permanent: false, recursive: false))
                deleted.append(change.path.description)
            default:
                guard let newContent = change.newContent else { continue }
                _ = try vfs.write(change.path, content: newContent, options: WriteOptions(newlineStyle: .preserve))
                written.append(change.path.description)
            }
        }

        var parts: [String] = []
        if !written.isEmpty { parts.append("改写了 \(written.count) 个文件：" + written.joined(separator: "、")) }
        if !deleted.isEmpty { parts.append("删除了 \(deleted.count) 个文件：" + deleted.joined(separator: "、")) }
        if applied.isCleanMatch { parts.append("全部精确匹配") }
        else { parts.append("部分使用了模糊匹配（请复核改动位置）") }
        return .ok(callID: call.id, summary: parts.joined(separator: "；"))
    }

    private func deletePath(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        guard let raw = args.value(at: ["path"])?.stringValue, let path = resolve(raw) else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `path`。")
        }
        let report = try vfs.delete(path, options: DeleteOptions(
            permanent: args.value(at: ["permanent"])?.boolValue ?? false,
            recursive: args.value(at: ["recursive"])?.boolValue ?? false
        ))
        if report.movedToTrash {
            return .ok(callID: call.id,
                       summary: "已把 \(path.description) 移入回收站（\(report.trashPath?.description ?? "")），没有真删。"
                           + "\n要彻底删除请明确传 `permanent: true`。")
        }
        return .ok(callID: call.id, summary: "已永久删除 \(path.description)。此操作不可撤销。")
    }

    private func movePath(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        guard let source = args.value(at: ["source"])?.stringValue.flatMap(resolve),
              let destination = args.value(at: ["destination"])?.stringValue.flatMap(resolve) else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `source` 或 `destination`。")
        }
        try vfs.move(source, to: destination, overwrite: false)
        return .ok(callID: call.id, summary: "已移动 \(source.description) → \(destination.description)")
    }

    private func copyPath(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        guard let source = args.value(at: ["source"])?.stringValue.flatMap(resolve),
              let destination = args.value(at: ["destination"])?.stringValue.flatMap(resolve) else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `source` 或 `destination`。")
        }
        try vfs.copy(source, to: destination, overwrite: args.value(at: ["overwrite"])?.boolValue ?? false)
        return .ok(callID: call.id, summary: "已复制 \(source.description) → \(destination.description)")
    }

    private func makeDir(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        guard let path = args.value(at: ["path"])?.stringValue.flatMap(resolve) else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `path`。")
        }
        try vfs.makeDirectory(path, intermediates: true)
        return .ok(callID: call.id, summary: "已确保目录存在：\(path.description)")
    }

    private func statPath(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        guard let path = args.value(at: ["path"])?.stringValue.flatMap(resolve) else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `path`。")
        }
        let entry = try vfs.stat(path)
        var lines = ["路径：\(entry.path.description)", "类型：\(entry.kind.rawValue)"]
        if entry.kind == .file { lines.append("大小：\(OutputBudget.humanBytes(Int(entry.byteSize)))") }
        if let modified = entry.modifiedAt { lines.append("修改时间：\(ISO8601DateFormatter().string(from: modified))") }
        if entry.kind == .symlink { lines.append("⚠️ 这是符号链接；读取时不会跟随它。") }
        return .ok(callID: call.id, summary: lines.joined(separator: "\n"))
    }

    // MARK: 检索

    private func glob(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        guard let pattern = args.value(at: ["pattern"])?.stringValue, !pattern.isEmpty else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `pattern`。",
                            suggestion: "给出通配模式，例如 `**/*Test.swift`。")
        }
        let root = args.value(at: ["path"])?.stringValue.flatMap(resolve) ?? base
        let limit = args.value(at: ["limit"])?.intValue ?? 200
        let matcher = GlobPattern(pattern)

        let entries = try vfs.list(root, options: ListOptions(recursive: true, maxDepth: 32, limit: 20_000))
        let matched = entries.filter { matcher.matches($0.path, isDirectory: $0.isDirectory) }

        // ⚠️ 按修改时间倒序：最近改过的文件最可能是要找的（与 docs/05 §2.2 一致）
        let sorted = matched.sorted { a, b in
            let am = a.modifiedAt ?? .distantPast
            let bm = b.modifiedAt ?? .distantPast
            if am != bm { return am > bm }
            return a.path.description < b.path.description
        }
        let shown = Array(sorted.prefix(limit))
        guard !shown.isEmpty else {
            return .ok(callID: call.id, summary: "没有匹配 `\(pattern)` 的文件。")
        }
        var text = "\(sorted.count) 个匹配" + (sorted.count > shown.count ? "（只列前 \(shown.count) 个）" : "") + "：\n"
        text += shown.map(\.path.description).joined(separator: "\n")
        return deliver(text, call: call, name: "glob 结果")
    }

    private func grepSearch(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        guard let pattern = args.value(at: ["pattern"])?.stringValue, !pattern.isEmpty else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `pattern`。")
        }
        let root = args.value(at: ["path"])?.stringValue.flatMap(resolve) ?? base
        let limit = args.value(at: ["limit"])?.intValue ?? 200

        let query = GrepQuery(
            pattern: pattern,
            mode: (args.value(at: ["is_regex"])?.boolValue ?? false) ? .regex : .literal,
            outputMode: Self.outputMode(fromToolArgument: args.value(at: ["output_mode"])?.stringValue),
            caseSensitive: args.value(at: ["case_sensitive"])?.boolValue ?? false,
            wholeWord: args.value(at: ["whole_word"])?.boolValue ?? false,
            contextBefore: args.value(at: ["context_lines"])?.intValue ?? 0,
            contextAfter: args.value(at: ["context_lines"])?.intValue ?? 0,
            maxResults: limit,
            includeGlobs: args.value(at: ["file_glob"])?.stringValue.map { [$0] } ?? []
        )

        // 候选来自 VFS（受同一套路径钳制），内容也走 VFS 读
        let entries = try vfs.list(root, options: ListOptions(recursive: true, maxDepth: 32, limit: 20_000))
        let candidates = entries.compactMap { entry -> GrepCandidate? in
            guard entry.kind == .file else { return nil }
            return GrepCandidate(path: entry.path, byteSize: Int(entry.byteSize), modifiedAt: entry.modifiedAt)
        }
        let source = GrepFileSource { path, maxBytes in
            guard let content = try? vfs.read(path, options: ReadOptions(maxBytes: maxBytes)) else { return nil }
            return Data(content.text.utf8)
        }

        let result = try GrepEngine.search(query: query, candidates: candidates, source: source, now: now())

        guard !result.matches.isEmpty || !result.fileSummaries.isEmpty else {
            return .ok(callID: call.id,
                       summary: "没有匹配。扫了 \(result.filesScanned) 个文件，跳过 \(result.filesSkipped) 个。")
        }

        var lines: [String] = [result.summary]
        switch query.outputMode {
        case .filesWithMatches:
            lines.append(contentsOf: result.fileSummaries.map(\.path.description))
        case .countOnly:
            lines.append(contentsOf: result.fileSummaries.map { "\($0.path.description): \($0.matchCount)" })
        case .matches:
            for match in result.matches {
                for context in match.contextBefore { lines.append("\(match.path.description)-\(match.line)│ \(context)") }
                let suffix = match.occurrencesOnLine > 1 ? "（本行另 \(match.occurrencesOnLine - 1) 处）" : ""
                lines.append("\(match.path.description):\(match.line):\(match.column)│ \(match.text)\(suffix)")
                for context in match.contextAfter { lines.append("\(match.path.description)-\(match.line)│ \(context)") }
            }
        }
        if result.truncated, let reason = result.truncationReason {
            lines.append("（结果已截断：\(reason)。缩小范围或加上 `file_glob` 再搜）")
        }
        return deliver(lines.joined(separator: "\n"), call: call, name: "搜索结果")
    }

    private func outlineFile(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        guard let path = args.value(at: ["path"])?.stringValue.flatMap(resolve) else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `path`。")
        }
        let maxEntries = args.value(at: ["max_entries"])?.intValue ?? 200
        let content = try vfs.read(path, options: ReadOptions(maxBytes: 2 * 1024 * 1024))
        let lines = content.text.components(separatedBy: "\n")

        // ⚠️ 这是**轻量**大纲：按缩进 + 常见定义关键字识别，不是 tree-sitter 语法树。
        //    设计文档里的 tree-sitter 版本要等 macOS；这一版先给出"文件由哪些块组成"这个最低价值，
        //    并**如实说明它是近似**——假装精确比不精确更糟。
        var entries: [String] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            let isDefinition = trimmed.hasPrefix("def ")
                || trimmed.hasPrefix("class ")
                || trimmed.hasPrefix("func ")
                || trimmed.hasPrefix("struct ")
                || trimmed.hasPrefix("enum ")
                || trimmed.hasPrefix("protocol ")
                || trimmed.hasPrefix("extension ")
                || trimmed.hasPrefix("interface ")
                || trimmed.hasPrefix("function ")
                || trimmed.hasPrefix("#")
            guard isDefinition else { continue }
            entries.append("\(index + 1)│\(String(repeating: " ", count: min(indent, 20)))\(trimmed.prefix(80))")
            if entries.count >= maxEntries { break }
        }
        let header = "\(path.description)（共 \(content.totalLines) 行，识别出 \(entries.count) 个定义/段落）\n"
        return .ok(callID: call.id,
                   summary: header + (entries.isEmpty ? "（没识别出定义——它可能不是代码文件）" : entries.joined(separator: "\n"))
                       + "\n\n（这是按缩进与关键字做的**近似**大纲，不是语法树。）")
    }

    private func hashFile(_ call: ToolCall, _ args: JSONValue) throws -> ToolResult {
        guard let path = args.value(at: ["path"])?.stringValue.flatMap(resolve) else {
            throw ToolError(kind: .invalidArguments, modelFacingMessage: "缺少 `path`。")
        }
        let algorithm = args.value(at: ["algorithm"])?.stringValue ?? "sha256"
        guard algorithm == "sha256" else {
            throw ToolError(kind: .invalidArguments,
                            modelFacingMessage: "只支持 `sha256`（`\(algorithm)` 在设备上没有实现）。",
                            suggestion: "改用 `algorithm: \"sha256\"`。")
        }
        let content = try vfs.read(path, options: ReadOptions(maxBytes: 64 * 1024 * 1024, allowBinary: true))
        let digest = SHA256.hash(Data(content.text.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return .ok(callID: call.id, summary: "\(path.description)\nsha256: \(hex)")
    }

    /// 工具参数 → 引擎的输出模式。
    ///
    /// ⚠️ 两边的词汇不一样（工具面向模型，用 `content`/`count`；引擎面向实现，用 `matches`/`countOnly`），
    ///    所以必须显式映射 —— 直接 `OutputMode(rawValue:)` 会在 `count` 上静默退化成 `.matches`。
    static func outputMode(fromToolArgument raw: String?) -> GrepQuery.OutputMode {
        switch raw {
        case "count": return .countOnly
        case "files": return .filesWithMatches
        default: return .matches
        }
    }

    // MARK: 输出纪律

    /// 按 spec 声明的输出形态决定"内联还是转制品"。
    ///
    /// ⚠️ 所有 handler 都必须经过它 —— 漏掉任何一个，模型就会在某次调用里收到几 MB 的日志
    ///    （`docs/05 §7` 那条纪律的唯一落点）。
    private func deliver(_ text: String, call: ToolCall, name: String) -> ToolResult {
        let spec = registry[call.name]
        let budget: OutputBudget
        switch spec?.outputShape {
        case .inline(let maxBytes): budget = OutputBudget(inlineLimit: maxBytes, artifactLimit: 4 * 1024 * 1024)
        case .artifact(let threshold): budget = OutputBudget(inlineLimit: threshold, artifactLimit: 8 * 1024 * 1024)
        case nil: budget = .standard
        }

        switch budget.disposition(byteCount: text.utf8.count) {
        case .inline:
            return .ok(callID: call.id, summary: text)
        case .artifact, .refuse:
            guard let reference = try? artifacts.store(text, suggestedName: "\(call.name).txt", kind: .log) else {
                // 连制品都存不下时**不能假装成功**：把前面一段给出去，并说清只有一段
                let head = budget.preview(text)
                return .ok(callID: call.id,
                           summary: "输出过大（\(OutputBudget.humanBytes(text.utf8.count))）且无法落为制品，只给了前面一段：\n\n\(head)")
            }
            let note = budget.artifactNote(
                handle: reference.relPath, displayName: "\(call.name) 的输出",
                byteCount: text.utf8.count, lineCount: reference.lineCount
            )
            return ToolResult(callID: call.id, status: .truncated,
                              summary: note + "\n\n预览：\n" + budget.preview(text),
                              artifacts: [reference])
        }
    }
}

// MARK: - 错误换算

private extension PatchApplication.FileChange {
    /// `PatchFile.Action` 在本项目里叫 `action`；这里给一个中性的名字避免与 `path` 混淆
    var pathAction: PatchFile.Action { action }
}

extension VFSFailure {
    /// 换成面向模型的工具错误。
    ///
    /// ⚠️ 分类要**准**：它决定了运行时会不会让模型自己改一次（`isSelfCorrectable`）。
    ///    把"路径不存在"报成"参数不合法"会让模型去乱改参数，反之则会让它放弃。
    func asToolError(path: VFSPath?) -> ToolError {
        let kind: ToolError.Kind
        switch self.kind {
        case .notFound, .parentMissing: kind = .pathNotFound
        case .outsideRoot, .symlinkEscape, .notAFile, .notADirectory,
             .alreadyExists, .notEmpty, .tooLarge: kind = .invalidArguments
        case .isBinary: kind = .other
        case .ioError: kind = .other
        }
        return ToolError(
            kind: kind,
            modelFacingMessage: detail,
            suggestion: suggestionForKind(),
            candidates: candidates
        )
    }

    private func suggestionForKind() -> String? {
        switch kind {
        case .notFound:
            return candidates.isEmpty
                ? "用 `list_dir` 或 `glob` 确认一下真实路径。"
                : "工作区里名字最接近的是：\(candidates.prefix(5).joined(separator: "、"))"
        case .notADirectory: return "它是个文件；要读内容请用 `read_file`。"
        case .notAFile: return "它是个目录；要列内容请用 `list_dir`。"
        case .alreadyExists: return "目标已存在。要覆盖请明确要求，或者换个名字。"
        case .notEmpty: return "目录非空。要删除请明确要求递归。"
        case .isBinary: return "这是二进制文件，读出来对判断没有帮助；需要内容请用专门工具。"
        case .outsideRoot, .symlinkEscape:
            return "工作区之外的路径不在授权范围内；改用工作区内的相对路径，或先让用户授权。"
        case .parentMissing: return "先建目录（`make_dir`），或者让写入自动创建父目录。"
        case .tooLarge: return "先用检索缩小范围，再分段处理。"
        case .ioError: return "换个做法，或先确认这个路径没有在被别的程序占用。"
        }
    }
}


