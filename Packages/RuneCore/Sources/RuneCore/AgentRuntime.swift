import Foundation
import RuneKernel
import RuneStore
import RuneNet
import RuneTools

/// 可恢复的真实运行时。可变状态仅在专用串行队列访问；取消由线程安全的 control 送达。
/// 每一步提交成功后才推进下一步，因此副作用前的工具意图已经在 SQLite 里。
public final class AgentRuntime: @unchecked Sendable {
    public static let toolNames = [ToolName.listDir, ToolName.readFile, ToolName.readArtifact, ToolName.writeFile,
        ToolName.editFile, ToolName.applyPatch, ToolName.deletePath, ToolName.movePath, ToolName.copyPath,
        ToolName.statPath, ToolName.makeDir, ToolName.glob, ToolName.grepSearch, ToolName.outlineFile, ToolName.hashFile]
        + DocumentToolExecutor.names
        // Git 只读工具（C54）：iOS 上没有系统 git，这一层是自研 Git 引擎的出口。
        // ⚠️ 只接了**只读**四个；git_add/git_commit 等写操作的风险级是 modifying/dangerous，
        //    需要单独的审批语义，不在这一片（别顺手加进来）。
        + Array(GitToolExecutor.names).sorted()
    private let queue = DispatchQueue(label: "RuneCore.runtime", qos: .userInitiated)
    private let lock = NSLock()
    private var active: RuntimeControl?
    private let config: RuntimeConfiguration
    private let store: RuneEventStore
    private let vfs: ModelWorkspace
    private let executor: RuntimeToolExecutor
    private let injected: (any ModelTransport)?
    private let tools: [String: ToolSpec]
    private var state: TurnState
    private var metadata: RuntimeMetadata
    private var revision: Int64

    public init(configuration: RuntimeConfiguration, objective: String, store: RuneEventStore,
                transport: (any ModelTransport)? = nil) throws {
        config = configuration; self.store = store; injected = transport
        vfs = ModelWorkspace(base: FileManagerVFS(baseURL: configuration.workspaceURL))
        tools = ToolRegistry.byName.merging(DocumentToolExecutor.specifications) { _, new in new }.filter { Self.toolNames.contains($0.key) }.mapValues { spec in
            guard spec.mutatesFileSystem else { return spec }
            return ToolSpec(name: spec.name, description: spec.description, inputSchema: spec.inputSchema,
                pathParameters: spec.pathParameters, example: spec.example, concurrency: spec.concurrency,
                isIdempotent: spec.isIdempotent, riskLevel: spec.riskLevel, needsApproval: .always,
                outputShape: spec.outputShape, requirements: spec.requirements)
        }
        let artifacts = try DiskArtifactStore(directory: configuration.artifactsURL)
        let workspace = vfs
        // ⚠️ Git 工具需要**真实文件系统路径**（`.git` 在磁盘上），而 `workspace` 是
        //    `FileManagerVFS`（真实目录）—— 所以这里能给出解析器。
        //    将来若换成内存工作区，Git 工具会如实报告"不可用"，而不是给出错答案。
        executor = RuntimeToolExecutor(local: LocalToolExecutor(vfs: workspace, registry: tools, artifacts: artifacts),
            documents: DocumentToolExecutor(read: { try workspace.readData($0, maxBytes: $1) }, artifacts: artifacts),
            git: GitToolExecutor(resolver: GitWorkspaceResolver(base: workspace.base)))
        if let saved = try store.loadRuntime(sessionID: configuration.sessionID) {
            state = saved.state; state.wasRestored = !saved.state.status.isTerminal
            metadata = try JSONDecoder().decode(RuntimeMetadata.self, from: saved.metadata)
            guard metadata.workspaceID == configuration.workspaceID,
                  metadata.providerID == configuration.provider.id, metadata.modelID == configuration.modelID else {
                throw RuntimeFailure("恢复配置与原任务不一致，请恢复原工作区和模型后再继续。")
            }
            if metadata.inFlightModel == true { metadata.interruptedRequest = true; metadata.paused = true }
            revision = saved.revision
        } else {
            state = TurnState(turnID: configuration.sessionID, sessionID: configuration.sessionID, objective: objective,
                              costCeilingMicroUSD: configuration.budgetMicroUSD)
            metadata = .init(workspaceID: configuration.workspaceID, providerID: configuration.provider.id, modelID: configuration.modelID)
            metadata.hasPricing = configuration.price != nil
            metadata.price = configuration.price
            revision = 0
        }
    }

    public static func snapshot(sessionID: UUID, store: RuneEventStore) throws -> RuntimeSnapshot? {
        guard let saved = try store.loadRuntime(sessionID: sessionID) else { return nil }
        var metadata = try JSONDecoder().decode(RuntimeMetadata.self, from: saved.metadata)
        if metadata.inFlightModel == true { metadata.interruptedRequest = true; metadata.paused = true }
        return .init(state: saved.state, metadata: metadata)
    }
    public func pause() { lock.lock(); let control = active; lock.unlock(); control?.stop(cancel: false) }
    public func cancel() { lock.lock(); let control = active; lock.unlock(); control?.stop(cancel: true) }

    public func run(_ action: RuntimeAction = .proceed) -> AsyncThrowingStream<RuntimeUpdate, Error> {
        let control = RuntimeControl()
        lock.lock()
        guard active == nil else {
            lock.unlock()
            return AsyncThrowingStream { $0.finish(throwing: RuntimeFailure("此任务已经在运行。")) }
        }
        active = control; lock.unlock()
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            continuation.onTermination = { @Sendable _ in control.stop(cancel: false) }
            self.queue.async {
                do {
                    let preview = RuntimePreview(provider: self.config.provider, model: self.config.modelID) { continuation.yield(.textPreview($0)) }
                    let networkAudit = RuntimeNetworkAudit()
                    let live = self.injected == nil ? try URLSessionModelTransport(
                        policy: .init(allowedOrigins: [self.config.provider.baseURL], allowPrivateNetwork: self.config.allowPrivateNetwork), onSSE: { preview.ingest($0) },
                        audit: { networkAudit.append($0) }) : nil
                    let transport = ControlledTransport(live: live, injected: self.injected, control: control, preview: preview)
                    let model = RuntimeModel(transport: transport, config: self.config, tools: self.tools, control: control)
                    let deps = self.dependencies(model: model)
                    let kernelConfig = TurnRunner.Config(maxRounds: self.config.maxRounds, maxToolCalls: 32,
                        maxCostMicroUSD: self.config.budgetMicroUSD, toolRegistry: self.tools)
                    try self.apply(action, deps: deps, kernelConfig: kernelConfig)
                    continuation.yield(.snapshot(self.snapshot))
                    let started = Date()
                    while self.state.canAdvance && !self.metadata.paused && !self.metadata.cancelled {
                        if let cancel = control.stopMode {
                            try self.stop(cancel: cancel, partial: preview.current)
                            break
                        }
                        if Date().timeIntervalSince(started) > 300 {
                            try self.stop(cancel: false, partial: preview.current)
                            break
                        }
                        if self.state.status == .reasoning && !self.state.wasRestored,
                           let forecast = model.projectedMaximumCost(self.state, price: self.metadata.price),
                           let ceiling = TurnRunner.effectiveCeiling(state: self.state, config: kernelConfig),
                           self.state.spentMicroUSD + forecast > ceiling {
                            let required = self.state.spentMicroUSD + forecast
                            self.state.status = .pausedBudget
                            self.metadata.suggestedBudgetMicroUSD = required
                            self.metadata.failure = "下一轮含重试的费用预留约 \(GatewayRouter.money(forecast))，超过当前剩余额度。尚未发出请求。"
                            self.state.budgetStop = BudgetStop(spentMicroUSD: self.state.spentMicroUSD, ceilingMicroUSD: ceiling,
                                options: [.raiseLimit(newLimitMicroUSD: required), .deliverSoFar], reason: self.metadata.failure!)
                            try self.commit([self.event(.budgetExceeded, ["reason": .string("next_request_reserve"), "required_micro_usd": .int(required)])])
                            break
                        }
                        let previousStatus = self.state.status
                        if previousStatus == .reasoning && !self.state.wasRestored
                            && self.state.round < kernelConfig.maxRounds
                            && TurnRunner.budgetStop(state: self.state, config: kernelConfig) == nil {
                            self.metadata.inFlightModel = true
                            try self.commit([self.event(.modelCallStarted, ["provider": .string(self.config.provider.id), "model": .string(self.config.modelID)])])
                        }
                        var stepDependencies = deps
                        stepDependencies.executor = ReviewedToolExecutor(base: self.executor, vfs: self.vfs, changes: self.metadata.changes)
                        let outcome = TurnRunner.step(self.state, deps: stepDependencies, config: kernelConfig)
                        if previousStatus == .reasoning, let cancel = control.stopMode {
                            self.metadata.interruptedRequest = true
                            self.metadata.inFlightModel = false
                            try self.recordNetwork(networkAudit.take())
                            try self.stop(cancel: cancel, partial: preview.current)
                            break
                        }
                        self.state = outcome.state
                        self.metadata.inFlightModel = false
                        self.metadata.partialText = ""
                        if let approval = outcome.pendingApproval {
                            do {
                                let changes = try self.preview(approval.call)
                                self.metadata.approval = .init(call: approval.call, reason: approval.reason,
                                    recovery: !self.state.pendingIntents.isEmpty, changes: changes)
                            } catch {
                                self.metadata.approval = .init(call: approval.call, reason: approval.reason,
                                    recovery: !self.state.pendingIntents.isEmpty, changes: [], reviewError: error.localizedDescription)
                            }
                        }
                        if previousStatus == .executing {
                            for i in self.metadata.changes.indices where !self.metadata.changes[i].applied && self.metadata.changes[i].reverted != true {
                                let change = self.metadata.changes[i]
                                if self.state.messages.contains(where: { message in message.blocks.contains(where: { block in
                                    if case .toolResult(let result) = block.kind { return result.callID == change.callID && result.status == .ok }; return false
                                }) }) { self.metadata.changes[i].applied = true }
                            }
                        }
                        if self.state.status == .failed { self.metadata.failure = outcome.terminalReason ?? "任务未能完成，请查看过程。" }
                        var events = outcome.newEvents
                        events.append(contentsOf: networkAudit.take().map { self.event(.egressAudited, Self.networkPayload($0)) })
                        try self.commit(events)
                        continuation.yield(.snapshot(self.snapshot))
                        if !outcome.didAdvance { break }
                    }
                    continuation.yield(.snapshot(self.snapshot))
                    self.lock.lock(); self.active = nil; self.lock.unlock()
                    continuation.finish()
                } catch {
                    self.lock.lock(); self.active = nil; self.lock.unlock()
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    private static func networkPayload(_ event: NetworkAuditEvent) -> JSONValue {
        .object(["request_id": .string(event.requestID.uuidString), "host": .string(event.host ?? ""),
                 "method": .string(event.method), "phase": .string(event.phase.rawValue),
                 "request_bytes": .int(event.requestBytes), "response_bytes": .int(event.responseBytes),
                 "status": .int(event.statusCode ?? 0), "error": .string(event.error?.description ?? "")])
    }
    private func recordNetwork(_ audit: [NetworkAuditEvent]) throws {
        guard !audit.isEmpty else { return }
        let events = audit.map { event(.egressAudited, Self.networkPayload($0)) }
        try commit(events)
    }
    private var snapshot: RuntimeSnapshot { .init(state: state, metadata: metadata) }
    private func commit(_ events: [RuntimeEvent] = []) throws {
        revision = try store.commitRuntime(state: state, metadata: JSONEncoder().encode(metadata), events: events, expectedRevision: revision)
    }
    private func event(_ kind: EventKind, _ payload: JSONValue = .object([:])) -> RuntimeEvent {
        state.eventSequence += 1
        let event = RuntimeEvent(sequence: state.eventSequence, sessionID: state.sessionID, turnID: state.turnID,
                                 kind: kind, payload: payload, originTrust: .runtimeGuidance, previousHash: state.lastEventHash)
        state.lastEventHash = event.hash
        return event
    }
    private func stop(cancel: Bool, partial: String) throws {
        metadata.paused = !cancel; metadata.cancelled = cancel; metadata.partialText = partial
        let event = event(cancel ? .turnInterrupted : .turnPaused, ["reason": .string(cancel ? "用户取消" : "已暂停")])
        try commit([event])
    }

    private func apply(_ action: RuntimeAction, deps: TurnRunner.Dependencies, kernelConfig: TurnRunner.Config) throws {
        guard !metadata.cancelled else { throw RuntimeFailure("此任务已取消。请新建任务，先检查已有文件。") }
        switch action {
        case .cancel:
            try stop(cancel: true, partial: metadata.partialText)
        case .undo(let changeID):
            guard state.status.isTerminal, let i = metadata.changes.lastIndex(where: { $0.id == changeID && $0.applied }) else {
                throw RuntimeFailure("此变更当前不可撤销。请先结束任务。")
            }
            let change = metadata.changes[i]
            let path = try VFSPath.parse(change.path)
            let current = vfs.exists(path) ? try vfs.read(path, options: ReadOptions(maxBytes: 262_144)).text : nil
            guard current == change.after else { throw RuntimeFailure("文件有后续变化，不能覆盖。") }
            // 撤销也要先落意图。若进程在写入后终止，再次撤销须先核对磁盘。
            try commit([event(.toolCallRequested, ["tool": .string("user_undo"), "path": .string(change.path)])])
            if let before = change.before { _ = try vfs.write(path, content: before) }
            else { _ = try vfs.delete(path, options: DeleteOptions()) }
            metadata.changes[i].applied = false
            metadata.changes[i].reverted = true
            state.messages.append(Message(role: .user, blocks: [.text("我已撤销 \(change.path) 的上次变更。后续操作前请重新读取当前文件。", origin: .userInstruction)], origin: .userInstruction))
            try commit([event(.toolCallFinished, ["tool": .string("user_undo"), "path": .string(change.path)])])
        case .proceed:
            guard !metadata.paused else { throw RuntimeFailure("任务已暂停，需要用户明确继续。") }
        case .resume:
            if state.round >= config.maxRounds || state.toolCallCount >= 32 {
                throw RuntimeFailure("本轮已达到执行上限。请新建聚焦任务，已有文件和审计记录会保留。")
            }
            metadata.paused = false; metadata.failure = nil
            if state.status == .failed { state.status = .reasoning }
        case .approve(let callID):
            guard state.status == .awaitingApproval, let approval = metadata.approval, approval.call.id == callID else { throw RuntimeFailure("审批已过期或与当前操作不符。") }
            guard approval.reviewError == nil else { throw RuntimeFailure("这次变更无法安全审阅，请拒绝后让模型缩小范围。") }
            for change in approval.changes {
                let path = try VFSPath.parse(change.path)
                let current = vfs.exists(path) ? try vfs.read(path, options: ReadOptions(maxBytes: 262_144)).text : nil
                guard current == change.before else { throw RuntimeFailure("文件在审阅期间已改变，不能应用旧的变更。请拒绝后重新准备。") }
            }
            metadata.changes.append(contentsOf: approval.changes)
            state = TurnRunner.approve(state, deps: deps)
            metadata.approval = nil; metadata.paused = false
            try commit([event(.toolApprovalDecided, ["call_id": .string(callID), "decision": .string("approved")])])
        case .reject(let callID):
            guard state.status == .awaitingApproval, let approval = metadata.approval, approval.call.id == callID else { throw RuntimeFailure("当前没有这项审批。") }
            let calls = state.pendingIntents.isEmpty ? [approval.call] : state.pendingIntents.map(\.call)
            for call in calls {
                let result = ToolResult(callID: call.id, status: .denied, summary: "用户拒绝此次执行。不要重试相同修改；先检查当前文件并说明替代方案。")
                state.messages.append(Message(role: .tool, blocks: [ContentBlock(kind: .toolResult(result), origin: .toolResultTrusted)], origin: .toolResultTrusted))
            }
            state.currentWave.removeAll { call in calls.contains { $0.id == call.id } }
            state.pendingIntents = []; state.status = .dispatching
            metadata.approval = nil; metadata.paused = false
            try commit([event(.toolApprovalDecided, ["call_id": .string(callID), "decision": .string("rejected")])])
        case .followUp(let text):
            guard state.status.isTerminal || (state.status == .awaitingUser && state.pendingIntents.isEmpty) else { throw RuntimeFailure("当前任务尚未结束，请先暂停或处理审批。") }
            let history = state.messages + [Message(role: .user, blocks: [.text(text, origin: .userInstruction)], origin: .userInstruction)]
            state = TurnState(sessionID: state.sessionID, objective: text, messages: history, eventSequence: state.eventSequence,
                              lastEventHash: state.lastEventHash, spentMicroUSD: state.spentMicroUSD, costCeilingMicroUSD: state.costCeilingMicroUSD)
            metadata.paused = false; metadata.failure = nil; metadata.approval = nil
        case .raiseBudget(let limit):
            let outcome = TurnRunner.raiseBudget(state, to: limit, deps: deps, config: kernelConfig)
            state = outcome.state; metadata.paused = false; metadata.failure = nil
            try commit(outcome.newEvents)
        }
        if state.wasRestored && state.status == .awaitingApproval { state.wasRestored = false }
        try commit()
    }
    private func dependencies(model: RuntimeModel) -> TurnRunner.Dependencies {
        let root = VFSPath(mount: .workspace)
        let token = CapabilityToken(issuedForTurn: state.turnID,
            scopes: [.fsRead(root), .fsWrite(root), .fsDelete(root)], expiresAt: Date().addingTimeInterval(600),
            grantedBy: .planApproval, reason: "用户选择的工作区；每个修改仍单独审批")
        return .init(modelEvents: { model.events($0) }, executor: executor,
            policyContext: .init(trustDial: config.trust, token: token, planApproved: false),
            costOfRound: { [config, price = metadata.price] usage in
                if let price { return CostCalculator.cost(usage: usage, price: price, providerID: config.provider.id, modelID: config.modelID) }
                return CostBreakdown(usage: usage, microUSD: 0, providerID: config.provider.id, modelID: config.modelID, isEstimated: true)
            })
    }
    private func preview(_ call: ToolCall) throws -> [RuntimeFileChange] {
        guard let spec = tools[call.name], spec.riskLevel != .safe else { return [] }
        let paths = ToolScheduler.defaultPaths(call, spec).paths
        var originals: [String: String] = [:]
        for path in paths where vfs.exists(path) {
            if try vfs.stat(path).kind == .directory {
                if spec.requirements.contains(.fsDelete) { throw RuntimeFailure("目录删除请先在文件管理中确认；当前运行时仅提供逐文件审阅。") }
                continue
            }
            let content = try vfs.read(path, options: ReadOptions(maxBytes: 262_144))
            guard !content.wasTruncated else { throw RuntimeFailure("待修改文件超过审阅上限，请缩小操作范围。") }
            originals[path.description] = content.text
        }
        let memory = MemoryVFS(files: originals)
        let result = try LocalToolExecutor(vfs: memory, registry: tools).execute(call)
        guard result.status == .ok else { return [] }
        return try paths.map { path in
            RuntimeFileChange(callID: call.id, path: path.description, before: originals[path.description],
                after: memory.exists(path) ? try memory.read(path).text : nil)
        }.filter { $0.before != $0.after }
    }
}
