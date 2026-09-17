import Foundation

// MARK: - 计划引擎
//
// 计划本身由模型产出（结构化 JSON），引擎负责：**校验、翻译成权限请求、推进状态、检测偏离**。
//
// 最重要的一件事是「**把计划翻译成一次性权限请求**」（docs/04 §3.1 称之为杀手级细节）：
// 计划里已经写明了接下来要用哪些工具、碰哪些路径 ——
// 于是可以在**批准计划的那一刻**把整包权限一次授予，
// 而不是每调用一个工具就弹一次审批。手机上一次弹一个审批是灾难。

public enum PlanEngine {

    // MARK: 校验

    public struct Validation: Sendable, Equatable {
        public var issues: [String]
        public var warnings: [String]
        /// 有 issues 就是不可用（必须让模型重出计划）
        public var isValid: Bool { issues.isEmpty }
    }

    public enum PlanError: Error, Sendable, Equatable {
        case notAnObject
        case missingGoalSummary
        case noSteps
        case tooManySteps(Int)
        case invalidStep(index: Int, reason: String)
        case unknownTool(step: Int, tool: String)

        public var modelFacingMessage: String {
            switch self {
            case .notAnObject:
                return "计划必须是一个 JSON 对象。"
            case .missingGoalSummary:
                return "计划缺少 `goalSummary`（一句话说明要达成什么）。"
            case .noSteps:
                return "计划里没有任何步骤。哪怕只有一个步骤也要写出来。"
            case .tooManySteps(let n):
                return "计划有 \(n) 个步骤，超过上限 20。请把它拆成几个更聚焦的任务。"
            case .invalidStep(let i, let reason):
                return "第 \(i + 1) 个步骤不合法：\(reason)"
            case .unknownTool(let i, let tool):
                return "第 \(i + 1) 个步骤引用了不存在的工具 `\(tool)`。可用工具见系统提示里的工具清单。"
            }
        }

        public var suggestion: String? {
            switch self {
            case .notAnObject, .missingGoalSummary, .noSteps:
                return "按 `{goalSummary, assumptions, steps:[{title, kind, toolHints, pathHints}], risks, estimatedCost}` 的结构重新给出计划。"
            case .tooManySteps:
                return "把任务拆小：先给出前几步的计划，跑完再规划后续。"
            case .invalidStep:
                return "每个步骤必须有 `title`，且 `kind` 取以下之一：read / analyze / write / execute / network / verify / deliver。"
            case .unknownTool:
                return "只使用工具清单里真实存在的工具名。"
            }
        }
    }

    // MARK: 解析

    /// 从模型的结构化输出解析计划。
    ///
    /// **宽容之处**：`kind` 缺失时按 `.analyze` 兜底；`assumptions` / `risks` / `estimatedCost` 可缺省。
    /// **严格之处**：必须有 `goalSummary`；必须有步骤；步骤数上限 20；引用了不存在的工具会被标记为**警告**而非错误
    /// （因为工具清单可能因渠道能力而变化，不该让计划整个作废——执行时会走"工具名幻觉"兜底）。
    public static func parse(
        _ json: JSONValue,
        knownTools: Set<String>? = nil
    ) throws -> (plan: Plan, validation: Validation) {
        guard let obj = json.objectValue else { throw PlanError.notAnObject }
        guard let goal = obj["goalSummary"]?.stringValue, !goal.isEmpty else {
            throw PlanError.missingGoalSummary
        }
        guard let rawSteps = obj["steps"]?.arrayValue, !rawSteps.isEmpty else {
            throw PlanError.noSteps
        }
        guard rawSteps.count <= 20 else { throw PlanError.tooManySteps(rawSteps.count) }

        var steps: [PlanStep] = []
        var warnings: [String] = []

        for (index, raw) in rawSteps.enumerated() {
            guard let stepObj = raw.objectValue else {
                throw PlanError.invalidStep(index: index, reason: "不是一个对象")
            }
            guard let title = stepObj["title"]?.stringValue, !title.isEmpty else {
                throw PlanError.invalidStep(index: index, reason: "缺少 title")
            }
            let kind = stepObj["kind"]?.stringValue.flatMap(PlanStep.StepKind.init(rawValue:)) ?? .analyze

            let toolHints = (stepObj["toolHints"]?.arrayValue ?? []).compactMap(\.stringValue)
            if let knownTools {
                for tool in toolHints where !knownTools.contains(tool) {
                    warnings.append("第 \(index + 1) 步引用了未知工具 `\(tool)`（执行时会走工具名幻觉兜底）")
                }
            }

            let pathHints = (stepObj["pathHints"]?.arrayValue ?? [])
                .compactMap(\.stringValue)
                .compactMap { VFSPath.parseOrNil($0) }

            steps.append(PlanStep(title: title, kind: kind, toolHints: toolHints, pathHints: pathHints))
        }

        let assumptions = (obj["assumptions"]?.arrayValue ?? []).compactMap(\.stringValue)

        let risks: [RiskNote] = (obj["risks"]?.arrayValue ?? []).compactMap { raw in
            guard let r = raw.objectValue, let summary = r["summary"]?.stringValue else { return nil }
            let severity = r["severity"]?.stringValue.flatMap(ToolSpec.RiskLevel.init(rawValue:)) ?? .modifying
            return RiskNote(
                summary: summary,
                severity: severity,
                isReversible: r["isReversible"]?.boolValue ?? true,
                isIrreversibleOrNetwork: r["isIrreversibleOrNetwork"]?.boolValue ?? (severity == .dangerous || severity == .irreversible)
            )
        }

        let estimate = CostEstimate(
            microUSD: obj["estimatedCost"]?.value(at: ["microUSD"])?.intValue ?? 0,
            estimatedSeconds: obj["estimatedCost"]?.value(at: ["estimatedSeconds"])?.intValue ?? 0
        )

        // 自动补上"计划本身的风险"：有副作用步骤但没写风险 → 提醒（不是错误）
        if risks.isEmpty, steps.contains(where: { $0.kind.isSideEffecting }) {
            warnings.append("计划里有会产生副作用的步骤，但没有列出风险说明")
        }

        let plan = Plan(
            goalSummary: goal,
            assumptions: assumptions,
            steps: steps,
            risks: risks,
            estimatedCost: estimate
        )
        return (plan, Validation(issues: [], warnings: warnings))
    }

    // MARK: 权限请求（**批量授权的基础**）

    /// 从计划推导出**一次性权限请求**。
    public struct CapabilityRequest: Sendable, Equatable {
        public var scopes: [CapabilityToken.Scope]
        /// 给用户看的逐条说明（"可以写 /workspace/src/**"）
        public var summaryLines: [String]
        public var estimatedCostMicroUSD: Int
        public var estimatedSeconds: Int
        /// 计划里出现了但我们**不预先授权**的能力（例如网络出口）——必须如实告诉用户
        public var notPreAuthorized: [String]
    }

    /// 把计划翻译成权限请求。
    ///
    /// 设计取舍：**网络出口不预先授权**。
    /// 理由：计划阶段模型并不知道它最终会访问哪些域名；预先授权域名等于开一张空白支票，
    /// 而域名白名单恰恰是最不该被"顺便"授予的东西。出口权限仍然逐次申请。
    public static func capabilityRequest(
        for plan: Plan,
        registry: [String: ToolSpec],
        workspaceRoot: VFSPath = VFSPath(mount: .workspace)
    ) -> CapabilityRequest {
        var scopes: [CapabilityToken.Scope] = []
        var lines: [String] = []
        var notPreAuthorized: [String] = []

        // 收集：需要哪些能力 + 涉及哪些路径
        var needsRead = false
        var writePrefixes: [VFSPath] = []
        var deletePrefixes: [VFSPath] = []
        var runtimes: Set<SandboxRuntime> = []
        var nativeAPIs: Set<NativeAPI> = []
        var wantsNetwork = false
        var wantsGitWrite = false

        for step in plan.steps {
            for tool in step.toolHints {
                guard let spec = registry[tool] else { continue }
                if spec.requirements.contains(.fsRead) { needsRead = true }
                if spec.requirements.contains(.egress) { wantsNetwork = true }
                if spec.requirements.contains(.gitWrite) { wantsGitWrite = true }
                if spec.requirements.contains(.native) { nativeAPIs.formUnion(nativeAPIsOf(tool)) }
                if spec.requirements.contains(.exec) { runtimes.insert(runtimeOf(tool)) }
                if spec.requirements.contains(.fsWrite) {
                    writePrefixes.append(contentsOf: step.pathHints.isEmpty ? [workspaceRoot] : step.pathHints)
                }
                if spec.requirements.contains(.fsDelete) {
                    deletePrefixes.append(contentsOf: step.pathHints.isEmpty ? [workspaceRoot] : step.pathHints)
                }
            }
        }

        // 读：只要读就用工作区根（读权限不敏感，且工作区已在用户授权范围内）
        if needsRead {
            scopes.append(.fsRead(workspaceRoot))
            lines.append("读取工作区内的任意文件")
        }

        // 写：**按计划声明的路径精确授权**（而不是整个工作区）
        for prefix in dedupePaths(writePrefixes) {
            scopes.append(.fsWrite(prefix))
            lines.append("写入 \(prefix.description)/**")
        }

        // 删除：即使计划里说了，也要单独列出来（破坏性最强）
        for prefix in dedupePaths(deletePrefixes) {
            scopes.append(.fsDelete(prefix))
            lines.append("⚠️ 删除 \(prefix.description)/** 下的文件")
        }

        for runtime in runtimes.sorted(by: { $0.rawValue < $1.rawValue }) {
            scopes.append(.exec(runtime: runtime))
            lines.append("执行 \(runtime.displayName) 脚本")
        }
        for api in nativeAPIs.sorted(by: { $0.rawValue < $1.rawValue }) {
            scopes.append(.native(api))
            lines.append("访问「\(api.displayName)」")
        }
        if wantsGitWrite {
            scopes.append(.gitWrite(remote: nil))
            lines.append("本地 Git 写操作（提交）；**推送仍需单独确认**")
        }

        if wantsNetwork {
            notPreAuthorized.append("网络访问（域名白名单）——需要访问具体域名时再单独确认")
        }
        if plan.risks.contains(where: { $0.isIrreversibleOrNetwork }) {
            notPreAuthorized.append("计划里标注的危险/不可逆操作 —— 每步都会单独确认")
        }

        return CapabilityRequest(
            scopes: scopes,
            summaryLines: lines,
            estimatedCostMicroUSD: plan.estimatedCost.microUSD,
            estimatedSeconds: plan.estimatedCost.estimatedSeconds,
            notPreAuthorized: notPreAuthorized
        )
    }

    private static func dedupePaths(_ paths: [VFSPath]) -> [VFSPath] {
        var result: [VFSPath] = []
        // 已被更宽的前缀覆盖的就不再加（例如同时有 /workspace 与 /workspace/src）
        for path in paths.sorted(by: { $0.components.count < $1.components.count }) {
            if result.contains(where: { path.isWithin($0) }) { continue }
            result.removeAll { $0.isWithin(path) }
            result.append(path)
        }
        return result.sorted()
    }

    private static func runtimeOf(_ tool: String) -> SandboxRuntime {
        switch tool {
        case ToolName.runPython: return .python
        case ToolName.runJavaScript: return .javascript
        case ToolName.runShell: return .shell
        case ToolName.runWasm: return .wasm
        default: return .shell
        }
    }

    private static func nativeAPIsOf(_ tool: String) -> Set<NativeAPI> {
        switch tool {
        case ToolName.photosSearch: return [.photos]
        case ToolName.cameraCapture: return [.camera]
        case ToolName.calendarRead, ToolName.calendarWrite: return [.calendar]
        case ToolName.remindersRead, ToolName.remindersWrite: return [.reminders]
        case ToolName.locationCurrent: return [.location]
        case ToolName.clipboardRead, ToolName.clipboardWrite: return [.clipboard]
        case ToolName.speechTranscribe: return [.speech]
        case ToolName.notifyUser: return [.notifications]
        case ToolName.shortcutsRun: return [.shortcuts]
        default: return []
        }
    }

    // MARK: 偏离检测

    public struct Deviation: Sendable, Equatable {
        public var reason: String
        public var isMajor: Bool
    }

    /// 判断修正后的计划是否需要用户重新确认。
    ///
    /// 规则（docs/04 §3.2）：
    ///   * **重大偏离**（改目标、新增危险网络副作用、成本超预估 150%）→ 必须确认
    ///   * **轻微偏离**（换一个等价的读操作、跳过可选验证）→ 自动继续但留痕
    public static func deviation(
        original: Plan,
        revised: Plan,
        actualCostMicroUSD: Int
    ) -> Deviation? {
        let check = revised.requiresUserConfirmation(comparedTo: original, actualCostMicroUSD: actualCostMicroUSD)
        if check.needed {
            return Deviation(reason: check.reason ?? "计划发生了重大偏离", isMajor: true)
        }
        // 轻微偏离：步骤增减、顺序调整、工具替换
        var notes: [String] = []
        if revised.steps.count != original.steps.count {
            notes.append("步骤数 \(original.steps.count) → \(revised.steps.count)")
        }
        let originalTools = original.requiredTools
        let revisedTools = revised.requiredTools
        if originalTools != revisedTools {
            let added = revisedTools.subtracting(originalTools)
            let removed = originalTools.subtracting(revisedTools)
            if !added.isEmpty { notes.append("新增工具：\(added.sorted().joined(separator: "、"))") }
            if !removed.isEmpty { notes.append("不再使用：\(removed.sorted().joined(separator: "、"))") }
        }
        guard !notes.isEmpty else { return nil }
        return Deviation(reason: notes.joined(separator: "；"), isMajor: false)
    }

    // MARK: 状态推进

    public enum AdvanceError: Error, Sendable, Equatable {
        case stepNotFound(UUID)
        case illegalTransition(from: PlanStep.StepStatus, to: PlanStep.StepStatus)
    }

    /// 推进一个步骤的状态。**带合法性校验**，防止"从 pending 直接跳到 done"这类谎报。
    public static func advance(
        _ plan: inout Plan,
        stepID: UUID,
        to newStatus: PlanStep.StepStatus,
        checkpointID: UUID? = nil
    ) throws {
        guard let index = plan.steps.firstIndex(where: { $0.id == stepID }) else {
            throw AdvanceError.stepNotFound(stepID)
        }
        let current = plan.steps[index].status
        guard isLegal(from: current, to: newStatus) else {
            throw AdvanceError.illegalTransition(from: current, to: newStatus)
        }
        plan.steps[index].status = newStatus
        if let checkpointID { plan.steps[index].checkpointID = checkpointID }
    }

    /// 合法迁移：终态不能再变；pending 不能直接 done（必须先 running）
    static func isLegal(from: PlanStep.StepStatus, to: PlanStep.StepStatus) -> Bool {
        if from.isTerminal && to != from { return false }
        switch (from, to) {
        case (.pending, .running), (.pending, .skipped):
            return true
        case (.running, .done), (.running, .failed), (.running, .skipped), (.running, .amended):
            return true
        case (_, .amended):
            return true      // 计划修正可以发生在任何时刻（记录"这一步被调整过"）
        default:
            return from == to
        }
    }

    /// 当前应该执行哪一步（第一个非终态）
    public static func currentStep(_ plan: Plan) -> PlanStep? {
        plan.steps.first { !$0.status.isTerminal }
    }

    public var summaryPlaceholder: String { "" }
}

// MARK: - 便捷入口

extension PlanEngine {
    /// 给用户看的"批准计划"摘要（UI 直接用）
    public static func approvalSummary(_ plan: Plan, request: CapabilityRequest) -> String {
        var lines: [String] = []
        lines.append(plan.goalSummary)
        if !plan.assumptions.isEmpty {
            lines.append("")
            lines.append("我假设：")
            lines.append(contentsOf: plan.assumptions.map { "· \($0)" })
        }
        lines.append("")
        lines.append("步骤（\(plan.steps.count) 步）：")
        lines.append(contentsOf: plan.steps.enumerated().map { index, step in
            "\(index + 1). [\(step.kind.displayName)] \(step.title)"
        })
        if !request.summaryLines.isEmpty {
            lines.append("")
            lines.append("将获得以下权限：")
            lines.append(contentsOf: request.summaryLines.map { "· \($0)" })
        }
        if !request.notPreAuthorized.isEmpty {
            lines.append("")
            lines.append("仍需逐次确认：")
            lines.append(contentsOf: request.notPreAuthorized.map { "· \($0)" })
        }
        lines.append("")
        lines.append("预计：\(plan.estimatedCost.displayString)")
        return lines.joined(separator: "\n")
    }
}
