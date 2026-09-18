import UIKit
@preconcurrency import BackgroundTasks

/// 系统可以收回后台执行时间。到期只请求暂停；运行时已逐步落盘，不假设常驻。
@MainActor
final class BackgroundExecution {
    private let prefix = "dev.rune.agent.continued."
    private var registered = false
    private var requests: [UUID: String] = [:]
    private var handlers: [String: @MainActor () -> Void] = [:]
    private var continued: [String: BGTask] = [:]
    private var fallback: [UUID: UIBackgroundTaskIdentifier] = [:]

    init() {
        if #available(iOS 26.0, *) {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: prefix + "*", using: .main) { [weak self] task in
                Task { @MainActor in
                    guard let self, let pause = self.handlers[task.identifier] else { task.setTaskCompleted(success: false); return }
                    self.continued[task.identifier] = task
                    if let task = task as? BGContinuedProcessingTask { task.progress.totalUnitCount = 40; task.progress.completedUnitCount = 1 }
                    task.expirationHandler = { [weak self] in
                        Task { @MainActor in
                            pause()
                            self?.finishIdentifier(task.identifier, success: false)
                        }
                    }
                }
            }
        }
    }

    func begin(id: UUID, title: String, pause: @escaping @MainActor () -> Void) {
        finish(id: id, success: false)
        // UI 自动化不向系统申请真实后台调度；专项/真机单独验收。
        guard !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return }
        if #available(iOS 26.0, *), registered, UIApplication.shared.applicationState == .active {
            let identifier = prefix + UUID().uuidString
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: String(title.prefix(60)), subtitle: "文件留在设备上，随时可暂停")
            request.strategy = .fail
            handlers[identifier] = pause; requests[id] = identifier
            do { try BGTaskScheduler.shared.submit(request); return }
            catch { handlers[identifier] = nil; requests[id] = nil }
        }
        fallback[id] = UIApplication.shared.beginBackgroundTask(withName: "Rune task") { [weak self] in
            Task { @MainActor in pause(); self?.finish(id: id, success: false) }
        }
    }
    func update(id: UUID, completedSteps: Int, detail: String) {
        guard #available(iOS 26.0, *), let identifier = requests[id],
              let task = continued[identifier] as? BGContinuedProcessingTask else { return }
        // 仅以已完成步骤表示进度；总数是资源预算，不是模型承诺的完成百分比。
        task.progress.totalUnitCount = max(40, Int64(completedSteps + 1))
        task.progress.completedUnitCount = Int64(max(1, completedSteps))
        task.updateTitle(task.title, subtitle: String(detail.prefix(80)))
    }
    func finish(id: UUID, success: Bool) {
        if let identifier = requests.removeValue(forKey: id) { finishIdentifier(identifier, success: success) }
        if let assertion = fallback.removeValue(forKey: id), assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
    }
    private func finishIdentifier(_ identifier: String, success: Bool) {
        handlers[identifier] = nil
        if let task = continued.removeValue(forKey: identifier) { task.setTaskCompleted(success: success) }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
