import SwiftUI
import RuneUI
import UniformTypeIdentifiers

struct WorkbenchView: View {
    @EnvironmentObject private var store: StudioStore
    @State private var importer = false
    @State private var workspaceSheet = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Button { workspaceSheet = true } label: {
                    HStack(spacing: 17) {
                        Image(systemName: "folder").font(.system(size: 30, weight: .light)).frame(width: 60, height: 60).background(RunePalette.paper, in: RoundedRectangle(cornerRadius: 18))
                        VStack(alignment: .leading, spacing: 6) { Text(store.workspace?.title ?? "选择工作区").font(.title2.weight(.semibold)); Text(store.workspace?.isSample == true ? "示例工作区 · 保存在本机" : "已授权的文件夹").font(.caption).foregroundStyle(RunePalette.secondary) }
                        Spacer(); Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }.foregroundStyle(RunePalette.ink).padding(20).runeSurface()
                }.accessibilityIdentifier("choose-workspace")
                VStack(alignment: .leading, spacing: 8) {
                    RuneSectionTitle("工作区", subtitle: "文件与上下文")
                    if let workspace = store.workspace {
                        NavigationLink { FileBrowserView(workspaceID: workspace.id) } label: { BenchRow("文件", detail: "浏览、编辑与分享", icon: "doc.on.doc") }.accessibilityIdentifier("open-files")
                    }
                    NavigationLink { NotesLibraryView(category: "记忆") } label: { BenchRow("项目笔记", detail: "值得留住的背景与决定", icon: "text.book.closed") }
                    NavigationLink { GoalsView() } label: { BenchRow("目标与清单", detail: "把大事拆成具体的小步", icon: "flag") }.accessibilityIdentifier("open-goals")
                    NavigationLink { AuditView() } label: { BenchRow("操作记录", detail: "查看本机发生过的事", icon: "clock.arrow.circlepath") }.accessibilityIdentifier("open-audit")
                }
                VStack(alignment: .leading, spacing: 8) {
                    RuneSectionTitle("Runebook", subtitle: "把好方法留住")
                    NavigationLink { NotesLibraryView(category: "技能") } label: { BenchRow("技能", detail: "可复用的协作方式", icon: "square.stack") }.accessibilityIdentifier("open-skills")
                    NavigationLink { NotesLibraryView(category: "工作流") } label: { BenchRow("工作流", detail: "把步骤安排好", icon: "point.3.connected.trianglepath.dotted") }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Label("文件留在这里", systemImage: "externaldrive").font(.subheadline.weight(.medium))
                    Text("只有你选择的目录会成为工作区。随时移除授权，不会删除原文件。")
                        .font(.subheadline).foregroundStyle(RunePalette.secondary).lineSpacing(4)
                    Button("添加文件夹", systemImage: "folder.badge.plus") { importer = true }.font(.subheadline.weight(.medium))
                }.padding(22).background(RunePalette.paper, in: RoundedRectangle(cornerRadius: 22))
            }.padding(24).frame(maxWidth: 800).frame(maxWidth: .infinity)
        }.background(RunePalette.canvas).navigationTitle("工作台")
            .fileImporter(isPresented: $importer, allowedContentTypes: [.folder]) { result in do { store.addWorkspace(try result.get()) } catch { store.report(error) } }
            .sheet(isPresented: $workspaceSheet) { WorkspaceSheet() }
    }
}
struct BenchRow: View {
    let title: String, detail: String, icon: String
    init(_ title: String, detail: String, icon: String) { self.title = title; self.detail = detail; self.icon = icon }
    var body: some View {
        HStack(spacing: 17) {
            Image(systemName: icon).font(.title3).foregroundStyle(RunePalette.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline.weight(.medium)).foregroundStyle(RunePalette.ink); Text(detail).font(.caption).foregroundStyle(RunePalette.secondary) }
            Spacer(); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(RunePalette.secondary)
        }.padding(.vertical, 17).contentShape(Rectangle())
    }
}

struct WorkspaceSheet: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var importer = false
    @State private var removing: StudioWorkspace?
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.state.workspaces) { workspace in
                    Button { store.state.selectedWorkspace = workspace.id; dismiss() } label: {
                        HStack { Label(workspace.title, systemImage: "folder"); Spacer(); if store.workspace?.id == workspace.id { Image(systemName: "checkmark") } }
                    }.swipeActions { if !workspace.isSample { Button("移除授权", role: .destructive) { removing = workspace } } }
                }
                Button("添加文件夹", systemImage: "folder.badge.plus") { importer = true }
            }.scrollContentBackground(.hidden).background(RunePalette.canvas).navigationTitle("工作区").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
                .fileImporter(isPresented: $importer, allowedContentTypes: [.folder]) { result in do { store.addWorkspace(try result.get()) } catch { store.report(error) } }
                .confirmationDialog("移除对此目录的访问？磁盘文件不会删除。", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                    Button("移除授权", role: .destructive) { if let removing { store.state.workspaces.removeAll { $0.id == removing.id }; if store.state.selectedWorkspace == removing.id { store.state.selectedWorkspace = store.state.workspaces.first?.id } }; removing = nil }
                }
        }.presentationDetents([.medium, .large])
    }
}

struct FileBrowserView: View {
    @EnvironmentObject private var store: StudioStore
    let workspaceID: UUID
    var folder = ""
    @State private var files: [StudioFile] = []
    @State private var search = ""
    @State private var create = false
    @State private var filename = ""
    @State private var deleting: StudioFile?
    @State private var renaming: StudioFile?
    @State private var newName = ""
    @State private var loadError: String?
    var body: some View {
        List {
            if let loadError { Text(loadError).foregroundStyle(RunePalette.amber) }
            if files.isEmpty && loadError == nil { RuneEmptyState("给这个目录添点内容", detail: "新建一个文件，记录你的想法。", symbol: "folder").listRowBackground(Color.clear) }
            ForEach(files.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { file in
                NavigationLink {
                    if file.isDirectory { FileBrowserView(workspaceID: workspaceID, folder: file.path) }
                    else { FileDetailView(workspaceID: workspaceID, path: file.path) }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: file.symbol).foregroundStyle(RunePalette.accent).frame(width: 26)
                        VStack(alignment: .leading, spacing: 5) { Text(file.name); Text(file.isDirectory ? "文件夹" : ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).font(.caption).foregroundStyle(RunePalette.secondary) }
                    }.padding(.vertical, 5)
                }.accessibilityIdentifier("file-" + file.path)
                    .contextMenu { Button("重命名", systemImage: "pencil") { newName = file.name; renaming = file }; Button("删除", systemImage: "trash", role: .destructive) { deleting = file } }
                    .swipeActions { Button("删除", role: .destructive) { deleting = file } }
            }
        }.scrollContentBackground(.hidden).background(RunePalette.canvas)
            .navigationTitle(folder.isEmpty ? "文件" : (folder as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "搜索此目录")
            .toolbar { Button("新建文件", systemImage: "doc.badge.plus") { filename = ""; create = true }.accessibilityIdentifier("create-file") }
            .onAppear(perform: reload).onChange(of: store.fileRevision) { _, _ in reload() }
            .alert("新建文件", isPresented: $create) {
                TextField("文件名，例如 ideas.md", text: $filename).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("取消", role: .cancel) { }
                Button("创建") { do { try store.createFile(workspaceID, name: filename, folder: folder); reload() } catch { store.report(error) } }
            }
            .alert("重命名文件", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("新名称", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") { if let renaming { do { try store.renameFile(workspaceID, path: renaming.path, name: newName); reload() } catch { store.report(error) } }; renaming = nil }
            }
            .confirmationDialog("删除 \(deleting?.name ?? "此文件")？此操作不能撤销。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除文件", role: .destructive) { if let deleting { do { try store.deleteFile(workspaceID, path: deleting.path); reload() } catch { store.report(error) } }; deleting = nil }
            }
    }
    private func reload() {
        do { files = try store.files(workspaceID, path: folder); loadError = nil }
        catch { loadError = error.localizedDescription }
    }
}

struct FileDetailView: View {
    @EnvironmentObject private var store: StudioStore
    let workspaceID: UUID
    let path: String
    @State private var text = ""
    @State private var original = ""
    @State private var editing = false
    @State private var preview = true
    @State private var loadError: String?
    @State private var export: FileSharePayload?
    @State private var discard = false
    var body: some View {
        Group {
            if let loadError { ContentUnavailableView("无法预览此文件", systemImage: "doc", description: Text(loadError)) }
            else if editing { TextEditor(text: $text).font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden).padding(12).accessibilityIdentifier("file-editor") }
            else {
                ScrollView([.vertical]) {
                    Group {
                        if preview && path.hasSuffix(".md") { Text(LocalizedStringKey(text)).font(.body).lineSpacing(7) }
                        else { Text(text.isEmpty ? "空文件" : text).font(.system(.subheadline, design: .monospaced)).lineSpacing(5) }
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(24).accessibilityIdentifier("file-content")
                }
            }
        }.background(RunePalette.canvas).navigationTitle((path as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(editing)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if editing {
                        Button("取消") { if text != original { discard = true } else { editing = false } }
                        Button("保存") { save() }.fontWeight(.semibold).accessibilityIdentifier("save-file")
                    } else {
                        Button("编辑", systemImage: "pencil") { editing = true }.disabled(loadError != nil).accessibilityIdentifier("edit-file")
                        Menu {
                            Button(preview ? "查看原文" : "预览 Markdown", systemImage: "doc.plaintext") { preview.toggle() }
                            Button("复制内容", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                            Button("分享文件", systemImage: "square.and.arrow.up") { do { export = .init(url: try store.shareFile(workspaceID, path: path)) } catch { store.report(error) } }.accessibilityIdentifier("share-file")
                        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("文件操作")
                    }
                }
            }
            .onAppear { load() }
            .sheet(item: $export) { payload in FileShareController(url: payload.url) }
            .confirmationDialog("放弃尚未保存的修改？", isPresented: $discard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { text = original; editing = false }
            }
    }
    private func load() {
        do { text = try store.readFile(workspaceID, path: path); original = text }
        catch { loadError = error.localizedDescription }
    }
    private func save() {
        do {
            guard try store.readFile(workspaceID, path: path) == original else { throw StudioFailure("文件已被其他操作修改。请退出编辑后重新打开，再合并修改。") }
            try store.writeFile(workspaceID, path: path, text: text)
            original = text; editing = false
        } catch { store.report(error) }
    }
}

struct NotesLibraryView: View {
    @EnvironmentObject private var store: StudioStore
    let category: String
    @State private var search = ""
    @State private var editor: StudioNote?
    var body: some View {
        List {
            Section {
                Text(category == "工作流" ? "用清晰的步骤组织任务。当前保存为任务模板，尚未自动执行。" : category == "记忆" ? "留住项目背景。笔记保存在本机，尚未自动注入模型上下文。" : "把可靠的方法写下来，下次直接作为任务的起点。")
                    .font(.subheadline).foregroundStyle(RunePalette.secondary).listRowBackground(Color.clear)
            }
            ForEach(store.state.notes.filter { $0.category == category && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }) { note in
                Button { editor = note } label: {
                    VStack(alignment: .leading, spacing: 8) { Text(note.title).font(.headline).foregroundStyle(RunePalette.ink); Text(note.body).font(.subheadline).foregroundStyle(RunePalette.secondary).lineLimit(2) }.padding(.vertical, 8)
                }.swipeActions { Button("删除", role: .destructive) { store.state.notes.removeAll { $0.id == note.id } } }
            }
            if !store.state.notes.contains(where: { $0.category == category }) {
                RuneEmptyState("留下第一条\(category == "记忆" ? "笔记" : category)", detail: "从一句清晰的说明开始。", symbol: "text.book.closed").listRowBackground(Color.clear)
            }
        }.scrollContentBackground(.hidden).background(RunePalette.canvas).navigationTitle(category == "记忆" ? "项目笔记" : category)
            .searchable(text: $search, prompt: "搜索")
            .toolbar { Button("新建", systemImage: "plus") { editor = .init(title: "", body: "", category: category) }.accessibilityIdentifier("new-note") }
            .sheet(item: $editor) { note in NoteEditor(note: note) }
    }
}
struct NoteEditor: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @State var note: StudioNote
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                TextField("标题", text: $note.title).font(.title2.weight(.semibold)).accessibilityIdentifier("note-title")
                TextEditor(text: $note.body).font(.body).scrollContentBackground(.hidden).accessibilityIdentifier("note-body")
                if note.category != "记忆" {
                    Button("用它创建任务", systemImage: "arrow.up.right") { save(); dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { store.compose(note.body) } }.disabled(note.body.isEmpty)
                }
            }.padding(24).background(RunePalette.canvas).navigationTitle(note.category == "记忆" ? "项目笔记" : note.category).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { save(); dismiss() }.disabled(note.title.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("save-note") }
                }
        }
    }
    private func save() {
        if let i = store.state.notes.firstIndex(where: { $0.id == note.id }) { store.state.notes[i] = note }
        else { store.state.notes.append(note) }
    }
}

struct InboxView: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var text = ""
    @State private var importer = false
    var body: some View {
        List {
            if store.state.inbox.isEmpty {
                RuneEmptyState("先放在这里", detail: "文件、链接、突然冒出的想法。\n有空的时候，再把它交给一个任务。", symbol: "tray").listRowBackground(Color.clear)
            }
            ForEach(store.state.inbox) { item in
                VStack(alignment: .leading, spacing: 10) {
                    Label(item.title, systemImage: item.filename == nil ? "text.alignleft" : "doc").font(.headline)
                    Text(item.body).font(.subheadline).foregroundStyle(RunePalette.secondary).lineLimit(3)
                    HStack { Text(item.date, style: .relative).font(.caption2).foregroundStyle(RunePalette.secondary); Spacer(); Button("指派任务", systemImage: "arrow.up.right") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { store.compose(item.filename == nil ? item.body : "处理收件箱中的文件：\(item.title)") } }.font(.caption.weight(.medium)) }
                }.padding(.vertical, 8).swipeActions { Button("移除", role: .destructive) { store.state.inbox.removeAll { $0.id == item.id } } }
            }
        }.scrollContentBackground(.hidden).background(RunePalette.canvas).navigationTitle("收件箱").navigationBarTitleDisplayMode(.inline)
            .onAppear { store.consumeSharedInbox() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Menu { Button("记一条想法", systemImage: "square.and.pencil") { text = ""; adding = true }; Button("导入文件", systemImage: "doc.badge.plus") { importer = true } } label: { Image(systemName: "plus") }.accessibilityIdentifier("add-inbox") }
            }
            .alert("记一条想法", isPresented: $adding) {
                TextField("文字或链接", text: $text)
                Button("取消", role: .cancel) { }
                Button("保存") { if !text.trimmingCharacters(in: .whitespaces).isEmpty { store.state.inbox.insert(.init(title: String(text.prefix(32)), body: text), at: 0) } }
            }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                do { for url in try result.get() { _ = try store.importFile(url) } } catch { store.report(error) }
            }
    }
}

struct AuditView: View {
    @EnvironmentObject private var store: StudioStore
    @State private var search = ""
    var body: some View {
        List {
            if store.state.audit.isEmpty { RuneEmptyState("每一步，都有记录", detail: "文件操作和界面授权会显示在这里。", symbol: "clock.arrow.circlepath").listRowBackground(Color.clear) }
            ForEach(store.state.audit.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search) }) { event in
                VStack(alignment: .leading, spacing: 7) { HStack { Text(event.title).font(.subheadline.weight(.medium)); Spacer(); Text(event.date, style: .time).font(.caption2) }; Text(event.detail).font(.caption).foregroundStyle(RunePalette.secondary).textSelection(.enabled) }.padding(.vertical, 5)
            }
        }.scrollContentBackground(.hidden).background(RunePalette.canvas).navigationTitle("操作记录")
            .searchable(text: $search, prompt: "搜索操作与文件")
            .toolbar { ShareLink(item: store.state.audit.map { "\($0.date.formatted())\t\($0.title)\t\($0.detail)" }.joined(separator: "\n")) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("导出操作记录") }
    }
}

struct FileSharePayload: Identifiable { let id = UUID(); let url: URL }
struct FileShareController: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
