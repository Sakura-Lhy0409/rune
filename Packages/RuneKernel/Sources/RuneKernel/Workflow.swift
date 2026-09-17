import Foundation

// MARK: - 工作流（Workflow）引擎
//
// 设计依据（docs/04 §8）：
// **Skill 解决「怎么做一件事」，Workflow 解决「一次性跑一大片互相独立的事」。**
// 典型场景：发版前检查（17 项）、全仓库文档补全、批量重构。
//
// ## 为什么引擎本身不执行任何东西
//
// 与 `TurnRunner` 同一套哲学：**引擎只回答「下一步该跑哪些」与「结果回来了怎么记」**，
// 真正的执行（起子代理、并发、调用模型）由运行时做。这样换来三件事：
//
//   1. **完全确定性**：同样的输入必然产出同样的决策，可以逐步骤断言，不需要等并发；
//   2. **天然可恢复**：每个步骤的状态都在 `WorkflowRun` 里，被系统杀掉之后接着跑就行；
//   3. **并发策略可替换**：手机上并发上限是 3，将来放宽到 8 也不用改引擎。
//
// 如果让引擎自己去 spawn 并发任务，上面三条会同时失去 —— 而它们正是移动端最需要的三条。

// MARK: - 单个步骤

/// 工作流里的一个步骤（对应脚本里的一次 `agent()` 调用）
public struct WorkflowStep: Sendable, Codable, Hashable, Identifiable {
    public enum Status: String, Sendable, Codable, Hashable {
        /// 依赖还没满足
        case pending
        /// 依赖已满足，可以跑
        case ready
        /// 正在跑（运行时已取走）
        case running
        case done
        /// 重试次数用尽
        case failed
        /// **上游返回了 null → 本步骤不需要跑**（pipeline 的短路语义）
        case skipped

        public var isTerminal: Bool {
            self == .done || self == .failed || self == .skipped
        }
    }

    public var id: String
    /// 所属阶段（脚本里 `phase("修复")` 的名字）—— UI 的进度看板按它分组
    public var phase: String
    /// 人类可读的一行（进度看板上显示的就是它）
    public var label: String
    /// 依赖的步骤 id：**全部终结**之后本步骤才有资格就绪
    public var dependencies: [String]
    /// 最长路径长度（根为 0）。排序时**深的优先**，这样流水线才是"流水"的（见 `nextBatch`）
    public var depth: Int
    /// 插入顺序（脚本里的书写顺序；作为深度相同时的稳定次序）
    public var order: Int
    public var prompt: String
    /// 期望的结构化输出（`agent(..., {schema})`）；有它才能校验子代理的返回
    public var outputSchema: JSONSchema?
    public var status: Status
    /// 结构化结果（被 `outputSchema` 校验过）
    public var result: JSONValue?
    public var error: String?
    public var attempts: Int
    public var costMicroUSD: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: String,
        phase: String,
        label: String,
        dependencies: [String] = [],
        depth: Int = 0,
        order: Int = 0,
        prompt: String,
        outputSchema: JSONSchema? = nil,
        status: WorkflowStep.Status = .pending,
        result: JSONValue? = nil,
        error: String? = nil,
        attempts: Int = 0,
        costMicroUSD: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.phase = phase
        self.label = label
        self.dependencies = dependencies
        self.depth = depth
        self.order = order
        self.prompt = prompt
        self.outputSchema = outputSchema
        self.status = status
        self.result = result
        self.error = error
        self.attempts = attempts
        self.costMicroUSD = costMicroUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// 上游返回了 null → 本步骤短路
    public var isSkippedDownstream: Bool { status == .skipped }
}

// MARK: - 定义

/// 工作流的**静态结构**。
///
/// ⚠️ 它是脚本（JS）**编译后的产物**，而不是脚本本身：
/// 脚本能表达动态编排（根据结果决定起几个子代理），那部分由 JSC 宿主在运行时
/// 通过 `WorkflowRun.addSteps` 追加。这样一来引擎只需要处理 DAG，永远不用碰 JS。
public struct WorkflowDefinition: Sendable, Codable, Hashable {
    public var name: String
    public var summary: String
    public var steps: [WorkflowStep]
    /// 输入（对应脚本里的 `args`，来自 UI）
    public var arguments: JSONValue
    /// 脚本原文（保留用于"重新编辑"与静态安全检查）
    public var script: String?

    public init(name: String, summary: String = "", steps: [WorkflowStep] = [],
                arguments: JSONValue = .object([:]), script: String? = nil) {
        self.name = name
        self.summary = summary
        self.steps = steps
        self.arguments = arguments
        self.script = script
    }

    /// 阶段名（按首次出现顺序）
    public var phases: [String] {
        var seen = Set<String>()
        return steps.map(\.phase).filter { seen.insert($0).inserted }
    }
}

// MARK: - 运行状态

/// 一次工作流运行的全部状态（**可持久化 → 可恢复**）
public struct WorkflowRun: Sendable, Codable, Hashable {
    public enum Status: String, Sendable, Codable, Hashable {
        case running
        /// 全部步骤终结，且至少有一个没失败
        case completed
        /// 有步骤失败（但其余都跑完了 —— **不因为一个失败就丢掉全部成果**）
        case completedWithFailures
        /// 被预算/用户中止
        case aborted

        public var isTerminal: Bool { self != .running }
    }

    public var definition: WorkflowDefinition
    public var status: Status
    public var startedAt: Date
    public var finishedAt: Date?
    /// 已花的钱（微美元）
    public var spentMicroUSD: Int
    /// 运行前的成本上界估算（用户批准时看到的就是它）
    public var costCeilingMicroUSD: Int
    /// 当前阶段名（UI 看板的标题）
    public var currentPhase: String?
    public var notes: [String]

    public init(
        definition: WorkflowDefinition,
        status: Status = .running,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        spentMicroUSD: Int = 0,
        costCeilingMicroUSD: Int = 0,
        currentPhase: String? = nil,
        notes: [String] = []
    ) {
        self.definition = definition
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.spentMicroUSD = spentMicroUSD
        self.costCeilingMicroUSD = costCeilingMicroUSD
        self.currentPhase = currentPhase
        self.notes = notes
    }

    public var steps: [WorkflowStep] { definition.steps }

    public func step(_ id: String) -> WorkflowStep? {
        definition.steps.first { $0.id == id }
    }

    // MARK: 统计（进度看板）

    public var totalSteps: Int { definition.steps.count }
    public var terminalCount: Int { definition.steps.filter { $0.status.isTerminal }.count }
    public var doneCount: Int { definition.steps.filter { $0.status == .done }.count }
    public var failedCount: Int { definition.steps.filter { $0.status == .failed }.count }
    public var skippedCount: Int { definition.steps.filter { $0.status == .skipped }.count }
    public var runningCount: Int { definition.steps.filter { $0.status == .running }.count }

    /// 进度看板的一行：`阶段 2/3 · 7/17 完成 · 已花 $0.12`
    ///
    /// ⚠️ 手机上这一行是**唯一的进度反馈**（用户在排队、在走路，不会盯着屏幕）。
    /// 所以要短、要每次都变、要包含"花了多少钱"—— 钱是用户最在意的那个数字。
    public var progressLine: String {
        let phases = definition.phases
        let phaseIndex = currentPhase.flatMap { phases.firstIndex(of: $0) }.map { $0 + 1 } ?? min(phases.count, 1)
        var parts: [String] = []
        if !phases.isEmpty { parts.append("阶段 \(max(1, phaseIndex))/\(phases.count)") }
        parts.append("\(terminalCount)/\(totalSteps) 完成")
        if skippedCount > 0 { parts.append("跳过 \(skippedCount)") }
        if failedCount > 0 { parts.append("失败 \(failedCount)") }
        parts.append(String(format: "已花 $%.2f", Double(spentMicroUSD) / 1_000_000))
        return parts.joined(separator: " · ")
    }

    /// 汇总结果（对应脚本的 `return {...}`）
    ///
    /// ⚠️ 被跳过的步骤在这里是 **null**，而不是"缺失"：
    /// pipeline 的语义就是"上游判断不需要做 → 这一步是 null"，用户要能看到这个区别。
    public var aggregated: JSONValue {
        var byPhase: [String: JSONValue] = [:]
        for phase in definition.phases {
            let items = definition.steps.filter { $0.phase == phase }.map { step -> JSONValue in
                switch step.status {
                case .done: return step.result ?? .null
                case .skipped: return .null
                case .failed: return .object(["error": .string(step.error ?? "失败")])
                default: return .object(["status": .string("未完成")])
                }
            }
            byPhase[phase] = .array(items)
        }
        return .object([
            "totals": .object([
                "steps": .int(totalSteps),
                "done": .int(doneCount),
                "failed": .int(failedCount),
                "skipped": .int(skippedCount),
            ]),
            "phases": .object(byPhase),
        ])
    }
}

// MARK: - 引擎

public enum WorkflowEngine {

    /// 移动端约束（docs/04 §8.3）
    public struct Limits: Sendable, Codable, Hashable {
        /// 并发子代理上限。
        /// ⚠️ 手机上取 3 而不是桌面的 8：每个子代理都有自己的上下文与内存，
        /// 并发起来会同时抢内存、CPU 和电量 —— 而 iOS 会因为内存压力直接杀 App。
        public var maxConcurrency: Int
        /// 单次运行最多多少步骤（防脚本写出无限 fan-out 把用户的钱烧光）
        public var maxSteps: Int
        /// 单个步骤最多重试几次（只对"瞬时失败"重试）
        public var maxAttempts: Int
        /// 运行前的成本上界（微美元）—— 超过它必须让用户先批准
        public var costCeilingMicroUSD: Int

        public init(
            maxConcurrency: Int = 3,
            maxSteps: Int = 200,
            maxAttempts: Int = 2,
            costCeilingMicroUSD: Int = 2_000_000
        ) {
            self.maxConcurrency = max(1, maxConcurrency)
            self.maxSteps = max(1, maxSteps)
            self.maxAttempts = max(1, maxAttempts)
            self.costCeilingMicroUSD = max(0, costCeilingMicroUSD)
        }

        public static let mobile = Limits()
    }

    // MARK: 调度：下一步该跑哪些

    /// 取出下一步该跑的步骤（**最多到并发上限为止**）。
    ///
    /// ## 为什么按「深度降序」排
    ///
    /// 这是 `pipeline` 无屏障语义的关键。设想 17 个目标、每个要过"检查 → 修复 → 验证"三个阶段：
    ///
    /// * 按**书写顺序**排：先把 17 个检查全跑完，再开始修复 —— 那实际上是**三级屏障**，
    ///   而设计文档明确要的是"每个 item 独立流过三个阶段，阶段之间没有屏障"；
    /// * 按**深度降序**排：某个 item 的检查一完成，它的修复步骤就会优先于还没开始的检查 ——
    ///   流水线真的流动起来，整体完成时间更短。
    ///
    /// 深度相同则按书写顺序，最后按 id 兜底 → **排序完全确定**（可回放、可测试）。
    public static func nextBatch(_ run: WorkflowRun, limits: Limits) -> [WorkflowStep] {
        guard run.status == .running else { return [] }
        let slots = limits.maxConcurrency - run.runningCount
        guard slots > 0 else { return [] }

        let ready = run.steps
            .filter { $0.status == .ready }
            .sorted { a, b in
                if a.depth != b.depth { return a.depth > b.depth }
                if a.order != b.order { return a.order < b.order }
                return a.id < b.id
            }
        return Array(ready.prefix(slots))
    }

    /// 把"准备开跑"标进状态（运行时要先调它，再真的去跑）
    public static func markRunning(_ ids: [String], in run: inout WorkflowRun, now: Date) {
        for id in ids {
            guard let index = run.definition.steps.firstIndex(where: { $0.id == id }) else { continue }
            run.definition.steps[index].status = .running
            run.definition.steps[index].attempts += 1
            run.definition.steps[index].startedAt = now
        }
    }

    // MARK: 推进：重新计算就绪状态

    /// 重算所有 `pending` 步骤的就绪状态，并推进阶段与终态。
    ///
    /// 由运行时在**每批结果回来之后**调用一次。
    public static func advance(_ run: inout WorkflowRun, now: Date) {
        guard run.status == .running else { return }

        // ---------- ① 传播"跳过"：上游返回 null → 下游也是 null ----------
        //
        // 这是 pipeline 的短路语义：`prev == null` 时这一阶段不跑，
        // 而它的输出同样是 null，于是**整条链一起短路**。
        var changed = true
        while changed {
            changed = false
            for index in run.definition.steps.indices {
                let step = run.definition.steps[index]
                guard step.status == .pending else { continue }
                let deps = step.dependencies.compactMap { run.step($0) }
                guard deps.count == step.dependencies.count else { continue }
                guard deps.allSatisfy({ $0.status.isTerminal }) else { continue }
                if deps.contains(where: { $0.status == .skipped }) {
                    run.definition.steps[index].status = .skipped
                    run.definition.steps[index].result = .null
                    run.definition.steps[index].finishedAt = now
                    changed = true
                }
            }
        }

        // ---------- ② 就绪：依赖全部终结，且没有一个失败/跳过 ----------
        for index in run.definition.steps.indices {
            let step = run.definition.steps[index]
            guard step.status == .pending else { continue }
            let deps = step.dependencies.compactMap { run.step($0) }
            guard deps.count == step.dependencies.count else { continue }
            guard deps.allSatisfy({ $0.status.isTerminal }) else { continue }
            if deps.contains(where: { $0.status == .failed }) {
                // ⚠️ 上游失败 → 本步骤**不跑**（它拿不到输入）。标成失败而不是跳过，
                //    因为"从没做过"和"判断不需要做"是两件事，用户要能区分。
                run.definition.steps[index].status = .failed
                run.definition.steps[index].error = "上游步骤失败，本步骤未执行"
                run.definition.steps[index].finishedAt = now
                continue
            }
            if deps.contains(where: { $0.status == .skipped }) {
                continue    // 由 ① 处理
            }
            run.definition.steps[index].status = .ready
        }

        // ---------- ③ 阶段推进（UI 看板的标题） ----------
        let phases = run.definition.phases
        let inFlight = run.definition.steps.first { !$0.status.isTerminal }
        run.currentPhase = inFlight?.phase ?? phases.last

        // ---------- ④ 终态 ----------
        if run.definition.steps.allSatisfy({ $0.status.isTerminal }) {
            run.finishedAt = now
            let failures = run.definition.steps.contains { $0.status == .failed }
            run.status = failures ? .completedWithFailures : .completed
        }
    }

    // MARK: 应用结果

    public enum Outcome: Sendable, Hashable {
        /// 成功，可带结构化结果（会按 `outputSchema` 校验）
        case success(result: JSONValue, costMicroUSD: Int, inputTokens: Int, outputTokens: Int)
        /// 上游判断"不需要做" → 本步骤短路（pipeline 的 null）
        case shortCircuit
        /// 可重试的失败（网络抖动、限流）
        case transient(message: String, costMicroUSD: Int)
        /// 不可重试的失败（子代理崩了、schema 不符）
        case failure(message: String, costMicroUSD: Int)

        public var costMicroUSD: Int {
            switch self {
            case .success(_, let cost, _, _): return cost
            case .transient(_, let cost): return cost
            case .failure(_, let cost): return cost
            case .shortCircuit: return 0
            }
        }
    }

    /// 应用一个子任务的结果，返回是否被接受（拒绝时步骤保持 `running`，由上层决定怎么办）。
    @discardableResult
    public static func apply(
        _ outcome: Outcome,
        to stepID: String,
        in run: inout WorkflowRun,
        limits: Limits = .mobile,
        now: Date
    ) -> Bool {
        guard let index = run.definition.steps.firstIndex(where: { $0.id == stepID }) else { return false }

        run.spentMicroUSD += outcome.costMicroUSD
        run.definition.steps[index].costMicroUSD += outcome.costMicroUSD

        switch outcome {
        case .success(let result, _, let inputTokens, let outputTokens):
            // ⚠️ schema 不符要**当成失败**，而不是"凑合用"：
            //    下游的脚本会按 schema 访问字段，塞进去一个形状不对的对象
            //    会以一种极难排查的方式在下游炸掉。
            if let schema = run.definition.steps[index].outputSchema,
               !SchemaValidator.validate(result, against: schema) {
                run.definition.steps[index].status = .failed
                run.definition.steps[index].error = "子代理返回的结构不符合声明的 schema"
                run.definition.steps[index].finishedAt = now
                return true
            }
            run.definition.steps[index].status = .done
            run.definition.steps[index].result = result
            run.definition.steps[index].inputTokens += inputTokens
            run.definition.steps[index].outputTokens += outputTokens
            run.definition.steps[index].finishedAt = now

        case .shortCircuit:
            run.definition.steps[index].status = .skipped
            run.definition.steps[index].result = .null
            run.definition.steps[index].finishedAt = now

        case .transient(let message, _):
            run.definition.steps[index].error = message
            if run.definition.steps[index].attempts < limits.maxAttempts {
                // 回到"可跑"状态等下一次调度（退避由运行时负责 —— 引擎不碰时间）
                run.definition.steps[index].status = .ready
            } else {
                run.definition.steps[index].status = .failed
                run.definition.steps[index].finishedAt = now
            }

        case .failure(let message, _):
            // ⚠️ **一个步骤失败不该杀掉整批**：其余 16 项照跑，用户至少拿到 16 项成果。
            //    这是"批量任务"与"单任务"最重要的体验差别。
            run.definition.steps[index].status = .failed
            run.definition.steps[index].error = message
            run.definition.steps[index].finishedAt = now
        }

        // 预算熔断：超上限就整体中止（用户批准过的那个数不能被悄悄突破）
        if limits.costCeilingMicroUSD > 0, run.spentMicroUSD > limits.costCeilingMicroUSD {
            run.status = .aborted
            run.notes.append("已超出运行前批准的成本上界，运行中止。")
            run.finishedAt = now
        }

        advance(&run, now: now)
        return true
    }

    // MARK: 动态追加（脚本运行到一半才决定要起几个子代理时用）

    @discardableResult
    public static func addSteps(
        _ steps: [WorkflowStep],
        to run: inout WorkflowRun,
        limits: Limits,
        now: Date
    ) -> [String] {
        // ⚠️ **必须先把运行"重新打开"。**
        //
        //    这里踩过一个会让第二阶段永远不跑的 bug：脚本的典型形状是
        //        phase("A"); const r = await agent(x); phase("B"); const r2 = await agent(y)
        //    第一个 agent 完成之后，**已知的全部步骤都终结了** → `advance` 把运行标成
        //    `.completed`。等脚本走到 B 想加新步骤时，`advance` 开头的
        //    `guard status == .running` 直接返回 → 新步骤永远停在 pending → 整段 B 静默消失。
        //
        //    而"脚本还在执行"这件事本身，就证明运行**没有结束** —— 是脚本在加步骤，
        //    不是引擎在猜。
        if run.status == .completed || run.status == .completedWithFailures {
            run.status = .running
            run.finishedAt = nil
            run.notes.append("脚本继续追加了步骤，运行已重新打开。")
        }

        var rejected: [String] = []
        for step in steps {
            if run.definition.steps.count >= limits.maxSteps {
                rejected.append(step.id)
                continue
            }
            guard !run.definition.steps.contains(where: { $0.id == step.id }) else {
                rejected.append(step.id)
                continue
            }
            run.definition.steps.append(step)
        }
        if !rejected.isEmpty {
            run.notes.append("有 \(rejected.count) 个步骤未能加入（超出步骤上限或 id 重复）。")
        }
        recomputeDepths(&run)
        advance(&run, now: now)
        return rejected
    }

    /// 重算深度（新增步骤之后必须重算，否则流水线排序会错）
    public static func recomputeDepths(_ run: inout WorkflowRun) {
        let byID = Dictionary(uniqueKeysWithValues: run.definition.steps.map { ($0.id, $0) })
        var memo: [String: Int] = [:]

        func depth(_ id: String, visiting: inout Set<String>) -> Int {
            if let cached = memo[id] { return cached }
            guard let step = byID[id], !visiting.contains(id) else { return 0 }
            visiting.insert(id)
            var best = 0
            for dep in step.dependencies where byID[dep] != nil {
                best = max(best, depth(dep, visiting: &visiting) + 1)
            }
            visiting.remove(id)
            memo[id] = best
            return best
        }

        for index in run.definition.steps.indices {
            var visiting = Set<String>()
            run.definition.steps[index].depth = depth(run.definition.steps[index].id, visiting: &visiting)
        }
    }

    // MARK: 校验

    public struct Issue: Sendable, Hashable, CustomStringConvertible {
        public enum Rule: String, Sendable, Hashable {
            case emptyWorkflow
            case duplicateStepID
            case danglingDependency
            case cycle
            case missingLabel
            case missingPrompt
            case tooManySteps
            case tooManyPhases
            case forbiddenToken
        }
        public var step: String
        public var rule: Rule
        public var detail: String
        public var description: String { "[\(rule.rawValue)] \(step)：\(detail)" }
    }

    /// 单次运行的步骤上限（手机上的默认约束）
    public static let defaultMaxSteps = 200
    /// 阶段数上限（UI 看板塞不下更多）
    public static let defaultMaxPhases = 8

    public static func validate(_ definition: WorkflowDefinition, limits: Limits = .mobile) -> [Issue] {
        var issues: [Issue] = []

        if definition.steps.isEmpty {
            issues.append(Issue(step: definition.name, rule: .emptyWorkflow, detail: "工作流里一个步骤都没有"))
        }
        if definition.steps.count > min(limits.maxSteps, defaultMaxSteps) {
            issues.append(Issue(step: definition.name, rule: .tooManySteps,
                                detail: "\(definition.steps.count) 个步骤超过上限 \(min(limits.maxSteps, defaultMaxSteps))"))
        }
        if definition.phases.count > defaultMaxPhases {
            issues.append(Issue(step: definition.name, rule: .tooManyPhases,
                                detail: "\(definition.phases.count) 个阶段超过上限 \(defaultMaxPhases)"))
        }

        var seen = Set<String>()
        for step in definition.steps {
            if !seen.insert(step.id).inserted {
                issues.append(Issue(step: step.id, rule: .duplicateStepID, detail: "步骤 id 重复"))
            }
            if step.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(Issue(step: step.id, rule: .missingLabel,
                                    detail: "没有 label —— 进度看板上会是一行空白"))
            }
            if step.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(Issue(step: step.id, rule: .missingPrompt, detail: "没有提示词"))
            }
            for dep in step.dependencies where !seen.contains(dep) && !definition.steps.contains(where: { $0.id == dep }) {
                issues.append(Issue(step: step.id, rule: .danglingDependency, detail: "依赖了不存在的步骤 `\(dep)`"))
            }
        }

        // 环检测（拓扑排序）。**有环的话 nextBatch 会永远返回空**，而运行会静默卡死 ——
        // 那是最难查的一类问题，所以必须在开跑之前就拦住。
        if let cycle = findCycle(definition) {
            issues.append(Issue(step: cycle.first ?? definition.name, rule: .cycle,
                                detail: "依赖成环：\(cycle.joined(separator: " → ")) —— 这些步骤永远不会就绪，运行会静默卡死"))
        }

        // 脚本静态安全检查（注意：**这不是安全边界**，见 `WorkflowScriptGuard` 的注释）
        if let script = definition.script {
            for issue in WorkflowScriptGuard.inspect(script) {
                issues.append(Issue(step: definition.name, rule: .forbiddenToken, detail: issue))
            }
        }
        return issues
    }

    /// 找出一个环（返回环上的步骤 id）
    static func findCycle(_ definition: WorkflowDefinition) -> [String]? {
        var graph: [String: [String]] = [:]
        for step in definition.steps { graph[step.id] = step.dependencies }
        var state: [String: Int] = [:]   // 0 未访问 / 1 在栈上 / 2 已完成
        var stack: [String] = []

        func visit(_ id: String) -> [String]? {
            if state[id] == 1 {
                if let start = stack.firstIndex(of: id) { return Array(stack[start...]) + [id] }
                return [id]
            }
            if state[id] == 2 { return nil }
            state[id] = 1
            stack.append(id)
            for dep in graph[id] ?? [] where graph[dep] != nil {
                if let cycle = visit(dep) { return cycle }
            }
            stack.removeLast()
            state[id] = 2
            return nil
        }

        for step in definition.steps {
            if let cycle = visit(step.id) { return cycle }
        }
        return nil
    }
}

// MARK: - 成本上界估算（docs/04 §8.3）
//
// 「运行前必须给出上界估算（agents × 平均 token × 单价），用户批准后开跑」
//
// ⚠️ 这一条不是可选的：Workflow 最典型的形态是"一次起 17 个子代理"，
// 而用户对"17 个子代理要花多少钱"完全没有直觉。
// 没有开跑前的上界，用户第一次用就会被账单吓到 —— 而那是一次性的信任损失。

public struct WorkflowCostEstimate: Sendable, Codable, Hashable {
    public var stepCount: Int
    /// 上界（微美元）—— 按每个步骤都用满预算算
    public var upperBoundMicroUSD: Int
    /// 中位数预期（微美元）—— 按历史均值算
    public var expectedMicroUSD: Int
    /// 按阶段拆分的上界（审批卡片上要能说清"哪一阶段最贵"）
    public var byPhase: [String: Int]
    public var assumptions: Assumptions

    public struct Assumptions: Sendable, Codable, Hashable {
        public var avgInputTokens: Int
        public var avgOutputTokens: Int
        public var inputPriceMicroUSDPerMillion: Int
        public var outputPriceMicroUSDPerMillion: Int
        /// 上界的放大系数（子代理往往比你估的要啰嗦）
        public var safetyFactor: Double

        public init(
            avgInputTokens: Int = 12_000,
            avgOutputTokens: Int = 1_200,
            inputPriceMicroUSDPerMillion: Int = 3_000_000,
            outputPriceMicroUSDPerMillion: Int = 15_000_000,
            safetyFactor: Double = 1.5
        ) {
            self.avgInputTokens = avgInputTokens
            self.avgOutputTokens = avgOutputTokens
            self.inputPriceMicroUSDPerMillion = inputPriceMicroUSDPerMillion
            self.outputPriceMicroUSDPerMillion = outputPriceMicroUSDPerMillion
            self.safetyFactor = safetyFactor
        }
    }

    /// 一句话给用户看（审批卡片的主文案）
    public var summary: String {
        let upper = Double(upperBoundMicroUSD) / 1_000_000
        let expected = Double(expectedMicroUSD) / 1_000_000
        return String(format: "%d 个步骤，预计 $%.2f，最坏 $%.2f", stepCount, expected, upper)
    }
}

public extension WorkflowEngine {

    static func estimateCost(
        _ definition: WorkflowDefinition,
        assumptions: WorkflowCostEstimate.Assumptions = .init()
    ) -> WorkflowCostEstimate {
        let perStepInput = Double(assumptions.avgInputTokens) / 1_000_000 * Double(assumptions.inputPriceMicroUSDPerMillion)
        let perStepOutput = Double(assumptions.avgOutputTokens) / 1_000_000 * Double(assumptions.outputPriceMicroUSDPerMillion)
        let perStep = perStepInput + perStepOutput
        let expected = Int(perStep.rounded())
        let upper = Int((perStep * assumptions.safetyFactor).rounded())

        var byPhase: [String: Int] = [:]
        for phase in definition.phases {
            byPhase[phase] = definition.steps.filter { $0.phase == phase }.count * upper
        }
        return WorkflowCostEstimate(
            stepCount: definition.steps.count,
            upperBoundMicroUSD: definition.steps.count * upper,
            expectedMicroUSD: definition.steps.count * expected,
            byPhase: byPhase,
            assumptions: assumptions
        )
    }
}

// MARK: - 脚本静态安全检查
//
// ⚠️⚠️ **必须先把话说清楚：文本扫描不是安全边界。**
//
// 真正的边界是 **JSC 宿主根本不暴露这些全局** ——
// 没有 `fetch`、没有文件 API、没有定时器，脚本就算写出 `fetch(...)` 也只是
// "调用了一个 undefined"，什么都不会发生。
// 任何号称靠关键字黑名单拦住逃逸的方案都是自欺欺人：`this["fet"+"ch"]` 一行就绕过去了。
//
// 那这一层是干什么用的？两件事：
//   1. **可用性**：用户写了一个注定跑不通的脚本（用了 `require`），
//      在开跑前就告诉他，而不是让他等 17 个子代理起来之后才发现；
//   2. **纵深防御**：导入的工作流如果**明晃晃**写着 `fetch("http://…")`，
//      那它多半是在偷数据 —— 值得在开跑前给用户看一眼。
//
// 所以：命中 ≠ 攻击，只是"值得提醒"；不命中 ≠ 安全。

public enum WorkflowScriptGuard {

    /// 宿主**只**暴露这些。其余全局一律不存在。
    public static let hostSurface = ["phase", "log", "args", "agent", "pipeline", "parallel"]

    /// 值得提醒用户的标识符（按类别分组，便于给出具体建议）
    public static let suspiciousTokens: [String] = [
        // 网络出口
        "fetch", "XMLHttpRequest", "WebSocket", "EventSource", "sendBeacon", "importScripts",
        // 模块与动态执行
        "require", "eval", "Function(", "import(", "import ", "export ",
        // 定时器（会破坏"每个步骤都可检查点"的假设）
        "setTimeout", "setInterval", "requestAnimationFrame",
        // 宿主对象逃逸（拿回全局的常见手法）
        "globalThis", "window", "document", "localStorage", "sessionStorage",
        "process", "Deno", "Bun",
        // 原型链逃逸
        "__proto__", "prototype", "constructor",
    ]

    /// 扫描脚本，返回**给人看的**提醒（不是错误）
    public static func inspect(_ script: String) -> [String] {
        var found: [String] = []
        for token in suspiciousTokens where script.contains(token) {
            found.append(hint(for: token))
        }
        return found
    }

    private static func hint(for token: String) -> String {
        switch token {
        case "fetch", "XMLHttpRequest", "WebSocket", "EventSource", "sendBeacon", "importScripts":
            return "脚本里出现了 `\(token)`：Workflow 沙箱**没有网络能力**。需要联网请让子代理用 `fetch_url`（那会走出口白名单与审批）。"
        case "require", "eval", "Function(", "import(", "import ", "export ":
            return "脚本里出现了 `\(token)`：Workflow 沙箱是**单文件表达式**，没有模块系统与动态执行。"
        case "setTimeout", "setInterval", "requestAnimationFrame":
            return "脚本里出现了 `\(token)`：定时器会破坏「每个步骤完成即写检查点」的假设，沙箱不提供。"
        case "__proto__", "prototype", "constructor", "globalThis", "window", "document", "localStorage", "sessionStorage", "process", "Deno", "Bun":
            return "脚本里出现了 `\(token)`：这通常是想拿回宿主全局对象。沙箱只提供 \(hostSurface.joined(separator: " / "))。"
        default:
            return "脚本里出现了可疑标识符 `\(token)`。"
        }
    }
}

// MARK: - 输出校验

/// 子代理返回值的**结构校验**（`agent(..., {schema})`）。
///
/// ⚠️ 为什么必须校验而不是"尽力而为"：下游脚本会按 schema 访问字段
/// （`prev.issues.length`）。塞一个形状不对的对象进去，会在下游某个无关的地方炸，
/// 而那时离真正的原因已经很远了。
public enum SchemaValidator {

    public static func validate(_ value: JSONValue, against schema: JSONSchema) -> Bool {
        switch schema {
        case .object(let properties, let required, let additional):
            guard let dict = value.objectValue else { return false }
            for key in required where dict[key] == nil { return false }
            if !additional {
                for key in dict.keys where properties[key] == nil { return false }
            }
            for (key, sub) in properties {
                if let child = dict[key], !validate(child, against: sub) { return false }
            }
            return true

        case .array(let items, let minItems, let maxItems):
            guard let array = value.arrayValue else { return false }
            if let minItems, array.count < minItems { return false }
            if let maxItems, array.count > maxItems { return false }
            return array.allSatisfy { validate($0, against: items) }

        case .string(let enumValues, let minLength, let maxLength):
            guard let text = value.stringValue else { return false }
            if let enumValues, !enumValues.contains(text) { return false }
            if let minLength, text.count < minLength { return false }
            if let maxLength, text.count > maxLength { return false }
            return true

        case .integer(let minimum, let maximum):
            // ⚠️ JSON 里 `1.0` 与 `1` 是同一个数，但我们的 `JSONValue` 可能把它们
            //    归一化成不同 case。整数校验要接受"数值上等于整数"的值，
            //    否则子代理返回 `1.0` 就会被无理由判失败。
            guard let number = numericValue(value) else { return false }
            guard number == number.rounded() else { return false }
            if let minimum, number < Double(minimum) { return false }
            if let maximum, number > Double(maximum) { return false }
            return true

        case .number(let minimum, let maximum):
            guard let number = numericValue(value) else { return false }
            if let minimum, number < minimum { return false }
            if let maximum, number > maximum { return false }
            return true

        case .boolean:
            return value.boolValue != nil

        case .any:
            return true
        }
    }

    static func numericValue(_ value: JSONValue) -> Double? {
        if let int = value.intValue { return Double(int) }
        if let double = value.doubleValue { return double }
        return nil
    }
}
