import SwiftUI
import RuneUI

struct CommandPalette: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let settings: () -> Void
    var body: some View {
        NavigationStack {
            List {
                Section("前往") {
                    if matches("新建任务") { Button { perform { store.compose() } } label: { Label("新建任务", systemImage: "plus.bubble") } }
                    if matches("今天") { Button { perform { store.section = 0 } } label: { Label("今天", systemImage: "circle.grid.2x2") } }
                    if matches("会话") { Button { perform { store.section = 1 } } label: { Label("会话", systemImage: "bubble.left.and.bubble.right") } }
                    if matches("工作台") { Button { perform { store.section = 2 } } label: { Label("工作台", systemImage: "square.stack.3d.up") } }
                    if matches("设置") { Button { perform(settings) } label: { Label("设置", systemImage: "slider.horizontal.3") } }
                }
                Section("从技能开始") {
                    ForEach(store.state.notes.filter { $0.category == "技能" && matches($0.title) }) { note in
                        Button { perform { store.compose(note.body) } } label: { Label(note.title, systemImage: "square.stack") }
                    }
                }
                Section("最近会话") {
                    ForEach(store.visibleTasks.filter { matches($0.title) }.prefix(6)) { task in
                        Button { perform { store.openTask(task.id) } } label: { Label(task.title, systemImage: task.phase.symbol) }
                    }
                }
            }.scrollContentBackground(.hidden).background(RunePalette.canvas).navigationTitle("快捷操作").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "搜索页面、技能或会话")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
    private func matches(_ title: String) -> Bool { query.isEmpty || title.localizedCaseInsensitiveContains(query) }
    private func perform(_ action: @escaping () -> Void) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { action() } }
}

struct CameraCapture: UIViewControllerRepresentable {
    let completed: (UIImage?) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera; controller.cameraCaptureMode = .photo; controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completed: completed) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completed: (UIImage?) -> Void
        init(completed: @escaping (UIImage?) -> Void) { self.completed = completed }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completed(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { completed(info[.originalImage] as? UIImage) }
    }
}

struct MessageContentView: View {
    let text: String
    @State private var copied: Set<Int> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(text.components(separatedBy: "```").enumerated()), id: \.offset) { index, part in
                if index.isMultiple(of: 2) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(part.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            if line.hasPrefix("### ") { Text(String(line.dropFirst(4))).font(.headline) }
                            else if line.hasPrefix("## ") { Text(String(line.dropFirst(3))).font(.title3.weight(.semibold)) }
                            else if line.hasPrefix("# ") { Text(String(line.dropFirst(2))).font(.title2.weight(.semibold)) }
                            else if line.hasPrefix("> ") { HStack(alignment: .top, spacing: 10) { RoundedRectangle(cornerRadius: 1).fill(RunePalette.accent).frame(width: 2); Text(LocalizedStringKey(String(line.dropFirst(2)))).foregroundStyle(RunePalette.secondary) }.fixedSize(horizontal: false, vertical: true) }
                            else if line.isEmpty { Color.clear.frame(height: 3) }
                            else { Text(LocalizedStringKey(line)).font(.body).lineSpacing(5) }
                        }
                    }.textSelection(.enabled)
                } else {
                    let rows = part.components(separatedBy: "\n")
                    let language = rows.first ?? ""
                    let code = rows.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(language.isEmpty ? "代码" : language).font(.caption2.monospaced())
                            Spacer()
                            Button(copied.contains(index) ? "已复制" : "复制", systemImage: copied.contains(index) ? "checkmark" : "doc.on.doc") {
                                UIPasteboard.general.string = code; copied.insert(index)
                            }.font(.caption2)
                        }.foregroundStyle(RunePalette.secondary).padding(12)
                        Divider()
                        ScrollView(.horizontal) { Text(code).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled).padding(14) }
                    }.background(RunePalette.paper, in: RoundedRectangle(cornerRadius: 15))
                }
            }
        }.foregroundStyle(RunePalette.ink).frame(maxWidth: .infinity, alignment: .leading)
    }
}
