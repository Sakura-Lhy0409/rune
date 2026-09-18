import SwiftUI
import RuneUI
import RuneNet
import RuneKernel
import RuneCore
import RuneStore
@preconcurrency import ActivityKit
import Security
import UniformTypeIdentifiers

struct TaskRoute: Identifiable { let id: UUID }
struct StudioFile: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int
    var id: String { path }
    var symbol: String { isDirectory ? "folder" : name.hasSuffix(".md") ? "doc.text" : "doc" }
}

@MainActor
final class StudioStore: ObservableObject {
    @Published var state: StudioState { didSet { if ready { persist() } } }
    @Published var section = 0
    @Published var taskRoute: TaskRoute?
    @Published var showComposer = false
    @Published var showInbox = false
    @Published var showSettings = false
    @Published var showCommands = false
    @Published var composerSeed = ""
    @Published var errorMessage: String?
    @Published var fileRevision = 0
    let root: URL
    private var ready = false
    var runtimeDatabase: RuneEventStore?
    let backgroundExecution = BackgroundExecution()
    var liveRuntimes: [UUID: AgentRuntime] = [:]
    var liveReaders: [UUID: Task<Void, Never>] = [:]
    var workspaceLeases: [UUID: RuntimeWorkspaceLease] = [:]
    private var runners: [UUID: Task<Void, Never>] = [:]
    private var runGenerations: [UUID: UUID] = [:]
    private var activities: [UUID: Activity<RuneActivityAttributes>] = [:]
    // 当前 SDK 的 Activity 仍缺少 Sendable 标注。更新经过同一条队列，不能并发回写旧状态。
    private var activityUpdate: Task<Void, Never>?
    private func enqueueActivity(_ operation: @escaping @MainActor () async -> Void) {
        let previous = activityUpdate
        activityUpdate = Task { await previous?.value; await operation() }
    }

    init() {
        let testing = ProcessInfo.processInfo.arguments.contains("--uitesting")
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(testing ? "RuneStudio-Testing" : "RuneStudio", isDirectory: true)
        state = StudioState()
        do {
            if testing && ProcessInfo.processInfo.arguments.contains("--reset-ui") && FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath: url.path) {
                state = try JSONDecoder().decode(StudioState.self, from: Data(contentsOf: url))
                state.recoverPresentation()
            } else {
                let workspace = StudioWorkspace(title: "随手记", isSample: true)
                state.workspaces = [workspace]; state.selectedWorkspace = workspace.id
                state.notes = [
                    .init(title: "整理一份说明", body: "先了解目录与文件，再整理一份简明的项目说明。变更前让我审阅。", category: "技能"),
                    .init(title: "审阅变更", body: "逐项检查变更的目的、边界情况和验证结果。只报告有证据的问题。", category: "技能"),
                    .init(title: "每日收尾", body: "整理今天的记录\n列出未完成事项\n写下下一步", category: "工作流"),
                ]
                let folder = root.appendingPathComponent("Workspaces/\(workspace.id.uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try "# 随手记\n\n给想法留一点空间。\n\n## 今天\n- [ ] 完成第一次文件审阅\n- [ ] 写下一个值得做的想法\n".write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
                try "# 欢迎来到 Rune\n\n这里是你的本地示例工作区。\n你可以读写文件、审阅变更，再亲手决定是否应用。\n\n文件留在这台设备上。\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            }
            if testing && ProcessInfo.processInfo.arguments.contains("--skip-onboarding") { state.onboarded = true }
            #if DEBUG
            if testing && ProcessInfo.processInfo.arguments.contains("--runtime-fixture") && state.providers.isEmpty {
                var provider = StudioProvider()
                provider.title = "本地验收夹具"; provider.model = "fixture"; provider.baseURL = "https://fixture.invalid/v1"
                state.providers = [provider]; state.selectedProvider = provider.id
            }
            #endif
            runtimeDatabase = try RuneEventStore(path: root.appendingPathComponent("runtime.sqlite").path)
            ready = true
            restoreRuntimeProjections()
            persist()
        } catch { errorMessage = "无法打开本地工作区：\(error.localizedDescription)" }
        UserDefaults(suiteName: RuneSharedInbox.group)?.set(testing, forKey: "uiTesting")
        for activity in Activity<RuneActivityAttributes>.activities {
            if let id = UUID(uuidString: activity.attributes.taskID) {
                activities[id] = activity
                if let task = task(id), task.phase.isActive { updateActivity(task) }
                else { enqueueActivity { await activity.end(nil, dismissalPolicy: .immediate) } }
            }
        }
    }

    var workspace: StudioWorkspace? { state.workspaces.first { $0.id == state.selectedWorkspace } ?? state.workspaces.first }
    var activeTasks: [StudioTask] { state.tasks.filter { $0.phase.isActive && !$0.archived } }
    var visibleTasks: [StudioTask] { state.tasks.filter { !$0.archived }.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.createdAt > $1.createdAt } }
    func task(_ id: UUID) -> StudioTask? { state.tasks.first { $0.id == id } }
    func workspaceName(_ id: UUID) -> String { state.workspaces.first { $0.id == id }?.title ?? "工作区" }
    func openTask(_ id: UUID) { taskRoute = TaskRoute(id: id) }
    func compose(_ text: String = "") { composerSeed = text; showComposer = true }
    func report(_ error: Error) { errorMessage = error.localizedDescription }

    @discardableResult func persist() -> Bool {
        do { try JSONEncoder().encode(state).write(to: root.appendingPathComponent("state.json"), options: .atomic); return true }
        catch { errorMessage = "保存失败，请保留当前页面后重试：\(error.localizedDescription)"; return false }
    }
    func audit(_ title: String, _ detail: String) {
        state.audit.insert(.init(title, detail: detail), at: 0)
        if state.audit.count > 500 { state.audit.removeLast(state.audit.count - 500) }
    }
    func updateTask(_ id: UUID, _ body: (inout StudioTask) -> Void) {
        guard let i = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        body(&state.tasks[i])
        updateActivity(state.tasks[i])
    }

    @discardableResult
    func createTask(_ text: String, demo: Bool = false, attachments: [String] = []) -> UUID? {
        guard let workspace, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var task = StudioTask(title: String(text.prefix(45)), workspaceID: workspace.id)
        var attachedPaths: [String] = []
        do {
            for name in attachments {
                guard let item = state.inbox.first(where: { $0.title == name }), let filename = item.filename,
                      filename == (filename as NSString).lastPathComponent else { throw StudioFailure("附件已经移除，请重新选择。") }
                let source = root.appendingPathComponent("Inbox/" + filename)
                let path = "attachments/" + filename
                try withWorkspace(workspace.id) { root in
                    let destination = try safeURL(root, path: path)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: source, to: destination) }
                }
                attachedPaths.append("/workspace/" + path)
            }
        } catch { report(error); return nil }
        task.messages = [.init(role: "user", text: text + (attachedPaths.isEmpty ? "" : "\n\n用户选择的附件路径：" + attachedPaths.joined(separator: "、")))]
        task.steps = [.init("任务已创建", detail: workspace.title)]
        task.isDemo = demo && workspace.isSample
        if task.isDemo {
            task.phase = .running
            task.messages.append(.init(role: "assistant", text: "先在示例文件里试一次。修改会先交给你审阅，不产生模型费用。"))
        } else {
            task.providerID = state.selectedProvider
            task.messages.append(.init(role: "notice", text: "任务已保存在本机。确认渠道后即可开始；会话与工具读取的内容将发送到所选模型。"))
        }
        state.tasks.insert(task, at: 0)
        if state.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        audit("创建任务", task.title)
        if task.isDemo { beginActivity(task); runDemo(task.id) }
        return task.id
    }

    func runDemo(_ id: UUID) {
        runners[id]?.cancel()
        let generation = UUID()
        runGenerations[id] = generation
        runners[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let steps: [(Double, String)] = [(0.2, "读取示例文件"), (0.4, "准备文件变更"), (0.6, "生成审阅内容")]
                for (progress, title) in steps {
                    guard let current = task(id), current.phase == .running else { return }
                    if current.progress >= progress { continue }
                    try await Task.sleep(for: .milliseconds(650))
                    try Task.checkCancellation()
                    guard task(id)?.phase == .running else { return }
                    updateTask(id) { $0.progress = progress; $0.steps.append(.init(title, detail: "notes.md")) }
                }
                guard let current = task(id) else { return }
                let before = try readFile(current.workspaceID, path: "notes.md")
                let after: String
                if let range = before.range(of: "- [ ] 完成第一次文件审阅") {
                    after = before.replacingCharacters(in: range, with: "- [x] 完成第一次文件审阅")
                } else { after = before + "\n- [x] 完成一次本地文件审阅\n" }
                updateTask(id) {
                    $0.changes = [.init(path: "notes.md", before: before, after: after)]
                    $0.phase = .approval
                    $0.steps.append(.init("等待审阅", detail: "一处变更，尚未写入文件。"))
                    $0.messages.append(.init(role: "assistant", text: "已准备好一处修改。逐行比较，再决定是否写入。"))
                }
            } catch is CancellationError { }
            catch { updateTask(id) { $0.phase = .failed; $0.messages.append(.init(role: "assistant", text: "无法准备变更：\(error.localizedDescription)")) } }
            if runGenerations[id] == generation { runners[id] = nil; runGenerations[id] = nil }
        }
    }

    func pause(_ id: UUID) {
        if task(id)?.isLive == true { liveRuntimes[id]?.pause(); return }
        guard task(id)?.phase == .running else { return }
        runners[id]?.cancel(); runners[id] = nil
        updateTask(id) { $0.phase = .paused; $0.steps.append(.init("由你暂停")) }
    }
    func resume(_ id: UUID) {
        if task(id)?.isLive == true { startLive(id, action: .resume); return }
        guard let current = task(id), current.phase == .paused, current.isDemo else { return }
        updateTask(id) { $0.phase = .running; $0.steps.append(.init("继续执行")) }
        if let current = task(id) { beginActivity(current) }
        runDemo(id)
    }
    func cancel(_ id: UUID) {
        if task(id)?.isLive == true { if let runtime = liveRuntimes[id] { runtime.cancel() } else { startLive(id, action: .cancel) }; return }
        runners[id]?.cancel(); runners[id] = nil
        updateTask(id) { $0.phase = .cancelled; $0.steps.append(.init("由你取消", detail: "未批准的变更没有写入文件。")) }
    }
    func send(_ text: String, to id: UUID) {
        if task(id)?.isLive == true { startLive(id, action: .followUp(text)); return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        updateTask(id) {
            $0.messages.append(.init(role: "user", text: text))
            $0.messages.append(.init(role: "assistant", text: "补充已保存在此会话中，尚未发送到模型。"))
        }
    }
    func decide(taskID: UUID, changeID: UUID, accept: Bool) {
        if let approval = task(taskID)?.runtimeApproval { decideLive(taskID, callID: approval.callID, accept: accept); return }
        guard let current = task(taskID), current.phase == .approval,
              let change = current.changes.first(where: { $0.id == changeID }), change.decision == "pending" else { return }
        do {
            if accept {
                guard try readFile(current.workspaceID, path: change.path) == change.before else {
                    throw StudioFailure("文件在审阅期间发生了变化。请重新准备变更，避免覆盖新的内容。")
                }
                try writeFile(current.workspaceID, path: change.path, text: change.after)
                guard try readFile(current.workspaceID, path: change.path) == change.after else {
                    throw StudioFailure("文件写入后的内容不一致，请检查当前文件。")
                }
            }
            if state.haptics { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            updateTask(taskID) { task in
                guard let i = task.changes.firstIndex(where: { $0.id == changeID }) else { return }
                task.changes[i].decision = accept ? "accepted" : "rejected"
                task.steps.append(.init(accept ? "变更已应用" : "变更已拒绝", detail: change.path))
                if !task.changes.contains(where: { $0.decision == "pending" }) {
                    task.phase = .completed; task.progress = 1
                    task.messages.append(.init(role: "assistant", text: accept ? "已写入文件，并复读确认。你可以打开文件查看结果，也可以撤销这次修改。" : "已保留原文件，未应用这处变更。"))
                }
            }
        } catch { report(error) }
    }
    func undo(_ id: UUID) {
        if task(id)?.isLive == true { undoLive(id); return }
        guard let task = task(id), let change = task.changes.last(where: { $0.decision == "accepted" }) else { return }
        do {
            guard try readFile(task.workspaceID, path: change.path) == change.after else { throw StudioFailure("文件已有后续修改，不能直接覆盖。请先检查当前内容。") }
            try writeFile(task.workspaceID, path: change.path, text: change.before)
            updateTask(id) { value in
                if let i = value.changes.firstIndex(where: { $0.id == change.id }) { value.changes[i].decision = "reverted" }
                value.steps.append(.init("已撤销文件修改", detail: change.path))
                value.messages.append(.init(role: "assistant", text: "文件已恢复到此次变更之前。"))
            }
        } catch { report(error) }
    }

    func withWorkspace<T>(_ id: UUID, _ body: (URL) throws -> T) throws -> T {
        guard let workspace = state.workspaces.first(where: { $0.id == id }) else { throw StudioFailure("工作区不存在。") }
        let url: URL
        if let bookmark = workspace.bookmark {
            var stale = false
            url = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, bookmarkDataIsStale: &stale)
        } else { url = root.appendingPathComponent("Workspaces/\(id.uuidString)", isDirectory: true) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }
    private func safeURL(_ root: URL, path: String) throws -> URL {
        guard !path.hasPrefix("/"), !path.components(separatedBy: "/").contains("..") else { throw StudioFailure("文件路径不在工作区内。") }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path == base.path || url.path.hasPrefix(base.path + "/") else { throw StudioFailure("不能跟随工作区之外的链接。") }
        return url
    }
    func files(_ workspace: UUID, path: String = "") throws -> [StudioFile] {
        try withWorkspace(workspace) { root in
            let folder = try safeURL(root, path: path)
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: .skipsHiddenFiles)
                .prefix(500).map { url in
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    return StudioFile(path: path.isEmpty ? url.lastPathComponent : path + "/" + url.lastPathComponent,
                                      name: url.lastPathComponent, isDirectory: values.isDirectory ?? false, size: values.fileSize ?? 0)
                }.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    func readFile(_ id: UUID, path: String) throws -> String {
        try withWorkspace(id) { root in
            let url = try safeURL(root, path: path)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2_000_000 else { throw StudioFailure("文件超过 2 MB，请通过分享在专用应用中打开。") }
            return try String(contentsOf: url, encoding: .utf8)
        }
    }
    func writeFile(_ id: UUID, path: String, text: String) throws {
        try withWorkspace(id) { root in try text.write(to: safeURL(root, path: path), atomically: true, encoding: .utf8) }
        fileRevision += 1
        audit("写入文件", workspaceName(id) + " / " + path)
    }
    func createFile(_ id: UUID, name: String, folder: String) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw StudioFailure("请输入有效的文件名。") }
        let path = folder.isEmpty ? name : folder + "/" + name
        try withWorkspace(id) { root in
            let url = try safeURL(root, path: path)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw StudioFailure("已存在同名文件。") }
            try "".write(to: url, atomically: true, encoding: .utf8)
        }
        fileRevision += 1; audit("新建文件", path)
    }
    func renameFile(_ id: UUID, path: String, name: String) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw StudioFailure("请输入有效的文件名。") }
        let parent = (path as NSString).deletingLastPathComponent
        let destination = parent.isEmpty ? name : parent + "/" + name
        try withWorkspace(id) { root in
            let source = try safeURL(root, path: path), target = try safeURL(root, path: destination)
            guard !FileManager.default.fileExists(atPath: target.path) else { throw StudioFailure("已存在同名文件。") }
            try FileManager.default.moveItem(at: source, to: target)
        }
        fileRevision += 1; audit("重命名文件", path + " → " + destination)
    }
    func deleteFile(_ id: UUID, path: String) throws {
        guard !path.isEmpty else { throw StudioFailure("不能删除工作区根目录。") }
        try withWorkspace(id) { root in try FileManager.default.removeItem(at: safeURL(root, path: path)) }
        fileRevision += 1; audit("删除文件", path)
    }
    func shareFile(_ id: UUID, path: String) throws -> URL {
        try withWorkspace(id) { root in
            let url = try safeURL(root, path: path)
            let export = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
            let target = export.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: target)
            return target
        }
    }
    func addWorkspace(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let workspace = StudioWorkspace(title: url.lastPathComponent, bookmark: bookmark)
            state.workspaces.append(workspace); state.selectedWorkspace = workspace.id
            audit("授权工作区", workspace.title)
        } catch { report(error) }
    }
    @discardableResult func importFile(_ url: URL) throws -> StudioInboxItem {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard properties.isRegularFile == true else { throw StudioFailure("请选择文件；文件夹请通过添加工作区授权。") }
        let size = properties.fileSize ?? 0
        guard size <= 25_000_000 else { throw StudioFailure("单个附件上限为 25 MB。") }
        let folder = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = UUID().uuidString + "-" + url.lastPathComponent
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
        let item = StudioInboxItem(title: url.lastPathComponent, body: "已保存在本机，可指派给任务。", filename: name)
        state.inbox.insert(item, at: 0)
        return item
    }
    func consumeSharedInbox() {
        if let prompt = UserDefaults.standard.string(forKey: "rune.intent.prompt") {
            UserDefaults.standard.removeObject(forKey: "rune.intent.prompt")
            compose(prompt)
        }
        guard let directory = try? RuneSharedInbox.directory(testing: ProcessInfo.processInfo.arguments.contains("--uitesting")),
              let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension == "json" {
            do {
                let envelope = try JSONDecoder().decode(SharedInboxEnvelope.self, from: Data(contentsOf: url))
                let source = envelope.filename.map { directory.appendingPathComponent($0) }
                if !state.inbox.contains(where: { $0.id == envelope.id }) {
                    if let filename = envelope.filename, let source {
                        guard source.lastPathComponent == filename else { continue }
                        let imported = try importFile(source)
                        if let i = state.inbox.firstIndex(where: { $0.id == imported.id }) { state.inbox[i].id = envelope.id; state.inbox[i].body = envelope.text; state.inbox[i].title = envelope.title }
                    } else {
                        var item = StudioInboxItem(title: envelope.title, body: envelope.text)
                        item.id = envelope.id; state.inbox.insert(item, at: 0)
                    }
                }
                guard persist() else { return }
                if let source, FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
                try FileManager.default.removeItem(at: url)
            } catch { report(error) }
        }
    }

    func saveProvider(_ provider: StudioProvider, secret: String) throws {
        guard provider.isValid else { throw StudioFailure("请填写名称、有效地址和模型 ID。公网必须 HTTPS，地址不要包含密钥或查询参数。") }
        if !secret.isEmpty { try ProviderSecrets.save(secret, id: provider.id) }
        if let i = state.providers.firstIndex(where: { $0.id == provider.id }) { state.providers[i] = provider }
        else { state.providers.append(provider) }
        if state.selectedProvider == nil { state.selectedProvider = provider.id }
    }
    func testProvider(_ provider: StudioProvider, secret: String) async throws -> String {
        guard provider.isValid else { throw StudioFailure("请先填写完整的渠道配置。") }
        let key = secret.isEmpty ? (ProviderSecrets.read(provider.id) ?? "") : secret
        var headers = ["Accept": "application/json"]
        if provider.protocolName == "Anthropic" { headers["x-api-key"] = key; headers["anthropic-version"] = "2023-06-01" }
        else if provider.protocolName == "Gemini" { headers["x-goog-api-key"] = key }
        else if !key.isEmpty { headers["Authorization"] = "Bearer " + key }
        let transport = URLSessionModelTransport(policy: try .init(allowedOrigins: [provider.baseURL], allowPrivateNetwork: provider.allowPrivateNetwork == true, methods: ["GET"]))
        let response = try await transport.sendAsync(.init(url: provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models", method: "GET", headers: headers, body: Data(), timeoutSeconds: 15))
        guard (200...299).contains(response.statusCode) else { throw StudioFailure("渠道返回 HTTP \(response.statusCode)。请检查地址、密钥和访问权限。") }
        return "连接成功。模型列表可访问；这不会验证模型生成能力。"
    }

    func open(_ url: URL) {
        guard url.scheme == "rune" else { return }
        if url.host == "new" { dismissRoutes(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.compose() }; return }
        if url.host == "inbox" { dismissRoutes(); section = 0; consumeSharedInbox(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.showInbox = true }; return }
        if url.host == "task", let id = UUID(uuidString: url.lastPathComponent), task(id) != nil {
            let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "action" })?.value
            if action == "pause" { pause(id) }
            if action == "resume" { resume(id) }
            dismissRoutes()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.openTask(id) }
        }
    }
    private func dismissRoutes() {
        showComposer = false; showInbox = false; showSettings = false; showCommands = false; taskRoute = nil
    }
    func hasActivity(_ id: UUID) -> Bool { activities[id] != nil }
    func beginActivity(_ task: StudioTask) {
        guard state.liveActivities, activities[task.id] == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activities[task.id] = try Activity.request(attributes: RuneActivityAttributes(taskID: task.id.uuidString, workspace: workspaceName(task.workspaceID), startedAt: task.createdAt),
                content: ActivityContent(state: activityState(task), staleDate: Date().addingTimeInterval(300)), pushType: nil)
        } catch { audit("实时活动未启动", String(describing: error)) }
    }
    func updateActivity(_ task: StudioTask) {
        guard let activity = activities[task.id] else { return }
        let content = ActivityContent(state: activityState(task), staleDate: Date().addingTimeInterval(300))
        if task.phase.isActive { enqueueActivity { await activity.update(content) } }
        else {
            activities[task.id] = nil
            enqueueActivity { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(60))) }
        }
    }
    func stopActivities() {
        let current = activities.values; activities = [:]
        enqueueActivity { for activity in current { await activity.end(nil, dismissalPolicy: .immediate) } }
    }
    private func activityState(_ task: StudioTask) -> RuneActivityAttributes.ContentState {
        .init(title: task.title, detail: task.steps.last?.title ?? task.phase.title, phase: task.phase.rawValue, progress: task.progress, requiresApproval: task.phase == .approval)
    }
}

struct StudioFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ProviderSecrets {
    static func save(_ secret: String, id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.rune.provider", kSecAttrAccount as String: id.uuidString]
        let attributes = [kSecValueData as String: Data(secret.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            // ⚠️ 报一个 `-34018` 给用户等于没报：它既没说清"发生了什么"，
            //    也没说清"后果是什么"。而这里的后果很具体 ——
            //    **密钥没存下来，这个渠道一旦真去跑任务就会鉴权失败**。
            //    实测触发方式：模拟器里的**未签名**构建（缺 Keychain entitlement，
            //    报 `errSecMissingEntitlement`）。真机用开发者证书签名后正常。
            //
            //    ⚠️ 另一条同样重要：**别说"已保存"**。测试连接用的是输入框里那份
            //    内存中的密钥，所以它会成功 —— 用户很容易以为"测试通过 = 配置好了"，
            //    然后在第一次真跑任务时撞上鉴权失败，且不知道原因。
            // ⚠️ `-34018`（errSecMissingEntitlement）**不在公开头文件里**，
            //    Swift 里拿不到这个符号（用了会编译失败），所以按数值比对。
            //    数值来自实测：模拟器未签名构建建 Keychain 项时返回它。
            let hint = status == -34018
                ? "这个构建没有钥匙串权限（模拟器里的未签名运行常见）。真机用开发者证书签名安装后可以正常保存。"
                : "请检查设备是否已解锁；若反复失败，重启 App 后再试。"
            throw StudioFailure("密钥没能存进钥匙串（错误码 \(status)）。\(hint)\n\n⚠️ 注意：这个渠道的密钥**没有保存**，直接开始任务会因为鉴权失败而报错。")
        }
    }
    static func read(_ id: UUID) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.rune.provider", kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func remove(_ id: UUID) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.rune.provider", kSecAttrAccount as String: id.uuidString] as CFDictionary) }
}
