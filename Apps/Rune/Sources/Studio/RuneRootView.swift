import SwiftUI
import RuneUI

struct RuneRootView: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.horizontalSizeClass) private var width
    private let tabs = [("今天", "circle.grid.2x2"), ("会话", "bubble.left.and.bubble.right"), ("工作台", "square.stack.3d.up")]

    var body: some View {
        Group {
            if width == .regular {
                NavigationSplitView {
                    List {
                        Section {
                            ForEach(0..<3) { index in
                                Button { store.section = index } label: {
                                    Label(tabs[index].0, systemImage: tabs[index].1)
                                        .foregroundStyle(store.section == index ? RunePalette.accent : RunePalette.ink)
                                }.listRowBackground(store.section == index ? RunePalette.paper : Color.clear)
                            }
                        }
                        Section("工作区") {
                            ForEach(store.state.workspaces) { workspace in
                                Button { store.state.selectedWorkspace = workspace.id; store.section = 2 } label: {
                                    Label(workspace.title, systemImage: "folder")
                                }
                            }
                        }
                    }.scrollContentBackground(.hidden).background(RunePalette.canvas)
                        .navigationTitle("Rune")
                        .toolbar { ToolbarItem(placement: .bottomBar) { Button("设置", systemImage: "slider.horizontal.3") { store.showSettings = true } } }
                } detail: { page(store.section) }
            } else {
                TabView(selection: $store.section) {
                    ForEach(0..<3) { index in
                        page(index).tabItem { Label(tabs[index].0, systemImage: tabs[index].1) }.tag(index)
                    }
                }
            }
        }
        .sheet(isPresented: $store.showSettings) { SettingsView() }
        .sheet(isPresented: $store.showCommands) { CommandPalette(settings: { store.showSettings = true }) }
        .sheet(isPresented: $store.showInbox) { NavigationStack { InboxView() } }
        .sheet(isPresented: $store.showComposer) { NewTaskSheet(seed: store.composerSeed) }
        .fullScreenCover(item: $store.taskRoute) { route in
            NavigationStack { ConversationView(taskID: route.id) }
        }
        .fullScreenCover(isPresented: Binding(get: { !store.state.onboarded }, set: { if !$0 { store.state.onboarded = true } })) {
            OnboardingView()
        }
        .onChange(of: store.errorMessage) { _, message in if let message { presentError(message) } }
        .onAppear { if let message = store.errorMessage { presentError(message) } }
        .background(RunePalette.canvas)
    }

    // 错误可能来自文件选择器、全屏会话或二级 sheet，必须出现在当前最上层。
    private func presentError(_ message: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard store.errorMessage == message,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
                  var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
            while let next = controller.presentedViewController { controller = next }
            guard !(controller is UIAlertController) else { return }
            let alert = UIAlertController(title: "需要留意", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "知道了", style: .default) { _ in store.errorMessage = nil })
            controller.present(alert, animated: true)
        }
    }

    private func page(_ index: Int) -> some View {
        NavigationStack {
            Group {
                switch index {
                case 0: TodayView()
                case 1: ConversationsView()
                default: WorkbenchView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("快捷操作", systemImage: "magnifyingglass") { store.showCommands = true }
                        .labelStyle(.iconOnly).keyboardShortcut("k", modifiers: .command).accessibilityIdentifier("command-palette")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("设置").accessibilityIdentifier("open-settings")
                }
            }
        }
    }
}

struct TodayView: View {
    @EnvironmentObject private var store: StudioStore
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize = 32
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Date(), format: .dateTime.month(.wide).day().weekday(.wide))
                            .font(.caption.weight(.medium)).foregroundStyle(RunePalette.secondary)
                        Text("给重要的事，\n留一点空间。")
                            .font(.system(size: headlineSize, weight: .medium, design: .serif))
                            .tracking(-0.8).lineSpacing(4).foregroundStyle(RunePalette.ink)
                    }
                    Spacer(minLength: 12)
                    RuneMark().foregroundStyle(RunePalette.accent).frame(width: 38, height: 54).padding(.top, 32)
                }.padding(.top, 8)

                if let active = store.activeTasks.first {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack { RuneStatusLabel(active.phase); Spacer(); Text("本地演练").font(.caption).foregroundStyle(RunePalette.secondary) }
                        Text(active.title).font(.title2.weight(.semibold)).foregroundStyle(RunePalette.ink)
                        Text(active.steps.last?.title ?? "准备开始").font(.subheadline).foregroundStyle(RunePalette.secondary)
                        ProgressView(value: active.progress).tint(RunePalette.accent)
                        HStack {
                            Button(active.phase == .approval ? "审阅变更" : "查看任务") { store.openTask(active.id) }
                                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                                .accessibilityIdentifier("open-active-task")
                            Spacer()
                            if active.phase == .running { Button("暂停", systemImage: "pause") { store.pause(active.id) }.labelStyle(.iconOnly) }
                            if active.phase == .paused { Button("继续", systemImage: "play") { store.resume(active.id) }.labelStyle(.iconOnly) }
                        }
                    }.padding(24).background(RunePalette.paper, in: RoundedRectangle(cornerRadius: 26))
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack { Label("从一次小协作开始", systemImage: "leaf").font(.caption.weight(.medium)); Spacer(); Image(systemName: "arrow.up.right").font(.caption) }
                        Text("看见变更，\n再决定下一步。")
                            .font(.system(.title2, design: .serif).weight(.medium)).lineSpacing(5)
                        Text("读一份文件，审阅一处修改。\n所有操作都留在你的设备上。")
                            .font(.subheadline).lineSpacing(4).opacity(0.78)
                        Button {
                            if let sample = store.state.workspaces.first(where: \.isSample) { store.state.selectedWorkspace = sample.id }
                            if let id = store.createTask("完成第一次文件审阅", demo: true) { store.openTask(id) }
                        } label: { HStack { Text("体验文件审阅"); Spacer(); Image(systemName: "arrow.right") }.font(.subheadline.weight(.semibold)) }
                        .padding(.vertical, 13).padding(.horizontal, 17)
                        .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("start-demo")
                    }.padding(25).foregroundStyle(Color(red: 0.94, green: 0.96, blue: 0.90))
                        .background(Color(red: 0.18, green: 0.29, blue: 0.23), in: RoundedRectangle(cornerRadius: 26))
                }

                VStack(spacing: 15) {
                    RuneSectionTitle("随时开始", subtitle: store.workspace?.title)
                    quickAction("梳理项目", detail: "先了解，再动手", icon: "text.magnifyingglass", prompt: "了解这个项目，并整理一份简明说明。")
                    Divider().overlay(RunePalette.line)
                    quickAction("审阅改动", detail: "把决定留给自己", icon: "square.and.pencil", prompt: "审阅工作区里的文件，列出值得改进的地方。")
                    Divider().overlay(RunePalette.line)
                    Button { store.showInbox = true } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "tray").font(.title3).frame(width: 28)
                            VStack(alignment: .leading, spacing: 4) { Text("收件箱").font(.subheadline.weight(.medium)); Text("留住文件、链接和临时想法").font(.caption).foregroundStyle(RunePalette.secondary) }
                            Spacer(); Text("\(store.state.inbox.count)").font(.caption.monospacedDigit()); Image(systemName: "chevron.right").font(.caption2)
                        }.foregroundStyle(RunePalette.ink).padding(.vertical, 5)
                    }.accessibilityIdentifier("open-inbox")
                }
                if !store.visibleTasks.isEmpty {
                    VStack(spacing: 15) {
                        RuneSectionTitle("最近的协作")
                        ForEach(store.visibleTasks.prefix(3)) { task in TaskRow(task: task) }
                    }
                }
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield"); Text("本地工作区 · 每一步由你掌握")
                }.font(.caption2).foregroundStyle(RunePalette.secondary).frame(maxWidth: .infinity).padding(.bottom, 8)
            }.padding(.horizontal, 24).padding(.bottom, 18).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .background(RunePalette.canvas).navigationTitle("Rune").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { ComposerLauncher().padding(.horizontal, 20).padding(.bottom, 10) }
    }
    private func quickAction(_ title: String, detail: String, icon: String, prompt: String) -> some View {
        Button { store.compose(prompt) } label: {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline.weight(.medium)); Text(detail).font(.caption).foregroundStyle(RunePalette.secondary) }
                Spacer(); Image(systemName: "arrow.up.right").font(.caption)
            }.foregroundStyle(RunePalette.ink).padding(.vertical, 5)
        }
    }
}

struct ComposerLauncher: View {
    @EnvironmentObject private var store: StudioStore
    var body: some View {
        Button { store.compose() } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus").font(.title3)
                Text("想一起做点什么？").font(.subheadline).foregroundStyle(RunePalette.secondary)
                Spacer()
                Image(systemName: "arrow.up").font(.subheadline.weight(.semibold)).foregroundStyle(RunePalette.canvas)
                    .frame(width: 32, height: 32).background(RunePalette.accent, in: Circle())
            }.foregroundStyle(RunePalette.ink).padding(.horizontal, 18).padding(.vertical, 13).runeGlass(radius: 28)
        }.accessibilityIdentifier("new-task").accessibilityLabel("新建任务").keyboardShortcut("n", modifiers: .command)
    }
}

struct TaskRow: View {
    @EnvironmentObject private var store: StudioStore
    let task: StudioTask
    var body: some View {
        Button { store.openTask(task.id) } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: task.phase.symbol).font(.title3).foregroundStyle(task.phase == .approval ? RunePalette.amber : RunePalette.accent)
                    .frame(width: 24).padding(.top, 3)
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(task.title).font(.subheadline.weight(.medium)).lineLimit(2); if task.pinned { Image(systemName: "pin.fill").font(.caption2) } }
                    HStack(spacing: 8) { Text(store.workspaceName(task.workspaceID)); Text("·"); Text(task.phase.title); Spacer(); Text(task.createdAt, style: .date) }.font(.caption2).foregroundStyle(RunePalette.secondary)
                }
                Image(systemName: "chevron.right").font(.caption2).padding(.top, 6).foregroundStyle(RunePalette.secondary)
            }.foregroundStyle(RunePalette.ink).padding(.vertical, 12).contentShape(Rectangle())
        }
    }
}

struct ConversationsView: View {
    @EnvironmentObject private var store: StudioStore
    @State private var search = ""
    @State private var filter = "全部"
    @State private var rename: StudioTask?
    @State private var name = ""
    @State private var deleting: StudioTask?
    var tasks: [StudioTask] {
        store.state.tasks.filter { task in
            (filter == "已归档" ? task.archived : !task.archived)
            && (filter != "进行中" || task.phase.isActive)
            && (search.isEmpty || task.title.localizedCaseInsensitiveContains(search) || task.messages.contains { $0.text.localizedCaseInsensitiveContains(search) })
        }.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.createdAt > $1.createdAt }
    }
    var body: some View {
        List {
            Section {
                Picker("筛选", selection: $filter) { ForEach(["全部", "进行中", "已归档"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            if tasks.isEmpty {
                RuneEmptyState(search.isEmpty ? "每一次协作，都留在这里" : "没有匹配的会话", detail: search.isEmpty ? "创建一个任务，随时回来接着做。" : "试试其他关键词。", symbol: "bubble.left.and.bubble.right")
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(tasks) { task in
                TaskRow(task: task).listRowBackground(Color.clear)
                    .swipeActions(edge: .leading) { Button(task.pinned ? "取消置顶" : "置顶", systemImage: "pin") { store.updateTask(task.id) { $0.pinned.toggle() } }.tint(RunePalette.accent) }
                    .swipeActions { Button("归档", systemImage: "archivebox") { store.updateTask(task.id) { $0.archived.toggle() } }.tint(RunePalette.secondary) }
                    .contextMenu {
                        Button("重命名", systemImage: "pencil") { name = task.title; rename = task }
                        Button(task.pinned ? "取消置顶" : "置顶", systemImage: "pin") { store.updateTask(task.id) { $0.pinned.toggle() } }
                        Button(task.archived ? "移出归档" : "归档", systemImage: "archivebox") { store.updateTask(task.id) { $0.archived.toggle() } }
                        Button("删除会话", systemImage: "trash", role: .destructive) { deleting = task }
                    }
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(RunePalette.canvas)
            .navigationTitle("会话").searchable(text: $search, prompt: "搜索会话与内容")
            .safeAreaInset(edge: .bottom) { ComposerLauncher().padding(.horizontal, 20).padding(.bottom, 10) }
            .alert("重命名会话", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
                TextField("会话名称", text: $name)
                Button("取消", role: .cancel) { rename = nil }
                Button("保存") { if let rename, !name.trimmingCharacters(in: .whitespaces).isEmpty { store.updateTask(rename.id) { $0.title = name } }; rename = nil }
            }
            .confirmationDialog("删除这段会话？文件会保留。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除会话", role: .destructive) { if let deleting { store.cancel(deleting.id); store.state.tasks.removeAll { $0.id == deleting.id } }; deleting = nil }
            }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var store: StudioStore
    @State private var step = 0
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 38
    private let titles = ["你的工作台，\n随身而行。", "先有边界，\n再放心协作。", "选择模型，\n保留主动权。"]
    private let details = ["文件、想法和需要完成的事，\n在一个安静的地方归拢。", "文件只在授权的工作区内访问。\n每一次重要变更，都先交给你决定。", "使用自己的渠道与密钥。\n也可以先从本地文件演练开始。"]
    var body: some View {
        GeometryReader { geometry in ScrollView { content.frame(minHeight: geometry.size.height) } }
            .background(RunePalette.canvas)
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack { Text("Rune").font(.system(.title2, design: .serif).weight(.semibold)); Spacer(); Button("稍后设置") { store.state.onboarded = true }.font(.subheadline) }
            Spacer()
            RuneMark().frame(width: 65, height: 96).foregroundStyle(RunePalette.accent)
            Text(titles[step]).font(.system(size: titleSize, weight: .medium, design: .serif)).tracking(-1).lineSpacing(7)
            Text(details[step]).font(.body).lineSpacing(7).foregroundStyle(RunePalette.secondary)
            Spacer()
            HStack(spacing: 7) { ForEach(0..<3) { i in Capsule().fill(i == step ? RunePalette.accent : RunePalette.line).frame(width: i == step ? 24 : 7, height: 6) } }.accessibilityLabel("第 \(step + 1) 步，共 3 步")
            Button(step == 2 ? "进入工作台" : "继续") { if step == 2 { store.state.onboarded = true } else { step += 1 } }.buttonStyle(RunePrimaryStyle()).accessibilityIdentifier("onboarding-next")
            Text("你的文件，由你掌握。").font(.caption2).foregroundStyle(RunePalette.secondary).frame(maxWidth: .infinity)
        }.foregroundStyle(RunePalette.ink).padding(30).frame(maxWidth: 640).frame(maxWidth: .infinity).background(RunePalette.canvas)
    }
}
