import Testing
import Foundation
@testable import RuneKernel

// MARK: - 计划引擎

@Suite("PlanEngine —— 计划校验与翻译")
struct PlanEngineTests {

    private let registry: [String: ToolSpec] = {
        let empty = JSONSchema.object(properties: [:], required: [], additionalProperties: true)
        func spec(_ name: String, _ kinds: Set<CapabilityKind>,
                  risk: ToolSpec.RiskLevel = .safe, approval: ToolSpec.ApprovalPolicy = .never,
                  concurrency: ToolSpec.Concurrency = .parallelSafe) -> ToolSpec {
            ToolSpec(name: name, description: "d", inputSchema: empty, concurrency: concurrency,
                     riskLevel: risk, needsApproval: approval, requirements: kinds)
        }
        return [
            ToolName.readFile: spec(ToolName.readFile, [.fsRead]),
            ToolName.grepSearch: spec(ToolName.grepSearch, [.fsRead]),
            ToolName.glob: spec(ToolName.glob, [.fsRead]),
            ToolName.applyPatch: spec(ToolName.applyPatch, [.fsWrite], risk: .modifying,
                                      approval: .perProject, concurrency: .serialPerPath),
            ToolName.writeFile: spec(ToolName.writeFile, [.fsWrite], risk: .modifying,
                                     approval: .perProject, concurrency: .serialPerPath),
            ToolName.deletePath: spec(ToolName.deletePath, [.fsDelete], risk: .dangerous,
                                      approval: .always, concurrency: .serialPerPath),
            ToolName.runTests: spec(ToolName.runTests, [.exec]),
            ToolName.runPython: spec(ToolName.runPython, [.exec]),
            ToolName.fetchURL: spec(ToolName.fetchURL, [.egress]),
            ToolName.gitCommit: spec(ToolName.gitCommit, [.gitWrite], risk: .modifying,
                                     approval: .always, concurrency: .serialPerPath),
            ToolName.gitPush: spec(ToolName.gitPush, [.gitWrite], risk: .dangerous,
                                   approval: .always, concurrency: .serialPerPath),
            ToolName.photosSearch: spec(ToolName.photosSearch, [.native]),
        ]
    }()

    private func planJSON(
        goal: String = "修复退款测试",
        steps: [JSONValue],
        risks: [JSONValue] = [],
        cost: Int = 120_000
    ) -> JSONValue {
        [
            "goalSummary": .string(goal),
            "assumptions": .array([.string("测试环境可用")]),
            "steps": .array(steps),
            "risks": .array(risks),
            "estimatedCost": .object(["microUSD": .int(cost), "estimatedSeconds": .int(240)]),
        ]
    }

    // MARK: 解析

    @Test("解析完整的计划")
    func parseFull() throws {
        // 有副作用步骤时**必须**列出风险说明，否则会有警告（下面另有一条测试专门验证）
        let json = planJSON(steps: [
            ["title": .string("复现测试"), "kind": .string("verify"), "toolHints": .array([.string(ToolName.runTests)])],
            ["title": .string("改代码"), "kind": .string("write"),
             "toolHints": .array([.string(ToolName.applyPatch)]),
             "pathHints": .array([.string("/workspace/src")])],
        ], risks: [
            ["summary": .string("会修改业务代码"), "severity": .string("modifying"), "isReversible": .bool(true)],
        ])
        let (plan, validation) = try PlanEngine.parse(json, knownTools: Set(registry.keys))
        #expect(plan.goalSummary == "修复退款测试")
        #expect(plan.steps.count == 2)
        #expect(plan.steps[0].kind == .verify)
        #expect(plan.steps[1].pathHints.first?.description == "/workspace/src")
        #expect(plan.assumptions.count == 1)
        #expect(plan.estimatedCost.microUSD == 120_000)
        #expect(validation.isValid)
        #expect(validation.warnings.isEmpty)
    }

    @Test("⚠️ 缺 goalSummary / 缺步骤 → 明确拒绝（不能让空计划下去执行）")
    func parseRejectsIncomplete() {
        #expect(throws: PlanEngine.PlanError.self) {
            try PlanEngine.parse(["steps": .array([["title": .string("x")]])])
        }
        #expect(throws: PlanEngine.PlanError.self) {
            try PlanEngine.parse(["goalSummary": .string("目标"), "steps": .array([])])
        }
        #expect(throws: PlanEngine.PlanError.self) {
            try PlanEngine.parse(.array([]))
        }
    }

    @Test("步骤数上限 20（手机上不能给一个 50 步的计划）")
    func stepLimit() {
        let steps = (0..<25).map { JSONValue.object(["title": .string("步骤 \($0)")]) }
        do {
            _ = try PlanEngine.parse(planJSON(steps: steps))
            Issue.record("应当拒绝超长计划")
        } catch let e as PlanEngine.PlanError {
            #expect(e.modelFacingMessage.contains("25"))
            #expect(e.suggestion?.contains("拆") == true)
        } catch { Issue.record("错误类型不对：\(error)") }
    }

    @Test("未知工具是警告而不是错误（渠道能力可能变化，不该让整个计划作废）")
    func unknownToolIsWarning() throws {
        let json = planJSON(steps: [
            ["title": .string("用不存在的工具"), "toolHints": .array([.string("nonexistent_tool")])],
        ])
        let (plan, validation) = try PlanEngine.parse(json, knownTools: Set(registry.keys))
        #expect(plan.steps.count == 1)
        #expect(validation.isValid, "未知工具不该让计划作废")
        #expect(validation.warnings.contains { $0.contains("nonexistent_tool") })
    }

    @Test("kind 缺失时按 analyze 兜底")
    func kindDefaultsToAnalyze() throws {
        let json = planJSON(steps: [["title": .string("看看")]])
        let (plan, _) = try PlanEngine.parse(json)
        #expect(plan.steps[0].kind == .analyze)
    }

    @Test("⚠️ 有副作用步骤却没写风险说明 → 警告（用户看不到风险就批准了）")
    func sideEffectingWithoutRisksWarns() throws {
        let json = planJSON(steps: [
            ["title": .string("写文件"), "kind": .string("write"),
             "toolHints": .array([.string(ToolName.writeFile)])],
        ])
        let (_, validation) = try PlanEngine.parse(json)
        #expect(validation.warnings.contains { $0.contains("没有列出风险") })

        // 补上风险说明后不再警告
        let withRisks = planJSON(steps: [
            ["title": .string("写文件"), "kind": .string("write"),
             "toolHints": .array([.string(ToolName.writeFile)])],
        ], risks: [["summary": .string("会改文件"), "severity": .string("modifying"), "isReversible": .bool(true)]])
        let (_, v2) = try PlanEngine.parse(withRisks)
        #expect(!v2.warnings.contains { $0.contains("没有列出风险") })
    }

    // MARK: 权限请求（批量授权）

    @Test("⚠️【核心】计划 → 一次性权限请求：按**声明路径**精确授权，而不是整个工作区")
    func capabilityRequestUsesDeclaredPaths() throws {
        let json = planJSON(steps: [
            ["title": .string("探查"), "kind": .string("read"),
             "toolHints": .array([.string(ToolName.grepSearch), .string(ToolName.readFile)])],
            ["title": .string("改 src"), "kind": .string("write"),
             "toolHints": .array([.string(ToolName.applyPatch)]),
             "pathHints": .array([.string("/workspace/src")])],
        ])
        let (plan, _) = try PlanEngine.parse(json)
        let request = PlanEngine.capabilityRequest(for: plan, registry: registry)

        // 读 → 工作区根；写 → 只有 src
        #expect(request.scopes.contains { if case .fsRead(let p) = $0 { return p.isMountRoot } else { return false } })
        let writePrefixes = request.scopes.compactMap { scope -> String? in
            if case .fsWrite(let p) = scope { return p.description } else { return nil }
        }
        #expect(writePrefixes == ["/workspace/src"], "写入范围应当精确到计划声明的路径")
        #expect(request.summaryLines.contains { $0.contains("/workspace/src/**") })
    }

    @Test("⚠️ 未声明路径的写操作 → 退化为整个工作区（并在给用户的说明里如实体现）")
    func writeWithoutPathHintsFallsBackToWorkspace() throws {
        let json = planJSON(steps: [
            ["title": .string("随便改"), "kind": .string("write"),
             "toolHints": .array([.string(ToolName.writeFile)])],
        ])
        let (plan, _) = try PlanEngine.parse(json)
        let request = PlanEngine.capabilityRequest(for: plan, registry: registry)
        let writePrefixes = request.scopes.compactMap { scope -> String? in
            if case .fsWrite(let p) = scope { return p.description } else { return nil }
        }
        #expect(writePrefixes == ["/workspace"])
    }

    @Test("⚠️ 网络出口**不预先授权**（计划阶段模型不知道会访问哪些域名，预授权 = 空白支票）")
    func egressIsNotPreAuthorized() throws {
        let json = planJSON(steps: [
            ["title": .string("查资料"), "kind": .string("network"),
             "toolHints": .array([.string(ToolName.fetchURL)])],
        ])
        let (plan, _) = try PlanEngine.parse(json)
        let request = PlanEngine.capabilityRequest(for: plan, registry: registry)
        #expect(!request.scopes.contains { if case .egress = $0 { return true }; return false })
        #expect(request.notPreAuthorized.contains { $0.contains("网络访问") })
    }

    @Test("删除权限单独列出（破坏性最强，必须在授权清单里显眼）")
    func deleteIsListedSeparately() throws {
        let json = planJSON(steps: [
            ["title": .string("清理构建产物"), "kind": .string("write"),
             "toolHints": .array([.string(ToolName.deletePath)]),
             "pathHints": .array([.string("/workspace/build")])],
        ])
        let (plan, _) = try PlanEngine.parse(json)
        let request = PlanEngine.capabilityRequest(for: plan, registry: registry)
        #expect(request.summaryLines.contains { $0.contains("⚠️") && $0.contains("删除") })
    }

    @Test("运行时会按工具推导（python / shell）；原生能力按工具映射")
    func runtimesAndNativeAPIs() throws {
        let json = planJSON(steps: [
            ["title": .string("跑脚本"), "toolHints": .array([.string(ToolName.runPython)])],
            ["title": .string("看相册"), "toolHints": .array([.string(ToolName.photosSearch)])],
        ])
        let (plan, _) = try PlanEngine.parse(json)
        let request = PlanEngine.capabilityRequest(for: plan, registry: registry)
        #expect(request.scopes.contains { if case .exec(let r) = $0 { return r == .python } else { return false } })
        #expect(request.scopes.contains { if case .native(let a) = $0 { return a == .photos } else { return false } })
    }

    @Test("路径去重：宽前缀覆盖窄前缀")
    func pathDeduplication() throws {
        let json = planJSON(steps: [
            ["title": .string("A"), "toolHints": .array([.string(ToolName.writeFile)]),
             "pathHints": .array([.string("/workspace/src")])],
            ["title": .string("B"), "toolHints": .array([.string(ToolName.writeFile)]),
             "pathHints": .array([.string("/workspace/src/deep")])],
        ])
        let (plan, _) = try PlanEngine.parse(json)
        let request = PlanEngine.capabilityRequest(for: plan, registry: registry)
        let writePrefixes = request.scopes.compactMap { scope -> String? in
            if case .fsWrite(let p) = scope { return p.description } else { return nil }
        }
        #expect(writePrefixes == ["/workspace/src"], "窄前缀应被宽前缀吸收")
    }

    @Test("Git 写权限说明里要写明「推送仍需单独确认」")
    func gitWriteNotesPushStillNeedsConfirmation() throws {
        let json = planJSON(steps: [
            ["title": .string("提交"), "toolHints": .array([.string(ToolName.gitCommit)])],
        ])
        let (plan, _) = try PlanEngine.parse(json)
        let request = PlanEngine.capabilityRequest(for: plan, registry: registry)
        #expect(request.summaryLines.contains { $0.contains("推送仍需单独确认") })
    }

    @Test("批准摘要可读（UI 直接用）")
    func approvalSummaryIsReadable() throws {
        let json = planJSON(
            steps: [
                ["title": .string("复现"), "kind": .string("verify"), "toolHints": .array([.string(ToolName.runTests)])],
                ["title": .string("修"), "kind": .string("write"),
                 "toolHints": .array([.string(ToolName.applyPatch)]),
                 "pathHints": .array([.string("/workspace/src")])],
            ],
            risks: [["summary": .string("会修改业务代码"), "severity": .string("modifying"), "isReversible": .bool(true)]]
        )
        let (plan, _) = try PlanEngine.parse(json)
        let request = PlanEngine.capabilityRequest(for: plan, registry: registry)
        let text = PlanEngine.approvalSummary(plan, request: request)
        #expect(text.contains("修复退款测试"))
        #expect(text.contains("我假设："))
        #expect(text.contains("1. [验证] 复现"))
        #expect(text.contains("将获得以下权限："))
    }

    // MARK: 偏离检测

    @Test("⚠️ 改目标 / 新增危险步骤 / 超支 150% → 重大偏离需要重新确认")
    func majorDeviation() throws {
        let original = Plan(goalSummary: "修测试", steps: [
            PlanStep(title: "改代码", kind: .write, toolHints: [ToolName.applyPatch]),
        ], estimatedCost: CostEstimate(microUSD: 100_000, estimatedSeconds: 60))

        var revised = original
        revised.goalSummary = "顺便重写支付模块"
        let deviation = PlanEngine.deviation(original: original, revised: revised, actualCostMicroUSD: 0)
        #expect(deviation?.isMajor == true)
        #expect(deviation?.reason.contains("目标") == true)
    }

    @Test("轻微偏离（步骤数变化、工具替换）→ 自动继续但留痕")
    func minorDeviation() {
        let original = Plan(goalSummary: "修测试", steps: [
            PlanStep(title: "探查", kind: .read, toolHints: [ToolName.grepSearch]),
            PlanStep(title: "改", kind: .write, toolHints: [ToolName.applyPatch]),
        ])
        var revised = original
        revised.steps[0].toolHints = [ToolName.findSymbol]   // 换了一个等价的读工具
        let deviation = PlanEngine.deviation(original: original, revised: revised, actualCostMicroUSD: 0)
        #expect(deviation?.isMajor == false)
        #expect(deviation?.reason.contains("新增工具") == true)
    }

    @Test("完全没变 → 无偏离")
    func noDeviation() {
        let plan = Plan(goalSummary: "x", steps: [PlanStep(title: "a", kind: .read)])
        #expect(PlanEngine.deviation(original: plan, revised: plan, actualCostMicroUSD: 0) == nil)
    }

    // MARK: 状态推进

    @Test("⚠️ 非法状态迁移被拒绝（不能从 pending 直接跳到 done）")
    func illegalTransitionRejected() throws {
        var plan = Plan(goalSummary: "x", steps: [PlanStep(title: "a", kind: .write)])
        let stepID = plan.steps[0].id

        #expect(throws: PlanEngine.AdvanceError.self) {
            try PlanEngine.advance(&plan, stepID: stepID, to: .done)
        }
        try PlanEngine.advance(&plan, stepID: stepID, to: .running)
        try PlanEngine.advance(&plan, stepID: stepID, to: .done)
        #expect(plan.steps[0].status == .done)
        // 终态不可再变
        #expect(throws: PlanEngine.AdvanceError.self) {
            try PlanEngine.advance(&plan, stepID: stepID, to: .running)
        }
    }

    @Test("currentStep 返回第一个未终态的步骤")
    func currentStep() throws {
        var plan = Plan(goalSummary: "x", steps: [
            PlanStep(title: "a", kind: .read), PlanStep(title: "b", kind: .write),
        ])
        #expect(PlanEngine.currentStep(plan)?.title == "a")
        try PlanEngine.advance(&plan, stepID: plan.steps[0].id, to: .running)
        try PlanEngine.advance(&plan, stepID: plan.steps[0].id, to: .done)
        #expect(PlanEngine.currentStep(plan)?.title == "b")
    }
}

// MARK: - 审批代理

@Suite("ApprovalBroker —— 批量 / 分级 / 记忆 / 失败关闭")
struct ApprovalBrokerTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func call(_ tool: String, path: String? = nil, id: String = UUID().uuidString) -> ToolCall {
        var args: [String: JSONValue] = [:]
        if let path { args["path"] = .string(path) }
        return ToolCall(id: id, name: tool, argumentsJSON: Data(JSONValue.object(args).canonicalString().utf8))
    }

    private func broker(_ config: ApprovalBroker.Config = .default) -> ApprovalBroker {
        ApprovalBroker(config: config)
    }

    // MARK: 提交与批量

    @Test("多个待批项 → 合并成一批展示")
    func batching() {
        var b = broker()
        b.submit(call: call(ToolName.writeFile, path: "/workspace/a.swift"), requirement: .showDetails,
                 risk: .modifying, reason: "写 a", now: base)
        b.submit(call: call(ToolName.writeFile, path: "/workspace/b.swift"), requirement: .showDetails,
                 risk: .modifying, reason: "写 b", now: base.addingTimeInterval(1))

        let batch = b.batch()
        #expect(batch?.count == 2)
        #expect(batch?.headline.contains("2 项") == true)
        #expect(batch?.canApproveAll == true)
        #expect(batch?.requiresBiometric == false)
        #expect(batch?.deferredCount == 0)
    }

    @Test("⚠️ 混合风险 → 标题如实；含不可逆则**不给「全部允许」按钮**")
    func highRiskBatchDisablesApproveAll() {
        var b = broker()
        b.submit(call: call(ToolName.writeFile, path: "/workspace/a.swift"), requirement: .showDetails,
                 risk: .modifying, reason: "写", now: base)
        b.submit(call: call("pay_invoice"), requirement: .biometricPlusPhrase,
                 risk: .irreversible, reason: "付款", now: base)

        let batch = b.batch()
        #expect(batch?.highestRisk == .irreversible)
        #expect(batch?.canApproveAll == false, "含不可逆操作时不能给一键全部允许")
        #expect(batch?.requiresBiometric == true)
    }

    @Test("单批上限：超出的延后（手机上超过 6 项用户就不看了）")
    func batchSizeCap() {
        var b = broker(ApprovalBroker.Config(maxBatchSize: 3))
        for i in 0..<7 {
            b.submit(call: call(ToolName.writeFile, path: "/workspace/f\(i).swift"),
                     requirement: .showDetails, risk: .modifying, reason: "写 \(i)",
                     now: base.addingTimeInterval(Double(i)))
        }
        let batch = b.batch()
        #expect(batch?.count == 3)
        #expect(batch?.deferredCount == 4)
        #expect(b.pendingCount == 7)
    }

    // MARK: 分级与自动允许

    @Test("⚠️「内联允许」到期自动通过；「点击确认」永不自动通过")
    func autoAllowOnlyForInline() {
        var b = broker(ApprovalBroker.Config(inlineAutoAllowDelay: 3, ticketTTL: 300))
        let lowRisk = b.submit(call: call(ToolName.fetchURL), requirement: .inlineAllow,
                               risk: .safe, reason: "读一个公开网页", now: base)
        let needsTap = b.submit(call: call(ToolName.writeFile, path: "/workspace/a.swift"),
                                requirement: .singleTap, risk: .modifying, reason: "写文件", now: base)

        #expect(lowRisk.autoAllowAt != nil)
        #expect(needsTap.autoAllowAt == nil, "「点击确认」及以上必须有人真的点一下")

        // 2 秒后还没到
        #expect(b.tick(now: base.addingTimeInterval(2)).isEmpty)
        // 4 秒后低风险项自动通过
        let changed = b.tick(now: base.addingTimeInterval(4))
        #expect(changed.count == 1)
        #expect(changed[0].id == lowRisk.id)
        #expect(changed[0].state == .autoApproved)
        #expect(changed[0].decidedBy == .autoAllow)
        // 需要点击的那条仍在等待
        #expect(b.ticket(needsTap.id)?.state == .pending)
    }

    @Test("⚠️ 超时 = **拒绝**（失败关闭，绝不能因为用户没看见就默认允许）")
    func timeoutFailsClosed() {
        var b = broker(ApprovalBroker.Config(ticketTTL: 60))
        let ticket = b.submit(call: call(ToolName.gitPush), requirement: .showDetails,
                              risk: .dangerous, reason: "推送到 main", now: base)

        #expect(b.tick(now: base.addingTimeInterval(30)).isEmpty)
        let changed = b.tick(now: base.addingTimeInterval(61))
        #expect(changed.count == 1)
        #expect(changed[0].state == .expired)
        #expect(changed[0].state.isDenial, "超时必须等同拒绝")
        #expect(changed[0].decidedBy == .timeout)
        _ = ticket
    }

    // MARK: 决定

    @Test("批准一次 / 拒绝")
    func approveAndDeny() throws {
        var b = broker()
        let t1 = b.submit(call: call(ToolName.writeFile, path: "/workspace/a.swift"),
                          requirement: .singleTap, risk: .modifying, reason: "写", now: base)
        let t2 = b.submit(call: call(ToolName.deletePath, path: "/workspace/build"),
                          requirement: .showDetails, risk: .dangerous, reason: "删", now: base)

        let approved = try b.decide(t1.id, .approveOnce, now: base)
        #expect(approved.isAllowed)
        #expect(approved.ticket.state == .approved)
        #expect(approved.override == nil, "批准一次不该产生策略覆盖")

        let denied = try b.decide(t2.id, .deny(reason: "先别删"), now: base)
        #expect(!denied.isAllowed)
        #expect(denied.ticket.state == .denied)
    }

    @Test("⚠️ 重复决定被拒绝（不能把已拒绝的又改成允许）")
    func cannotDecideTwice() throws {
        var b = broker()
        let ticket = b.submit(call: call(ToolName.writeFile, path: "/workspace/a.swift"),
                              requirement: .singleTap, risk: .modifying, reason: "写", now: base)
        _ = try b.decide(ticket.id, .deny(reason: nil), now: base)
        #expect(throws: ApprovalBroker.BrokerError.self) {
            try b.decide(ticket.id, .approveOnce, now: base)
        }
    }

    // MARK: 记住选择

    @Test("⚠️「记住这次选择」→ 写回策略，下次自动放行")
    func rememberChoice() throws {
        var b = broker()
        let ticket = b.submit(call: call(ToolName.writeFile, path: "/workspace/src/a.swift"),
                              requirement: .showDetails, risk: .modifying, reason: "写 src", now: base)
        let outcome = try b.decide(ticket.id, .approveAndRemember(expiresIn: 3600), now: base)
        #expect(outcome.override != nil)
        #expect(outcome.override?.scope == .toolInPath(
            tool: ToolName.writeFile,
            prefix: VFSPath(mount: .workspace, components: ["src"])
        ), "应当记住到所在目录，而不是那个具体文件")

        // 同一目录下的另一个文件 → 自动放行
        let second = b.submit(call: call(ToolName.writeFile, path: "/workspace/src/b.swift"),
                              requirement: .showDetails, risk: .modifying, reason: "写 src/b", now: base)
        #expect(second.state == .approved)
        #expect(second.decidedBy == .rememberedPolicy)

        // 别的目录 → 仍然要问
        let third = b.submit(call: call(ToolName.writeFile, path: "/workspace/docs/c.md"),
                             requirement: .showDetails, risk: .modifying, reason: "写 docs", now: base)
        #expect(third.state == .pending)
    }

    @Test("⚠️ 危险/不可逆操作**不允许记住**")
    func dangerousCannotBeRemembered() {
        var b = broker()
        let dangerous = b.submit(call: call(ToolName.gitPush), requirement: .showDetails,
                                 risk: .dangerous, reason: "推送", now: base)
        #expect(!dangerous.isRememberable)
        #expect(throws: ApprovalBroker.BrokerError.self) {
            try b.decide(dangerous.id, .approveAndRemember(expiresIn: nil), now: base)
        }

        let irreversible = b.submit(call: call("pay_invoice"), requirement: .biometricPlusPhrase,
                                    risk: .irreversible, reason: "付款", now: base)
        #expect(!irreversible.isRememberable)
    }

    @Test("记住的策略可以撤销，撤销后重新开始询问")
    func revokeOverride() throws {
        var b = broker()
        let ticket = b.submit(call: call(ToolName.writeFile, path: "/workspace/src/a.swift"),
                              requirement: .showDetails, risk: .modifying, reason: "写", now: base)
        let outcome = try b.decide(ticket.id, .approveAndRemember(expiresIn: nil), now: base)
        let overrideID = outcome.override!.id
        #expect(b.activeOverrides.count == 1)

        let revoked = b.revoke(overrideID, at: base.addingTimeInterval(10))
        #expect(revoked)
        #expect(b.activeOverrides.isEmpty)

        let again = b.submit(call: call(ToolName.writeFile, path: "/workspace/src/z.swift"),
                             requirement: .showDetails, risk: .modifying, reason: "写", now: base.addingTimeInterval(11))
        #expect(again.state == .pending, "撤销后必须重新询问")
    }

    @Test("记住的策略可以过期")
    func overrideExpiry() throws {
        var b = broker()
        let ticket = b.submit(call: call(ToolName.writeFile, path: "/workspace/src/a.swift"),
                              requirement: .showDetails, risk: .modifying, reason: "写", now: base)
        _ = try b.decide(ticket.id, .approveAndRemember(expiresIn: 60), now: base)

        let later = base.addingTimeInterval(120)
        let again = b.submit(call: call(ToolName.writeFile, path: "/workspace/src/q.swift"),
                             requirement: .showDetails, risk: .modifying, reason: "写", now: later)
        #expect(again.state == .pending, "过期的记住项不该再自动放行")
    }

    @Test("⚠️「按工具记住」时，带路径的调用**不能**靠它放行（否则等于全局白名单）")
    func toolWideOverrideDoesNotCoverPaths() throws {
        var b = broker()
        // 一个没有路径的调用 → 记住范围退化为"整个工具"
        let noPath = b.submit(call: call("run_build"), requirement: .singleTap,
                              risk: .modifying, reason: "构建", paths: [], now: base)
        _ = try b.decide(noPath.id, .approveAndRemember(expiresIn: nil), now: base)

        // 随后一个**带路径**的调用命中"按工具记住"的记录 → 按设计不应放行
        let withPath = b.submit(call: call(ToolName.writeFile, path: "/workspace/secret/x"),
                                requirement: .showDetails, risk: .modifying, reason: "写", now: base)
        #expect(withPath.state == .pending)
    }

    // MARK: 批量决定

    @Test("全部允许：逐条校验，任一条不合格则整批不生效")
    func approveAllIsAllOrNothing() throws {
        var b = broker()
        b.submit(call: call(ToolName.writeFile, path: "/workspace/a.swift"), requirement: .showDetails,
                 risk: .modifying, reason: "写 a", now: base)
        b.submit(call: call("pay_invoice"), requirement: .biometricPlusPhrase,
                 risk: .irreversible, reason: "付款", now: base)

        #expect(throws: ApprovalBroker.BrokerError.self) {
            try b.approveAll(now: base)
        }
        // 一条都没被批准
        #expect(b.pendingCount == 2)
    }

    @Test("全部允许：全部合规时一次通过")
    func approveAllSucceeds() throws {
        var b = broker()
        b.submit(call: call(ToolName.writeFile, path: "/workspace/a.swift"), requirement: .showDetails,
                 risk: .modifying, reason: "写 a", now: base)
        b.submit(call: call(ToolName.writeFile, path: "/workspace/b.swift"), requirement: .showDetails,
                 risk: .modifying, reason: "写 b", now: base)
        let outcomes = try b.approveAll(now: base)
        #expect(outcomes.count == 2)
        #expect(outcomes.allSatisfy { $0.isAllowed })
        #expect(outcomes.allSatisfy { $0.ticket.decidedBy == .batchApproval })
        #expect(b.pendingCount == 0)
    }

    @Test("全部拒绝")
    func denyAll() {
        var b = broker()
        for i in 0..<3 {
            b.submit(call: call(ToolName.writeFile, path: "/workspace/f\(i)"),
                     requirement: .showDetails, risk: .modifying, reason: "写", now: base)
        }
        let outcomes = b.denyAll(reason: "先别改", now: base)
        #expect(outcomes.count == 3)
        #expect(outcomes.allSatisfy { !$0.isAllowed })
        #expect(b.pendingCount == 0)
    }

    @Test("空批次不崩")
    func emptyBatch() {
        var b = broker()
        #expect(b.batch() == nil)
        #expect(b.pendingCount == 0)
        #expect(throws: ApprovalBroker.BrokerError.self) { try b.approveAll(now: base) }
        #expect(b.denyAll(reason: nil, now: base).isEmpty)
    }

    @Test("从运行时的审批请求直接提交")
    func submitFromRuntimeRequest() {
        var b = broker()
        let request = TurnRunner.ApprovalRequest(
            call: call(ToolName.gitPush),
            requirement: .biometric,
            reason: "推送到 main",
            risk: .dangerous
        )
        let ticket = b.submit(request, paths: [], now: base)
        #expect(ticket.toolName == ToolName.gitPush)
        #expect(ticket.requirement == .biometric)
        #expect(ticket.risk == .dangerous)
        #expect(b.batch()?.requiresBiometric == true)
    }

    @Test("设置页摘要可读")
    func overrideSummary() throws {
        var b = broker()
        let ticket = b.submit(call: call(ToolName.writeFile, path: "/workspace/src/a.swift"),
                              requirement: .showDetails, risk: .modifying, reason: "写", now: base)
        _ = try b.decide(ticket.id, .approveAndRemember(expiresIn: nil), now: base)
        let summary = b.overrideSummary(at: base)
        #expect(summary.count == 1)
        #expect(summary[0].contains("write_file"))
        #expect(summary[0].contains("/workspace/src"))
    }

    @Test("审批档位自身的语义：可记住 / 会打断")
    func requirementSemantics() {
        #expect(!ApprovalRequirement.none.interrupts)
        #expect(!ApprovalRequirement.inlineAllow.interrupts)
        #expect(ApprovalRequirement.singleTap.interrupts)
        #expect(ApprovalRequirement.showDetails.isRememberable)
        #expect(!ApprovalRequirement.biometricPlusPhrase.isRememberable)
    }
}


