import SwiftUI
import RuneUI
import PhotosUI
import UniformTypeIdentifiers
import Speech
import AVFoundation

struct NewTaskSheet: View {
    @EnvironmentObject private var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var demo = false
    @State private var importer = false
    @State private var photo: PhotosPickerItem?
    @State private var camera = false
    @State private var attachments: [String] = []
    @StateObject private var speech = SpeechInput()
    @FocusState private var focused: Bool
    init(seed: String) { _text = State(initialValue: seed) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack { Label(store.workspace?.title ?? "选择工作区", systemImage: "folder"); Spacer(); Text("新任务").foregroundStyle(RunePalette.secondary) }.font(.caption)
                    TextField("说说你想完成的事…", text: $text, axis: .vertical)
                        .font(.title3).lineLimit(5...10).focused($focused).accessibilityIdentifier("task-prompt")
                    HStack(spacing: 18) {
                        Button("添加文件", systemImage: "paperclip") { importer = true }.labelStyle(.iconOnly)
                        Button("拍照", systemImage: "camera") { camera = true }.labelStyle(.iconOnly)
                            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                        PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "photo") }.accessibilityLabel("添加照片")
                        Button(speech.isRecording ? "停止录音" : "语音输入", systemImage: speech.isRecording ? "stop.circle.fill" : "mic") {
                            if speech.isRecording { speech.stop() }
                            else { Task { await speech.start() } }
                        }.labelStyle(.iconOnly).disabled(speech.isStarting)
                        Spacer()
                        if speech.isRecording { Text("正在聆听…").font(.caption).foregroundStyle(RunePalette.amber) }
                    }.font(.title3).padding(.vertical, 10)
                    if !speech.transcript.isEmpty && speech.isRecording { Text(speech.transcript).font(.subheadline).foregroundStyle(RunePalette.secondary) }
                    if let error = speech.error { Text(error).font(.caption).foregroundStyle(RunePalette.amber) }
                    ForEach(attachments, id: \.self) { name in
                        HStack { Label(name, systemImage: "doc").lineLimit(1); Spacer(); Button("移除附件", systemImage: "xmark.circle.fill") { attachments.removeAll { $0 == name } }.labelStyle(.iconOnly) }.font(.caption).padding(12).background(RunePalette.paper, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 15) {
                        Text("从一个小目标开始").font(.caption).foregroundStyle(RunePalette.secondary)
                        ForEach(["梳理这个项目的结构", "帮我整理今天的记录", "审阅一份文件的变更"], id: \.self) { prompt in
                            Button { text = prompt } label: { HStack { Text(prompt); Spacer(); Image(systemName: "arrow.up.left").font(.caption) }.font(.subheadline) }.foregroundStyle(RunePalette.ink)
                        }
                    }
                    if store.workspace?.isSample == true {
                        Toggle("使用示例文件演练", isOn: $demo).font(.subheadline).accessibilityIdentifier("demo-toggle")
                        Text(demo ? "在 notes.md 上完成准备、审阅、应用和撤销，不调用模型。" : "任务先保存在本机；进入会话确认后，会调用你选择的渠道处理。")
                            .font(.caption).foregroundStyle(RunePalette.secondary)
                    }
                }.padding(24)
            }.background(RunePalette.canvas)
                .navigationTitle("一起做点什么").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    Button { submit() } label: { HStack { Text(demo ? "开始演练" : "保存任务"); Image(systemName: "arrow.up") } }
                        .buttonStyle(RunePrimaryStyle()).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("submit-task").padding(20).background(RunePalette.canvas)
                }
                .fileImporter(isPresented: $importer, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                    do { for url in try result.get() { attachments.append(try store.importFile(url).title) } } catch { store.report(error) }
                }
                .fullScreenCover(isPresented: $camera) {
                    CameraCapture { image in
                        camera = false
                        guard let data = image?.jpegData(compressionQuality: 0.9) else { return }
                        do {
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("拍摄-\(UUID().uuidString.prefix(6)).jpg")
                            try data.write(to: url); attachments.append(try store.importFile(url).title)
                        } catch { store.report(error) }
                    }.ignoresSafeArea()
                }
                .onChange(of: photo) { _, photo in
                    Task {
                        do {
                            guard let data = try await photo?.loadTransferable(type: Data.self), data.count <= 25_000_000 else { return }
                            let suffix = photo?.supportedContentTypes.first?.preferredFilenameExtension ?? "img"
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("照片-\(UUID().uuidString.prefix(6)).\(suffix)")
                            try data.write(to: url)
                            attachments.append(try store.importFile(url).title)
                        } catch { store.report(error) }
                    }
                }
                .onChange(of: speech.isRecording) { wasRecording, recording in
                    if wasRecording && !recording && !speech.transcript.isEmpty { text += speech.transcript; speech.transcript = "" }
                }
                .onDisappear { speech.stop() }
        }
    }
    private func submit() {
        if speech.isRecording { text += speech.transcript; speech.transcript = "" }
        speech.stop()
        guard let id = store.createTask(text, demo: demo, attachments: attachments) else { return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { store.openTask(id) }
    }
}

@MainActor
final class SpeechInput: ObservableObject {
    @Published var isRecording = false
    @Published var isStarting = false
    private var generation = UUID()
    @Published var transcript = ""
    @Published var error: String?
    private var engine: AVAudioEngine?
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func start() async {
        guard !isStarting, !isRecording else { return }
        isStarting = true
        defer { isStarting = false }
        let current = UUID(); generation = current
        error = nil; transcript = ""
        let permission = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        guard generation == current else { return }
        guard permission == .authorized else { error = "请在系统设置中允许语音识别，也可以直接输入文字。"; return }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard generation == current else { return }
        guard microphone else { error = "请在系统设置中允许麦克风。"; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { error = "本机离线语音识别暂不可用，请使用键盘输入。"; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true)
            let engine = AVAudioEngine(), request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
            self.engine = engine; self.request = request
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let complete = result?.isFinal == true || error != nil
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    if let text { self.transcript = text }
                    if complete { self.stop() }
                }
            }
            engine.prepare(); try engine.start(); isRecording = true
        } catch { self.error = "暂时无法开始录音：\(error.localizedDescription)"; stop() }
    }
    func stop() {
        generation = UUID()
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio(); recognition?.cancel()
        engine = nil; request = nil; recognition = nil; isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
