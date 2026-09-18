import SwiftUI

struct KernelDiagnosticsView: View {
    @StateObject private var engine = RuneEngine()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    Button {
                        engine.runDemo()
                    } label: {
                        Label(engine.isRunning ? "正在跑…" : "在设备上跑一遍内核",
                              systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(engine.isRunning)

                    if let report = engine.report {
                        conclusion(report)
                        timeline(report)
                        files(report)
                    } else {
                        explainer
                    }
                }
                .padding()
            }
            .navigationTitle("Rune")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("完全在设备上运行的 Agent")
                .font(.headline)
            Text("这一版证明内核能在 iPhone 上构建、运行、真的改设备上的文件，并且事件日志是真的。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("点上面的按钮，它会：").font(.footnote).foregroundStyle(.secondary)
            ForEach([
                "列目录 → 读 notes.md → 改掉一行 → 复读确认",
                "每一步都走真正的 TurnRunner / 策略引擎 / 工具注册表",
                "文件是真的被改的（在 App 的 Documents/RuneDemo 下）",
                "把全过程写成事件日志，并校验哈希链",
            ], id: \.self) { line in
                Label(line, systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("（暂时没有联网：真的模型客户端要等 RuneNet 接上。跑完可以用「文件」App 打开 Documents/RuneDemo 看结果。）")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func conclusion(_ report: RunReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("结论").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            Text(report.finalText)
                .font(.body)
            HStack(spacing: 12) {
                Label("\(report.toolCalls) 次工具调用", systemImage: "wrench.and.screwdriver")
                Label(report.chainOK ? "链校验通过" : "链校验失败",
                      systemImage: report.chainOK ? "checkmark.seal" : "exclamationmark.triangle")
                    .foregroundStyle(report.chainOK ? .green : .red)
            }
            .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func timeline(_ report: RunReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("时间轴（来自事件日志）")
                .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            Text(report.statusText).font(.caption2).foregroundStyle(.tertiary)
            ForEach(Array(report.timeline.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(.secondary).frame(width: 5, height: 5).padding(.top, 6)
                    Text(line).font(.footnote)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func files(_ report: RunReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("工作区（磁盘上的真实内容）").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            if !report.workspacePath.isEmpty {
                Text(report.workspacePath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            ForEach(report.files.keys.sorted(), id: \.self) { path in
                VStack(alignment: .leading, spacing: 3) {
                    Label(path, systemImage: "doc.text").font(.footnote)
                    // ⚠️ 预览**必须直接可见**，不能只塞进折叠区里。
                    //    两个理由：
                    //      ① 产品上：这个面板的标题是「磁盘上的真实内容」，
                    //         而只有文件名的话它是名不副实的 —— 用户得展开才知道内容。
                    //      ② 测试上：折叠区里的文字**不在辅助功能树里**，
                    //         所以 UI 测试断言"被改的那一行出现在界面上"会永远失败
                    //         （模拟器冒烟测试最后一条断言就是卡在这里）。
                    Text(Self.preview(report.files[path] ?? ""))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                }
                DisclosureGroup {
                    Text(report.files[path] ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("展开全文（\(report.files[path]?.count ?? 0) 字符）", systemImage: "text.alignleft")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 4)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    /// 文件内容的一小段预览：短文件全给，长文件给前几行并说明被截断了。
    ///
    /// ⚠️ 短文件必须**整段**给出，不要"一律只给 3 行" ——
    ///    演示工作区里的文件本来就只有几行，截断会让"改掉的那一行"看不见，
    ///    于是面板看起来还是什么都没证明。
    static func preview(_ content: String, limit: Int = 600, lines: Int = 12) -> String {
        guard !content.isEmpty else { return "（空文件）" }
        if content.count <= limit { return content }
        let head = content.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(lines)
            .joined(separator: "\n")
        return head + "\n…（还有 \(content.count - head.count) 个字符，展开看全文）"
    }
}


