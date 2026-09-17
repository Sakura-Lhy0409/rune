import SwiftUI

// MARK: - App 入口

@main
struct RuneApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

// MARK: - 根视图
//
// ⚠️ 这一版 UI 刻意做得**极简**：一个按钮、一段结论、一条时间轴、一个文件清单。
//
// 理由不是偷懒，是顺序：在没有 Mac 的环境里（docs/16），
// 第一次推到手机上的版本要能回答**一个**问题 —— **"这条链路通了没有"**。
// 花哨的界面会把这个问题埋掉。等确认能装、能跑、事件日志是真的，
// 再去实现 docs/08 里那套交互（时间轴、审批卡片、Diff 视图、Live Activity）。

struct RootView: View {
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
                DisclosureGroup {
                    Text(report.files[path] ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label(path, systemImage: "doc.text")
                        .font(.footnote)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}


