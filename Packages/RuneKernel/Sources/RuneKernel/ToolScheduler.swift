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
    public typealias PathExtractor = @Sendable (ToolCall, ToolSpec) -> PathExtraction

    /// 默认提取器：按 `ToolSpec` 声明的参数名 + 解析补丁正文
    public static let defaultPaths: PathExtractor = { call, spec in
        CallPaths.extract(from: call, spec: spec)
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
        var runnable: [(call: ToolCall, spec: ToolSpec, paths: PathExtraction)] = []
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
        var admitted: [(call: ToolCall, spec: ToolSpec, paths: PathExtraction)] = []
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
        var currentWave: [(call: ToolCall, spec: ToolSpec, paths: PathExtraction)] = []

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
        _ a: (call: ToolCall, spec: ToolSpec, paths: PathExtraction),
        _ b: (call: ToolCall, spec: ToolSpec, paths: PathExtraction),
        config: Config
    ) -> Bool {
        // 1. 并发属性
        guard a.spec.concurrency == .parallelSafe, b.spec.concurrency == .parallelSafe else { return true }

        // ⚠️ 有"越出挂载点"的路径 → 保守起见当作冲突（它会走拒绝流程，不该被并行调度掩盖）
        if !a.paths.outsideMounts.isEmpty || !b.paths.outsideMounts.isEmpty { return true }

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
            for pa in a.paths.paths {
                for pb in b.paths.paths where pathsOverlap(pa, pb) { return true }
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

/// 一次调用的路径提取结果。
///
/// ⚠️ 为什么需要 `outsideMounts` 而不是只返回一个 `[VFSPath]`：
///
/// 模型写的路径有两种形态 —— `/workspace/src/a.py`（绝对，带挂载点）和 `src/a.py`（相对）。
/// 而**相对路径才是绝大多数**。早期实现直接用 `VFSPath.parseOrNil` 解析，
/// 相对路径一律解析失败 → 返回空数组 → 上层看到的是"这次调用不涉及任何路径"。
/// 后果是**静默的**：
///   * 策略引擎跳过路径范围判定（`path == nil` 等于"没有路径参数"），越权写入被放行；
///   * "记住选择"退化成整个工具的白名单；
///   * 冲突检测失效。
///
/// 另一类更微妙：`/etc/passwd` 这种"绝对但挂载点不认识"的路径，
/// 如果按相对路径处理会被悄悄映射成 `/workspace/etc/passwd` —— 检查的路径和工具实际
/// 操作的路径不是同一个，那是典型的**混淆代理**漏洞。
/// 所以它必须被单独标成"越出挂载点"，由上层**直接拒绝**。
public struct PathExtraction: Sendable, Hashable {
    /// 落在某个挂载点内的路径（相对路径已按工作区根解析）
    public var paths: [VFSPath]
    /// 越出所有挂载点的路径原文（**必须被拒**，不能当作"没有路径参数"）
    public var outsideMounts: [String]
    /// 是否发生了 `..` 钳制（模型想往工作区外走，被拉回来了）
    public var wasClamped: Bool

    public init(paths: [VFSPath] = [], outsideMounts: [String] = [], wasClamped: Bool = false) {
        self.paths = paths
        self.outsideMounts = outsideMounts
        self.wasClamped = wasClamped
    }

    public var isEmpty: Bool { paths.isEmpty && outsideMounts.isEmpty }

    /// 去重（同一个路径出现两次不必检查两遍）
    public var deduped: PathExtraction {
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0.description).inserted }
        var seenOutside = Set<String>()
        let uniqueOutside = outsideMounts.filter { seenOutside.insert($0).inserted }
        return PathExtraction(paths: unique, outsideMounts: uniqueOutside, wasClamped: wasClamped)
    }
}

public enum CallPaths {

    /// 常见路径参数键名（**兜底用**：真实工具应当在 `ToolSpec.pathParameters` 里显式声明）
    public static let pathKeys = ["path", "file", "file_path", "target", "source", "destination", "to"]
    /// 数组形式的路径参数键名
    public static let pathArrayKeys = ["paths", "files", "targets"]

    /// **唯一的路径提取实现。**
    ///
    /// - Parameters:
    ///   - spec: 有它就用它声明的参数名（精确）；没有就退回猜常见键名（兜底）
    ///   - base: 相对路径的解析基准，默认工作区根
    public static func extract(
        from call: ToolCall,
        spec: ToolSpec? = nil,
        base: VFSPath = VFSPath(mount: .workspace)
    ) -> PathExtraction {
        guard let obj = try? call.arguments().objectValue else { return PathExtraction() }

        // ---------- 参数名：优先走声明 ----------
        let declaredKeys: [String]
        let declaredArrayKeys: [String]
        if let spec, !spec.pathParameters.isEmpty {
            declaredKeys = spec.pathParameters
            var arrays = spec.pathParameters.filter { pathArrayKeys.contains($0) }
            for key in spec.pathParameters where !arrays.contains(key) {
                if let schema = propertySchema(spec.inputSchema, key), case .array = schema {
                    arrays.append(key)
                }
            }
            declaredArrayKeys = arrays
        } else {
            declaredKeys = pathKeys + pathArrayKeys
            declaredArrayKeys = pathArrayKeys
        }

        var raw: [String] = []
        for key in declaredKeys where !declaredArrayKeys.contains(key) {
            if let value = obj[key]?.stringValue { raw.append(value) }
        }
        for key in declaredArrayKeys {
            if let array = obj[key]?.arrayValue {
                raw.append(contentsOf: array.compactMap(\.stringValue))
            }
        }

        // ---------- 补丁正文里的文件段（**最容易被漏掉的一类**） ----------
        if let patchText = obj["patch"]?.stringValue, let patch = try? Patch.parse(patchText) {
            raw.append(contentsOf: patch.files.map(\.path.description))
        }

        return resolve(raw, base: base)
    }

    /// 把一批原始路径解析成"挂载点内 + 越界"两部分
    public static func resolve(_ raw: [String], base: VFSPath = VFSPath(mount: .workspace)) -> PathExtraction {
        var paths: [VFSPath] = []
        var outside: [String] = []
        var clamped = false

        for text in raw where !text.isEmpty {
            // 绝对路径且挂载点认识 → 直接用
            if text.hasPrefix("/"), let absolute = VFSPath.parseOrNil(text) {
                paths.append(absolute)
                continue
            }
            // 绝对但挂载点不认识（`/etc/passwd`）→ **越界，交给上层拒绝**
            if text.hasPrefix("/") {
                outside.append(text)
                continue
            }
            // 相对路径 → 按基准解析，`..` 被钳制在挂载点内
            let resolved = VFSPath.resolve(base: base, relative: text)
            if resolved.clamped { clamped = true }
            paths.append(resolved.path)
        }

        return PathExtraction(paths: paths, outsideMounts: outside, wasClamped: clamped).deduped
    }

    /// schema 里某个属性的类型（用于判断它是不是数组）
    static func propertySchema(_ schema: JSONSchema, _ key: String) -> JSONSchema? {
        guard case .object(let props, _, _) = schema else { return nil }
        return props[key]
    }

    /// 便捷：只要挂载点内的路径（供调度器的冲突检测等使用）
    public static func paths(
        from call: ToolCall,
        spec: ToolSpec? = nil,
        base: VFSPath = VFSPath(mount: .workspace)
    ) -> [VFSPath] {
        extract(from: call, spec: spec, base: base).paths
    }
}
