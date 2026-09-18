import ActivityKit
import Foundation

struct RuneActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var detail: String
        var phase: String
        var progress: Double
        var requiresApproval: Bool
    }
    var taskID: String
    var workspace: String
    var startedAt: Date
}

struct SharedInboxEnvelope: Codable {
    var id: UUID
    var title: String
    var text: String
    var filename: String?
    var date: Date
}

enum RuneSharedInbox {
    static let group = "group.dev.rune.agent"
    static func directory(testing: Bool? = nil) throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let useTesting = testing ?? (UserDefaults(suiteName: group)?.bool(forKey: "uiTesting") ?? false)
        let url = root.appendingPathComponent(useTesting ? "Inbox-Testing" : "Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
