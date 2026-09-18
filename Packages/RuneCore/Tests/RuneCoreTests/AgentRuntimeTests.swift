import Foundation
import Testing
import RuneKernel
import RuneStore
@testable import RuneCore

final class FixtureTransport: ModelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [ModelHTTPResponse]
    private var sent: [ModelHTTPRequest] = []
    init(_ bodies: [String]) { responses = bodies.map { .init(statusCode: 200, body: Data($0.utf8)) } }
    var requests: [ModelHTTPRequest] { lock.lock(); defer { lock.unlock() }; return sent }
    func send(_ request: ModelHTTPRequest) throws -> ModelHTTPResponse {
        lock.lock(); defer { lock.unlock() }
        sent.append(request)
        guard !responses.isEmpty else { throw ProviderError(kind: .request, providerID: "test", message: "fixture exhausted", userFacingMessage: "fixture exhausted") }
        return responses.removeFirst()
    }
}
private func text(_ value: String) -> String {
    "data: " + JSONValue.object(["choices": .array([.object(["delta": .object(["content": .string(value)]), "finish_reason": .string("stop")])])]).canonicalString() + "\n\ndata: [DONE]\n\n"
}
private func call(_ name: String, _ args: JSONValue, id: String = "call-1") -> String {
    "data: " + JSONValue.object(["choices": .array([.object(["delta": .object(["tool_calls": .array([.object(["index": .int(0), "id": .string(id), "function": .object(["name": .string(name), "arguments": .string(args.canonicalString())])])])]), "finish_reason": .string("tool_calls")])])]).canonicalString() + "\n\ndata: [DONE]\n\n"
}
private struct Fixture {
    let directory: URL
    let config: RuntimeConfiguration
    let store: RuneEventStore
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "before\n".write(to: directory.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        store = try RuneEventStore(inMemory: true)
        let provider = ProviderConfig(id: "fixture", displayName: "测试", protocolFamily: .openAIChat,
                                      baseURL: "https://fixture.example/v1", auth: .bearer(keyRef: "test"), models: [])
        config = .init(sessionID: UUID(), workspaceID: UUID(), workspaceURL: directory,
                       artifactsURL: directory.appendingPathComponent("artifacts"), provider: provider, modelID: "test", secret: "fixture-secret")
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func content() throws -> String { try String(contentsOf: directory.appendingPathComponent("notes.md"), encoding: .utf8) }
}
private func finish(_ stream: AsyncThrowingStream<RuntimeUpdate, Error>) async throws -> RuntimeSnapshot {
    var final: RuntimeSnapshot?
    for try await update in stream { if case .snapshot(let snapshot) = update { final = snapshot } }
    return try #require(final)
}
@Suite("真实运行时接线")
struct AgentRuntimeTests {
    @Test("模型读取文件，结果回传后完成；事件与状态真实存储")
    func readAndFinish() async throws {
        let f = try Fixture(); defer { f.remove() }
        let transport = FixtureTransport([call(ToolName.readFile, ["path": .string("notes.md")]), text("已经读到 before")])
        let runtime = try AgentRuntime(configuration: f.config, objective: "读文件", store: f.store, transport: transport)
        let result = try await finish(runtime.run())
        #expect(result.state.status == .completed)
        #expect(result.state.toolCallCount == 1)
        #expect(transport.requests.count == 2)
        #expect(String(decoding: transport.requests[1].body, as: UTF8.self).contains("before"))
        #expect(try f.store.eventLog(sessionID: f.config.sessionID).verify(full: true).isOK)
        #expect(try f.store.loadRuntime(sessionID: f.config.sessionID)?.state.status == .completed)
    }
    @Test("修改必须先审批，重建运行时后批准能继续且不丢上下文")
    func approvalAndRecovery() async throws {
        let f = try Fixture(); defer { f.remove() }
        let transport = FixtureTransport([call(ToolName.editFile, ["path": .string("notes.md"), "old_string": .string("before"), "new_string": .string("after")]), text("已完成")])
        let runtime = try AgentRuntime(configuration: f.config, objective: "改文件", store: f.store, transport: transport)
        let paused = try await finish(runtime.run())
        #expect(paused.state.status == .awaitingApproval)
        #expect(try f.content() == "before\n")
        let approval = try #require(paused.metadata.approval)
        #expect(approval.changes.first?.after == "after\n")
        let recovered = try AgentRuntime(configuration: f.config, objective: "改文件", store: f.store, transport: transport)
        let done = try await finish(recovered.run(.approve(callID: approval.call.id)))
        #expect(done.state.status == .completed)
        #expect(try f.content() == "after\n")
        #expect(done.metadata.changes.first?.applied == true)
    }
    @Test("拒绝不会写文件，而且工具结果仍与调用配对")
    func rejection() async throws {
        let f = try Fixture(); defer { f.remove() }
        let transport = FixtureTransport([call(ToolName.writeFile, ["path": .string("notes.md"), "content": .string("replace")]), text("保留原文件")])
        let runtime = try AgentRuntime(configuration: f.config, objective: "改文件", store: f.store, transport: transport)
        let pending = try await finish(runtime.run())
        let approval = try #require(pending.metadata.approval)
        let done = try await finish(runtime.run(.reject(callID: approval.call.id)))
        #expect(done.state.status == .completed)
        #expect(try f.content() == "before\n")
        #expect(OutboundCheck.review(done.state.messages, family: .openAIChat).isSendable)
    }
    @Test("审阅期间文件变化必须阻止旧变更")
    func externalChange() async throws {
        let f = try Fixture(); defer { f.remove() }
        let transport = FixtureTransport([call(ToolName.writeFile, ["path": .string("notes.md"), "content": .string("replace")])])
        let runtime = try AgentRuntime(configuration: f.config, objective: "改文件", store: f.store, transport: transport)
        let pending = try await finish(runtime.run())
        try "user edit".write(to: f.directory.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        await #expect(throws: RuntimeFailure.self) { try await finish(runtime.run(.approve(callID: "call-1"))) }
        #expect(pending.metadata.approval != nil)
        #expect(try f.content() == "user edit")
    }
    @Test("正常结束后追加问题会复用历史并保持事件链连续")
    func followUp() async throws {
        let f = try Fixture(); defer { f.remove() }
        let transport = FixtureTransport([text("第一轮完成"), text("第二轮完成")])
        let runtime = try AgentRuntime(configuration: f.config, objective: "第一个问题", store: f.store, transport: transport)
        _ = try await finish(runtime.run())
        let done = try await finish(runtime.run(.followUp("第二个问题")))
        #expect(done.state.status == .completed)
        #expect(String(decoding: transport.requests.last!.body, as: UTF8.self).contains("第一轮完成"))
        #expect(try f.store.eventLog(sessionID: f.config.sessionID).verify(full: true).isOK)
    }
    @Test("错误响应不能伪装成完成")
    func failure() async throws {
        let f = try Fixture(); defer { f.remove() }
        let runtime = try AgentRuntime(configuration: f.config, objective: "失败", store: f.store, transport: FixtureTransport(["data: {\"error\":{\"code\":401,\"message\":\"bad key\"}}\n\n"]))
        let result = try await finish(runtime.run())
        #expect(result.state.status == .failed)
        #expect(result.metadata.failure != nil)
    }
}

@Suite("恢复、取消与凭据隔离")
struct RuntimeRecoveryTests {
    @Test("修改意图已提交而结果未知，目标内容已存在时不重复写")
    func interruptedWrite() throws {
        let f = try Fixture(); defer { f.remove() }
        let vfs = ModelWorkspace(base: FileManagerVFS(baseURL: f.directory))
        let args = JSONValue.object(["path": .string("notes.md"), "old_string": .string("before"), "new_string": .string("after")])
        let call = ToolCall(id: "recovered", name: ToolName.editFile, argumentsJSON: Data(args.canonicalString().utf8))
        _ = try vfs.write(try VFSPath.parse("/workspace/notes.md"), content: "after\n")
        let guarded = ReviewedToolExecutor(base: LocalToolExecutor(vfs: vfs), vfs: vfs,
            changes: [.init(callID: call.id, path: "/workspace/notes.md", before: "before\n", after: "after\n")])
        let result = try guarded.execute(call)
        #expect(result.status == .ok)
        #expect(result.summary.contains("未重复写入"))
        #expect(try f.content() == "after\n")
    }
    @Test("凭据不能被读取、列出或复制到普通文件")
    func credentialIsolation() throws {
        let f = try Fixture(); defer { f.remove() }
        try "DO_NOT_SEND".write(to: f.directory.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let vfs = ModelWorkspace(base: FileManagerVFS(baseURL: f.directory))
        let credential = try VFSPath.parse("/workspace/.env")
        #expect(throws: ToolError.self) { try vfs.read(credential) }
        #expect(!vfs.exists(credential))
        try FileManager.default.createSymbolicLink(at: f.directory.appendingPathComponent("ordinary.txt"), withDestinationURL: f.directory.appendingPathComponent(".env"))
        #expect(throws: ToolError.self) { try vfs.read(VFSPath(mount: .workspace, components: ["ordinary.txt"])) }

        #expect(try !vfs.listAll(includeHidden: true).contains { $0.name == ".env" })
        #expect(throws: ToolError.self) { try vfs.copy(credential, to: VFSPath(mount: .workspace, components: ["out.txt"]), overwrite: false) }
    }
    @Test("暂停期间可取消，关闭重开也不继续调用模型")
    func cancelPersistedApproval() async throws {
        let f = try Fixture(); defer { f.remove() }
        let transport = FixtureTransport([call(ToolName.writeFile, ["path": .string("notes.md"), "content": .string("after")])])
        let runtime = try AgentRuntime(configuration: f.config, objective: "修改", store: f.store, transport: transport)
        _ = try await finish(runtime.run())
        let cancelled = try await finish(runtime.run(.cancel))
        #expect(cancelled.metadata.cancelled)
        #expect(try f.content() == "before\n")
        let reloaded = try AgentRuntime(configuration: f.config, objective: "修改", store: f.store, transport: transport)
        await #expect(throws: RuntimeFailure.self) { try await finish(reloaded.run(.resume)) }
        #expect(transport.requests.count == 1)
    }
    @Test("撤销新建文件会删除文件且写入审计，不留空壳文件")
    func undoNewFile() async throws {
        let f = try Fixture(); defer { f.remove() }
        let transport = FixtureTransport([call(ToolName.writeFile, ["path": .string("new.md"), "content": .string("new")]), text("完成")])
        let runtime = try AgentRuntime(configuration: f.config, objective: "新建", store: f.store, transport: transport)
        _ = try await finish(runtime.run())
        let done = try await finish(runtime.run(.approve(callID: "call-1")))
        let change = try #require(done.metadata.changes.first)
        let reverted = try await finish(runtime.run(.undo(changeID: change.id)))
        #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("new.md").path))
        #expect(reverted.metadata.changes.first?.reverted == true)
        #expect(try f.store.eventLog(sessionID: f.config.sessionID).verify(full: true).isOK)
    }
    @Test("取消等待立即唤醒，后续请求不会发出")
    func interruptibleDelay() async throws {
        let control = RuntimeControl()
        let started = Date()
        let worker = Task.detached { try control.wait(seconds: 30) }
        control.stop(cancel: false)
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(Date().timeIntervalSince(started) < 1)
    }
}

@Suite("预算和网络崩溃边界")
struct RuntimeBudgetTests {
    @Test("下一次请求预留超过预算时，一次 HTTP 都不能发送")
    func reserveBeforeSending() async throws {
        let f = try Fixture(); defer { f.remove() }
        let priced = RuntimeConfiguration(sessionID: f.config.sessionID, workspaceID: f.config.workspaceID,
            workspaceURL: f.config.workspaceURL, artifactsURL: f.config.artifactsURL, provider: f.config.provider,
            modelID: f.config.modelID, secret: f.config.secret,
            price: .init(inputMicroPerMTok: 10_000_000, outputMicroPerMTok: 30_000_000), budgetMicroUSD: 1)
        let transport = FixtureTransport([text("done")])
        let runtime = try AgentRuntime(configuration: priced, objective: "test", store: f.store, transport: transport)
        let snapshot = try await finish(runtime.run())
        #expect(snapshot.state.status == .pausedBudget)
        #expect(snapshot.metadata.suggestedBudgetMicroUSD ?? 0 > 1)
        #expect(transport.requests.isEmpty)
        let raised = try await finish(runtime.run(.raiseBudget(1_000_000)))
        #expect(raised.state.status == .completed)
        #expect(transport.requests.count == 1)
    }
    @Test("进程终止在网络调用窗口，恢复必须提示可能重复计费")
    func recoverInFlightModel() throws {
        let f = try Fixture(); defer { f.remove() }
        let state = TurnState(sessionID: f.config.sessionID, objective: "test", status: .reasoning)
        var metadata = RuntimeMetadata(workspaceID: f.config.workspaceID, providerID: f.config.provider.id, modelID: f.config.modelID)
        metadata.inFlightModel = true
        _ = try f.store.commitRuntime(state: state, metadata: JSONEncoder().encode(metadata), events: [], expectedRevision: 0)
        let restored = try #require(try AgentRuntime.snapshot(sessionID: state.sessionID, store: f.store))
        #expect(restored.metadata.paused)
        #expect(restored.metadata.interruptedRequest)
    }
    @Test("无法预览的大文件停在可拒绝的审批，而不是直接写入")
    func oversizedPreview() async throws {
        let f = try Fixture(); defer { f.remove() }
        try String(repeating: "x", count: 300_000).write(to: f.directory.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let transport = FixtureTransport([call(ToolName.writeFile, ["path": .string("notes.md"), "content": .string("bad")]), text("未修改")])
        let runtime = try AgentRuntime(configuration: f.config, objective: "test", store: f.store, transport: transport)
        let pending = try await finish(runtime.run())
        #expect(pending.metadata.approval?.reviewError != nil)
        await #expect(throws: RuntimeFailure.self) { try await finish(runtime.run(.approve(callID: "call-1"))) }
        let denied = try await finish(runtime.run(.reject(callID: "call-1")))
        #expect(denied.state.status == .completed)
        #expect(try f.content().count == 300_000)
    }
}

@Suite("真实 TCP 到运行时的完整链路")
struct RuntimeHTTPIntegrationTests {
    @Test("真实 URLSession 传输经过审批和文件写入，再从 SQLite 验链")
    func actualNetworkLoop() async throws {
        let f = try Fixture(); defer { f.remove() }
        let server = try LoopbackServer { request in
            let response = String(decoding: request.body, as: UTF8.self).contains("tool_call_id")
                ? text("已完成")
                : call(ToolName.editFile, ["path": .string("notes.md"), "old_string": .string("before"), "new_string": .string("after")])
            return .init(chunks: [Data(response.utf8)], chunked: true)
        }
        try await server.start(); defer { server.stop() }
        var provider = f.config.provider; provider.baseURL = server.origin
        let config = RuntimeConfiguration(sessionID: f.config.sessionID, workspaceID: f.config.workspaceID,
            workspaceURL: f.config.workspaceURL, artifactsURL: f.config.artifactsURL, provider: provider,
            modelID: "test", secret: "fixture-only", allowPrivateNetwork: true)
        let runtime = try AgentRuntime(configuration: config, objective: "执行真实网络测试", store: f.store)
        let pending = try await finish(runtime.run())
        #expect(pending.state.status == .awaitingApproval)
        #expect(try f.content() == "before\n")
        let result = try await finish(runtime.run(.approve(callID: "call-1")))
        #expect(result.state.status == .completed)
        #expect(try f.content() == "after\n")
        #expect(server.requests.count == 2)
        #expect(server.requests.first?.headers["authorization"] == "Bearer fixture-only")
        let events = try f.store.loadAll(sessionID: config.sessionID)
        #expect(events.contains { $0.kind == .egressAudited })
        #expect(try f.store.eventLog(sessionID: config.sessionID).verify(full: true).isOK)
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(!encoded.contains("fixture-only"))
    }
}

// MARK: - Git 工具接线（C54）
//
// ⚠️ 这条测试存在的唯一理由：**"模块全绿"不等于"它被调用了"**。
//    项目在这上面栽过四次（T48/T49/T54/T59 —— 规则表、安全闸门、整个网关子系统、
//    守门脚本，全都是"写好了、测过了、没人调"）。
//    所以这里不走 `GitToolExecutor` 单测，而是**从 AgentRuntime 真的执行一次工具调用**，
//    断言模型拿到的那段文本里有 git_status 的结果。

@Suite("Git 工具接线 —— 从 AgentRuntime 真的调用")
struct GitToolWiringTests {

    @Test("⭐⭐ 模型调 git_status：真的执行自研 Git 引擎，而不是报「未知工具」")
    func gitStatusIsReachableFromRuntime() async throws {
        let f = try Fixture()
        defer { f.remove() }
        // 把工作区变成一个真实 git 仓库（用 git 命令行不方便，直接手搓最小结构：
        // 只建 .git 目录，`git_status` 在"没有 HEAD、没有 index"的空仓库上也应当工作）
        let gitDir = f.directory.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir.appendingPathComponent("refs/heads"),
                                                withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: gitDir.appendingPathComponent("HEAD"),
                                           atomically: true, encoding: .utf8)

        let transport = FixtureTransport([
            call(ToolName.gitStatus, .object([:])),
            text("done"),
        ])
        let runtime = try AgentRuntime(configuration: f.config, objective: "看看工作区状态",
                                       store: f.store, transport: transport)
        let result = try await finish(runtime.run())

        let events = try f.store.loadAll(sessionID: f.config.sessionID)
        let completed = events.filter { $0.kind == .toolCallFinished }
        #expect(completed.count == 1, "git_status 必须真的被执行一次，实际完成 \(completed.count) 次")
        // ⚠️ 关键断言：**不能是"未知工具"**。工具没接上时模型收到的正是那个错误，
        //    而它看起来像"模型用错了工具"，很容易被误判成模型的问题。
        let payload = String(decoding: try JSONEncoder().encode(events.map(\.payload)), as: UTF8.self)
        #expect(!payload.contains("未知工具") && !payload.contains("没有名为"),
                "git_status 没有被接上（模型收到「未知工具」）")
        #expect(result.state.status == .completed)
    }

    @Test("⚠️ 模型不能借 git 工具读 .git 里的内容（凭据防线不能被绕开）")
    func gitToolsCannotReachIntoDotGit() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let gitDir = f.directory.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir.appendingPathComponent("refs/heads"),
                                                withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: gitDir.appendingPathComponent("HEAD"),
                                           atomically: true, encoding: .utf8)
        // 放一个"凭据"在 .git 里：如果解析器漏了拦截，它就会变成 git 仓库根
        try "secret-token\n".write(to: gitDir.appendingPathComponent("config"),
                                   atomically: true, encoding: .utf8)

        let transport = FixtureTransport([
            call(ToolName.gitStatus, .object(["path": .string(".git")])),
            text("done"),
        ])
        let runtime = try AgentRuntime(configuration: f.config, objective: "试图进 .git",
                                       store: f.store, transport: transport)
        _ = try await finish(runtime.run())

        let events = try f.store.loadAll(sessionID: f.config.sessionID)
        let payload = String(decoding: try JSONEncoder().encode(events.map(\.payload)), as: UTF8.self)
        // 要么被解析器拒（拿不到路径），要么被当成"不是仓库"——但绝不能真的把 .git 当仓库读
        #expect(!payload.contains("secret-token"), "凭据内容绝不能出现在事件里")
    }
}

// MARK: - run_javascript 接线（C56）

@Suite("JS 工具接线 —— 从 AgentRuntime 真的调用")
struct JavaScriptToolWiringTests {

    @Test("⭐⭐ 模型调 run_javascript：真的执行 JSC 宿主，而不是报「未知工具」")
    func javascriptIsReachableFromRuntime() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let transport = FixtureTransport([
            call(ToolName.runJavaScript, .object(["code": .string("console.log('from-js')")])),
            text("done"),
        ])
        let runtime = try AgentRuntime(configuration: f.config, objective: "跑一段 JS",
                                       store: f.store, transport: transport)
        // ⚠️ `run_javascript` 的 risk 是 `.modifying`、`approval: .perProject`，
        //    所以**第一次一定停在审批门**（这是设计，不是失败）。
        //    第一版测试直接断言"执行完成"，被审批门挡下 —— 那条断言本身是错的。
        let pending = try await finish(runtime.run())
        #expect(pending.state.status == .awaitingApproval, "modifying 工具必须先过审批，实际：\(pending.state.status)")
        let approval = try #require(pending.metadata.approval)
        let result = try await finish(runtime.run(.approve(callID: approval.call.id)))

        let events = try f.store.loadAll(sessionID: f.config.sessionID)
        let payload = String(decoding: try JSONEncoder().encode(events.map(\.payload)), as: UTF8.self)
        // ⚠️⚠️ 这一条我第一版写错了，值得记下来：
        //    原来断言的是「`toolCallFinished` 恰好一条」。但**工具失败时也会发这个事件**
        //    （`toolCallFailed` 是另一个 kind，而"执行过一次"这件事两者都满足）——
        //    于是把 JS 路由整个摘掉（模型收到"未知工具"）时，那条断言**照样绿**。
        //    破坏性验证当场暴露了它：摘掉路由 → 18 条测试一条都没红。
        //    正确的判据是**可观测的行为变化**：JS 真的跑过 → 它的输出必然出现在事件里。
        // ⚠️⚠️ 判据必须落在**工具结果的状态**上，而不是"输出文本里有 from-js"。
        //    我第二版就是查文本，结果仍然是假绿：因为 `argsPreview` 里**回显了模型传的 code**，
        //    所以 "from-js" 在"真的执行了"和"根本没接上"两种状态下**都出现**。
        //    这是"断言了一个不区分两种状态的东西"——比没有断言更危险，因为它看着像在检查。
        //    正确的判据（破坏性验证过）：
        //      * 接上了 → `ToolCallFinished` 的 status 是 ok，summary 是 JS 的输出
        //      * 没接上 → status 是 error，summary 是"不属于本机文件/检索工具集"
        let finished = events.filter { $0.kind == .toolCallFinished }
        #expect(finished.count == 1, "审批后必须真的产生一条工具结果，实际 \(finished.count) 条")
        let status = finished.first?.payload.value(at: ["status"])?.stringValue
        #expect(status == "ok", "工具结果状态应当是 ok，实际：\(status ?? "无")（没接上时会退到 local 并报 error）")
        let summary = finished.first?.payload.value(at: ["summary"])?.stringValue ?? ""
        #expect(!summary.contains("不属于本机文件"), "run_javascript 没有被接上，实际输出：\(summary)")
        #expect(summary.contains("from-js"), "summary 里应当是 JS 的真实输出，实际：\(summary)")
        #expect(!events.contains { $0.kind == .toolCallFailed }, "接上了就不该有工具失败事件")
        #expect(result.state.status == .completed)
    }
}

// MARK: - todo_write 接线（C57）
//
// ⚠️ 判据按 T63 的教训写：**落在可观测的行为差异上**（工具结果的 status + 状态真的被写回），
//    不是"有没有发生过某件事"（失败时也会发 toolCallFinished），
//    也不是查输出文本（argsPreview 会回显参数）。

@Suite("todo_write 接线 —— 从 AgentRuntime 真的调用")
struct TodoToolWiringTests {

    @Test("⭐⭐ 模型调 todo_write：清单必须**写回 TurnState**，而不只是回一段文本")
    func todoIsPersistedIntoState() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let arguments = JSONValue.object(["items": .array([
            .object(["text": .string("读 notes.md"), "status": .string("done")]),
            .object(["text": .string("改成 after"), "status": .string("in_progress")]),
        ])])
        let transport = FixtureTransport([
            call(ToolName.todoWrite, arguments),
            text("done"),
        ])
        let runtime = try AgentRuntime(configuration: f.config, objective: "列个清单",
                                       store: f.store, transport: transport)
        let result = try await finish(runtime.run())

        let events = try f.store.loadAll(sessionID: f.config.sessionID)
        let finished = events.filter { $0.kind == .toolCallFinished }
        #expect(finished.count == 1, "实际 \(finished.count) 条工具结果")
        let status = finished.first?.payload.value(at: ["status"])?.stringValue
        // 没接上时会退到 local 并报 error
        #expect(status == "ok", "工具结果状态应当是 ok，实际：\(status ?? "无")")

        // ⚠️ 真正的证据：清单进了 TurnState（这是"接线"与"工具能跑"的分界）
        let todos = try #require(result.state.todos, "todo_write 之后 TurnState.todos 不该是 nil")
        #expect(todos.count == 2, "实际 \(todos.count) 条")
        #expect(todos[0].text == "读 notes.md")
        #expect(todos[0].status == .done)
        #expect(todos[1].status == .inProgress)

        // 且随状态一起**落盘**（切后台再回来不该忘掉自己列过哪几步）
        let reloaded = try f.store.loadRuntime(sessionID: f.config.sessionID)
        #expect(reloaded?.state.todos?.count == 2, "清单必须随检查点持久化")
    }

    @Test("⚠️ 不合法的清单不该污染状态（被拒时 TurnState 保持原样）")
    func invalidListDoesNotPolluteState() async throws {
        let f = try Fixture()
        defer { f.remove() }
        // 两条 in_progress → 必须被工具拒绝
        let arguments = JSONValue.object(["items": .array([
            .object(["text": .string("A"), "status": .string("in_progress")]),
            .object(["text": .string("B"), "status": .string("in_progress")]),
        ])])
        let transport = FixtureTransport([
            call(ToolName.todoWrite, arguments),
            text("done"),
        ])
        let runtime = try AgentRuntime(configuration: f.config, objective: "列个坏清单",
                                       store: f.store, transport: transport)
        let result = try await finish(runtime.run())

        let finished = try f.store.loadAll(sessionID: f.config.sessionID)
            .filter { $0.kind == .toolCallFinished }
        #expect(finished.first?.payload.value(at: ["status"])?.stringValue != "ok",
                "非法清单必须被拒")
        #expect(result.state.todos == nil, "被拒的清单绝不能写进状态（否则模型以为它生效了）")
    }
}

// MARK: - ask_user 接线（C58）
//
// ⚠️ 判据按 T63/T64 的教训：**落在可观测的行为差异上** ——
//    状态真的变成 `.awaitingUser`、问题真的出现在 metadata 里、回答真的进了历史。
//    不是"有没有发过某个事件"（失败时也发），也不是查输出文本。

@Suite("ask_user 接线 —— 从 AgentRuntime 完整走一遍")
struct AskUserWiringTests {

    private func questionArguments(_ text: String) -> JSONValue {
        .object([
            "question": .string(text),
            "options": .array([
                .object(["label": .string("跟随订单币种"), "detail": .string("美元 2 位、日元 0 位")]),
                .object(["label": .string("固定两位小数")]),
            ]),
            "default": .string("跟随订单币种"),
            "why": .string("选错会导致退款金额有偏差"),
        ])
    }

    @Test("⭐⭐⭐ 提问 → metadata 里能拿到 → 回答 → 继续（完整闭环）")
    func fullAskAnswerRoundTrip() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let transport = FixtureTransport([
            call(ToolName.askUser, questionArguments("用哪个币种的精度？")),
            text("明白了，按跟随订单币种处理。"),
        ])
        let runtime = try AgentRuntime(configuration: f.config, objective: "改退款逻辑",
                                       store: f.store, transport: transport)

        // ① 第一步必须**停在等回答**，而不是继续跑
        let pending = try await finish(runtime.run())
        #expect(pending.state.status == .awaitingUser,
                "提问后必须停下等用户，实际：\(pending.state.status)")
        let question = try #require(pending.metadata.question, "问题必须出现在 metadata 里（UI 靠它渲染提问卡）")
        #expect(question.question == "用哪个币种的精度？")
        #expect(question.options.count == 2)
        #expect(question.why?.contains("退款") == true)

        // ② 用户回答 → 继续推进到完成
        let result = try await finish(runtime.run(.answer("跟随订单币种")))
        #expect(result.state.status == .completed, "回答之后应当能跑完，实际：\(result.state.status)")
        #expect(result.metadata.question == nil, "回答后问题必须清掉（否则卡片会再弹）")

        // ③ 回答必须进了历史，而且标明是"回答哪一问"
        let history = result.state.messages
        let userTexts = history.filter { $0.origin == .userInstruction }.flatMap { message in
            message.blocks.compactMap { block -> String? in
                if case .text(let value) = block.kind { return value }
                return nil
            }
        }
        #expect(userTexts.contains { $0.contains("用哪个币种的精度？") && $0.contains("跟随订单币种") },
                "回答必须带上「回答的是哪个问题」，实际历史：\(userTexts)")
    }

    @Test("⚠️ 待答问题必须随状态落盘（用户可能隔很久才回答）")
    func questionSurvivesReload() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let transport = FixtureTransport([
            call(ToolName.askUser, questionArguments("选哪个？")),
            text("好"),
        ])
        let runtime = try AgentRuntime(configuration: f.config, objective: "提问",
                                       store: f.store, transport: transport)
        _ = try await finish(runtime.run())

        // 从磁盘重新读一次（模拟进程被回收后重开）
        let reloaded = try f.store.loadRuntime(sessionID: f.config.sessionID)
        #expect(reloaded?.state.pendingQuestion?.question == "选哪个？",
                "问题必须随检查点持久化，否则用户回来只看到「卡住」")
        #expect(reloaded?.state.status == .awaitingUser)

        // ⚠️ 而且要在**不重新跑一遍**的前提下还能从磁盘恢复出那个问题
        //    （UI 重开 App 后要直接渲染它，而不是要求用户先点一次"继续"）
        let reopened = try #require(try AgentRuntime.snapshot(sessionID: f.config.sessionID, store: f.store))
        #expect(reopened.metadata.question?.question == "选哪个？",
                "重开后 metadata 里也该有那个问题（UI 直接渲染它）")
        #expect(reopened.state.status == .awaitingUser)
    }

    @Test("⚠️ 不在等回答时调 answer 要报错，而不是静默忽略")
    func answerWithoutQuestionIsRejected() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let transport = FixtureTransport([text("直接做完了")])
        let runtime = try AgentRuntime(configuration: f.config, objective: "不用提问",
                                       store: f.store, transport: transport)
        _ = try await finish(runtime.run())

        do {
            _ = try await finish(runtime.run(.answer("随便答")))
            Issue.record("没有待答问题时 answer 应当报错")
        } catch {
            #expect(String(describing: error).contains("没有等待回答"),
                    "错误信息要说清原因，实际：\(error)")
        }
    }

    @Test("⚠️「要不要我继续」这类废话要被拒，而且**不停下来**")
    func fillerQuestionDoesNotSuspend() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let transport = FixtureTransport([
            call(ToolName.askUser, .object(["question": .string("要不要我继续")])),
            text("那我直接做完。"),
        ])
        let runtime = try AgentRuntime(configuration: f.config, objective: "废话提问",
                                       store: f.store, transport: transport)
        let result = try await finish(runtime.run())

        #expect(result.state.status == .completed, "废话问题不该把任务卡住，实际：\(result.state.status)")
        #expect(result.metadata.question == nil, "不该产生待答问题")
        // 而且模型必须收到可执行的纠正
        // ⚠️ 判据落在**事件 kind + 工具结果**上，不是"payload 文本里有没有某个词"
        //    （那是 T63 记过的假绿套路）。
        let events = try f.store.loadAll(sessionID: f.config.sessionID)
        #expect(events.contains { $0.kind == .toolCallDenied }, "被拒必须落一条 toolCallDenied 事件")
        // 而且模型必须收到**可执行的纠正**（否则它只会原样再问一遍）
        let denied = events.first { $0.kind == .toolCallDenied }
        #expect(denied?.payload.value(at: ["reason"])?.stringValue == "invalidQuestion",
                "拒绝原因要标成 invalidQuestion，实际：\(String(describing: denied?.payload))")
        // 工具结果本身也要带上"该怎么改"
        var paired: ToolResult?
        for message in result.state.messages {
            for block in message.blocks {
                if case .toolResult(let r) = block.kind, r.callID == "call-1" { paired = r }
            }
        }
        #expect(paired?.status != .ok, "废话问题必须回一个失败结果")
        #expect(paired?.error?.modelFacingText.contains("没有信息量") == true,
                "要告诉模型这类问题为什么不行，实际：\(paired?.error?.modelFacingText ?? "无")")
    }
}
