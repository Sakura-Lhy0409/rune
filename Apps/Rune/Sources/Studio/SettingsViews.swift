import SwiftUI
import RuneUI
import ActivityKit

struct SettingsView: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 17) {
                        RuneMark().frame(width: 30, height: 43).foregroundStyle(RunePalette.accent)
                        VStack(alignment: .leading, spacing: 4) { Text("Rune").font(.system(.title2, design: .serif).weight(.semibold)); Text("一个随身的工作台").font(.caption).foregroundStyle(RunePalette.secondary) }
                        Spacer(); Text("0.2").font(.caption.monospaced()).foregroundStyle(RunePalette.secondary)
                    }.padding(.vertical, 10)
                }
                Section("协作") {
                    NavigationLink { ProvidersView() } label: { Label("渠道与模型", systemImage: "point.3.connected.trianglepath.dotted") }.accessibilityIdentifier("settings-providers")
                    NavigationLink { BudgetSettingsView() } label: { Label("预算与用量", systemImage: "chart.bar") }
                    NavigationLink { LiveActivitySettingsView() } label: { Label("灵动岛与实时活动", systemImage: "capsule") }.accessibilityIdentifier("settings-live")
                }
                Section("使用体验") {
                    Picker(selection: $store.state.appearance) { ForEach(RuneAppearance.allCases, id: \.self) { Text($0.title).tag($0) } } label: { Label("外观", systemImage: "circle.lefthalf.filled") }.accessibilityIdentifier("appearance-picker")
                    Toggle(isOn: $store.state.haptics) { Label("触感反馈", systemImage: "hand.tap") }
                }
                Section("数据与隐私") {
                    NavigationLink { AuditView() } label: { Label("操作记录", systemImage: "clock.arrow.circlepath") }
                    NavigationLink { PrivacyView() } label: { Label("本地数据与权限", systemImage: "lock.shield") }
                    Button { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: { Label("系统权限设置", systemImage: "gear") }
                }
                Section {
                    NavigationLink { AboutView() } label: { Label("关于 Rune", systemImage: "info.circle") }
                    NavigationLink { KernelDiagnosticsView() } label: { Label("运行诊断", systemImage: "stethoscope") }
                }
            }.scrollContentBackground(.hidden).background(RunePalette.canvas).navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("close-settings") } }
        }
    }
}

struct ProvidersView: View {
    @EnvironmentObject private var store: StudioStore
    @State private var editor: StudioProvider?
    @State private var deleting: StudioProvider?
    var body: some View {
        List {
            Section {
                Text("选择你信任的渠道。密钥只保存在本机钥匙串，模型由你决定。")
                    .font(.subheadline).foregroundStyle(RunePalette.secondary).listRowBackground(Color.clear)
            }
            ForEach(store.state.providers) { provider in
                Button { editor = provider } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "network").foregroundStyle(RunePalette.accent)
                        VStack(alignment: .leading, spacing: 5) { Text(provider.title).font(.headline).foregroundStyle(RunePalette.ink); Text(provider.model).font(.caption).foregroundStyle(RunePalette.secondary) }
                        Spacer()
                        if store.state.selectedProvider == provider.id { Text("默认").font(.caption2).foregroundStyle(RunePalette.accent) }
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(RunePalette.secondary)
                    }.padding(.vertical, 6)
                }.contextMenu {
                    Button("设为默认") { store.state.selectedProvider = provider.id }
                    Button("删除渠道", role: .destructive) { deleting = provider }
                }
            }
            if store.state.providers.isEmpty {
                RuneEmptyState("选一个合拍的模型", detail: "官方渠道、自定义服务，\n都可以从这里配置。", symbol: "network").listRowBackground(Color.clear)
            }
            Button("添加渠道", systemImage: "plus") { editor = StudioProvider() }.accessibilityIdentifier("add-provider")
        }.scrollContentBackground(.hidden).background(RunePalette.canvas).navigationTitle("渠道与模型")
            .sheet(item: $editor) { provider in ProviderEditor(provider: provider) }
            .confirmationDialog("删除此渠道和保存的密钥？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除渠道", role: .destructive) {
                    if let deleting { ProviderSecrets.remove(deleting.id); store.state.providers.removeAll { $0.id == deleting.id }; if store.state.selectedProvider == deleting.id { store.state.selectedProvider = store.state.providers.first?.id } }
                    deleting = nil
                }
            }
    }
}

struct ProviderEditor: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @State var provider: StudioProvider
    @State private var secret = ""
    @State private var testing = false
    @State private var result: String?
    @State private var error: String?
    @State private var testTask: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section("渠道") {
                    TextField("名称", text: $provider.title).accessibilityIdentifier("provider-name")
                    Picker("协议", selection: $provider.protocolName) { ForEach(["OpenAI 兼容", "OpenAI Responses", "Anthropic", "Gemini"], id: \.self) { Text($0) } }
                    TextField("HTTPS Base URL", text: $provider.baseURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("provider-url")
                    TextField("模型 ID", text: $provider.model).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("provider-model")
                }
                Section {
                    Toggle("允许局域网服务", isOn: Binding(get: { provider.allowPrivateNetwork == true }, set: { provider.allowPrivateNetwork = $0 }))
                } footer: { Text("仅在你信任的内网使用。明文 HTTP 只允许本地地址，公网仍需 HTTPS。发送内容对所选服务可见。") }
                Section {
                    SecureField(ProviderSecrets.read(provider.id) == nil ? "API Key（可选）" : "已保存密钥，输入以替换", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().accessibilityIdentifier("provider-key")
                } header: { Text("密钥") } footer: { Text("保存在本机钥匙串，不写入会话、文件或导出内容。") }
                Section {
                    Button {
                        if testing { testTask?.cancel(); testing = false; return }
                        testing = true; result = nil; error = nil
                        testTask = Task {
                            do { result = try await store.testProvider(provider, secret: secret) }
                            catch { if !Task.isCancelled { self.error = String(describing: error) } }
                            testing = false
                        }
                    } label: { HStack { Text(testing ? "取消测试" : "测试连接"); Spacer(); if testing { ProgressView() } else { Image(systemName: "arrow.triangle.2.circlepath") } } }.disabled(!provider.isValid)
                    if let result { Label(result, systemImage: "checkmark.circle").font(.caption).foregroundStyle(RunePalette.accent) }
                    if let error { Text(error).font(.caption).foregroundStyle(RunePalette.amber) }
                } footer: { Text("只请求模型列表，不发送会话内容，不调用付费生成。部分服务不提供列表接口。") }
                Section {
                    TextField("输入价格 / 百万 token（USD）", value: $provider.inputPricePerMillion, format: .number).keyboardType(.decimalPad)
                    TextField("输出价格 / 百万 token（USD）", value: $provider.outputPricePerMillion, format: .number).keyboardType(.decimalPad)
                } header: { Text("报价（可选）") } footer: { Text("请填写渠道实际报价。未填写时仅显示用量，不能声称费用为零；预算按每个任务估算，渠道账单为准。") }
                Section("快速填写") {
                    Button("OpenAI") { provider.title = "OpenAI"; provider.protocolName = "OpenAI Responses"; provider.baseURL = "https://api.openai.com/v1" }
                    Button("Anthropic") { provider.title = "Anthropic"; provider.protocolName = "Anthropic"; provider.baseURL = "https://api.anthropic.com/v1" }
                    Button("Gemini") { provider.title = "Gemini"; provider.protocolName = "Gemini"; provider.baseURL = "https://generativelanguage.googleapis.com/v1beta" }
                    Button("自定义渠道") { provider.title = "我的渠道"; provider.protocolName = "OpenAI 兼容"; provider.baseURL = "" }
                }
            }.scrollContentBackground(.hidden).background(RunePalette.canvas).navigationTitle("配置渠道").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { do { try store.saveProvider(provider, secret: secret); dismiss() } catch { self.error = error.localizedDescription } }.disabled(!provider.isValid).accessibilityIdentifier("save-provider") }
                }
                .onDisappear { testTask?.cancel() }
        }
    }
}

struct BudgetSettingsView: View {
    @EnvironmentObject private var store: StudioStore
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) { Text("本机记录的模型用量").font(.caption).foregroundStyle(RunePalette.secondary); Text(String(format: "$%.4f", Double(store.state.tasks.reduce(0) { $0 + ($1.costMicroUSD ?? 0) }) / 1_000_000)).font(.system(size: 42, weight: .light, design: .rounded)); Text("仅汇总配置了报价的任务估算值").font(.subheadline).foregroundStyle(RunePalette.secondary) }.padding(.vertical, 12)
            }
            Section {
                Stepper(value: $store.state.dailyBudget, in: 0.5...100, step: 0.5) { VStack(alignment: .leading, spacing: 5) { Text("每个任务预算"); Text(store.state.dailyBudget, format: .currency(code: "USD")).font(.title3.monospacedDigit()).foregroundStyle(RunePalette.accent) } }
            } footer: { Text("新任务采用此上限，已运行任务保留原预算。未填写渠道报价时无法计算金额，但仍有 8 轮/32 次工具调用上限。中断请求的费用以渠道账单为准。") }
        }.scrollContentBackground(.hidden).background(RunePalette.canvas).navigationTitle("预算与用量")
    }
}

struct LiveActivitySettingsView: View {
    @EnvironmentObject private var store: StudioStore
    @State private var style = "展开"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                Text("不用一直盯着，\n也知道做到哪了。")
                    .font(.system(.title, design: .serif)).foregroundStyle(RunePalette.ink).lineSpacing(5)
                Picker("布局", selection: $style) { ForEach(["展开", "紧凑", "锁屏"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                VStack(spacing: 18) {
                    if style == "紧凑" {
                        HStack(spacing: 50) { RuneMark().frame(width: 16, height: 24); Image(systemName: "hand.raised.fill").font(.caption) }.padding(.horizontal, 24).padding(.vertical, 14).background(.black, in: Capsule())
                    } else {
                        VStack(alignment: .leading, spacing: 15) {
                            HStack { RuneMark().frame(width: 18, height: 27); Text("Rune").font(.system(.subheadline, design: .serif)); Spacer(); Text("等你确认").font(.caption).foregroundStyle(Color(red: 0.91, green: 0.74, blue: 0.47)) }
                            Text("完成第一次文件审阅").font(.headline)
                            HStack { Text("一处变更，待你审阅").font(.caption); Spacer(); Text("3 / 4").font(.caption.monospacedDigit()) }.foregroundStyle(.white.opacity(0.65))
                            ProgressView(value: 0.75).tint(Color(red: 0.72, green: 0.83, blue: 0.67))
                        }.padding(23).background(.black, in: RoundedRectangle(cornerRadius: style == "锁屏" ? 24 : 38))
                    }
                    Text("布局预览").font(.caption2).foregroundStyle(RunePalette.secondary)
                }.foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 10)
                Toggle("显示实时活动", isOn: $store.state.liveActivities).font(.headline)
                    .onChange(of: store.state.liveActivities) { _, enabled in
                        if enabled { for task in store.activeTasks { store.beginActivity(task) } } else { store.stopActivities() }
                    }
                Text("任务进度、暂停与待审批状态会同步到锁屏和灵动岛。轻点打开任务；展开后可以进入审阅或暂停、继续。")
                    .font(.subheadline).foregroundStyle(RunePalette.secondary).lineSpacing(5)
                Label(ActivityAuthorizationInfo().areActivitiesEnabled ? "系统已允许实时活动" : "系统暂未允许实时活动", systemImage: ActivityAuthorizationInfo().areActivitiesEnabled ? "checkmark.circle" : "info.circle")
                    .font(.caption).foregroundStyle(RunePalette.secondary)
                Text("实时活动用于显示状态，不会让任务获得无限后台运行时间。")
                    .font(.caption).foregroundStyle(RunePalette.secondary)
            }.padding(24).frame(maxWidth: 650).frame(maxWidth: .infinity)
        }.background(RunePalette.canvas).navigationTitle("灵动岛与实时活动").navigationBarTitleDisplayMode(.inline)
    }
}
struct PrivacyView: View {
    var body: some View {
        List {
            Section("文件") { Text("工作区只包含应用自己的目录，以及你在文件选择器中明确授权的目录。文件修改和删除会记录在操作记录里。") }
            Section("模型密钥") { Text("密钥单独存入设备钥匙串，仅在测试渠道连接时使用。会话和配置导出不包含密钥。") }
            Section("语音与照片") { Text("仅在你点击时请求系统权限。语音输入要求本机离线识别可用；不自动上传录音。照片只读取你选中的项目。") }
            Section("当前版本") { Text("本地文件浏览、编辑、审阅与撤销可用。自定义任务经你点击开始后才发送到所选模型；读取的文件内容可能随上下文发出。实时活动显示实际运行状态。") }
        }.scrollContentBackground(.hidden).background(RunePalette.canvas).navigationTitle("本地数据与权限")
    }
}
struct AboutView: View {
    var body: some View {
        VStack(spacing: 22) {
            Spacer(); RuneMark().frame(width: 58, height: 84).foregroundStyle(RunePalette.accent)
            Text("Rune").font(.system(size: 46, weight: .regular, design: .serif))
            Text("刻在你手机里的智能体。").font(.subheadline).foregroundStyle(RunePalette.secondary)
            Text("为 iPhone 与 iPad 设计。\n让文件、想法和行动，在同一个地方发生。")
                .font(.body).lineSpacing(6).multilineTextAlignment(.center).foregroundStyle(RunePalette.secondary)
            Spacer(); Text("版本 0.2 · 运行时预览").font(.caption2).foregroundStyle(RunePalette.secondary)
        }.padding(30).frame(maxWidth: .infinity).background(RunePalette.canvas).navigationTitle("关于")
    }
}
