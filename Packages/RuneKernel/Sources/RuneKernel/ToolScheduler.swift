import Foundation

// MARK: - 工具调度
//
// 设计依据（docs/04 §4.3）：一轮里模型可能一次给出多个工具调用。
// 全串行 → 慢且浪费（只读操作本该并行）；全并行 → **会出事**（两个写同一文件、或边跑测试边改文件）。
//
// 因此调度的核心不是"并发度"，而是**冲突判定**：
//   * 只读操作可以放心并行（上限保守：手机上是 6，不是 64）
//   * 写同一路径 / 目录嵌套 → 必须串行（按模型给出的顺序，不重排）
//   * **执行类工具与任何写操作冲突** —— 这是最容易漏的一条：
//     一边跑 `run_tests` 一边 `apply_patch`，测试会读到半成品，产出**假失败**
//   * 需要审批的调用**批量提交**（手机上一次弹一个审批是灾难）

public enum ToolScheduler {

    // MARK: 配置

    public struct Config: Sendable {
        /// 同时可并行的工具数上限。
        /// 手机上取保守值：并行意味着同时占用内存与 CPU，而 iOS 的预算很紧。
        public var maxConcurrency: Int
        /// 单轮最多执行多少个工具调用（超出的延后到下一轮）
        public var maxCallsPerWave: Int
        /// 是否把"执行类工具"视为与写操作冲突（**强烈建议保持 true**）
        public var execConflictsWithWrites: Bool

        public init(
            maxConcurrency: Int = 6,
            maxCallsPerWave: Int = 24,
            execConflictsWithWrites: Bool = true
        ) {
            self.maxConcurrency = max(1, maxConcurrency)
            self.maxCallsPerWave = max(1, maxCallsPerWave)
            self.execConflictsWithWrites = execConflictsWithWrites
        }

        /// 按设备核数推导一个合适的并发度（手机上封顶 6）
        public static func forDevice(activeProcessorCount: Int) -> Config {
            Config(maxConcurrency: min(6, max(2, activeProcessorCount)))
        }
    }

    // MARK: 路径提取

    /// 一次调用**可能影响**的路径集合。
    ///
    /// ⚠️ 必须返回**全部**路径，而不是第一个：`apply_patch` 一次可能改多个文件，
    /// 漏掉其中任何一个都会让冲突检测失效。
    public typealias PathExtractor = @Sendable (ToolCall, ToolSpec) -> [VFSPath]

    /// 默认提取器：查常见键名 + 解析补丁正文
    ///
    /// 注意它**不需要 ToolSpec**（真正用到的是参数本身），所以拆出了 `CallPaths` 供其他模块复用。
    public static let defaultPaths: PathExtractor = { call, _ in
        CallPaths.extract(from: call)
    }

    // MARK: 结果

    /// 一个"波次"：波内可并行，波间必须串行
    public struct Wave: Sendable {
        public var calls: [ToolCall]
        /// 为什么它们可以（或必须）这样分组 —— 用于调试与 UI 解释
        public var reason: String
        /// 是否可并行执行（单元素波次等价于串行）
        public var isParallel: Bool { calls.count > 1 }
    }

    public struct Schedule: Sendable {
        /// 按顺序执行；同一波内可并行
        public var waves: [Wave]
        /// 需要用户一次性批准的调用（**批量**，一次展示完）
        public var approvalsNeeded: [ToolCall]
        /// 预算不足、延后到下一轮的调用
        public var deferred: [ToolCall]
        /// 诊断信息（供开发者面板与测试断言）
        public var diagnostics: [String]

        public var totalScheduled: Int { waves.reduce(0) { $0 + $1.calls.count } }
        public var isParallelizable: Bool { waves.contains(where: \.isParallel) }
    }

    // MARK: 调度

    /// 把一轮的工具调用排成"波次"。
    ///
    /// 顺序保证：**同类调用保持模型给出的相对顺序**（不重排），因为模型有时依赖顺序语义
    /// （"先建目录再写文件"）。我们只决定"谁和谁能同时跑"，不改变先后。
    public static func schedule(
        calls: [ToolCall],
        specs: [String: ToolSpec],
        config: Config = Config(),
        paths: PathExtractor = ToolScheduler.defaultPaths
    ) -> Schedule {
        var diagnostics: [String] = []
        var approvals: [ToolCall] = []
        var runnable: [(call: ToolCall, spec: ToolSpec, paths: [VFSPath])] = []
        var deferred: [ToolCall] = []
        var unknown: [ToolCall] = []

        // ---------- 第 1 步：分类 ----------
        for call in calls {
            guard let spec = specs[call.name] else {
                unknown.append(call)
                continue
            }
            // 需要审批的**先摘出来批量提交**（它们不该阻塞后面的只读操作）
            if spec.needsApproval == .always || spec.needsApproval == .biometric
                || spec.riskLevel == .dangerous || spec.riskLevel == .irreversible {
                approvals.append(call)
                continue
            }
            runnable.append((call, spec, paths(call, spec)))
        }

        if !unknown.isEmpty {
            diagnostics.append("有 \(unknown.count) 个调用引用了未注册的工具（会走「工具名幻觉」兜底）")
        }
        if !approvals.isEmpty {
            diagnostics.append("\(approvals.count) 个调用需要审批，已合并为一次批量确认")
        }

        // ---------- 第 2 步：预算截断 ----------
        var budgetLeft = config.maxCallsPerWave
        var admitted: [(call: ToolCall, spec: ToolSpec, paths: [VFSPath])] = []
        for item in runnable {
            if budgetLeft <= 0 {
                deferred.append(item.call)
                continue
            }
            admitted.append(item)
            budgetLeft -= 1
        }
        if !deferred.isEmpty {
            diagnostics.append("\(deferred.count) 个调用因单轮预算已满而延后")
        }

        // ---------- 第 3 步：分波 ----------
        var waves: [Wave] = []
        var currentWave: [(call: ToolCall, spec: ToolSpec, paths: [VFSPath])] = []

        func flushWave() {
            guard !currentWave.isEmpty else { return }
            let calls = currentWave.map(\.call)
            let parallel = calls.count > 1 && currentWave.allSatisfy { $0.spec.concurrency == .parallelSafe }
            waves.append(Wave(
                calls: calls,
                reason: parallel
                    ? "\(calls.count) 个只读调用无路径冲突，可并行"
                    : "按顺序串行（含写操作或独占操作）"
            ))
            currentWave = []
        }

        for item in admitted {
            // 独占操作：先结算当前波，再单独成波
            if item.spec.concurrency == .exclusive {
                flushWave()
                waves.append(Wave(calls: [item.call], reason: "独占操作，单独执行"))
                continue
            }

            // 只读 + 无冲突 + 未超并发上限 → 并入当前波
            let canJoin: Bool
            if item.spec.concurrency == .parallelSafe && currentWave.count < config.maxConcurrency {
                canJoin = !currentWave.contains { other in
                    conflicts(item, other, config: config)
                }
            } else {
                canJoin = false
            }

            if canJoin {
                currentWave.append(item)
            } else {
                flushWave()
                currentWave.append(item)
            }
        }
        flushWave()

        return Schedule(
            waves: waves,
            approvalsNeeded: approvals,
            deferred: deferred + unknown,
            diagnostics: diagnostics
        )
    }

    // MARK: 冲突判定

    /// 两个调用是否冲突（不能并行）
    ///
    /// 冲突的四种情形：
    ///   1. 任一不是 `parallelSafe`（写操作、独占操作）
    ///   2. 路径重叠（相等、或一个是另一个的祖先目录）
    ///   3. **执行类工具与任何写操作冲突**（边跑测试边改文件 = 假失败）
    ///   4. 两个执行类工具互相冲突（同时跑两个脚本会争抢 CPU / 相互影响产物）
    static func conflicts(
        _ a: (call: ToolCall, spec: ToolSpec, paths: [VFSPath]),
        _ b: (call: ToolCall, spec: ToolSpec, paths: [VFSPath]),
        config: Config
    ) -> Bool {
        // 1. 并发属性
        guard a.spec.concurrency == .parallelSafe, b.spec.concurrency == .parallelSafe else { return true }

        let aWrites = a.spec.requirements.contains(.fsWrite) || a.spec.requirements.contains(.fsDelete)
        let bWrites = b.spec.requirements.contains(.fsWrite) || b.spec.requirements.contains(.fsDelete)
        let aExecs = a.spec.requirements.contains(.exec)
        let bExecs = b.spec.requirements.contains(.exec)

        // 2. 执行类 vs 写操作（**最容易漏的一条**）
        if config.execConflictsWithWrites {
            if (aExecs && bWrites) || (bExecs && aWrites) { return true }
            // 3. 两个执行类互相冲突
            if aExecs && bExecs { return true }
        }

        // 4. 路径重叠
        if aWrites || bWrites {
            for pa in a.paths {
                for pb in b.paths where pathsOverlap(pa, pb) { return true }
            }
        }

        return false
    }

    /// 路径是否重叠：相等，或一个是另一个的祖先（写目录会影响其下所有文件）
    public static func pathsOverlap(_ a: VFSPath, _ b: VFSPath) -> Bool {
        a.isWithin(b) || b.isWithin(a)
    }
}

// MARK: - 调用路径提取
//
// 独立成类型（而不是只作为 `ToolScheduler` 的内部闭包）是因为**多个模块都需要它**：
// 调度器用它做冲突检测、策略引擎用它做范围判定、审批代理用它决定"记住选择"的精确范围。
// 三处用不同的实现会出问题——尤其审批代理：
// **忘了传路径会让"记住选择"退化成整个工具的白名单**（比用户以为的范围大得多）。

public enum CallPaths {

    /// 常见路径参数键名
    public static let pathKeys = ["path", "file", "file_path", "target", "source", "destination", "to"]
    /// 数组形式的路径参数键名
    public static let pathArrayKeys = ["paths", "files", "targets"]

    /// 提取**全部**受影响路径（不需要 ToolSpec）
    public static func extract(from call: ToolCall) -> [VFSPath] {
        guard let obj = try? call.arguments().objectValue else { return [] }
        var paths: [VFSPath] = []

        for key in pathKeys {
            if let raw = obj[key]?.stringValue, let p = VFSPath.parseOrNil(raw) {
                paths.append(p)
            }
        }
        for key in pathArrayKeys {
            if let arr = obj[key]?.arrayValue {
                for item in arr {
                    if let raw = item.stringValue, let p = VFSPath.parseOrNil(raw) {
                        paths.append(p)
                    }
                }
            }
        }
        // 补丁正文里的文件段（**这是最容易被漏掉的一类**）
        if let patchText = obj["patch"]?.stringValue, let patch = try? Patch.parse(patchText) {
            paths.append(contentsOf: patch.files.map(\.path))
        }
        return paths
    }
}
