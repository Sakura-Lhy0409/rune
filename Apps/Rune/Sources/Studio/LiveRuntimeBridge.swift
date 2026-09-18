import Foundation
import RuneCore
import RuneStore
import RuneKernel
import RuneUI

/// security-scoped bookmark 的访问必须跨整个异步任务持有，不能在初始化后立即释放。
final class RuntimeWorkspaceLease {
    let url: URL
    private let acquired: Bool
    init(_ url: URL) { self.url = url; acquired = url.startAccessingSecurityScopedResource() }
    deinit { if acquired { url.stopAccessingSecurityScopedResource() } }
}

extension StudioStore {
    func restoreRuntimeProjections() {
        guard let database = runtimeDatabase else { return }
        for task in state.tasks where task.isLive == true {
            do {
                if let snapshot = try AgentRuntime.snapshot(sessionID: task.id, store: database) {
                    applyRuntime(snapshot, id: task.id, coldStart: true)
                }
            } catch { errorMessage = "任务恢复被阻止：\(error.localizedDescription)" }
        }
    }
    func startLive(_ id: UUID, action: RuntimeAction = .proceed) {
        guard liveReaders[id] == nil else { errorMessage = "任务还在运行，先暂停或等待当前步骤完成。"; return }
        guard let task = task(id), !task.isDemo else { return }
        do {
            guard let database = runtimeDatabase else { throw StudioFailure("运行数据库尚未就绪。") }
            let selected = task.providerID ?? state.selectedProvider
            guard let profile = state.providers.first(where: { $0.id == selected }), profile.isValid else {
                throw StudioFailure("请先在设置中添加渠道与模型，再开始任务。")
            }
            guard let workspace = state.workspaces.first(where: { $0.id == task.workspaceID }) else { throw StudioFailure("此工作区已被移除，请重新授权。") }
            if liveRuntimes[id] == nil {
                let url: URL
                if let bookmark = workspace.bookmark {
                    var stale = false
                    url = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, bookmarkDataIsStale: &stale)
                } else { url = root.appendingPathComponent("Workspaces/\(workspace.id.uuidString)") }
                let lease = RuntimeWorkspaceLease(url)
                let family: ProtocolFamily
                let auth: AuthConfig
                let ref = "keychain://provider/" + profile.id.uuidString
                var headers: [String: String] = [:]
                switch profile.protocolName {
                case "Anthropic": family = .anthropicMessages; auth = .header(name: "x-api-key", keyRef: ref); headers["anthropic-version"] = "2023-06-01"
                case "Gemini": family = .geminiGenerate; auth = .header(name: "x-goog-api-key", keyRef: ref)
                case "OpenAI Responses": family = .openAIResponses; auth = .bearer(keyRef: ref)
                default: family = .openAIChat; auth = .bearer(keyRef: ref)
                }
                let provider = ProviderConfig(id: profile.id.uuidString, displayName: profile.title,
                    protocolFamily: family, baseURL: profile.baseURL, auth: auth, extraHeaders: headers,
                    category: .thirdPartyRelay, models: [ModelDescriptor(id: profile.model)])
                let price: ModelPrice?
                if let input = profile.inputPricePerMillion, let output = profile.outputPricePerMillion {
                    price = .init(inputMicroPerMTok: Int(input * 1_000_000), outputMicroPerMTok: Int(output * 1_000_000),
                                  cachedInputMicroPerMTok: Int(input * 1_000_000), cacheWriteMicroPerMTok: Int(input * 1_000_000))
                } else { price = nil }
                let trust: TrustDial = task.trust == .readOnly || task.trust == .suggest ? .readOnly : .collaborate
                let config = RuntimeConfiguration(sessionID: id, workspaceID: workspace.id, workspaceURL: lease.url,
                    artifactsURL: root.appendingPathComponent("RuntimeArtifacts/\(id.uuidString)"), provider: provider,
                    modelID: profile.model, secret: ProviderSecrets.read(profile.id) ?? "", trust: trust,
                    price: price, budgetMicroUSD: Int(state.dailyBudget * 1_000_000), allowPrivateNetwork: profile.allowPrivateNetwork == true)
                let objective = task.messages.first(where: { $0.role == "user" })?.text ?? task.title
                #if DEBUG
                let transport: (any ModelTransport)? = ProcessInfo.processInfo.arguments.contains("--runtime-fixture") ? StudioRuntimeFixture() : nil
                #else
                let transport: (any ModelTransport)? = nil
                #endif
                liveRuntimes[id] = try AgentRuntime(configuration: config, objective: objective, store: database, transport: transport)
                workspaceLeases[id] = lease
            }
            guard let runtime = liveRuntimes[id] else { return }
            updateTask(id) { $0.providerID = profile.id; $0.modelName = profile.model; $0.isLive = true; $0.phase = .running; $0.liveText = nil }
            if let active = self.task(id) { beginActivity(active) }
            backgroundExecution.begin(id: id, title: task.title) { [weak runtime] in runtime?.pause() }
            liveReaders[id] = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await update in runtime.run(action) {
                        switch update {
                        case .snapshot(let value): applyRuntime(value, id: id)
                        case .textPreview(let text):
                            if let i = state.tasks.firstIndex(where: { $0.id == id }) { state.tasks[i].liveText = text }
                        }
                    }
                } catch {
                    // 数据库提交错误不能被界面吞掉；保留磁盘检查点，暂停并交给用户重试。
                    updateTask(id) {
                        $0.phase = .failed
                        $0.messages.append(.init(role: "notice", text: "运行已停止：\(error.localizedDescription)"))
                    }
                }
                backgroundExecution.finish(id: id, success: self.task(id)?.phase != .failed)
                liveReaders[id] = nil
                liveRuntimes[id] = nil
                workspaceLeases[id] = nil
                fileRevision += 1
            }
        } catch { report(error) }
    }

    func applyRuntime(_ snapshot: RuntimeSnapshot, id: UUID, coldStart: Bool = false) {
        guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        let turn = snapshot.state, metadata = snapshot.metadata
        let old = state.tasks[index]
        var value = old
        value.isLive = true; value.modelName = metadata.modelID
        value.costKnown = metadata.hasPricing; value.costMicroUSD = turn.spentMicroUSD
        value.requestCount = turn.round; value.budgetPaused = turn.status == .pausedBudget
        value.suggestedBudgetMicroUSD = metadata.suggestedBudgetMicroUSD
        value.liveText = metadata.partialText.isEmpty ? nil : metadata.partialText
        value.messages = turn.messages.filter { ($0.role == .user || $0.role == .assistant) && !$0.plainText.isEmpty }.map {
            var message = StudioMessage(role: $0.role == .user ? "user" : "assistant", text: $0.plainText)
            message.id = $0.id
            return message
        }
        if let failure = metadata.failure { value.messages.append(.init(role: "notice", text: failure)) }
        if metadata.interruptedRequest && metadata.paused { value.messages.append(.init(role: "notice", text: "请求已中断。继续时会重新请求模型，部分调用费用需以渠道账单为准。")) }
        value.steps = turn.steps.enumerated().map { index, step in
            if index < old.steps.count, old.steps[index].title == step.summary { return old.steps[index] }
            return StudioStep(step.summary)
        }
        if metadata.cancelled { value.phase = .cancelled }
        else if metadata.paused || turn.status == .pausedBudget || turn.status == .interrupted || turn.status == .awaitingUser { value.phase = .paused }
        else {
            switch turn.status {
            case .completed: value.phase = .completed
            case .failed: value.phase = .failed
            case .awaitingApproval: value.phase = .approval
            default: value.phase = coldStart ? .paused : .running
            }
        }
        value.progress = value.phase == .completed ? 1 : value.phase == .approval ? 0.5 : 0
        if let approval = metadata.approval {
            value.runtimeApproval = .init(callID: approval.call.id, tool: approval.call.name, reason: approval.reason,
                arguments: String(decoding: approval.call.argumentsJSON, as: UTF8.self), recovery: approval.recovery, reviewError: approval.reviewError)
        } else { value.runtimeApproval = nil }
        let allChanges = metadata.changes + (metadata.approval?.changes ?? [])
        value.changes = allChanges.map { change in
            var result = old.changes.first { $0.runtimeID == change.id }
                ?? StudioChange(path: change.path.replacingOccurrences(of: "/workspace/", with: ""), before: change.before ?? "", after: change.after ?? "")
            result.runtimeID = change.id
            result.decision = change.reverted == true ? "reverted" : change.applied ? "accepted" : "pending"
            return result
        }
        state.tasks[index] = value
        backgroundExecution.update(id: id, completedSteps: turn.steps.count, detail: turn.steps.last?.summary ?? value.phase.title)
        updateActivity(value)
    }
    func decideLive(_ id: UUID, callID: String, accept: Bool) { startLive(id, action: accept ? .approve(callID: callID) : .reject(callID: callID)) }
    func raiseRuntimeBudget(_ id: UUID) {
        guard let task = task(id) else { return }
        startLive(id, action: .raiseBudget(max(task.suggestedBudgetMicroUSD ?? 0, max(Int(state.dailyBudget * 2_000_000), (task.costMicroUSD ?? 0) * 2))))
    }
    func undoLive(_ id: UUID) {
        guard let change = task(id)?.changes.last(where: { $0.decision == "accepted" }), let changeID = change.runtimeID else { return }
        startLive(id, action: .undo(changeID: changeID))
    }
    func runtimeCostLabel(_ task: StudioTask) -> String {
        if task.isDemo { return "本地演练 · $0.00" }
        guard task.isLive == true else { return "尚未调用模型" }
        guard task.costKnown == true else { return "未配置报价 · \(task.requestCount ?? 0) 轮" }
        return String(format: "估算 $%.4f", Double(task.costMicroUSD ?? 0) / 1_000_000)
    }
}
