import Foundation
import SwiftUI

public enum StudioPhase: String, Codable, CaseIterable, Sendable {
    case queued, running, paused, approval, completed, cancelled, failed
    public var title: String {
        switch self {
        case .queued: "待连接"
        case .running: "进行中"
        case .paused: "已暂停"
        case .approval: "等你确认"
        case .completed: "已完成"
        case .cancelled: "已取消"
        case .failed: "需要处理"
        }
    }
    public var symbol: String {
        switch self {
        case .queued: "clock"
        case .running: "circle.dotted.circle"
        case .paused: "pause.circle"
        case .approval: "hand.raised"
        case .completed: "checkmark.circle"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.circle"
        }
    }
    public var isActive: Bool { [.running, .paused, .approval].contains(self) }
}

public enum RuneAppearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark
    public var title: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" } }
    public var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
}

public enum StudioTrust: String, Codable, CaseIterable, Sendable {
    case readOnly, suggest, collaborate, autonomous, full
    public var title: String { switch self { case .readOnly: "只读"; case .suggest: "提议"; case .collaborate: "协作"; case .autonomous: "自治"; case .full: "全权" } }
    public var detail: String {
        switch self {
        case .readOnly: "了解文件与项目，不修改内容。"
        case .suggest: "生成建议和变更，等你审阅后应用。"
        case .collaborate: "在已授权工作区协作；删除和外发仍需确认。"
        case .autonomous: "在明确批准的范围内连续推进任务。"
        case .full: "扩大自主范围，仍受系统沙箱和具体授权约束。"
        }
    }
}

public struct StudioMessage: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var role: String
    public var text: String
    public var date = Date()
    public init(role: String, text: String) { self.role = role; self.text = text }
}
public struct StudioStep: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    public var detail: String
    public var date = Date()
    public init(_ title: String, detail: String = "") { self.title = title; self.detail = detail }
}
public struct StudioChange: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var path: String
    public var before: String
    public var after: String
    public var decision: String = "pending"
    public var runtimeID: String?
    public init(path: String, before: String, after: String) { self.path = path; self.before = before; self.after = after }
}
public struct StudioRuntimeApproval: Codable, Hashable, Sendable {
    public var callID: String
    public var tool: String
    public var reason: String
    public var arguments: String
    public var recovery: Bool
    public var reviewError: String?
    public init(callID: String, tool: String, reason: String, arguments: String, recovery: Bool, reviewError: String? = nil) {
        self.callID = callID; self.tool = tool; self.reason = reason; self.arguments = arguments; self.recovery = recovery; self.reviewError = reviewError
    }
}
public struct StudioTask: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    public var workspaceID: UUID
    public var createdAt = Date()
    public var phase: StudioPhase = .queued
    public var progress: Double = 0
    public var messages: [StudioMessage] = []
    public var steps: [StudioStep] = []
    public var changes: [StudioChange] = []
    public var pinned = false
    public var archived = false
    public var isDemo = false
    public var trust: StudioTrust = .collaborate
    public var isLive: Bool?
    public var providerID: UUID?
    public var modelName: String?
    public var liveText: String?
    public var runtimeApproval: StudioRuntimeApproval?
    public var costMicroUSD: Int?
    public var costKnown: Bool?
    public var budgetPaused: Bool?
    public var suggestedBudgetMicroUSD: Int?
    public var requestCount: Int?
    public init(title: String, workspaceID: UUID) { self.title = title; self.workspaceID = workspaceID }
}
public struct StudioWorkspace: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    public var icon = "folder"
    public var bookmark: Data?
    public var isSample = false
    public init(title: String, isSample: Bool = false, bookmark: Data? = nil) {
        self.title = title; self.isSample = isSample; self.bookmark = bookmark
    }
}
public struct StudioProvider: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var title = ""
    public var baseURL = "https://api.openai.com/v1"
    public var model = ""
    public var protocolName = "OpenAI 兼容"
    public var allowPrivateNetwork: Bool?
    public var inputPricePerMillion: Double?
    public var outputPricePerMillion: Double?
    public init() {}
    public var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty, !model.trimmingCharacters(in: .whitespaces).isEmpty,
              let url = URL(string: baseURL), (url.scheme == "https" || (allowPrivateNetwork == true && url.scheme == "http")), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        for value in [inputPricePerMillion, outputPricePerMillion].compactMap({ $0 }) {
            if !value.isFinite || value < 0 || value > 10_000 { return false }
        }
        return true
    }
}
public struct StudioNote: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    public var body: String
    public var category: String
    public init(title: String, body: String, category: String) { self.title = title; self.body = body; self.category = category }
}
public struct StudioInboxItem: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    public var body: String
    public var filename: String?
    public var date = Date()
    public init(title: String, body: String, filename: String? = nil) { self.title = title; self.body = body; self.filename = filename }
}
public struct StudioAudit: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    public var detail: String
    public var date = Date()
    public init(_ title: String, detail: String) { self.title = title; self.detail = detail }
}
public struct StudioState: Codable, Sendable {
    public var version = 1
    public var workspaces: [StudioWorkspace] = []
    public var tasks: [StudioTask] = []
    public var providers: [StudioProvider] = []
    public var selectedProvider: UUID?
    public var selectedWorkspace: UUID?
    public var notes: [StudioNote] = []
    public var inbox: [StudioInboxItem] = []
    public var audit: [StudioAudit] = []
    public var appearance: RuneAppearance = .system
    public var dailyBudget = 3.0
    public var liveActivities = true
    public var haptics = true
    public var onboarded = false
    public init() {}

    /// 冷启动不能继续显示虚假的运行态；界面演练在下次由用户恢复。
    public mutating func recoverPresentation() {
        for i in tasks.indices where tasks[i].phase == .running {
            tasks[i].phase = .paused
            tasks[i].steps.append(.init("任务已暂停", detail: "重新打开后，可从这里继续。"))
        }
    }
}

public struct StudioDiffLine: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case context, inserted, removed }
    public let id: Int
    public let text: String
    public let kind: Kind
    public let number: Int?
    public static func make(before: String, after: String) -> [StudioDiffLine] {
        let old = before.components(separatedBy: "\n"), new = after.components(separatedBy: "\n")
        let difference = new.difference(from: old)
        let removed = Set(difference.removals.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset }; return nil
        })
        let inserted = Set(difference.insertions.compactMap { change -> Int? in
            if case .insert(let offset, _, _) = change { return offset }; return nil
        })
        var rows: [StudioDiffLine] = [], i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                rows.append(.init(id: rows.count, text: old[i], kind: .removed, number: i + 1)); i += 1
            } else if j < new.count, inserted.contains(j) {
                rows.append(.init(id: rows.count, text: new[j], kind: .inserted, number: j + 1)); j += 1
            } else if j < new.count {
                rows.append(.init(id: rows.count, text: new[j], kind: .context, number: j + 1)); i += 1; j += 1
            } else { i += 1 }
        }
        return rows
    }
}
