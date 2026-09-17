import Testing
import Foundation
@testable import RuneKernel

// MARK: - 本机工具实现的测试
//
// 这一组的意义：把 `ToolRegistry` 里的**契约**变成**真能干活的工具**。
// 而且因为 VFS 有两份实现（C23），同一套断言可以同时验证内存与真实文件系统 ——
// 在没有 Mac 的开发路径下（docs/16），这是唯一能保证这些工具是对的办法。

private func tempVFS() -> (any VFS, URL, () -> Void) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("rune-tools-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (FileManagerVFS(baseURL: base), base, { try? FileManager.default.removeItem(at: base) })
}

private func call(_ name: String, _ args: [String: JSONValue], id: String = "c1") -> ToolCall {
    ToolCall(id: id, name: name, argumentsJSON: Data(JSONValue.object(args).canonicalString().utf8))
}

private func seedProject(_ vfs: any VFS) throws {
    _ = try vfs.write(path("/workspace/src/money.py"), content: """
    def round_amount(amount):
        # BUG: 没有按币种精度取整
        return round(amount)

    def total(items):
        return round(sum(items))
    """)
    _ = try vfs.write(path("/workspace/tests/test_money.py"), content: """
    def test_round_amount():
        assert round_amount(12.295) == 12.30
    """)
    _ = try vfs.write(path("/workspace/README.md"), content: "# 演示项目\n\n跑在设备上的 Agent。\n")
}

private func executor(_ vfs: any VFS) -> LocalToolExecutor {
    LocalToolExecutor(vfs: vfs, now: { Date(timeIntervalSince1970: 1_700_000_000) })
}

// MARK: - 基础行为

@Suite("LocalToolExecutor —— 参数校验与错误分类")

struct LocalToolExecutorBasicsTests {

    @Test("⭐ 参数不合 schema 时**必须先拒绝，再动手**")
    func validatesBeforeActing() throws {
        let (vfs, _, cleanup) = tempVFS()
        defer { cleanup() }
        try seedProject(vfs)

        // 缺 `path` 的 delete_path —— 如果先执行再校验，就会删掉点什么
        let result = try executor(vfs).execute(call(ToolName.deletePath, [:]))
        #expect(result.status == .error)
        #expect(result.error?.kind == .invalidArguments)
        // 报错要说清**缺哪个字段**（模型靠它自己改对）
        #expect(result.error?.candidates.contains("path") == true)
        #expect(result.summary.contains("参数"))
        // 文件一个都没少
        #expect(try vfs.exists(path("/workspace/README.md")))
    }

    @Test("未知工具给最接近的名字")
    func unknownTool() throws {
        let (vfs, _, cleanup) = tempVFS()
        defer { cleanup() }
        let result = try executor(vfs).execute(call("reed_file", ["path": .string("a.py")]))
        #expect(result.error?.kind == .unknownTool)
        #expect(result.error?.suggestion?.contains("read_file") == true)
    }

    @Test("不属于本机工具集的工具要如实说明（而不是假装没这个工具）")
    func platformToolsAreReportedHonestly() throws {
        let (vfs, _, cleanup) = tempVFS()
        defer { cleanup() }
        let result = try executor(vfs).execute(call(ToolName.runPython, ["code": .string("print(1)")]))
        #expect(result.status == .error)
        #expect(result.summary.contains("平台层"))
    }

    @Test("⭐ 相对路径按工作区根解析（与策略引擎用同一套 CallPaths）")
    func relativePathsResolve() throws {
        let (vfs, _, cleanup) = tempVFS()
        defer { cleanup() }
        try seedProject(vfs)
        // 模型给的多半是相对路径 —— 这条不生效的话，所有工具都会"找不到文件"
        let result = try executor(vfs).execute(call(ToolName.readFile, ["path": .string("src/money.py")]))
        #expect(result.status == .ok)
        #expect(result.summary.contains("round_amount"))
    }

    @Test("文件不存在时给相似路径候选")
    func notFoundGivesCandidates() throws {
        let (vfs, _, cleanup) = tempVFS()
        defer { cleanup() }
        try seedProject(vfs)
        let result = try executor(vfs).execute(call(ToolName.readFile, ["path": .string("src/monye.py")]))
        #expect(result.error?.kind == .pathNotFound)
        #expect(result.error?.candidates.contains { $0.hasSuffix("money.py") } == true)
    }
}

// MARK: - 文件操作

@Suite("LocalToolExecutor —— 文件工具（内存与真实文件系统跑同一套断言）")

struct LocalToolExecutorFileTests {

    /// 同一个测试体，跑在两份 VFS 上
    private func runBoth(_ body: (any VFS) throws -> Void) throws {
        let memory = MemoryVFS(files: [:], directories: [])
        try seedProject(memory)
        try body(memory)

        let (disk, _, cleanup) = tempVFS()
        defer { cleanup() }
        try seedProject(disk)
        try body(disk)
    }

    @Test("list_dir")
    func listDir() throws {
        try runBoth { vfs in
            let result = try executor(vfs).execute(call(ToolName.listDir, ["path": .string("/workspace")]))
            #expect(result.status == .ok)
            #expect(result.summary.contains("src"))
            #expect(result.summary.contains("README.md"))
        }
    }

    @Test("⭐ read_file 给出行号，且行号是**文件里的真实行号**")
    func readFileNumbersLines() throws {
        try runBoth { vfs in
            let all = try executor(vfs).execute(call(ToolName.readFile, ["path": .string("src/money.py")]))
            #expect(all.summary.contains("共 6 行"))
            #expect(all.summary.contains("1│def round_amount"))
            #expect(all.summary.contains("3│    return round(amount)"))

            let partial = try executor(vfs).execute(call(ToolName.readFile, [
                "path": .string("src/money.py"), "start_line": .int(3), "end_line": .int(4),
            ]))
            // ⚠️ 部分读取的行号必须接着文件的真实行号走，否则模型会拿错行号打补丁
            #expect(partial.summary.contains("3│"), "部分读取的行号应当从 3 开始：\(partial.summary)")
            #expect(!partial.summary.contains("1│def"))
        }
    }

    @Test("⭐ write_file 要区分「新建」与「覆盖」（覆盖可能已经毁掉用户原有内容）")
    func writeFileDistinguishesCreate() throws {
        try runBoth { vfs in
            let created = try executor(vfs).execute(call(ToolName.writeFile, [
                "path": .string("src/new.py"), "content": .string("x = 1\n"),
            ]))
            #expect(created.summary.contains("新建"))

            let overwritten = try executor(vfs).execute(call(ToolName.writeFile, [
                "path": .string("src/new.py"), "content": .string("x = 2\n"),
            ]))
            #expect(overwritten.summary.contains("覆盖"))
            #expect(try vfs.read(path("/workspace/src/new.py")).text == "x = 2\n")
        }
    }

    @Test("⭐ edit_file 唯一才改；匹配多处必须拒绝")
    func editFileUniqueness() throws {
        try runBoth { vfs in
            let ok = try executor(vfs).execute(call(ToolName.editFile, [
                "path": .string("src/money.py"),
                "old_string": .string("return round(amount)"),
                "new_string": .string("return round(amount, 2)"),
            ]))
            #expect(ok.status == .ok)
            #expect(try vfs.read(path("/workspace/src/money.py")).text.contains("round(amount, 2)"))

            // 造一个多处匹配的文件
            _ = try vfs.write(path("/workspace/dup.txt"), content: "same\nsame\n")
            let ambiguous = try executor(vfs).execute(call(ToolName.editFile, [
                "path": .string("dup.txt"),
                "old_string": .string("same"), "new_string": .string("other"),
            ]))
            #expect(ambiguous.status == .error)
            #expect(ambiguous.summary.contains("2 次"), "要说清出现了几次：\(ambiguous.summary)")
            // ⚠️ 被拒绝时**一个字都不能改**
            #expect(try vfs.read(path("/workspace/dup.txt")).text == "same\nsame\n")
        }
    }

    @Test("edit_file 找不到旧内容时给出最接近的位置")
    func editFileNotFoundGivesNearest() throws {
        try runBoth { vfs in
            let result = try executor(vfs).execute(call(ToolName.editFile, [
                "path": .string("src/money.py"),
                "old_string": .string("return round(amountt)"),
                "new_string": .string("x"),
            ]))
            #expect(result.status == .error)
            #expect(result.summary.contains("找不到"))
        }
    }

    @Test("⭐ apply_patch：一次改多个文件，且一处失败则整体不落地")
    func applyPatchMultiFile() throws {
        try runBoth { vfs in
            let patch = """
            *** File: src/money.py
            @@
            -    return round(amount)
            +    return round(amount, 2)
            *** File: README.md
            @@
            -# 演示项目
            +# 退款金额修复演示
            """
            let result = try executor(vfs).execute(call(ToolName.applyPatch, ["patch": .string(patch)]))
            #expect(result.status == .ok, "补丁应当成功：\(result.summary)")
            #expect(try vfs.read(path("/workspace/src/money.py")).text.contains("round(amount, 2)"))
            #expect(try vfs.read(path("/workspace/README.md")).text.contains("退款金额修复演示"))
        }
    }

    @Test("⚠️ 补丁里有一处锚点找不到 → **一个文件都不改**")
    func applyPatchIsAllOrNothing() throws {
        try runBoth { vfs in
            let before = try vfs.read(path("/workspace/src/money.py")).text
            let patch = """
            *** File: src/money.py
            @@
            -    return round(amount)
            +    return round(amount, 2)
            *** File: README.md
            @@
            -这段内容根本不存在
            +新内容
            """
            let result = try executor(vfs).execute(call(ToolName.applyPatch, ["patch": .string(patch)]))
            #expect(result.status == .error)
            // ⚠️ 第一个文件的改动也不能落地 —— 否则用户面对的是"改了一半"的工作区
            #expect(try vfs.read(path("/workspace/src/money.py")).text == before,
                    "整体失败时第一个文件也不该被改")
        }
    }

    @Test("⭐ delete_path 默认进回收站，不真删")
    func deleteGoesToTrash() throws {
        try runBoth { vfs in
            let result = try executor(vfs).execute(call(ToolName.deletePath, ["path": .string("README.md")]))
            #expect(result.status == .ok)
            #expect(result.summary.contains("回收站"))
            #expect(!(try vfs.exists(path("/workspace/README.md"))))
            // 文件确实还在（在回收站里）
            let trashed = try vfs.list(path("/workspace/.rune/trash"), options: ListOptions(includeHidden: true))
            #expect(!trashed.isEmpty)
        }
    }

    @Test("永久删除要明确要求")
    func permanentDelete() throws {
        try runBoth { vfs in
            let result = try executor(vfs).execute(call(ToolName.deletePath, [
                "path": .string("README.md"), "permanent": .bool(true),
            ]))
            #expect(result.summary.contains("永久删除"))
            #expect(result.summary.contains("不可撤销"))
            #expect(!(try vfs.exists(path("/workspace/README.md"))))
            // 别的文件一个都不能少
            #expect(try vfs.exists(path("/workspace/src/money.py")))
        }
    }

    @Test("move / copy / make_dir / stat_path")
    func miscellaneousOps() throws {
        try runBoth { vfs in
            let ex = executor(vfs)
            let moved = try ex.execute(call(ToolName.movePath, [
                "source": .string("README.md"), "destination": .string("docs/README.md"),
            ]))
            #expect(moved.status == .ok)
            #expect(try vfs.exists(path("/workspace/docs/README.md")))

            let copied = try ex.execute(call(ToolName.copyPath, [
                "source": .string("docs/README.md"), "destination": .string("docs/README.bak"),
            ]))
            #expect(copied.status == .ok)

            let dir = try ex.execute(call(ToolName.makeDir, ["path": .string("a/b/c")]))
            #expect(dir.status == .ok)

            let stat = try ex.execute(call(ToolName.statPath, ["path": .string("docs/README.bak")]))
            #expect(stat.summary.contains("file"))
            #expect(stat.summary.contains("大小"))
        }
    }
}

// MARK: - 检索

@Suite("LocalToolExecutor —— 检索工具")

struct LocalToolExecutorSearchTests {

    @Test("glob 按通配匹配，按修改时间倒序")
    func glob() throws {
        let (vfs, _, cleanup) = tempVFS()
        defer { cleanup() }
        try seedProject(vfs)
        let result = try executor(vfs).execute(call(ToolName.glob, ["pattern": .string("**/*.py")]))
        #expect(result.status == .ok)
        #expect(result.summary.contains("src/money.py"))
        #expect(result.summary.contains("tests/test_money.py"))
        #expect(!result.summary.contains("README.md"))
    }

    @Test("⭐ grep_search：中文与正则都能搜")
    func grepSearch() throws {
        let (vfs, _, cleanup) = tempVFS()
        defer { cleanup() }
        try seedProject(vfs)
        let ex = executor(vfs)

        let literal = try ex.execute(call(ToolName.grepSearch, [
            "pattern": .string("round_amount"), "file_glob": .string("*.py"),
        ]))
        #expect(literal.status == .ok)
        #expect(literal.summary.contains("money.py:1"))
        #expect(literal.summary.contains("test_money.py"))

        // 正则模式
        let regex = try ex.execute(call(ToolName.grepSearch, [
            "pattern": .string("round\\(.*\\)"), "is_regex": .bool(true), "file_glob": .string("*.py"),
        ]))
        #expect(regex.status == .ok)
        #expect(regex.summary.contains("money.py"))

        // 中文（本项目的用户是中文用户，这条必须有）
        let chinese = try ex.execute(call(ToolName.grepSearch, ["pattern": .string("演示项目")]))
        #expect(chinese.summary.contains("README.md"))
    }

    @Test("没有匹配时如实说扫了多少、跳过多少")
    func grepNoMatch() throws {
        let (vfs, _, cleanup) = tempVFS()
        defer { cleanup() }
        try seedProject(vfs)
        let result = try executor(vfs).execute(call(ToolName.grepSearch, ["pattern": .string("绝对不存在的东西")]))
        #expect(result.status == .ok)
        #expect(result.summary.contains("没有匹配"))
        #expect(result.summary.contains("扫了"))
    }

    @Test("outline_file 给出近似大纲，并**如实说明它是近似**")
    func outline() throws {
        let (vfs, _, cleanup) = tempVFS()
        defer { cleanup() }
        try seedProject(vfs)
        let result = try executor(vfs).execute(call(ToolName.outlineFile, ["path": .string("src/money.py")]))
        #expect(result.summary.contains("def round_amount"))
        #expect(result.summary.contains("近似"), "要说明这不是语法树：\(result.summary)")
    }

    @Test("hash_file 只支持 sha256，并且如实说明别的算法没实现")
    func hashFile() throws {
        let (vfs, _, cleanup) = tempVFS()
        defer { cleanup() }
        try seedProject(vfs)
        let ex = executor(vfs)
        let ok = try ex.execute(call(ToolName.hashFile, ["path": .string("src/money.py")]))
        #expect(ok.summary.contains("sha256:"))

        let md5 = try ex.execute(call(ToolName.hashFile, [
            "path": .string("src/money.py"), "algorithm": .string("md5"),
        ]))
        #expect(md5.status == .error)
        #expect(md5.summary.contains("sha256"))
    }
}

// MARK: - 输出纪律与制品

@Suite("LocalToolExecutor —— 输出纪律（大输出转制品，且能读回来）")

struct LocalToolExecutorArtifactTests {

    @Test("⭐ 小输出直接内联")
    func smallOutputInline() throws {
        let (vfs, _, cleanup) = tempVFS()
        defer { cleanup() }
        try seedProject(vfs)
        let result = try executor(vfs).execute(call(ToolName.readFile, ["path": .string("README.md")]))
        #expect(result.artifacts.isEmpty)
        #expect(result.status == .ok)
    }

    @Test("⭐ 大输出转制品：给句柄 + 摘要 + 预览，而且**能读回来**")
    func largeOutputBecomesArtifact() throws {
        let (vfs, _, cleanup) = tempVFS()
        defer { cleanup() }
        // 造一个大到超过内联上限的文件
        let big = (1...5_000).map { "第 \($0) 行：一些内容" }.joined(separator: "\n")
        _ = try vfs.write(path("/workspace/big.txt"), content: big)

        let store = InMemoryArtifactStore()
        let ex = LocalToolExecutor(vfs: vfs, artifacts: store, now: { Date() })

        let result = try ex.execute(call(ToolName.readFile, ["path": .string("big.txt")]))
        #expect(result.status == .truncated, "大输出应当被标成 truncated：\(result.status)")
        #expect(result.artifacts.count == 1)
        let handle = try #require(result.artifacts.first?.relPath)
        #expect(result.summary.contains("read_artifact"))
        #expect(result.summary.contains("预览"))
        // ⚠️ 上下文里不该出现全文
        #expect(result.summary.utf8.count < big.utf8.count / 3)

        // ⭐ 最重要的一条：给出去的东西**必须能拿回来**（否则"截断"等于"丢数据"）
        let readBack = try ex.execute(call(ToolName.readArtifact, ["handle": .string(handle)]))
        #expect(readBack.status != .error)
        #expect(readBack.summary.contains("第 1 行"))

        // 关键字定位也要能用
        let located = try ex.execute(call(ToolName.readArtifact, [
            "handle": .string(handle), "keyword": .string("第 4321 行"),
        ]))
        #expect(located.summary.contains("第 4321 行"))
    }

    @Test("制品句柄不存在时给候选")
    func missingArtifact() throws {
        let (vfs, _, cleanup) = tempVFS()
        defer { cleanup() }
        let result = try executor(vfs).execute(call(ToolName.readArtifact, ["handle": .string("artifacts/nope.txt")]))
        #expect(result.status == .error)
        #expect(result.error?.kind == .pathNotFound)
    }
}

// MARK: - ⭐ 端到端：在**真实文件系统**上跑完一个完整任务

@Suite("LocalToolExecutor × TurnRunner —— 在真实文件系统上当 Agent")

struct LocalToolExecutorEndToEndTests {

    /// 一个真实形状的脚本：找 bug → 读文件 → 改文件 → 再读一遍确认
    private func fixScript() -> @Sendable (TurnState) -> [ModelEvent] {
        { state in
            switch state.round {
            case 0:
                return oneCall("c1", ToolName.grepSearch,
                               .object(["pattern": .string("round(amount)"), "file_glob": .string("*.py")]))
            case 1:
                return oneCall("c2", ToolName.readFile, .object(["path": .string("src/money.py")]))
            case 2:
                return oneCall("c3", ToolName.editFile, .object([
                    "path": .string("src/money.py"),
                    "old_string": .string("return round(amount)"),
                    "new_string": .string("return round(amount, 2)"),
                ]))
            case 3:
                return oneCall("c4", ToolName.readFile, .object(["path": .string("src/money.py")]))
            default:
                return [.textDelta("改好了，并且复读确认过。"), .finished(reason: .stop)]
            }
        }
    }

    private func deps(_ vfs: any VFS) -> TurnRunner.Dependencies {
        let scope = VFSPath(mount: .workspace)
        let token = CapabilityToken(
            issuedForTurn: UUID(),
            scopes: [.fsRead(scope), .fsWrite(scope)],
            expiresAt: Date().addingTimeInterval(3_600),
            grantedBy: .planApproval, reason: "端到端测试"
        )
        return TurnRunner.Dependencies(
            modelEvents: fixScript(),
            executor: LocalToolExecutor(vfs: vfs, now: { Date() }),
            policy: PolicyEngine(),
            policyContext: PolicyEngine.Context(trustDial: .collaborate, token: token, planApproved: true),
            now: { Date() },
            pathsOfCall: ToolScheduler.defaultPaths
        )
    }

    @Test("⭐ 真实文件系统上：找 bug → 读 → 改 → 复读确认，磁盘上的文件真的变了")
    func fixesAFileOnDisk() throws {
        let (vfs, base, cleanup) = tempVFS()
        defer { cleanup() }
        try seedProject(vfs)

        let (final, events, _) = TurnRunner.run(
            TurnState(objective: "修掉 round_amount 没做精度取整的问题"),
            deps: deps(vfs), config: TurnRunner.Config(maxRounds: 8, maxToolCalls: 12, toolRegistry: ToolRegistry.byName)
        )

        #expect(final.status == .completed)
        #expect(final.toolCallCount == 4)

        // ⭐ 磁盘上的**真实文件**被改了（不是内存里的副本）
        let onDisk = try String(contentsOf: base.appendingPathComponent("src/money.py"), encoding: .utf8)
        #expect(onDisk.contains("round(amount, 2)"), "磁盘上的文件没被改：\(onDisk)")
        #expect(!onDisk.contains("return round(amount)\n"))

        // 别的文件没被动
        let readme = try String(contentsOf: base.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains("演示项目"))

        // 事件流里能看到完整的一串工具调用
        let toolCalls = events.filter { $0.kind == .toolCallRequested }
            .compactMap { $0.payload.value(at: ["tool"])?.stringValue }
        #expect(toolCalls == [ToolName.grepSearch, ToolName.readFile, ToolName.editFile, ToolName.readFile])
    }

    @Test("⭐ 越权路径被策略引擎拦下，且**磁盘上什么都没变**")
    func outOfScopeWriteNeverReachesDisk() throws {
        let (vfs, base, cleanup) = tempVFS()
        defer { cleanup() }
        try seedProject(vfs)

        // 只授权 src/ 可写
        let srcScope = VFSPath(mount: .workspace, components: ["src"])
        let token = CapabilityToken(
            issuedForTurn: UUID(),
            scopes: [.fsRead(VFSPath(mount: .workspace)), .fsWrite(srcScope)],
            expiresAt: Date().addingTimeInterval(3_600),
            grantedBy: .planApproval, reason: "只给 src"
        )
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            guard state.round == 0 else { return [] }
            return oneCall("bad", ToolName.writeFile, .object([
                "path": .string("README.md"), "content": .string("被改坏了"),
            ]))
        }
        let deps = TurnRunner.Dependencies(
            modelEvents: script,
            executor: LocalToolExecutor(vfs: vfs, now: { Date() }),
            policy: PolicyEngine(),
            policyContext: PolicyEngine.Context(trustDial: .collaborate, token: token, planApproved: true),
            now: { Date() }, pathsOfCall: ToolScheduler.defaultPaths
        )
        let (final, _, _) = TurnRunner.run(
            TurnState(objective: "改 README"), deps: deps,
            config: TurnRunner.Config(maxRounds: 4, maxToolCalls: 4, toolRegistry: ToolRegistry.byName)
        )

        let result = final.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }.first
        #expect(result?.status == .denied || result?.status == .error)

        // ⭐ 最关键的一条：**工具根本没被执行**，磁盘上必须是原样
        let readme = try String(contentsOf: base.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains("演示项目"), "越权写入竟然落到了磁盘上：\(readme)")
        #expect(!readme.contains("被改坏了"))
    }
}
