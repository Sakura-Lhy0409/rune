import AppIntents
import Foundation

struct StartRuneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "在 Rune 中创建任务"
    static let description = IntentDescription("打开任务输入，保留你的想法。不会自动发送到模型。")
    static let openAppWhenRun = true
    @Parameter(title: "任务内容", default: "") var prompt: String
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(prompt, forKey: "rune.intent.prompt")
        NotificationCenter.default.post(name: .init("RuneComposeIntent"), object: nil)
        return .result()
    }
}
struct RuneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRuneTaskIntent(), phrases: ["在 \(.applicationName) 中创建任务", "用 \(.applicationName) 记一下"], shortTitle: "新建任务", systemImageName: "plus.bubble")
    }
}
