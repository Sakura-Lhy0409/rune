import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let context = extensionContext else { return }
        let view = UIHostingController(rootView: RuneShareView(context: context))
        addChild(view); self.view.addSubview(view.view)
        view.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            view.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            view.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            view.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        view.didMove(toParent: self)
    }
}

struct RuneShareView: View {
    let context: NSExtensionContext
    @State private var note = ""
    @State private var saving = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("先留住，之后再处理。", systemImage: "tray").font(.headline)
                    Text("内容会保存在本机，打开 Rune 后进入收件箱。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("补充一句") { TextField("可选备注", text: $note, axis: .vertical).lineLimit(3...6) }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }.navigationTitle("存入 Rune").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { context.cancelRequest(withError: CocoaError(.userCancelled)) } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { saving = true; Task { await save() } } label: { if saving { ProgressView() } else { Text("保存") } }.disabled(saving)
                    }
                }
                .tint(Color(red: 0.21, green: 0.35, blue: 0.28))
        }
    }
    @MainActor private func save() async {
        do {
            let directory = try RuneSharedInbox.directory()
            let items = context.inputItems.compactMap { $0 as? NSExtensionItem }
            var saved = false
            for provider in items.flatMap({ $0.attachments ?? [] }).prefix(5) {
                let id = UUID()
                let envelope: SharedInboxEnvelope
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    let filename = try await copyFileURL(provider, directory: directory)
                    envelope = .init(id: id, title: provider.suggestedName ?? "分享的文件", text: note, filename: filename, date: Date())
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    let text = try await loadText(provider, type: UTType.url.identifier)
                    envelope = .init(id: id, title: "分享的链接", text: text + (note.isEmpty ? "" : "\n" + note), date: Date())
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    let text = try await loadText(provider, type: UTType.plainText.identifier)
                    envelope = .init(id: id, title: String(text.prefix(32)), text: text + (note.isEmpty ? "" : "\n" + note), date: Date())
                } else if let type = provider.registeredTypeIdentifiers.first {
                    let filename = try await copyFile(provider, type: type, directory: directory)
                    envelope = .init(id: id, title: provider.suggestedName ?? "分享的文件", text: note, filename: filename, date: Date())
                } else { continue }
                try JSONEncoder().encode(envelope).write(to: directory.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
                saved = true
            }
            if !saved {
                let text = items.compactMap { $0.attributedContentText?.string }.joined(separator: "\n") + note
                guard !text.isEmpty else { throw CocoaError(.fileReadUnknown) }
                let envelope = SharedInboxEnvelope(id: UUID(), title: String(text.prefix(32)), text: text, date: Date())
                try JSONEncoder().encode(envelope).write(to: directory.appendingPathComponent(envelope.id.uuidString + ".json"), options: .atomic)
            }
            context.completeRequest(returningItems: [])
        } catch {
            failure = "未能存入收件箱。请确认 Rune 已安装并具有共享容器权限，再重试。\n\(error.localizedDescription)"
            saving = false
        }
    }
    private func loadText(_ provider: NSItemProvider, type: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else if let url = item as? URL { continuation.resume(returning: url.absoluteString) }
                else if let text = item as? String { continuation.resume(returning: String(text.prefix(100_000))) }
                else { continuation.resume(throwing: CocoaError(.fileReadCorruptFile)) }
            }
        }
    }
    // file-url 也是 url，必须先复制其内容，不能把临时本地路径当网页链接保存。
    private func copyFileURL(_ provider: NSItemProvider, directory: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                do {
                    if let error { throw error }
                    guard let url = item as? URL, url.isFileURL else { throw CocoaError(.fileReadCorruptFile) }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard properties.isRegularFile == true, (properties.fileSize ?? 0) <= 25_000_000 else { throw CocoaError(.fileReadTooLarge) }
                    let filename = UUID().uuidString + "-" + url.lastPathComponent
                    try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(filename))
                    continuation.resume(returning: filename)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func copyFile(_ provider: NSItemProvider, type: String, directory: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw CocoaError(.fileReadNoSuchFile) }
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 25_000_000 else { throw CocoaError(.fileReadTooLarge) }
                    let filename = UUID().uuidString + "-" + url.lastPathComponent
                    try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(filename))
                    continuation.resume(returning: filename)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
