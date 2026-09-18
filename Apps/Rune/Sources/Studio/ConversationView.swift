import SwiftUI
import RuneUI

struct ConversationView: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let taskID: UUID
    @State private var draft = ""
    @State private var timeline = false
    @State private var trust = false
    @State private var artifacts = false
    @State private var stop = false
    @State private var revert = false
    @State private var increaseBudget = false
    @State private var copied = false
    @State private var selectedChange: StudioChange?
    private var task: StudioTask? { store.task(taskID) }

    var body: some View {
        Group {
            if let task {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 27) {
                            HStack(spacing: 9) {
                                Label(store.workspaceName(task.workspaceID), systemImage: "folder")
                                Spacer()
                                Text(store.runtimeCostLabel(task))
                            }.font(.caption2).foregroundStyle(RunePalette.secondary)
                            if !task.isDemo {
                                Menu {
                                    ForEach(store.state.providers) { provider in
                                        Button(provider.title + " · " + provider.model) { store.updateTask(taskID) { $0.providerID = provider.id } }
                                    }
                                    if store.state.providers.isEmpty { Text("先在设置中添加渠道") }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "network")
                                        if let provider = store.state.providers.first(where: { $0.id == (task.providerID ?? store.state.selectedProvider) }) {
                                            Text(provider.title + " · " + (task.modelName ?? provider.model)).lineLimit(1)
                                        } else { Text("尚未选择渠道") }
                                        if task.isLive != true { Image(systemName: "chevron.down") }
                                    }.font(.caption).foregroundStyle(RunePalette.secondary)
                                }.disabled(task.isLive == true).accessibilityIdentifier("task-provider")
                            }
                            if store.hasActivity(taskID) {
                                Label("实时活动已开启", systemImage: "capsule").font(.caption2).foregroundStyle(RunePalette.secondary).accessibilityIdentifier("live-activity-active")
                            }
                            ForEach(task.messages) { message in messageView(message) }
                            if !task.isDemo && (task.phase == .queued || task.phase == .failed) && task.runtimeApproval == nil {
                                VStack(alignment: .leading, spacing: 14) {
                                    HStack { Label(task.phase == .failed ? "任务需要重新尝试" : "准备开始", systemImage: task.phase == .failed ? "exclamationmark.circle" : "play.circle").font(.headline); Spacer(); Text(store.runtimeCostLabel(task)).font(.caption).foregroundStyle(RunePalette.secondary) }
                                    Text(task.phase == .failed ? "上次执行已停止；已有文件和事件会保留。重新开始前会先从检查点恢复。" : "这会把会话内容发送到你选择的模型，并在每次修改前请求确认。")
                                        .font(.subheadline).foregroundStyle(RunePalette.secondary).lineSpacing(4)
                                    Button(task.phase == .failed ? "重新开始" : "开始执行", systemImage: "play.fill") { store.startLive(taskID, action: task.phase == .failed ? .resume : .proceed) }
                                        .buttonStyle(RunePrimaryStyle()).accessibilityIdentifier("start-live-task")
                                }.padding(20).runeSurface()
                            }
                            if task.phase == .paused && task.budgetPaused == true {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label("预算已暂停", systemImage: "dollarsign.circle").font(.headline).foregroundStyle(RunePalette.amber)
                                    Text("已花费 \(store.runtimeCostLabel(task))。提高预算后会从保存的检查点继续。").font(.subheadline).foregroundStyle(RunePalette.secondary)
                                    Button("提高预算并继续") { increaseBudget = true }.buttonStyle(RunePrimaryStyle()).accessibilityIdentifier("raise-budget")
                                }.padding(20).background(RunePalette.paper, in: RoundedRectangle(cornerRadius: 20))
                            }
                            if task.phase == .running || (task.phase == .paused && task.budgetPaused != true) {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack { RuneStatusLabel(task.phase); Spacer(); Text(task.isLive == true ? "第 \(task.requestCount ?? 0) 轮" : "\(Int(task.progress * 100))%").font(.caption.monospacedDigit()) }
                                    Text(task.steps.last?.title ?? "准备开始").font(.subheadline)
                                    if task.isLive == true { ProgressView() } else { ProgressView(value: task.progress) }
                                    Button(task.phase == .running ? "暂停任务" : "继续任务", systemImage: task.phase == .running ? "pause" : "play") {
                                        if task.phase == .running { store.pause(taskID) } else { store.resume(taskID) }
                                    }.font(.caption.weight(.medium)).accessibilityIdentifier("pause-resume-task")
                                }.padding(20).runeSurface()
                            }
                            if let liveText = task.liveText, !liveText.isEmpty {
                                VStack(alignment: .leading, spacing: 8) { Label("模型正在回复", systemImage: "waveform").font(.caption.weight(.medium)).foregroundStyle(RunePalette.accent); MessageContentView(text: liveText) }
                                    .padding(17).runeSurface()
                            }
                            if let approval = task.runtimeApproval {
                                VStack(alignment: .leading, spacing: 15) {
                                    HStack { RuneStatusLabel(.approval); Spacer(); Text(approval.recovery ? "恢复确认" : approval.tool).font(.caption).foregroundStyle(RunePalette.secondary) }
                                    Text(approval.reason).font(.subheadline).foregroundStyle(RunePalette.ink).lineSpacing(4)
                                    if let reviewError = approval.reviewError { Text("无法审阅：" + reviewError).font(.caption).foregroundStyle(RunePalette.amber) }
                                    if !approval.arguments.isEmpty { Text(approval.arguments).font(.system(.caption, design: .monospaced)).foregroundStyle(RunePalette.secondary).lineLimit(4).textSelection(.enabled).padding(12).background(RunePalette.paper, in: RoundedRectangle(cornerRadius: 12)) }
                                    HStack {
                                        Button("拒绝") { store.decideLive(taskID, callID: approval.callID, accept: false) }.buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityIdentifier("reject-live-change")
                                        Spacer()
                                        Button("允许并继续", systemImage: "checkmark") { store.decideLive(taskID, callID: approval.callID, accept: true) }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).accessibilityIdentifier("approve-live-change").disabled(approval.reviewError != nil)
                                    }
                                }.padding(20).background(RunePalette.paper, in: RoundedRectangle(cornerRadius: 22))
                            }
                            if !task.changes.isEmpty {
                                VStack(alignment: .leading, spacing: 16) {
                                    HStack { Label("文件变更", systemImage: "square.and.pencil").font(.headline); Spacer(); Text("\(task.changes.count) 个文件").font(.caption).foregroundStyle(RunePalette.secondary) }
                                    ForEach(task.changes) { change in
                                        VStack(alignment: .leading, spacing: 15) {
                                            Button { selectedChange = change } label: {
                                                HStack { Label(change.path, systemImage: "doc.text").font(.subheadline.weight(.medium)); Spacer(); Text("查看差异").font(.caption); Image(systemName: "chevron.right").font(.caption2) }
                                            }.accessibilityIdentifier("open-diff")
                                            DiffExcerpt(change: change)
                                            if change.decision == "pending" && task.phase == .approval {
                                                HStack(spacing: 12) {
                                                    Button("拒绝") { store.decide(taskID: taskID, changeID: change.id, accept: false) }
                                                        .buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityIdentifier("reject-change")
                                                    Spacer()
                                                    Button("审阅并应用", systemImage: "checkmark") { selectedChange = change }
                                                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).accessibilityIdentifier("review-change")
                                                }
                                            } else {
                                                Label(change.decision == "accepted" ? "已写入文件" : change.decision == "reverted" ? "已撤销" : "已保留原文件", systemImage: change.decision == "accepted" ? "checkmark.circle" : "arrow.uturn.backward")
                                                    .font(.caption).foregroundStyle(RunePalette.accent).accessibilityIdentifier("change-result")
                                            }
                                        }.padding(18).background(RunePalette.surface, in: RoundedRectangle(cornerRadius: 20))
                                    }
                                }
                            }
                            if task.phase == .completed {
                                HStack {
                                    RuneStatusLabel(.completed)
                                    Spacer()
                                    if task.changes.contains(where: { $0.decision == "accepted" }) {
                                        Button("撤销修改", systemImage: "arrow.uturn.backward") { revert = true }.font(.caption).accessibilityIdentifier("undo-change")
                                    }
                                }
                            }
                            Button { timeline = true } label: {
                                HStack { Image(systemName: "clock.arrow.circlepath"); Text("查看完整过程"); Spacer(); Text("\(task.steps.count) 步"); Image(systemName: "chevron.right") }.font(.caption).foregroundStyle(RunePalette.secondary)
                            }.padding(.vertical, 12).accessibilityIdentifier("open-timeline").keyboardShortcut("t", modifiers: [.command, .shift])
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(24).frame(maxWidth: 800).frame(maxWidth: .infinity)
                    }.background(RunePalette.canvas)
                        .safeAreaInset(edge: .bottom) {
                            HStack(alignment: .bottom, spacing: 12) {
                                Menu {
                                    Button("文件与产物", systemImage: "doc.on.doc") { artifacts = true }
                                    Button("信任与权限", systemImage: "hand.raised") { trust = true }
                                    Button("时间轴", systemImage: "clock.arrow.circlepath") { timeline = true }
                                } label: { Image(systemName: "plus").frame(width: 30, height: 34) }.accessibilityLabel("会话工具")
                                TextField("补充一句…", text: $draft, axis: .vertical).lineLimit(1...5).font(.subheadline).accessibilityIdentifier("message-input")
                                Button {
                                    store.send(draft, to: taskID); draft = ""
                                    if reduceMotion { proxy.scrollTo("bottom", anchor: .bottom) }
                                    else { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                                } label: { Image(systemName: "arrow.up").font(.subheadline.weight(.semibold)).frame(width: 34, height: 34).foregroundStyle(RunePalette.canvas).background(RunePalette.accent, in: Circle()) }
                                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("发送补充").accessibilityIdentifier("send-message").keyboardShortcut(.return, modifiers: .command)
                            }.padding(13).runeGlass(radius: 27).padding(.horizontal, 18).padding(.bottom, 10)
                        }
                }
                .navigationTitle(task.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("关闭", systemImage: "chevron.down") { dismiss() }.labelStyle(.iconOnly).accessibilityIdentifier("close-conversation") }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("信任与权限", systemImage: "hand.raised") { trust = true }
                            Button("文件与产物", systemImage: "doc.on.doc") { artifacts = true }
                            Button("时间轴", systemImage: "clock.arrow.circlepath") { timeline = true }
                            Button(task.pinned ? "取消置顶" : "置顶", systemImage: "pin") { store.updateTask(taskID) { $0.pinned.toggle() } }
                            ShareLink(item: task.messages.map { "\($0.role == "user" ? "我" : "Rune")：\n\($0.text)" }.joined(separator: "\n\n")) { Label("导出会话", systemImage: "square.and.arrow.up") }
                            if task.phase.isActive { Button("取消任务", systemImage: "stop.circle", role: .destructive) { stop = true } }
                        } label: { Image(systemName: "ellipsis") }.accessibilityIdentifier("conversation-menu").accessibilityLabel("更多操作")
                    }
                }
                .sheet(isPresented: $timeline) { TimelineView(taskID: taskID) }
                .sheet(isPresented: $trust) { TrustSheet(taskID: taskID) }
                .sheet(isPresented: $artifacts) { NavigationStack { ArtifactsView(taskID: taskID) } }
                .sheet(item: $selectedChange) { change in DiffReviewView(taskID: taskID, changeID: change.id) }
                .confirmationDialog("取消这个任务？未应用的变更会保留供查看。", isPresented: $stop, titleVisibility: .visible) {
                    Button("取消任务", role: .destructive) { store.cancel(taskID) }
                }
                .confirmationDialog("确认提高任务预算？", isPresented: $increaseBudget, titleVisibility: .visible) {
                    Button("提高并继续") { store.raiseRuntimeBudget(taskID) }
                } message: {
                    Text(String(format: "新上限约 $%.2f。继续会再次调用所选模型。", Double(max(task.suggestedBudgetMicroUSD ?? 0, max(Int(store.state.dailyBudget * 2_000_000), (task.costMicroUSD ?? 0) * 2))) / 1_000_000))
                }
                .confirmationDialog("将文件恢复到这次变更之前？", isPresented: $revert, titleVisibility: .visible) {
                    Button("确认撤销", role: .destructive) { store.undo(taskID) }.accessibilityIdentifier("confirm-undo")
                }
            } else { ContentUnavailableView("会话不存在", systemImage: "bubble.left").toolbar { Button("关闭") { dismiss() } } }
        }
    }
    private func messageView(_ message: StudioMessage) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            if message.role != "user" {
                HStack(spacing: 8) { RuneMark().frame(width: 13, height: 20); Text("Rune").font(.system(.caption, design: .serif).weight(.semibold)) }.foregroundStyle(RunePalette.accent)
            }
            MessageContentView(text: message.text)
        }
        .padding(message.role == "user" ? 18 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == "user" ? RunePalette.paper : Color.clear, in: RoundedRectangle(cornerRadius: 20))
        .contextMenu { Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text } }
    }
}

struct DiffExcerpt: View {
    let change: StudioChange
    var rows: [StudioDiffLine] { Array(StudioDiffLine.make(before: change.before, after: change.after).filter { $0.kind != .context }.prefix(6)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 9) {
                    Text(row.kind == .removed ? "−" : "+").frame(width: 12)
                    Text(row.text.isEmpty ? " " : row.text).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(.caption, design: .monospaced)).padding(9)
                    .foregroundStyle(row.kind == .removed ? RunePalette.danger : RunePalette.accent)
                    .background((row.kind == .removed ? RunePalette.danger : RunePalette.accent).opacity(0.06))
            }
        }.clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct DiffReviewView: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID, changeID: UUID
    @State private var onlyChanges = false
    @State private var apply = false
    private var change: StudioChange? { store.task(taskID)?.changes.first { $0.id == changeID } }
    var body: some View {
        NavigationStack {
            if let change {
                VStack(spacing: 0) {
                    HStack { Label(change.path, systemImage: "doc.text").font(.subheadline.weight(.medium)); Spacer(); Toggle("仅变更", isOn: $onlyChanges).font(.caption).fixedSize().accessibilityLabel("仅显示变更") }.padding(20)
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(StudioDiffLine.make(before: change.before, after: change.after).filter { !onlyChanges || $0.kind != .context }) { row in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(row.number.map(String.init) ?? "").frame(width: 25, alignment: .trailing).foregroundStyle(RunePalette.secondary)
                                    Text(row.kind == .inserted ? "+" : row.kind == .removed ? "−" : " ").frame(width: 12)
                                    Text(row.text.isEmpty ? " " : row.text).textSelection(.enabled).frame(minWidth: 270, alignment: .leading)
                                }.font(.system(.caption, design: .monospaced)).padding(.horizontal, 16).padding(.vertical, 7)
                                    .foregroundStyle(row.kind == .removed ? RunePalette.danger : row.kind == .inserted ? RunePalette.accent : RunePalette.ink)
                                    .background((row.kind == .removed ? RunePalette.danger : row.kind == .inserted ? RunePalette.accent : Color.clear).opacity(0.08))
                            }
                        }
                    }.defaultScrollAnchor(.topLeading, for: .alignment)
                    if change.decision == "pending", store.task(taskID)?.phase == .approval {
                        VStack(spacing: 12) {
                            Label("审阅当前操作涉及的变更；确认后将执行整次工具调用。", systemImage: "lock.shield").font(.caption).foregroundStyle(RunePalette.secondary)
                            HStack {
                                Button("拒绝变更") { store.decide(taskID: taskID, changeID: changeID, accept: false); dismiss() }.buttonStyle(.bordered)
                                Button("应用这处变更", systemImage: "checkmark") { apply = true }.buttonStyle(RunePrimaryStyle()).accessibilityIdentifier("apply-change")
                            }
                        }.padding(20).background(RunePalette.surface)
                    }
                }.background(RunePalette.canvas).navigationTitle("审阅变更").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                    .confirmationDialog("应用到 \(change.path)？", isPresented: $apply, titleVisibility: .visible) {
                        Button("确认应用") { store.decide(taskID: taskID, changeID: changeID, accept: true); dismiss() }.accessibilityIdentifier("confirm-apply")
                    } message: { Text("写入前会再次检查原文件，防止覆盖你刚做的修改。") }
            }
        }
    }
}

struct TimelineView: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    @State private var filter = "全部"
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Picker("事件类型", selection: $filter) { ForEach(["全部", "文件", "决定"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                    if let task = store.task(taskID) {
                        HStack { RuneStatusLabel(task.phase); Spacer(); Text(store.runtimeCostLabel(task)).font(.caption.monospacedDigit()).foregroundStyle(RunePalette.secondary) }
                        ForEach(Array(task.steps.filter { filter == "全部" || (filter == "文件" ? !$0.detail.isEmpty : $0.title.contains("审阅") || $0.title.contains("应用") || $0.title.contains("暂停") || $0.title.contains("拒绝")) }.enumerated()), id: \.element.id) { index, step in
                            HStack(alignment: .top, spacing: 16) {
                                VStack(spacing: 9) { Circle().fill(RunePalette.accent).frame(width: 9, height: 9); Rectangle().fill(RunePalette.line).frame(width: 1, height: 46) }.frame(width: 12).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(step.title).font(.subheadline.weight(.medium))
                                    if !step.detail.isEmpty { Text(step.detail).font(.caption).foregroundStyle(RunePalette.secondary) }
                                    Text(step.date, format: .dateTime.hour().minute().second()).font(.caption2.monospacedDigit()).foregroundStyle(RunePalette.secondary)
                                }
                                Spacer()
                            }.foregroundStyle(RunePalette.ink)
                        }
                    }
                }.padding(24)
            }.background(RunePalette.canvas).navigationTitle("时间轴").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct TrustSheet: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    @State private var selected: StudioTrust = .collaborate
    @State private var confirm = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("让协作，\n停在合适的边界。 ").font(.system(.title, design: .serif)).foregroundStyle(RunePalette.ink)
                    ForEach(StudioTrust.allCases, id: \.self) { level in
                        Button { selected = level } label: {
                            HStack(alignment: .top, spacing: 15) {
                                Image(systemName: selected == level ? "checkmark.circle.fill" : "circle").font(.title3)
                                VStack(alignment: .leading, spacing: 5) { Text(level.title).font(.headline); Text(level.detail).font(.subheadline).foregroundStyle(RunePalette.secondary).multilineTextAlignment(.leading) }
                                Spacer(minLength: 0)
                            }.foregroundStyle(RunePalette.accent).padding(18).background(selected == level ? RunePalette.paper : RunePalette.surface, in: RoundedRectangle(cornerRadius: 18))
                        }
                    }
                    Text("只读与提议模式禁止修改；其余模式仍需逐次审批文件修改。正在运行的任务会在下一次启动时应用新的信任设置。")
                        .font(.caption).foregroundStyle(RunePalette.secondary)
                    Button("应用到此会话") { confirm = true }.buttonStyle(RunePrimaryStyle())
                }.padding(24)
            }.background(RunePalette.canvas).navigationTitle("信任与权限").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .onAppear { selected = store.task(taskID)?.trust ?? .collaborate }
                .confirmationDialog("将此会话设为\(selected.title)？", isPresented: $confirm, titleVisibility: .visible) {
                    Button("确认选择") { store.updateTask(taskID) { $0.trust = selected }; store.audit("调整会话偏好", selected.title); dismiss() }
                }
        }
    }
}

struct ArtifactsView: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    var body: some View {
        List {
            if let task = store.task(taskID) {
                if task.changes.isEmpty { RuneEmptyState("还没有产物", detail: "完成任务后，文件与变更会归拢在这里。", symbol: "doc.on.doc").listRowBackground(Color.clear) }
                ForEach(task.changes) { change in
                    NavigationLink { FileDetailView(workspaceID: task.workspaceID, path: change.path) } label: {
                        Label { VStack(alignment: .leading, spacing: 5) { Text(change.path); Text(change.decision == "accepted" ? "已应用" : "变更记录").font(.caption).foregroundStyle(RunePalette.secondary) } } icon: { Image(systemName: "doc.text") }
                    }
                }
            }
        }.scrollContentBackground(.hidden).background(RunePalette.canvas).navigationTitle("文件与产物")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
    }
}
