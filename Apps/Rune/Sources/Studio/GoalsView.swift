import SwiftUI
import RuneUI

struct GoalsView: View {
    @EnvironmentObject private var store: StudioStore
    @State private var adding = false
    @State private var title = ""
    var goals: [StudioNote] { store.state.notes.filter { $0.category == "目标" } }
    var body: some View {
        List {
            Section {
                Text("不急着做完所有事。先写下目标，再把下一步变具体。")
                    .font(.subheadline).foregroundStyle(RunePalette.secondary).listRowBackground(Color.clear)
            }
            if goals.isEmpty { RuneEmptyState("从一个值得做的目标开始", detail: "这是你的本地行动清单，\n由你勾选进度，不会自动启动模型。", symbol: "flag").listRowBackground(Color.clear) }
            ForEach(goals) { goal in
                NavigationLink { GoalDetailView(goalID: goal.id) } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(goal.title).font(.headline)
                        let lines = goal.body.components(separatedBy: "\n").filter { !$0.isEmpty }
                        let completed = lines.filter { $0.hasPrefix("[x] ") }.count
                        ProgressView(value: Double(completed), total: Double(max(1, lines.count)))
                        Text("\(completed) / \(lines.count) 步完成").font(.caption).foregroundStyle(RunePalette.secondary)
                    }.padding(.vertical, 9)
                }
            }
        }.scrollContentBackground(.hidden).background(RunePalette.canvas).navigationTitle("目标与清单")
            .toolbar { Button("新目标", systemImage: "plus") { title = ""; adding = true }.accessibilityIdentifier("new-goal") }
            .alert("创建目标", isPresented: $adding) {
                TextField("你想完成什么？", text: $title)
                Button("取消", role: .cancel) { }
                Button("创建") { if !title.trimmingCharacters(in: .whitespaces).isEmpty { store.state.notes.append(.init(title: title, body: "", category: "目标")) } }
            }
    }
}
struct GoalDetailView: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    let goalID: UUID
    @State private var step = ""
    @State private var deleting = false
    private var goal: StudioNote? { store.state.notes.first { $0.id == goalID } }
    private var lines: [String] { goal?.body.components(separatedBy: "\n").filter { !$0.isEmpty } ?? [] }
    var body: some View {
        List {
            Section {
                let count = lines.filter { $0.hasPrefix("[x] ") }.count
                HStack { Text("一步一步来").font(.subheadline); Spacer(); Text("\(count)/\(lines.count)").font(.caption.monospacedDigit()) }
                ProgressView(value: Double(count), total: Double(max(1, lines.count)))
            }
            Section("行动清单") {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Button {
                        var updated = lines
                        updated[index] = (line.hasPrefix("[x] ") ? "[ ] " : "[x] ") + String(line.dropFirst(4))
                        save(updated)
                    } label: {
                        HStack(spacing: 12) { Image(systemName: line.hasPrefix("[x] ") ? "checkmark.circle.fill" : "circle"); Text(String(line.dropFirst(4))).strikethrough(line.hasPrefix("[x] ")).foregroundStyle(line.hasPrefix("[x] ") ? RunePalette.secondary : RunePalette.ink) }.padding(.vertical, 5)
                    }.accessibilityIdentifier("goal-step-\(index)")
                }.onDelete { indices in var updated = lines; updated.remove(atOffsets: indices); save(updated) }
                HStack { TextField("添加一个具体的步骤", text: $step).accessibilityIdentifier("goal-step-input"); Button("添加", systemImage: "plus.circle.fill") { add() }.labelStyle(.iconOnly).disabled(step.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("add-goal-step") }
            }
            Section { Button("用此目标创建任务", systemImage: "arrow.up.right") { if let goal { store.compose(goal.title + "\n" + goal.body) } } }
        }.scrollContentBackground(.hidden).background(RunePalette.canvas).navigationTitle(goal?.title ?? "目标").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("删除目标", systemImage: "trash", role: .destructive) { deleting = true } }
            .confirmationDialog("删除这个目标和行动清单？", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除目标", role: .destructive) { store.state.notes.removeAll { $0.id == goalID }; dismiss() }
            }
    }
    private func add() { guard !step.trimmingCharacters(in: .whitespaces).isEmpty else { return }; save(lines + ["[ ] " + step]); step = "" }
    private func save(_ lines: [String]) { if let i = store.state.notes.firstIndex(where: { $0.id == goalID }) { store.state.notes[i].body = lines.joined(separator: "\n") } }
}
