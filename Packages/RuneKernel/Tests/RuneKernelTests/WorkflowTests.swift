import Testing
import Foundation
@testable import RuneKernel

// MARK: - 工作流引擎的测试
//
// 这一组守的是 Workflow 存在的理由：**一次性跑一大片互相独立的事**。
// 所以最关键的断言不是"能跑通"，而是"不因为一个失败就丢掉其余全部成果"、
// "阶段之间没有屏障"、"被系统杀掉之后能接着跑"。

private func step(
    _ id: String,
    phase: String = "检查",
    deps: [String] = [],
    order: Int = 0,
    label: String? = nil,
    prompt: String = "干活",
    schema: JSONSchema? = nil
) -> WorkflowStep {
    WorkflowStep(
        id: id, phase: phase, label: label ?? id,
        dependencies: deps, order: order,
        prompt: prompt, outputSchema: schema
    )
}

private func definition(_ steps: [WorkflowStep], name: String = "wf", script: String? = nil) -> WorkflowDefinition {
    WorkflowDefinition(name: name, summary: "", steps: steps, script: script)
}

/// 6 个目标 × 3 个阶段（检查 → 修复 → 验证），链条式依赖
private func pipelineDefinition(count: Int = 6) -> WorkflowDefinition {
    var steps: [WorkflowStep] = []
    for i in 0..<count {
        steps.append(step("check-\(i)", phase: "检查", order: i))
        steps.append(step("fix-\(i)", phase: "修复", deps: ["check-\(i)"], order: count + i))
        steps.append(step("verify-\(i)", phase: "验证", deps: ["fix-\(i)"], order: 2 * count + i))
    }
    return definition(steps)
}

private func boot(_ def: WorkflowDefinition, now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> WorkflowRun {
    var run = WorkflowRun(definition: def, startedAt: now)
    WorkflowEngine.recomputeDepths(&run)
    WorkflowEngine.advance(&run, now: now)
    return run
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func ok(_ result: JSONValue = .object([:]), cost: Int = 0) -> WorkflowEngine.Outcome {
    .success(result: result, costMicroUSD: cost, inputTokens: 100, outputTokens: 20)
}

// MARK: - 调度

@Suite("WorkflowEngine —— DAG 调度与无屏障流水线")

struct WorkflowScheduleTests {

    @Test("只有根步骤一开始就绪")
    func rootsAreReadyFirst() {
        let run = boot(pipelineDefinition(count: 2))
        let ready = run.steps.filter { $0.status == .ready }.map(\.id).sorted()
        #expect(ready == ["check-0", "check-1"])
        #expect(run.steps.filter { $0.status == .pending }.count == 4)
    }

    @Test("并发上限：手机上是 3")
    func concurrencyCap() {
        let run = boot(pipelineDefinition(count: 6))
        let batch = WorkflowEngine.nextBatch(run, limits: .mobile)
        #expect(batch.count == 3)
        // 自定义上限也生效
        var loose = WorkflowEngine.Limits.mobile
        loose.maxConcurrency = 5
        #expect(WorkflowEngine.nextBatch(run, limits: loose).count == 5)
    }

    @Test("⭐ 阶段之间没有屏障：某个 item 的下一阶段优先于其他 item 的第一阶段")
    func pipelineHasNoBarrier() {
        // 这是 pipeline 与"批量 → 批量"最本质的区别。
        // 按书写顺序排会退化成三级屏障；按深度降序排才是真流水线。
        var run = boot(pipelineDefinition(count: 6))
        var first = WorkflowEngine.nextBatch(run, limits: .mobile)
        #expect(first.map(\.id) == ["check-0", "check-1", "check-2"])
        WorkflowEngine.markRunning(first.map(\.id), in: &run, now: t0)

        // item 0 的检查完成 → 它的"修复"就绪，而其余 check 还没跑
        WorkflowEngine.apply(ok(), to: "check-0", in: &run, now: t0)
        let second = WorkflowEngine.nextBatch(run, limits: .mobile)

        // 此时只剩 1 个空位（c1、c2 还在飞）→ 必须把这个空位给更靠下游的 fix-0
        #expect(second.map(\.id) == ["fix-0"], "实际批次：\(second.map(\.id))")
        // 对照：如果按**书写顺序**选（也就是退回成"先把所有检查跑完"），空位会给 check-3
        let readyByOrder = run.steps
            .filter { $0.status == .ready }
            .sorted { $0.order < $1.order }
        #expect(readyByOrder.first?.id == "check-3", "对照组的第一个应当是 check-3")
    }

    @Test("排序完全确定（同一状态两次调度结果一致）")
    func schedulingIsDeterministic() {
        let run = boot(pipelineDefinition(count: 6))
        let a = WorkflowEngine.nextBatch(run, limits: .mobile).map(\.id)
        let b = WorkflowEngine.nextBatch(run, limits: .mobile).map(\.id)
        #expect(a == b)
    }

    @Test("依赖没全部终结之前不会就绪")
    func dependenciesGateReadiness() {
        var run = boot(pipelineDefinition(count: 1))
        #expect(run.step("fix-0")?.status == .pending)
        WorkflowEngine.markRunning(["check-0"], in: &run, now: t0)
        WorkflowEngine.apply(.transient(message: "网络抖动", costMicroUSD: 0), to: "check-0", in: &run, now: t0)
        // 瞬时失败 → 回到 ready，但还没终结 → fix-0 不能就绪
        #expect(run.step("check-0")?.status == .ready)
        #expect(run.step("fix-0")?.status == .pending)
    }

    @Test("跑完就停：终态之后 nextBatch 返回空")
    func noBatchAfterTerminal() {
        var run = boot(pipelineDefinition(count: 1))
        WorkflowEngine.markRunning(["check-0"], in: &run, now: t0)
        WorkflowEngine.apply(ok(), to: "check-0", in: &run, now: t0)
        WorkflowEngine.markRunning(["fix-0"], in: &run, now: t0)
        WorkflowEngine.apply(ok(), to: "fix-0", in: &run, now: t0)
        WorkflowEngine.markRunning(["verify-0"], in: &run, now: t0)
        WorkflowEngine.apply(ok(), to: "verify-0", in: &run, now: t0)

        #expect(run.status == .completed)
        #expect(WorkflowEngine.nextBatch(run, limits: .mobile).isEmpty)
    }
}

// MARK: - 短路

@Suite("WorkflowEngine —— pipeline 的短路语义")

struct WorkflowShortCircuitTests {

    @Test("⭐ 上游返回 null → 本步骤跳过，结果是 null（而不是失败）")
    func shortCircuitSkipsStep() {
        var run = boot(pipelineDefinition(count: 1))
        WorkflowEngine.markRunning(["check-0"], in: &run, now: t0)
        WorkflowEngine.apply(ok(.object(["clean": .bool(true)])), to: "check-0", in: &run, now: t0)

        WorkflowEngine.markRunning(["fix-0"], in: &run, now: t0)
        WorkflowEngine.apply(.shortCircuit, to: "fix-0", in: &run, now: t0)

        #expect(run.step("fix-0")?.status == .skipped)
        #expect(run.step("fix-0")?.result == .null)
        // 下游跟着短路（`prev == null` 一路传下去）
        #expect(run.step("verify-0")?.status == .skipped)
        #expect(run.status == .completed)
        #expect(run.skippedCount == 2)
        #expect(run.failedCount == 0)
    }

    @Test("⚠️ 短路与失败是两件不同的事（用户要能区分）")
    func skippedIsNotFailed() {
        var run = boot(definition([
            step("a", order: 0), step("b", deps: ["a"], order: 1),
        ]))
        WorkflowEngine.markRunning(["a"], in: &run, now: t0)
        WorkflowEngine.apply(.shortCircuit, to: "a", in: &run, now: t0)
        // 短路 → completed（不是 completedWithFailures）
        #expect(run.status == .completed)
        // a 本身 + 被传染的 b
        #expect(run.skippedCount == 2)
        #expect(run.doneCount == 0)
    }

    @Test("汇总里被跳过的项是 null，而不是缺失")
    func aggregationUsesNullForSkipped() {
        var run = boot(pipelineDefinition(count: 1))
        WorkflowEngine.markRunning(["check-0"], in: &run, now: t0)
        WorkflowEngine.apply(ok(.object(["clean": .bool(true)])), to: "check-0", in: &run, now: t0)
        WorkflowEngine.markRunning(["fix-0"], in: &run, now: t0)
        WorkflowEngine.apply(.shortCircuit, to: "fix-0", in: &run, now: t0)

        let totals = run.aggregated.value(at: ["totals"])
        #expect(totals?.value(at: ["skipped"]) == .int(2))
        let fixPhase = run.aggregated.value(at: ["phases", "修复"])
        #expect(fixPhase?.arrayValue?.first == .null)
    }
}

// MARK: - 失败隔离

@Suite("WorkflowEngine —— 一个失败不该丢掉其余全部成果")

struct WorkflowFailureIsolationTests {

    @Test("⭐ 17 项里有一项失败 → 其余 16 项照跑完，终态是「完成但有失败」")
    func oneFailureDoesNotKillTheBatch() {
        var run = boot(pipelineDefinition(count: 6))
        // 把所有 6 个检查跑完，其中 check-2 失败
        var batch = WorkflowEngine.nextBatch(run, limits: .mobile)
        WorkflowEngine.markRunning(batch.map(\.id), in: &run, now: t0)
        for step in batch {
            WorkflowEngine.apply(step.id == "check-2" ? .failure(message: "子代理崩了", costMicroUSD: 0) : ok(),
                                 to: step.id, in: &run, now: t0)
        }
        // 继续跑到终态
        var guardCount = 0
        while run.status == .running, guardCount < 100 {
            let next = WorkflowEngine.nextBatch(run, limits: .mobile)
            guard !next.isEmpty else { break }
            WorkflowEngine.markRunning(next.map(\.id), in: &run, now: t0)
            for step in next { WorkflowEngine.apply(ok(), to: step.id, in: &run, now: t0) }
            guardCount += 1
        }

        #expect(run.status == .completedWithFailures)
        // 其余 5 个 item 真的做完了三个阶段
        #expect(run.doneCount == 5 * 3)
        #expect(run.failedCount >= 1)
    }

    @Test("⚠️ 上游失败 → 下游标「失败」而不是「跳过」（从没做过 ≠ 判断不需要做）")
    func downstreamOfFailureIsFailedNotSkipped() {
        var run = boot(pipelineDefinition(count: 1))
        WorkflowEngine.markRunning(["check-0"], in: &run, now: t0)
        WorkflowEngine.apply(.failure(message: "崩了", costMicroUSD: 0), to: "check-0", in: &run, now: t0)

        #expect(run.step("fix-0")?.status == .failed)
        #expect(run.step("fix-0")?.status != .skipped)
        #expect(run.step("fix-0")?.error?.contains("上游") == true)
        // 而它的下游同样是 failed（一路传下去）
        #expect(run.step("verify-0")?.status == .failed)
    }
}

// MARK: - 重试

@Suite("WorkflowEngine —— 瞬时失败要重试，真失败不重试")

struct WorkflowRetryTests {

    @Test("瞬时失败 → 回到可跑状态，等下一次调度")
    func transientGoesBackToReady() {
        var run = boot(pipelineDefinition(count: 1))
        WorkflowEngine.markRunning(["check-0"], in: &run, now: t0)
        WorkflowEngine.apply(.transient(message: "429 限流", costMicroUSD: 100), to: "check-0", in: &run, now: t0)
        #expect(run.step("check-0")?.status == .ready)
        #expect(run.step("check-0")?.attempts == 1)
        // 花费照样记账（失败的那次也花了钱）
        #expect(run.spentMicroUSD == 100)
    }

    @Test("重试次数用尽 → 失败")
    func attemptsExhausted() {
        var run = boot(pipelineDefinition(count: 1))
        for _ in 0..<3 {
            WorkflowEngine.markRunning(["check-0"], in: &run, now: t0)
            if run.step("check-0")?.status == .running {
                WorkflowEngine.apply(.transient(message: "又抖了", costMicroUSD: 0), to: "check-0", in: &run, now: t0)
            }
            if run.step("check-0")?.status != .ready { break }
        }
        #expect(run.step("check-0")?.status == .failed)
        #expect(run.step("check-0")?.attempts == WorkflowEngine.Limits.mobile.maxAttempts)
    }

    @Test("不可重试的失败直接终结")
    func hardFailureIsFinal() {
        var run = boot(pipelineDefinition(count: 1))
        WorkflowEngine.markRunning(["check-0"], in: &run, now: t0)
        WorkflowEngine.apply(.failure(message: "schema 不符", costMicroUSD: 0), to: "check-0", in: &run, now: t0)
        #expect(run.step("check-0")?.status == .failed)
        #expect(run.step("check-0")?.attempts == 1)
    }
}

// MARK: - 结构化输出校验

@Suite("SchemaValidator —— 形状不对就必须判失败")

struct SchemaValidatorTests {

    private let issueSchema = JSONSchema.object(
        properties: [
            "file": .string(enumValues: nil, minLength: nil, maxLength: nil),
            "line": .integer(minimum: 1, maximum: nil),
            "severity": .string(enumValues: ["error", "warn", "info"], minLength: nil, maxLength: nil),
            "message": .string(enumValues: nil, minLength: nil, maxLength: nil),
        ],
        required: ["file", "severity", "message"],
        additionalProperties: false
    )

    @Test("符合 schema → 通过")
    func validObject() {
        let value = JSONValue.object([
            "file": .string("a.swift"), "line": .int(12),
            "severity": .string("error"), "message": .string("炸了"),
        ])
        #expect(SchemaValidator.validate(value, against: issueSchema))
    }

    @Test("缺必填字段 → 不通过")
    func missingRequired() {
        #expect(!SchemaValidator.validate(.object(["file": .string("a.swift")]), against: issueSchema))
    }

    @Test("多出字段（additionalProperties: false）→ 不通过")
    func extraFieldRejected() {
        let value = JSONValue.object([
            "file": .string("a"), "severity": .string("warn"), "message": .string("m"),
            "extra": .int(1),
        ])
        #expect(!SchemaValidator.validate(value, against: issueSchema))
    }

    @Test("枚举外的值 → 不通过")
    func enumViolation() {
        let value = JSONValue.object([
            "file": .string("a"), "severity": .string("fatal"), "message": .string("m"),
        ])
        #expect(!SchemaValidator.validate(value, against: issueSchema))
    }

    @Test("⚠️ 数值上等于整数的小数要接受（JSON 里 1.0 与 1 是同一个数）")
    func integerAcceptsWholeDoubles() {
        let value = JSONValue.object([
            "file": .string("a"), "line": .double(12.0),
            "severity": .string("info"), "message": .string("m"),
        ])
        #expect(SchemaValidator.validate(value, against: issueSchema))
    }

    @Test("超出范围 → 不通过")
    func rangeViolation() {
        let value = JSONValue.object([
            "file": .string("a"), "line": .int(0),
            "severity": .string("info"), "message": .string("m"),
        ])
        #expect(!SchemaValidator.validate(value, against: issueSchema))
    }

    @Test("数组：元素逐个校验，minItems/maxItems 生效")
    func arrays() {
        let schema = JSONSchema.array(
            items: .object(properties: ["n": .integer(minimum: nil, maximum: nil)],
                           required: ["n"], additionalProperties: false),
            minItems: 1, maxItems: 2
        )
        #expect(SchemaValidator.validate(.array([.object(["n": .int(1)])]), against: schema))
        #expect(!SchemaValidator.validate(.array([]), against: schema))
        #expect(!SchemaValidator.validate(.array([.object(["n": .int(1)]), .object(["n": .int(2)]), .object(["n": .int(3)])]), against: schema))
        #expect(!SchemaValidator.validate(.array([.object(["m": .int(1)])]), against: schema))
    }

    @Test("⭐ 形状不对的子代理返回 → 该步骤判失败，而不是「凑合用」")
    func badShapeFailsTheStep() {
        var run = boot(definition([step("a", order: 0, schema: issueSchema)]))
        WorkflowEngine.markRunning(["a"], in: &run, now: t0)
        // 子代理返回了一个字符串而不是对象
        WorkflowEngine.apply(ok(.string("我觉得没问题")), to: "a", in: &run, now: t0)
        #expect(run.step("a")?.status == .failed)
        #expect(run.step("a")?.error?.contains("schema") == true)
    }
}

// MARK: - 预算与中止

@Suite("WorkflowEngine —— 用户批准的上界不能被悄悄突破")

struct WorkflowBudgetTests {

    @Test("⚠️ 超出运行前批准的成本上界 → 整体中止")
    func costCeilingAborts() {
        var limits = WorkflowEngine.Limits.mobile
        limits.costCeilingMicroUSD = 1_000
        var run = boot(definition([step("a", order: 0), step("b", order: 1)]))
        run.costCeilingMicroUSD = 1_000

        WorkflowEngine.markRunning(["a"], in: &run, now: t0)
        WorkflowEngine.apply(ok(cost: 600), to: "a", in: &run, limits: limits, now: t0)
        #expect(run.status == .running)

        WorkflowEngine.markRunning(["b"], in: &run, now: t0)
        WorkflowEngine.apply(ok(cost: 600), to: "b", in: &run, limits: limits, now: t0)

        #expect(run.status == .aborted)
        #expect(run.notes.contains { $0.contains("上界") })
        #expect(WorkflowEngine.nextBatch(run, limits: limits).isEmpty)
    }

    @Test("花费逐步累计（进度看板要显示它）")
    func spendingAccumulates() {
        var run = boot(definition([step("a", order: 0), step("b", order: 1)]))
        WorkflowEngine.markRunning(["a", "b"], in: &run, now: t0)
        WorkflowEngine.apply(ok(cost: 250), to: "a", in: &run, now: t0)
        WorkflowEngine.apply(ok(cost: 750), to: "b", in: &run, now: t0)
        #expect(run.spentMicroUSD == 1_000)
        #expect(run.step("a")?.costMicroUSD == 250)
        #expect(run.progressLine.contains("$0.00") == true)   // $0.001 四舍五入到 $0.00
    }
}

// MARK: - 动态追加

@Suite("WorkflowEngine —— 脚本运行到一半才决定起几个子代理")

struct WorkflowDynamicTests {

    @Test("追加步骤并重算深度")
    func addStepsRecomputesDepth() {
        var run = boot(definition([step("root", order: 0)]))
        WorkflowEngine.markRunning(["root"], in: &run, now: t0)
        WorkflowEngine.apply(ok(), to: "root", in: &run, now: t0)

        let rejected = WorkflowEngine.addSteps([
            step("child-0", deps: ["root"], order: 1),
            step("child-1", deps: ["root"], order: 2),
            step("grandchild", deps: ["child-0"], order: 3),
        ], to: &run, limits: .mobile, now: t0)

        #expect(rejected.isEmpty)
        #expect(run.step("child-0")?.depth == 1)
        #expect(run.step("grandchild")?.depth == 2)
        // 新加的两个子步骤就绪
        #expect(Set(WorkflowEngine.nextBatch(run, limits: .mobile).map(\.id)) == ["child-0", "child-1"])
    }

    @Test("⚠️ 重复 id 与超出步骤上限都会被拒（防脚本把自己跑成无限 fan-out）")
    func rejectsDuplicatesAndOverflow() {
        var run = boot(definition([step("a", order: 0)]))
        var limits = WorkflowEngine.Limits.mobile
        limits.maxSteps = 3

        let rejected = WorkflowEngine.addSteps([
            step("a", order: 1),           // 重复
            step("b", order: 2),
            step("c", order: 3),
            step("d", order: 4),           // 超上限
        ], to: &run, limits: limits, now: t0)

        #expect(rejected.contains("a"))
        #expect(rejected.contains("d"))
        #expect(run.definition.steps.count <= 3)
        #expect(!run.notes.isEmpty, "被拒的事要如实记下来")
    }
}

// MARK: - 校验

@Suite("WorkflowEngine.validate —— 开跑之前就要拦住")

struct WorkflowValidationTests {

    private func rules(_ def: WorkflowDefinition) -> Set<WorkflowEngine.Issue.Rule> {
        Set(WorkflowEngine.validate(def).map(\.rule))
    }

    @Test("空工作流会被抓到")
    func emptyWorkflow() {
        #expect(rules(definition([])).contains(.emptyWorkflow))
    }

    @Test("重复步骤 id 会被抓到")
    func duplicateStepID() {
        #expect(rules(definition([step("a", order: 0), step("a", order: 1)])).contains(.duplicateStepID))
    }

    @Test("悬空依赖会被抓到")
    func danglingDependency() {
        #expect(rules(definition([step("a", deps: ["不存在"], order: 0)])).contains(.danglingDependency))
    }

    @Test("⭐ 依赖成环会被抓到（有环的话运行会**静默卡死**，那是最难查的一类问题）")
    func cycleDetected() {
        let cyclic = definition([
            step("a", deps: ["b"], order: 0),
            step("b", deps: ["a"], order: 1),
        ])
        let issues = WorkflowEngine.validate(cyclic)
        #expect(issues.contains { $0.rule == .cycle })
        // 报错信息里要能看到环上的步骤，否则用户不知道从哪下手
        let cycle = issues.first { $0.rule == .cycle }
        #expect(cycle?.detail.contains("→") == true, "环上的步骤要写出来：\(cycle?.detail ?? "")")
    }

    @Test("自环也会被抓到")
    func selfCycle() {
        #expect(rules(definition([step("a", deps: ["a"], order: 0)])).contains(.cycle))
    }

    @Test("缺 label 与缺提示词会被抓到")
    func missingLabelAndPrompt() {
        #expect(rules(definition([step("a", order: 0, label: "  ")])).contains(.missingLabel))
        #expect(rules(definition([step("a", order: 0, prompt: "")])).contains(.missingPrompt))
    }

    @Test("步骤数 / 阶段数上限")
    func sizeLimits() {
        let many = definition((0..<250).map { step("s\($0)", order: $0) })
        #expect(rules(many).contains(.tooManySteps))

        let phases = definition((0..<12).map { step("s\($0)", phase: "阶段\($0)", order: $0) })
        #expect(rules(phases).contains(.tooManyPhases))
    }

    @Test("一个大而合规的工作流不报任何问题")
    func cleanWorkflowPasses() {
        let issues = WorkflowEngine.validate(pipelineDefinition(count: 6))
        for issue in issues { Issue.record("\(issue.description)") }
        #expect(issues.isEmpty)
    }
}

// MARK: - 脚本静态检查

@Suite("WorkflowScriptGuard —— 说清它不是安全边界")

struct WorkflowScriptGuardTests {

    @Test("⚠️ 干净脚本不报任何东西")
    func cleanScript() {
        let script = """
        phase("静态检查")
        const results = await parallel(args.targets.map(t => async () => agent(`检查 ${t}`)))
        return { n: results.length }
        """
        #expect(WorkflowScriptGuard.inspect(script).isEmpty)
    }

    @Test("网络能力给出**可执行**的提醒（不是一句「不允许」）")
    func networkToken() {
        let issues = WorkflowScriptGuard.inspect("const r = await fetch('http://x')")
        #expect(issues.count == 1)
        #expect(issues[0].contains("fetch_url"), "要告诉用户正确的做法：\(issues[0])")
    }

    @Test("模块系统 / 动态执行 / 定时器 / 宿主逃逸都能被指出")
    func otherCategories() {
        #expect(WorkflowScriptGuard.inspect("const x = require('fs')").first?.contains("模块系统") == true)
        #expect(WorkflowScriptGuard.inspect("eval('1+1')").first?.contains("动态执行") == true)
        #expect(WorkflowScriptGuard.inspect("setTimeout(f, 100)").first?.contains("检查点") == true)
        #expect(WorkflowScriptGuard.inspect("globalThis.x = 1").first?.contains("宿主全局") == true)
        #expect(WorkflowScriptGuard.inspect("obj.__proto__").first?.contains("宿主全局") == true)
    }

    @Test("暴露的宿主面就是设计里的那 6 个")
    func hostSurface() {
        #expect(WorkflowScriptGuard.hostSurface == ["phase", "log", "args", "agent", "pipeline", "parallel"])
    }

    @Test("工作流校验会把可疑脚本报出来")
    func validationSurfacesScriptIssues() {
        let def = definition([step("a", order: 0)], script: "fetch('http://evil.test')")
        #expect(WorkflowEngine.validate(def).contains { $0.rule == .forbiddenToken })
    }
}

// MARK: - 成本估算

@Suite("WorkflowCostEstimate —— 17 个子代理要花多少钱，必须先说清")

struct WorkflowCostTests {

    @Test("⭐ 上界 > 预期，且按阶段拆分")
    func upperBoundAndBreakdown() {
        let estimate = WorkflowEngine.estimateCost(pipelineDefinition(count: 6))
        #expect(estimate.stepCount == 18)
        #expect(estimate.upperBoundMicroUSD > estimate.expectedMicroUSD)
        #expect(estimate.byPhase.keys.sorted() == ["修复", "检查", "验证"])
        // 三个阶段各 6 个步骤，金额相同
        #expect(Set(estimate.byPhase.values).count == 1)
        // 18 个步骤的上界 = 18 × 单步上界
        #expect(estimate.upperBoundMicroUSD == estimate.byPhase["检查"]! * 3)
    }

    @Test("文案给用户看的是「预计多少、最坏多少」")
    func summaryIsHumanReadable() {
        let estimate = WorkflowEngine.estimateCost(pipelineDefinition(count: 6))
        #expect(estimate.summary.contains("18 个步骤"))
        #expect(estimate.summary.contains("预计 $"))
        #expect(estimate.summary.contains("最坏 $"))
    }

    @Test("价格变了金额跟着变（中转站的自定义价格要能生效）")
    func pricingAffectsEstimate() {
        var cheap = WorkflowCostEstimate.Assumptions()
        cheap.inputPriceMicroUSDPerMillion = 300_000
        cheap.outputPriceMicroUSDPerMillion = 600_000
        let cheapEstimate = WorkflowEngine.estimateCost(pipelineDefinition(count: 6), assumptions: cheap)
        let normalEstimate = WorkflowEngine.estimateCost(pipelineDefinition(count: 6))
        #expect(cheapEstimate.upperBoundMicroUSD < normalEstimate.upperBoundMicroUSD)
    }
}

// MARK: - 进度与可恢复性

@Suite("WorkflowRun —— 进度看板与可恢复性")

struct WorkflowRunTests {

    @Test("进度行包含阶段 / 完成数 / 花费（手机上这行是唯一的进度反馈）")
    func progressLine() {
        var run = boot(pipelineDefinition(count: 6))
        run.currentPhase = "检查"
        run.spentMicroUSD = 120_000
        let line = run.progressLine
        #expect(line.contains("阶段 1/3"))
        #expect(line.contains("0/18 完成"))
        #expect(line.contains("$0.12"))
    }

    @Test("有跳过与失败时会显示（不要藏起来）")
    func progressShowsProblems() {
        var run = boot(pipelineDefinition(count: 6))
        WorkflowEngine.markRunning(["check-0", "check-1"], in: &run, now: t0)
        WorkflowEngine.apply(.shortCircuit, to: "check-0", in: &run, now: t0)
        WorkflowEngine.apply(.failure(message: "崩了", costMicroUSD: 0), to: "check-1", in: &run, now: t0)
        #expect(run.progressLine.contains("跳过"))
        #expect(run.progressLine.contains("失败"))
    }

    @Test("⭐ 状态可序列化往返（被系统杀掉之后要能接着跑）")
    func codableRoundTrip() throws {
        var run = boot(pipelineDefinition(count: 2))
        WorkflowEngine.markRunning(["check-0"], in: &run, now: t0)
        WorkflowEngine.apply(ok(.object(["clean": .bool(false)])), to: "check-0", in: &run, now: t0)

        let data = try JSONEncoder().encode(run)
        let restored = try JSONDecoder().decode(WorkflowRun.self, from: data)
        #expect(restored == run)

        // 从恢复出来的状态继续调度，行为一致
        #expect(WorkflowEngine.nextBatch(restored, limits: .mobile).map(\.id)
                == WorkflowEngine.nextBatch(run, limits: .mobile).map(\.id))
    }

    @Test("⭐ 中断恢复：从持久化状态接着跑，最终结果与不中断一致")
    func resumeMatchesUninterrupted() {
        // 基线：一口气跑完
        func runAll(_ interruptedAfter: Int?) -> WorkflowRun {
            var run = boot(pipelineDefinition(count: 4))
            var completedCycles = 0
            var guardCount = 0
            while run.status == .running, guardCount < 200 {
                if let limit = interruptedAfter, completedCycles >= limit { break }
                let batch = WorkflowEngine.nextBatch(run, limits: .mobile)
                guard !batch.isEmpty else { break }
                WorkflowEngine.markRunning(batch.map(\.id), in: &run, now: t0)
                for step in batch { WorkflowEngine.apply(ok(.object(["ok": .bool(true)])), to: step.id, in: &run, now: t0) }
                completedCycles += 1
                guardCount += 1
            }
            return run
        }

        let baseline = runAll(nil)
        #expect(baseline.status == .completed)

        for cut in 0..<6 {
            var partial = runAll(cut)
            // 模拟被系统杀掉之后恢复：状态就是持久化的那一份
            var guardCount = 0
            while partial.status == .running, guardCount < 200 {
                let batch = WorkflowEngine.nextBatch(partial, limits: .mobile)
                guard !batch.isEmpty else { break }
                WorkflowEngine.markRunning(batch.map(\.id), in: &partial, now: t0)
                for step in batch { WorkflowEngine.apply(ok(.object(["ok": .bool(true)])), to: step.id, in: &partial, now: t0) }
                guardCount += 1
            }
            #expect(partial.status == baseline.status, "在第 \(cut) 轮切断后终态不一致")
            #expect(partial.doneCount == baseline.doneCount, "在第 \(cut) 轮切断后完成数不一致")
            #expect(partial.aggregated == baseline.aggregated, "在第 \(cut) 轮切断后汇总结果不一致")
        }
    }

    @Test("汇总包含每个阶段的结果数组与总计")
    func aggregationShape() {
        var run = boot(pipelineDefinition(count: 1))
        WorkflowEngine.markRunning(["check-0"], in: &run, now: t0)
        WorkflowEngine.apply(ok(.object(["clean": .bool(true)])), to: "check-0", in: &run, now: t0)

        let aggregated = run.aggregated
        #expect(aggregated.value(at: ["totals", "steps"]) == .int(3))
        #expect(aggregated.value(at: ["totals", "done"]) == .int(1))
        let checkPhase = aggregated.value(at: ["phases", "检查"])?.arrayValue
        #expect(checkPhase?.first?.value(at: ["clean"]) == .bool(true))
    }
}



// MARK: - 组合证明：工作流的每个步骤就是一次真实的 Agent Turn
//
// 这是把两块拼起来的那颗螺丝：Workflow 负责"一片独立的事怎么调度"，
// TurnRunner 负责"一件事怎么干完"。若它们拼不上，前面两个模块各自全绿也说明不了什么。

/// 让每个步骤都真的跑一轮 TurnRunner（读一个文件），把结果当结构化输出
final class TurnDrivenSteps: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: JSONValue] = [:]

    func store(_ id: String, _ value: JSONValue) { lock.lock(); results[id] = value; lock.unlock() }
    func load(_ id: String) -> JSONValue? { lock.lock(); defer { lock.unlock() }; return results[id] }
}

private func driveStep(
    _ step: WorkflowStep,
    store: TurnDrivenSteps,
    context: PolicyEngine.Context,
    config: TurnRunner.Config,
    /// 这个文件在不在（用来模拟"某个目标根本不存在"）
    exists: (String) -> Bool = { _ in true }
) -> WorkflowEngine.Outcome {
    // 从提示词里挑出要读的文件（真实实现里这一步是子代理自己想明白的）
    let path = step.prompt
    let files: [String: String] = exists(path)
        ? [ScenarioWorkspace.normalize(path): "内容：\(step.id)"]
        : [:]
    let executor = ScenarioExecutor(ws: ScenarioWorkspace(files: files))
    let script: @Sendable (TurnState) -> [ModelEvent] = { state in
        guard state.round == 0 else { return [] }
        return oneCall("r-\(step.id)", ToolName.readFile, .object(["path": .string(path)]))
    }
    let deps = TurnRunner.Dependencies(
        modelEvents: script, executor: executor,
        policy: PolicyEngine(), policyContext: context,
        now: { t0 }, pathsOfCall: ToolScheduler.defaultPaths
    )
    let (final, _, _) = TurnRunner.run(TurnState(objective: step.label), deps: deps, config: config)

    // ⚠️ 子任务必须**自己证明它做完了**：拿到工具结果才算成功。
    //    只看"Turn 没报错"是不够的 —— 一个什么都没做的 Turn 也是 completed。
    let read = final.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }
        .first { $0.status == .ok }
    guard let read, final.status == .completed else {
        return .failure(message: "子任务没有取得任何工具结果（status=\(final.status.rawValue)）", costMicroUSD: 0)
    }
    let value = JSONValue.object(["path": .string(path), "read": .string(read.summary)])
    store.store(step.id, value)
    return .success(result: value, costMicroUSD: 1_000, inputTokens: 800, outputTokens: 100)
}

@Suite("Workflow × TurnRunner —— 组合起来真的能当批处理用")

struct WorkflowTurnIntegrationTests {

    private let readSchema = JSONSchema.object(
        properties: [
            "path": .string(enumValues: nil, minLength: nil, maxLength: nil),
            "read": .string(enumValues: nil, minLength: nil, maxLength: nil),
        ],
        required: ["path", "read"], additionalProperties: false
    )

    @Test("⭐ 6 个目标各跑一轮真实 Turn，全部完成且结果符合声明的 schema")
    func workflowDrivesRealTurns() {
        let store = TurnDrivenSteps()
        let targets = (0..<6).map { "src/module-\($0).py" }
        let def = definition(targets.enumerated().map { index, path in
            step("task-\(index)", phase: "批处理", order: index, prompt: path, schema: readSchema)
        })
        var run = boot(def)
        let context = Scenario.context()
        let config = TurnRunner.Config(maxRounds: 4, maxToolCalls: 4, toolRegistry: ToolRegistry.byName)

        var guardCount = 0
        while run.status == .running, guardCount < 50 {
            let batch = WorkflowEngine.nextBatch(run, limits: .mobile)
            guard !batch.isEmpty else { break }
            WorkflowEngine.markRunning(batch.map(\.id), in: &run, now: t0)
            for step in batch {
                let outcome = driveStep(step, store: store, context: context, config: config)
                WorkflowEngine.apply(outcome, to: step.id, in: &run, now: t0)
            }
            guardCount += 1
        }

        #expect(run.status == .completed)
        #expect(run.doneCount == 6)
        #expect(run.spentMicroUSD == 6_000)
        // 每个步骤都真的读到了自己的那个文件（不是所有步骤都拿到同一个结果）
        for index in 0..<6 {
            let result = run.step("task-\(index)")?.result
            #expect(result?.value(at: ["path"]) == .string("src/module-\(index).py"))
            #expect(result?.value(at: ["read"]) == .string("内容：task-\(index)"))
        }
    }

    @Test("⚠️ 某项失败不拖累其他项：5/6 成功，用户拿到 5 份成果")
    func partialFailureStillDelivers() {
        let store = TurnDrivenSteps()
        // task-3 的目标文件不存在 → 那一轮 Turn 拿不到工具结果 → 该步骤失败
        let paths = (0..<6).map { $0 == 3 ? "src/definitely-missing.py" : "src/module-\($0).py" }
        let def = definition(paths.enumerated().map { index, path in
            step("task-\(index)", phase: "批处理", order: index, prompt: path, schema: readSchema)
        })
        var run = boot(def)
        let context = Scenario.context()
        let config = TurnRunner.Config(maxRounds: 4, maxToolCalls: 4, toolRegistry: ToolRegistry.byName)

        var guardCount = 0
        while run.status == .running, guardCount < 50 {
            let batch = WorkflowEngine.nextBatch(run, limits: .mobile)
            guard !batch.isEmpty else { break }
            WorkflowEngine.markRunning(batch.map(\.id), in: &run, now: t0)
            for step in batch {
                let outcome = driveStep(
                    step, store: store, context: context, config: config,
                    exists: { $0 != "src/definitely-missing.py" }
                )
                WorkflowEngine.apply(outcome, to: step.id, in: &run, now: t0)
            }
            guardCount += 1
        }

        #expect(run.status == .completedWithFailures)
        #expect(run.doneCount == 5)
        #expect(run.failedCount == 1)
        #expect(run.step("task-3")?.error?.contains("工具结果") == true)
        // 汇总里 5 份成果都在
        let phase = run.aggregated.value(at: ["phases", "批处理"])?.arrayValue ?? []
        #expect(phase.count == 6)
        #expect(phase.filter { $0.value(at: ["read"]) != nil }.count == 5)
    }
}

