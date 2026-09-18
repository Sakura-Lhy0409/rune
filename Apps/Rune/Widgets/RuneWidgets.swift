import SwiftUI
import WidgetKit
import ActivityKit
import RuneUI

@main
struct RuneWidgets: WidgetBundle {
    var body: some Widget { RuneLiveActivity(); RuneQuickWidget() }
}

struct RuneLiveActivity: Widget {
    private let green = Color(red: 0.72, green: 0.83, blue: 0.67)
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RuneActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    HStack(spacing: 7) { RuneMark().frame(width: 14, height: 22); Text("Rune").font(.system(.subheadline, design: .serif).weight(.semibold)) }
                    Spacer(); Text(context.isStale ? "等待更新" : context.state.requiresApproval ? "等你确认" : phaseTitle(context.state.phase)).font(.caption).foregroundStyle(context.state.requiresApproval ? .orange : green)
                }
                Text(context.state.title).font(.headline).lineLimit(1)
                HStack { Text(context.isStale ? "打开 Rune 查看任务状态" : context.state.detail).font(.caption).lineLimit(1); Spacer(); Text(context.attributes.workspace).font(.caption2) }.foregroundStyle(.white.opacity(0.7))
                ProgressView(value: context.state.progress).tint(green)
                controls(context)
            }.padding(18).foregroundStyle(.white)
                .activityBackgroundTint(Color(red: 0.09, green: 0.13, blue: 0.10))
                .activitySystemActionForegroundColor(green)
                .widgetURL(taskURL(context.attributes.taskID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { HStack(spacing: 7) { RuneMark().frame(width: 13, height: 21); Text("Rune").font(.caption.weight(.semibold)) }.foregroundStyle(green) }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.requiresApproval { Image(systemName: "hand.raised.fill").foregroundStyle(.orange) }
                    else { Text("\(Int(context.state.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(green) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        Text(context.isStale ? "打开 Rune 查看任务状态" : context.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        ProgressView(value: context.state.progress).tint(green)
                        controls(context)
                    }.padding(.top, 4)
                }
            } compactLeading: {
                RuneMark().frame(width: 13, height: 22).foregroundStyle(green)
            } compactTrailing: {
                Image(systemName: context.state.requiresApproval ? "hand.raised.fill" : context.state.phase == "paused" ? "pause.fill" : "circle.dotted.circle")
                    .foregroundStyle(context.state.requiresApproval ? .orange : green)
            } minimal: {
                Image(systemName: context.state.requiresApproval ? "hand.raised.fill" : "leaf").foregroundStyle(green)
            }
            .widgetURL(taskURL(context.attributes.taskID)).keylineTint(green)
        }
    }
    private func controls(_ context: ActivityViewContext<RuneActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            Link(destination: taskURL(context.attributes.taskID)) {
                Label(context.state.requiresApproval ? "审阅变更" : "查看任务", systemImage: "arrow.up.right")
                    .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(green.opacity(0.16), in: Capsule())
            }
            Spacer()
            if ["running", "paused"].contains(context.state.phase) {
                Link(destination: taskURL(context.attributes.taskID, action: context.state.phase == "paused" ? "resume" : "pause")) {
                    Label(context.state.phase == "paused" ? "继续" : "暂停", systemImage: context.state.phase == "paused" ? "play.fill" : "pause.fill").font(.caption)
                }
            }
        }.foregroundStyle(green)
    }
    private func taskURL(_ id: String, action: String? = nil) -> URL { URL(string: "rune://task/\(id)" + (action.map { "?action=\($0)" } ?? ""))! }
    private func phaseTitle(_ phase: String) -> String {
        switch phase { case "running": "进行中"; case "paused": "已暂停"; case "completed": "已完成"; case "cancelled": "已取消"; default: "查看任务" }
    }
}

struct RuneEntry: TimelineEntry { let date: Date }
struct RuneProvider: TimelineProvider {
    func placeholder(in context: Context) -> RuneEntry { RuneEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (RuneEntry) -> Void) { completion(RuneEntry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RuneEntry>) -> Void) { completion(Timeline(entries: [RuneEntry(date: Date())], policy: .never)) }
}
struct RuneQuickWidget: Widget {
    let kind = "RuneQuickWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RuneProvider()) { entry in RuneQuickWidgetView() }
            .configurationDisplayName("随手开始").description("创建任务，或打开收件箱。")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}
struct RuneQuickWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if family == .accessoryCircular { Link(destination: URL(string: "rune://new")!) { Image(systemName: "plus.bubble").font(.title2) } }
            else if family == .accessoryRectangular {
                Link(destination: URL(string: "rune://new")!) { VStack(alignment: .leading) { Text("Rune").font(.headline); Label("开始一件事", systemImage: "arrow.up.right").font(.caption) } }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("Rune").font(.system(.title2, design: .serif)); Spacer(); Image(systemName: "leaf") }
                    Spacer(minLength: 0)
                    Link(destination: URL(string: "rune://new")!) { Label("新建任务", systemImage: "plus").font(.headline) }
                    if family == .systemMedium { Link(destination: URL(string: "rune://inbox")!) { Label("打开收件箱", systemImage: "tray").font(.subheadline) } }
                }.foregroundStyle(Color(red: 0.21, green: 0.35, blue: 0.28))
            }
        }.containerBackground(for: .widget) { Color(red: 0.94, green: 0.94, blue: 0.89) }
    }
}
