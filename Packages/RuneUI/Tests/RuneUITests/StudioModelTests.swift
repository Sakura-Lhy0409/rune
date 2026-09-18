import Testing
import Foundation
@testable import RuneUI

@Suite("界面状态与审阅模型")
struct StudioModelTests {
    @Test("界面状态往返保留会话、审批决定和工作区")
    func roundTrip() throws {
        var state = StudioState()
        let workspace = StudioWorkspace(title: "工作区", isSample: true)
        state.workspaces = [workspace]
        state.selectedWorkspace = workspace.id
        var task = StudioTask(title: "审阅文件", workspaceID: workspace.id)
        task.phase = .approval
        task.changes = [.init(path: "a.md", before: "before", after: "after")]
        task.messages = [.init(role: "user", text: "需要审阅")]
        state.tasks = [task]
        let decoded = try JSONDecoder().decode(StudioState.self, from: JSONEncoder().encode(state))
        #expect(decoded.tasks == state.tasks)
        #expect(decoded.workspaces == state.workspaces)
        #expect(decoded.selectedWorkspace == workspace.id)
    }
    @Test("冷启动只暂停运行中的任务，不自动批准变更")
    func coldStart() {
        var state = StudioState()
        state.tasks = StudioPhase.allCases.map { phase in
            var task = StudioTask(title: phase.title, workspaceID: UUID()); task.phase = phase; return task
        }
        state.recoverPresentation()
        #expect(!state.tasks.contains { $0.phase == .running })
        #expect(state.tasks.filter { $0.phase == .paused }.count == 2)
        #expect(state.tasks.first { $0.title == StudioPhase.approval.title }?.phase == .approval)
    }
    @Test("差异行能无损重建修改前后，包含重复行、空行与中文", arguments: [
        ["a\nb\nc\n", "a\nB\nc\n"], ["", "新建"], ["删除\n", ""],
        ["a\na\nb\na", "a\nb\na\na"], ["第一行\n\n第三行", "第一行\n第二行\n第三行"],
    ])
    func diffRoundTrip(pair: [String]) {
        let rows = StudioDiffLine.make(before: pair[0], after: pair[1])
        #expect(rows.filter { $0.kind != .inserted }.map(\.text).joined(separator: "\n") == pair[0])
        #expect(rows.filter { $0.kind != .removed }.map(\.text).joined(separator: "\n") == pair[1])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }
    @Test("配置拒绝不安全地址和 URL 中的密钥")
    func providerValidation() throws {
        var provider = StudioProvider(); provider.title = "测试"; provider.model = "model"
        #expect(provider.isValid)
        for url in ["http://example.com", "https://key:secret@example.com", "https://example.com?key=secret", "https://example.com#secret", "file:///tmp/"] {
            provider.baseURL = url
            #expect(!provider.isValid)
        }
        let json = try String(decoding: JSONEncoder().encode(StudioProvider()), as: UTF8.self)
        #expect(!json.contains("apiKey"))
        #expect(!json.contains("secret"))
    }
    @Test("只有运行、暂停和等待审批属于活跃任务")
    func activityStates() {
        #expect(StudioPhase.allCases.filter(\.isActive) == [.running, .paused, .approval])
    }
    @Test("旧界面 JSON 缺少运行时和报价字段时仍可读取")
    func previousUIVersion() throws {
        var state = StudioState()
        var provider = StudioProvider(); provider.title = "保留渠道"; provider.model = "test"
        state.providers = [provider]
        state.tasks = [StudioTask(title: "旧会话", workspaceID: UUID())]
        let decoded = try JSONDecoder().decode(StudioState.self, from: JSONEncoder().encode(state))
        #expect(decoded.tasks.first?.isLive == nil)
        #expect(decoded.providers.first?.inputPricePerMillion == nil)
        #expect(decoded.providers.first?.title == "保留渠道")
    }

}
