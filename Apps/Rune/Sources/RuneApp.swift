import SwiftUI
import RuneUI

@main
struct RuneApp: App {
    @StateObject private var studio = StudioStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RuneRootView()
                .environmentObject(studio)
                .tint(RunePalette.accent)
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                .preferredColorScheme(studio.state.appearance.colorScheme)
                .onOpenURL { studio.open($0) }
                .onReceive(NotificationCenter.default.publisher(for: .init("RuneComposeIntent"))) { _ in studio.consumeSharedInbox() }
                .onChange(of: phase) { _, phase in
                    if phase == .active { studio.consumeSharedInbox() }
                }
        }
    }
}
