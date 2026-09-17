import Testing
import Foundation
@testable import RuneKernel

// MARK: - 修正性重试的夹具
//
// 这一组测试要守住的东西（docs/04 §4.4）：
//   * 「修正性重试」是**回灌一条精确到能照着改的错误**，不是运行时替模型重发调用
//     （伪造 tool_call 会让整个会话后续请求全部 400）
//   * 同一个根因改不过来时**别再问同一个模型第五遍** —— 停下来给可执行的选项
//   * 逐字重复（参数一字未改）**立刻**止损，不必等计数用完
//   * 「模型改不了」的错误（越权/沙箱/网络）不该记账，否则会把正常的拒绝算成模型无能
//   * 运行时引导语可以提示模型，但**永远不能**伪造成用户授权

// MARK: 工具与执行器

private enum Fix {
    static let editSpec = ToolSpec(
        name: ToolName.editFile,
        description: "改文件",
        inputSchema: .object(
            properties: [
                "path": .string(enumValues: nil, minLength: 1, maxLength: nil),
                "old_string": .string(enumValues: nil, minLength: nil, maxLength: nil),
                "new_string": .string(enumValues: nil, minLength: nil, maxLength: nil),
            ],
            required: ["path", "old_string", "new_string"],
            additionalProperties: false
        ),
        concurrency: .serialPerPath,
        riskLevel: .modifying,
        needsApproval: .never,
        requirements: [.fsRead, .fsWrite]
    )

    static let registry: [String: ToolSpec] = [
        ToolName.editFile: editSpec,
        ToolName.readFile: ToolSpec(
            name: ToolName.readFile, description: "读",
            inputSchema: .object(properties: ["path": .string(enumValues: nil, minLength: nil, maxLength: nil)],
                                 required: ["path"], additionalProperties: false),
            riskLevel: .safe, requirements: [.fsRead]
        ),
        ToolName.gitPush: ToolSpec(
            name: ToolName.gitPush, description: "推送",
            inputSchema: .object(properties: [:], required: [], additionalProperties: true),
            isIdempotent: false, riskLevel: .irreversible,
            needsApproval: .always, requirements: [.gitWrite]
        ),
    ]
}

/// 单次工具调用的一轮模型事件
func oneCall(_ id: String, _ name: String, _ args: JSONValue) -> [ModelEvent] {
    [
        .toolCallStarted(index: 0, id: id, name: name),
        .toolCallArgumentsDelta(index: 0, jsonFragment: args.canonicalString()),
        .usage(TokenUsage(inputTokens: 100, outputTokens: 20)),
        .finished(reason: .toolCalls),
    ]
}

/// 只有 `path` 恰好等于期望值才成功；前 `failUntil` 次一律返回"参数不合法"。
/// 用它模拟"模型前几次参数写错、后来改对了"。
final class PickyExecutor: ToolExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var seen: [ToolCall] = []

    let expectedPath: String
    let failUntil: Int
    let errorKind: ToolError.Kind

    init(expectedPath: String = "src/a.py", failUntil: Int = 0, errorKind: ToolError.Kind = .invalidArguments) {
        self.expectedPath = expectedPath
        self.failUntil = failUntil
        self.errorKind = errorKind
    }

    var executedCalls: [ToolCall] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    func execute(_ call: ToolCall) throws -> ToolResult {
        lock.lock()
        callCount += 1
        seen.append(call)
        let n = callCount
        lock.unlock()

        guard n > failUntil else {
            return .failure(callID: call.id, error: ToolError(
                kind: errorKind,
                modelFacingMessage: "参数 `path` 不合法：`\(call.name)` 需要一个相对路径字符串。",
                suggestion: "`path` 必须是相对于工作区根目录的字符串。",
                candidates: ["path"]
            ))
        }
        return .ok(callID: call.id, summary: "已修改 \(expectedPath)")
    }
}

private extension CorrectionLedger {
    /// 造一次失败的调用 + 结果，直接喂给记账
    static func feed(
        _ ledger: inout CorrectionLedger,
        tool: String = ToolName.editFile,
        args: String,
        kind: ToolError.Kind = .invalidArguments,
        suggestion: String? = "换成正确的相对路径",
        candidates: [String] = []
    ) -> Correction.Decision {
        let call = ToolCall(id: UUID().uuidString, name: tool, argumentsJSON: Data(args.utf8))
        let error = ToolError(
            kind: kind,
            modelFacingMessage: "\(tool) 出错了",
            suggestion: suggestion,
            candidates: candidates
        )
        return ledger.record(
            call: call,
            result: .failure(callID: call.id, error: error),
            spec: Fix.registry[tool],
            limits: .init(maxSelfCorrections: 2, maxConsecutiveFailures: 5)
        )
    }

    static func feedSuccess(_ ledger: inout CorrectionLedger, tool: String = ToolName.editFile, args: String = "{}") -> Correction.Decision {
        let call = ToolCall(id: UUID().uuidString, name: tool, argumentsJSON: Data(args.utf8))
        return ledger.record(
            call: call,
            result: .ok(callID: call.id, summary: "好了"),
            spec: Fix.registry[tool],
            limits: .init(maxSelfCorrections: 2, maxConsecutiveFailures: 5)
        )
    }
}

// MARK: - 记账与判定

@Suite("修正性重试 —— 记账与止损")

struct CorrectionLedgerTests {

    @Test("第一次可修正错误：允许重试，且不是最后一次")
    func firstAttemptAllowed() {
        var ledger = CorrectionLedger()
        let decision = CorrectionLedger.feed(&ledger, args: #"{"path":"a.py"}"#)
        guard case .allowRetry(let used, let limit, let isFinal, let nudge) = decision else {
            Issue.record("应当是 allowRetry，实际 \(decision)")
            return
        }
        #expect(used == 1)
        #expect(limit == 2)
        #expect(!isFinal)
        #expect(nudge == nil)
    }

    @Test("⚠️ 最后一次机会：必须额外给一条「这是最后一次」的强提示")
    func finalAllowanceCarriesNudge() {
        var ledger = CorrectionLedger()
        _ = CorrectionLedger.feed(&ledger, args: #"{"path":"a.py"}"#)
        let decision = CorrectionLedger.feed(&ledger, args: #"{"path":"b.py"}"#)
        guard case .allowRetry(let used, _, let isFinal, let nudge) = decision else {
            Issue.record("应当是 allowRetry，实际 \(decision)")
            return
        }
        #expect(used == 2)
        #expect(isFinal)
        let text = nudge ?? ""
        #expect(text.contains("最后一次"))
        // 强提示里要带上**确定的** schema 信息，而不是又一句"请检查参数"
        #expect(text.contains("`old_string`"))
        #expect(text.contains("必填"))
    }

    @Test("⚠️ 第三次同样的错误：不再问模型，而是停下来上报")
    func exhaustedEscalates() {
        var ledger = CorrectionLedger()
        _ = CorrectionLedger.feed(&ledger, args: #"{"path":"a.py"}"#)
        _ = CorrectionLedger.feed(&ledger, args: #"{"path":"b.py"}"#)
        let decision = CorrectionLedger.feed(&ledger, args: #"{"path":"c.py"}"#)
        guard case .escalate(let escalation) = decision else {
            Issue.record("应当是 escalate，实际 \(decision)")
            return
        }
        #expect(escalation.cause == .correctionsExhausted)
        #expect(escalation.toolName == ToolName.editFile)
        #expect(escalation.failureCount == 3)
        #expect(ledger.needsUserDecision)
    }

    @Test("⚠️ 任何卡死都必须有「换方案」和「停下」两条出口")
    func everyEscalationHasExit() {
        var ledger = CorrectionLedger()
        _ = CorrectionLedger.feed(&ledger, args: #"{"path":"a.py"}"#)
        _ = CorrectionLedger.feed(&ledger, args: #"{"path":"b.py"}"#)
        let decision = CorrectionLedger.feed(&ledger, args: #"{"path":"c.py"}"#)
        guard case .escalate(let escalation) = decision else {
            Issue.record("应当上报，实际 \(decision)")
            return
        }
        #expect(ledger.lastEscalation == escalation)
        let actions = Set(escalation.options.map(\.action))
        #expect(actions.contains(.changeApproach))
        #expect(actions.contains(.stop))
        // 「换方案」必须明确禁止继续微调 —— 否则模型会换个说法再试一遍同样的东西
        let change = escalation.options.first { $0.action == .changeApproach }
        #expect(change?.nudgeText?.contains("不要再在原参数上微调") == true)
    }

    @Test("⚠️ 逐字重复：参数一字未改又发一遍 → 立刻止损，不等计数用完")
    func verbatimRepeatEscalatesImmediately() {
        var ledger = CorrectionLedger()
        let same = #"{"path":"a.py","old_string":"x","new_string":"y"}"#
        let first = CorrectionLedger.feed(&ledger, args: same)
        if case .allowRetry = first {} else { Issue.record("第一次不该熔断") }

        let second = CorrectionLedger.feed(&ledger, args: same)
        guard case .escalate(let escalation) = second else {
            Issue.record("逐字重复应当立刻上报，实际 \(second)")
            return
        }
        #expect(escalation.cause == .verbatimRepeat)
        #expect(escalation.headline.contains("一字未改"))
    }

    @Test("⚠️ 参数键序不同但语义相同，仍算逐字重复（走规范化 JSON）")
    func verbatimIgnoresKeyOrder() {
        var ledger = CorrectionLedger()
        _ = CorrectionLedger.feed(&ledger, args: #"{"path":"a.py","old_string":"x"}"#)
        let decision = CorrectionLedger.feed(&ledger, args: #"{"old_string":"x","path":"a.py"}"#)
        guard case .escalate(let escalation) = decision else {
            Issue.record("键序不同不该被当成新错误，实际 \(decision)")
            return
        }
        #expect(escalation.cause == .verbatimRepeat)
    }

    @Test("参数变了就不算逐字重复")
    func changedArgumentsNotVerbatim() {
        var ledger = CorrectionLedger()
        _ = CorrectionLedger.feed(&ledger, args: #"{"path":"a.py"}"#)
        let decision = CorrectionLedger.feed(&ledger, args: #"{"path":"b.py"}"#)
        if case .allowRetry = decision {} else { Issue.record("换了参数应当是正常的第二次修正，实际 \(decision)") }
    }

    @Test("⚠️ 不同工具名的幻觉各自计数，不互相拖累")
    func differentHallucinatedNamesCountSeparately() {
        var ledger = CorrectionLedger()
        let a = CorrectionLedger.feed(&ledger, tool: "read_files", args: #"{"path":"a.py"}"#, kind: .unknownTool, suggestion: "你是不是想用 read_file？", candidates: ["read_file"])
        let b = CorrectionLedger.feed(&ledger, tool: "ls_dir", args: #"{"path":"a.py"}"#, kind: .unknownTool, suggestion: "你是不是想用 list_dir？", candidates: ["list_dir"])
        let c = CorrectionLedger.feed(&ledger, tool: "cat_file", args: #"{"path":"a.py"}"#, kind: .unknownTool, suggestion: "你是不是想用 read_file？", candidates: ["read_file"])
        for decision in [a, b, c] {
            if case .allowRetry = decision {} else {
                Issue.record("每次都是不熟工具表，不该熔断，实际 \(decision)")
            }
        }
    }

    @Test("⚠️ 同一个瞎编的名字出现三次 → 那是真的改不过来")
    func sameHallucinatedNameExhausts() {
        var ledger = CorrectionLedger()
        _ = CorrectionLedger.feed(&ledger, tool: "read_files", args: #"{"path":"a.py"}"#, kind: .unknownTool, candidates: ["read_file"])
        _ = CorrectionLedger.feed(&ledger, tool: "read_files", args: #"{"path":"b.py"}"#, kind: .unknownTool, candidates: ["read_file"])
        let decision = CorrectionLedger.feed(&ledger, tool: "read_files", args: #"{"path":"c.py"}"#, kind: .unknownTool, candidates: ["read_file"])
        guard case .escalate(let escalation) = decision else {
            Issue.record("应当熔断，实际 \(decision)")
            return
        }
        #expect(escalation.cause == .correctionsExhausted)
    }

    @Test("成功会清零连续失败，重新给满额度")
    func successResetsEverything() {
        var ledger = CorrectionLedger()
        _ = CorrectionLedger.feed(&ledger, args: #"{"path":"a.py"}"#)
        let recovered = CorrectionLedger.feedSuccess(&ledger)
        #expect(recovered == .progress(isRecovery: true))
        #expect(ledger.recoveredCount == 1)

        let again = CorrectionLedger.feed(&ledger, args: #"{"path":"d.py"}"#)
        guard case .allowRetry(let used, _, _, _) = again else {
            Issue.record("成功之后应当重新从第 1 次算，实际 \(again)")
            return
        }
        #expect(used == 1)
    }

    @Test("成功但之前没失败 → 不算「自行修正」")
    func plainSuccessIsNotRecovery() {
        var ledger = CorrectionLedger()
        #expect(CorrectionLedger.feedSuccess(&ledger) == .progress(isRecovery: false))
        #expect(ledger.recoveredCount == 0)
        #expect(ledger.summaryLine == nil)
    }

    @Test("⚠️ 模型改不了的错误（越权/沙箱/网络）不记账")
    func notCorrectableDoesNotCount() {
        var ledger = CorrectionLedger()
        for i in 0..<8 {
            let decision = CorrectionLedger.feed(&ledger, args: #"{"path":"p\#(i).py"}"#, kind: .capabilityDenied, suggestion: nil)
            #expect(decision == .notCorrectable(kind: .capabilityDenied))
        }
        // 没熔断，也没污染连续失败计数
        #expect(ledger.consecutiveFailures == 0)
        #expect(!ledger.needsUserDecision)
    }

    @Test("⚠️ 但越权调用被原样重发 → 仍然要停下来（它没在听）")
    func repeatedDeniedCallStillStops() {
        var ledger = CorrectionLedger()
        let same = #"{"path":"/etc/passwd"}"#
        _ = CorrectionLedger.feed(&ledger, args: same, kind: .capabilityDenied, suggestion: nil)
        let decision = CorrectionLedger.feed(&ledger, args: same, kind: .capabilityDenied, suggestion: nil)
        guard case .escalate(let escalation) = decision else {
            Issue.record("明知会被拒还原样重发，应当停下来，实际 \(decision)")
            return
        }
        #expect(escalation.cause == .verbatimRepeat)
    }

    @Test("⚠️ 输出过大不是失败，不该算成模型无能")
    func outputTooLargeIsAPointer() {
        var ledger = CorrectionLedger()
        for i in 0..<4 {
            let decision = CorrectionLedger.feed(&ledger, args: #"{"path":"大文件\#(i).txt"}"#, kind: .outputTooLarge, suggestion: nil)
            guard case .pointer(let hint) = decision else {
                Issue.record("应当是 pointer，实际 \(decision)")
                return
            }
            #expect(hint.contains("read_artifact"))
        }
        #expect(ledger.consecutiveFailures == 0)
        #expect(ledger.recoveredCount == 0)
    }

    @Test("⚠️ 乱试检测：连续多次失败但根因各不相同 → 也要停")
    func thrashingDetected() {
        var ledger = CorrectionLedger()
        let tools = ["t1", "t2", "t3", "t4"]
        for tool in tools {
            _ = CorrectionLedger.feed(&ledger, tool: tool, args: #"{"path":"a.py"}"#, kind: .pathNotFound)
        }
        let decision = CorrectionLedger.feed(&ledger, tool: "t5", args: #"{"path":"a.py"}"#, kind: .pathNotFound)
        guard case .escalate(let escalation) = decision else {
            Issue.record("连续 5 次不同根因的失败应当上报，实际 \(decision)")
            return
        }
        #expect(escalation.cause == .thrashing)
        #expect(escalation.detail.contains("t5"))
    }

    @Test("中间成功一次，就不算乱试")
    func successBreaksThrashing() {
        var ledger = CorrectionLedger()
        for tool in ["t1", "t2"] { _ = CorrectionLedger.feed(&ledger, tool: tool, args: #"{"path":"a.py"}"#, kind: .pathNotFound) }
        _ = CorrectionLedger.feedSuccess(&ledger, tool: "t2")
        for tool in ["t3", "t4"] { _ = CorrectionLedger.feed(&ledger, tool: tool, args: #"{"path":"a.py"}"#, kind: .pathNotFound) }
        #expect(ledger.consecutiveFailures == 2)
        #expect(!ledger.needsUserDecision)
    }

    @Test("⚠️ 用户点了「继续」= 重新开一份额度，而不是立刻再熔断")
    func clearEscalationReopensAllowance() {
        var ledger = CorrectionLedger()
        _ = CorrectionLedger.feed(&ledger, args: #"{"path":"a.py"}"#)
        _ = CorrectionLedger.feed(&ledger, args: #"{"path":"b.py"}"#)
        _ = CorrectionLedger.feed(&ledger, args: #"{"path":"c.py"}"#)
        #expect(ledger.needsUserDecision)

        ledger.clearEscalation()
        #expect(!ledger.needsUserDecision)

        let decision = CorrectionLedger.feed(&ledger, args: #"{"path":"d.py"}"#)
        guard case .allowRetry(let used, _, _, _) = decision else {
            Issue.record("用户选择继续后应当重新有额度，实际 \(decision)")
            return
        }
        #expect(used == 1)
    }

    @Test("用户转向 = 新情况，清掉旧账")
    func newDirectionResetsLedger() {
        var ledger = CorrectionLedger()
        _ = CorrectionLedger.feed(&ledger, args: #"{"path":"a.py"}"#)
        _ = CorrectionLedger.feed(&ledger, args: #"{"path":"b.py"}"#)
        ledger.resetForNewDirection()
        #expect(ledger.consecutiveFailures == 0)
        #expect(ledger.attempts.isEmpty)
        guard case .allowRetry(let used, _, _, _) = CorrectionLedger.feed(&ledger, args: #"{"path":"c.py"}"#) else {
            Issue.record("清账后应当是第一次")
            return
        }
        #expect(used == 1)
    }

    @Test("⚠️ 记账有上限：长任务里不能让持久化状态无限膨胀")
    func trackedRootsAreBounded() {
        var ledger = CorrectionLedger()
        let limits = Correction.Limits(maxTrackedRoots: 4)
        for i in 0..<40 {
            let call = ToolCall(id: "c\(i)", name: "tool\(i)", argumentsJSON: Data(#"{"path":"a.py"}"#.utf8))
            _ = ledger.record(
                call: call,
                result: .failure(callID: call.id, error: ToolError(kind: .pathNotFound, modelFacingMessage: "没了")),
                spec: nil,
                limits: limits
            )
        }
        #expect(ledger.attempts.count <= 4)
        #expect(ledger.recentFailures.count <= 8)
    }

    @Test("统计文案：只在真有事可说时才出现")
    func summaryLineOnlyWhenMeaningful() {
        var ledger = CorrectionLedger()
        #expect(ledger.summaryLine == nil)
        _ = CorrectionLedger.feed(&ledger, args: #"{"path":"a.py"}"#)
        _ = CorrectionLedger.feedSuccess(&ledger)
        #expect(ledger.summaryLine?.contains("已自动修正 1 次") == true)
    }
}

// MARK: - 选项内容

@Suite("修正性重试 —— 选项必须「可执行」，而不是一句解释")

struct CorrectionOptionTests {

    @Test("⚠️ 工具名幻觉：给出正确名字，并明确要求沿用原参数")
    func unknownToolOptionNamesTheRightTool() {
        let attempt = CorrectionLedger.Attempt(
            key: "unknownTool:read_files",
            errorKind: .unknownTool,
            toolName: "read_files",
            count: 1,
            lastMessage: "没有这个工具",
            lastSuggestion: "你是不是想用 `read_file`？",
            lastCandidates: ["read_file"],
            lastArgumentsFingerprint: "x",
            repeatedVerbatim: 0,
            didEscalate: false
        )
        let options = Correction.options(for: attempt, spec: Fix.registry[ToolName.readFile], cause: .correctionsExhausted)
        let nudge = options.first { $0.action == .nudge }
        #expect(nudge != nil)
        #expect(nudge?.title.contains("read_file") == true)
        // 「参数沿用你刚才给的那一份」这句是关键：模型常常改对了名字又把参数改坏
        #expect(nudge?.nudgeText?.contains("参数沿用") == true)
    }

    @Test("⚠️ 参数不合法：把 schema 签名原样再摆一遍（确定的信息，不是猜的）")
    func invalidArgumentsOptionRestatesSchema() {
        let attempt = CorrectionLedger.Attempt(
            key: "invalidArguments:edit_file",
            errorKind: .invalidArguments,
            toolName: ToolName.editFile,
            count: 2,
            lastMessage: "参数不合法",
            lastSuggestion: nil,
            lastCandidates: ["path"],
            lastArgumentsFingerprint: "x",
            repeatedVerbatim: 0,
            didEscalate: false
        )
        let options = Correction.options(for: attempt, spec: Fix.editSpec, cause: .correctionsExhausted)
        let nudge = options.first { $0.action == .nudge }
        let text = nudge?.nudgeText ?? ""
        #expect(text.contains("`path`"))
        #expect(text.contains("`old_string`"))
        #expect(text.contains("必填"))
        #expect(text.contains("请**只改正参数**"))
        // 还要给"我自己告诉你"这条出口
        #expect(options.contains { $0.action == .askUser })
    }

    @Test("路径不存在：给出相似路径候选，并给出「先列目录」这条路")
    func pathNotFoundOptionOffersCandidates() {
        let attempt = CorrectionLedger.Attempt(
            key: "pathNotFound:read_file",
            errorKind: .pathNotFound,
            toolName: ToolName.readFile,
            count: 2,
            lastMessage: "文件不存在",
            lastSuggestion: nil,
            lastCandidates: ["src/a.py", "src/b.py"],
            lastArgumentsFingerprint: "x",
            repeatedVerbatim: 0,
            didEscalate: false
        )
        let options = Correction.options(for: attempt, spec: Fix.registry[ToolName.readFile], cause: .correctionsExhausted)
        #expect(options.contains { $0.title.contains("src/a.py") })
        #expect(options.contains { $0.nudgeText?.contains("list_dir") == true })
    }

    @Test("schema 签名能读：把 JSONSchema 压成一行参数清单")
    func schemaSignature() {
        let sig = Correction.signature(of: Fix.editSpec)
        #expect(sig.contains("`path`：字符串（必填）"))
        #expect(sig.contains("（选填）") == false)  // edit_file 三个参数全是必填

        let enumSig = Correction.signature(of: .string(enumValues: ["replace", "append"], minLength: nil, maxLength: nil))
        // 非对象 schema 没有参数清单
        #expect(enumSig.isEmpty)

        let objSchema = JSONSchema.object(
            properties: ["mode": .string(enumValues: ["replace", "append"], minLength: nil, maxLength: nil)],
            required: [],
            additionalProperties: false
        )
        let objSig = Correction.signature(of: objSchema)
        #expect(objSig.contains("replace / append"))
        #expect(objSig.contains("选填"))
    }

    @Test("用户直接补参数之后注入的引导语")
    func userSuppliedNudge() {
        let text = Correction.userSuppliedNudge(field: "path", value: "src/内部/配置.json", toolName: ToolName.readFile)
        #expect(text.contains("src/内部/配置.json"))
        #expect(text.contains(ToolName.readFile))
    }
}

// MARK: - 回灌成品

@Suite("修正性重试 —— 回灌内容")

struct CorrectionDeliveryTests {

    @Test("⚠️ 提示必须挂进工具结果正文（那是唯一合法的插入位置）")
    func nudgeMergedIntoSummary() {
        let original = ToolResult.failure(callID: "c1", error: ToolError(
            kind: .invalidArguments, modelFacingMessage: "参数不对", suggestion: "看看 schema"
        ))
        let decision = Correction.Decision.allowRetry(used: 2, limit: 2, isFinalAllowance: true, nudge: "⚠️ 这是最后一次机会。")
        let delivered = Correction.delivered(original, decision: decision)

        #expect(delivered.summary.contains("参数不对"))
        #expect(delivered.summary.contains("看看 schema"))
        #expect(delivered.summary.contains("最后一次机会"))
        // 其他字段一个都不能变（callID 变了会让协议配对失败）
        #expect(delivered.callID == original.callID)
        #expect(delivered.status == original.status)
        #expect(delivered.error == original.error)
    }

    @Test("不该改的时候一个字都不改")
    func untouchedWhenNothingToSay() {
        let original = ToolResult.ok(callID: "c1", summary: "好了")
        #expect(Correction.delivered(original, decision: .progress(isRecovery: true)) == original)
        #expect(Correction.delivered(original, decision: .notCorrectable(kind: .capabilityDenied)) == original)
        #expect(Correction.delivered(original, decision: .allowRetry(used: 1, limit: 2, isFinalAllowance: false, nudge: nil)) == original)
    }

    @Test("输出过大时把「去哪儿读」说清楚")
    func pointerHintDelivered() {
        let original = ToolResult(callID: "c1", status: .truncated, summary: "输出过大")
        let delivered = Correction.delivered(original, decision: .pointer(hint: "请用 read_artifact 读 `artifacts/1.txt`"))
        #expect(delivered.summary.contains("read_artifact"))
    }
}

// MARK: - 信任级

@Suite("运行时引导语 —— 提权防线")

struct RuntimeGuidanceTrustTests {

    @Test("⚠️ 运行时写的话不是用户指令，也不能驱动危险动作")
    func runtimeGuidanceCannotImpersonateTheUser() {
        let level = TrustLevel.runtimeGuidance
        #expect(!level.isInstruction)
        #expect(!level.isTainted)
        // 这一条是防线本身：如果它返回 true，运行时就能伪造用户授权去推送/外发/删除
        #expect(!level.canDriveDangerousAction)
        #expect(level.boundaryTag == "runtime")
    }

    @Test("对照：用户指令与项目指令仍然是可执行指令")
    func userAndProjectRemainInstructions() {
        #expect(TrustLevel.userInstruction.isInstruction)
        #expect(TrustLevel.userInstruction.canDriveDangerousAction)
        #expect(TrustLevel.projectInstruction.isInstruction)
        #expect(!TrustLevel.untrustedContent.canDriveDangerousAction)
    }
}

// MARK: - 与 Turn 循环的集成

/// 允许整个 workspace 写、exec、git 的上下文
private func fullContext() -> PolicyEngine.Context {
    let scope = VFSPath(mount: .workspace)
    let token = CapabilityToken(
        issuedForTurn: UUID(),
        scopes: [.fsRead(scope), .fsWrite(scope), .exec(runtime: .python), .gitWrite(remote: nil)],
        expiresAt: Date().addingTimeInterval(3600),
        grantedBy: .planApproval,
        reason: "测试"
    )
    return PolicyEngine.Context(trustDial: .collaborate, token: token, planApproved: true)
}

private func deps(
    _ executor: any ToolExecuting,
    script: @escaping @Sendable (TurnState) -> [ModelEvent]
) -> TurnRunner.Dependencies {
    TurnRunner.Dependencies(
        modelEvents: script,
        executor: executor,
        policy: PolicyEngine(),
        policyContext: fullContext(),
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
}

private let fixConfig = TurnRunner.Config(
    maxRounds: 12, maxToolCalls: 40, maxSelfCorrections: 2, toolRegistry: Fix.registry
)

@Suite("TurnRunner × 修正性重试")

struct CorrectionRunnerTests {

    /// 模型每次都发**参数不同**的坏调用（避免命中逐字重复）
    private func alwaysBadScript() -> @Sendable (TurnState) -> [ModelEvent] {
        { state in oneCall("call-\(state.round)", ToolName.editFile, .object([
            "path": .string("wrong-\(state.round).py"),
            "old_string": .string("x"),
            "new_string": .string("y"),
        ])) }
    }

    @Test("⚠️ 模型改不过来时：Turn 必须**停下来问用户**，而不是继续烧 token")
    func escalatesInsteadOfLooping() {
        let executor = PickyExecutor(failUntil: 99)
        let script = alwaysBadScript()
        var state = TurnState(objective: "改文件")

        var escalations = 0
        for _ in 0..<20 {
            let outcome = TurnRunner.step(state, deps: deps(executor, script: script), config: fixConfig)
            state = outcome.state
            if let escalation = outcome.pendingCorrection {
                escalations += 1
                #expect(escalation.cause == .correctionsExhausted)
                #expect(!escalation.options.isEmpty)
            }
            if !state.canAdvance { break }
        }

        #expect(escalations == 1)
        #expect(state.status == .awaitingUser)
        // 只跑了 3 次工具调用就停下 —— 而不是把 maxToolCalls(40) 全烧完
        #expect(state.toolCallCount == 3)
        #expect(state.corrections.needsUserDecision)
    }

    @Test("⚠️ 模型自己改对了：要记账，并且给用户一个「它在自己修」的信号")
    func recoveryIsRecorded() {
        let executor = PickyExecutor(failUntil: 2)
        // 前 3 轮各发一次参数不同的坏调用（第 3 次会成功），第 4 轮不再调工具 → 正常收尾
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            guard state.round < 3 else {
                return [.textDelta("改好了"), .usage(TokenUsage(inputTokens: 50, outputTokens: 10)), .finished(reason: .stop)]
            }
            return oneCall("call-\(state.round)", ToolName.editFile, .object([
                "path": .string("wrong-\(state.round).py"),
                "old_string": .string("x"),
                "new_string": .string("y"),
            ]))
        }
        let (final, events, _) = TurnRunner.run(
            TurnState(objective: "改文件"),
            deps: deps(executor, script: script),
            config: fixConfig
        )
        #expect(final.corrections.recoveredCount == 1)
        #expect(final.status == .completed)
        #expect(events.contains { $0.kind == .modelSelfCorrected })
        #expect(final.corrections.summaryLine?.contains("已自动修正 1 次") == true)
    }

    @Test("⚠️ 最后一次机会的强提示必须真的出现在发给模型的工具结果里")
    func finalNudgeReachesTheModel() {
        let executor = PickyExecutor(failUntil: 99)
        let script = alwaysBadScript()
        var state = TurnState(objective: "改文件")
        for _ in 0..<20 {
            state = TurnRunner.step(state, deps: deps(executor, script: script), config: fixConfig).state
            if !state.canAdvance { break }
        }
        // 找第 2 个工具结果（第二次失败 = 最后一次机会）
        let results = state.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }
        #expect(results.count == 3)
        let second = results[1].summary
        #expect(second.contains("最后一次"))
        #expect(results[0].summary.contains("最后一次") == false)
    }

    @Test("⚠️ 用户的选择必须走状态机落成事件（否则上下文里会出现「没人说过的话」）")
    func resolveIsEventSourced() {
        let executor = PickyExecutor(failUntil: 99)
        let script = alwaysBadScript()
        let deps = deps(executor, script: script)
        var state = TurnState(objective: "改文件")
        for _ in 0..<20 {
            state = TurnRunner.step(state, deps: deps, config: fixConfig).state
            if !state.canAdvance { break }
        }
        #expect(state.status == .awaitingUser)

        let outcome = TurnRunner.resolve(
            state,
            CorrectionResolution(action: .changeApproach, nudge: "请换个完全不同的做法。"),
            deps: deps,
            config: fixConfig
        )
        let resumed = outcome.state

        #expect(outcome.didAdvance)
        #expect(outcome.newEvents.contains { $0.kind == .correctionResolved })
        #expect(outcome.newEvents.contains { $0.kind == .guidanceInjected })
        #expect(resumed.status == .dispatching)
        #expect(!resumed.corrections.needsUserDecision)
        // 转向 = 新情况，给模型一份干净的记账
        #expect(resumed.corrections.attempts.isEmpty)

        let guidance = resumed.messages.last
        #expect(guidance?.role == .user)
        #expect(guidance?.origin == .runtimeGuidance)
        #expect(guidance?.plainText.contains("换个完全不同的做法") == true)
        // ⚠️ 绝不能标成用户指令 —— 那等于运行时伪造用户授权
        #expect(guidance?.origin != .userInstruction)
    }

    @Test("⚠️ 选择「换方案」时不带提示也不能崩，仍然要恢复")
    func resolveWithoutNudge() {
        let executor = PickyExecutor(failUntil: 99)
        let script = alwaysBadScript()
        let deps = deps(executor, script: script)
        var state = TurnState(objective: "改文件")
        for _ in 0..<20 {
            state = TurnRunner.step(state, deps: deps, config: fixConfig).state
            if !state.canAdvance { break }
        }
        let outcome = TurnRunner.resolve(state, CorrectionResolution(action: .changeApproach), deps: deps, config: fixConfig)
        #expect(outcome.state.status == .dispatching)
        #expect(!outcome.newEvents.contains { $0.kind == .guidanceInjected })
    }

    @Test("不在等修正决策时 resolve 是空操作")
    func resolveIsNoopWhenNothingPending() {
        let executor = PickyExecutor()
        let script: @Sendable (TurnState) -> [ModelEvent] = { _ in [] }
        let deps = deps(executor, script: script)
        let state = TurnState(objective: "随便")
        let outcome = TurnRunner.resolve(state, CorrectionResolution(action: .stop), deps: deps, config: fixConfig)
        #expect(!outcome.didAdvance)
        #expect(outcome.newEvents.isEmpty)
    }

    @Test("⚠️ 用户选择「停下」：所有未执行的调用都要补上结果（否则下次请求 400）")
    func stopReapsOrphans() {
        // 一波里两个调用，第一个把额度用尽 → 第二个的意图还在，第三个还在队列里
        let executor = PickyExecutor(failUntil: 99)
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            multiCallEvents([
                (id: "a-\(state.round)", name: ToolName.editFile, args: .object(["path": .string("p1.py")])),
                (id: "b-\(state.round)", name: ToolName.editFile, args: .object(["path": .string("p2.py")])),
                (id: "c-\(state.round)", name: ToolName.readFile, args: .object(["path": .string("r.py")])),
            ])
        }
        let deps = deps(executor, script: script)
        var state = TurnState(objective: "多文件")
        for _ in 0..<40 {
            state = TurnRunner.step(state, deps: deps, config: fixConfig).state
            if !state.canAdvance { break }
        }
        #expect(state.status == .awaitingUser)

        let outcome = TurnRunner.resolve(state, CorrectionResolution(action: .stop), deps: deps, config: fixConfig)
        let stopped = outcome.state
        #expect(stopped.status == .interrupted)
        #expect(stopped.corrections.abandonedCount == 1)
        // `.interrupted` 是稳定态 → 循环必须就此停住，不能空转
        #expect(!stopped.canAdvance)

        // 协议不变式：历史里每个 toolCall 都有对应结果，且不重复
        let callIDs = stopped.messages.flatMap { $0.blocks.compactMap(\.toolCallValue) }.map(\.id)
        let resultIDs = stopped.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }.map(\.callID)
        #expect(Set(callIDs) == Set(resultIDs))
        #expect(callIDs.count == resultIDs.count)
        #expect(resultIDs.count >= 3)
    }

    @Test("⚠️ 早返回路径留下的孤儿调用会在下一次模型调用前被补上（协议不变式）")
    func orphanCallsReapedBeforeNextModelCall() {
        let executor = PickyExecutor()
        let firstScript: @Sendable (TurnState) -> [ModelEvent] = { state in
            guard state.round == 0 else { return [] }
            return multiCallEvents([
                (id: "a1", name: ToolName.readFile, args: .object(["path": .string("a.py")])),
                (id: "b1", name: ToolName.readFile, args: .object(["path": .string("b.py")])),
                (id: "c1", name: ToolName.readFile, args: .object(["path": .string("c.py")])),
            ])
        }

        // 预算只够一个工具调用 → Turn 会在**波次中途**结束，剩下两个调用成了孤儿
        let tight = TurnRunner.Config(maxRounds: 6, maxToolCalls: 1, toolRegistry: Fix.registry)
        let (failed, _, _) = TurnRunner.run(
            TurnState(objective: "读三个文件"),
            deps: deps(executor, script: firstScript),
            config: tight
        )
        #expect(failed.status == .failed)
        let orphanIDs = failed.messages.flatMap { $0.blocks.compactMap(\.toolCallValue) }.map(\.id)
        let orphanResults = failed.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }.map(\.callID)
        #expect(orphanIDs.count == 3)
        #expect(orphanResults == ["a1"])   // 这就是"孤儿"：两个调用没有结果

        // 用户点「继续」：会话层把历史带进新的一轮（这正是真实运行时的做法）
        let resumed = TurnState(
            sessionID: failed.sessionID,
            objective: failed.objective,
            messages: failed.messages,
            eventSequence: failed.eventSequence,
            lastEventHash: failed.lastEventHash
        )
        let noCalls: @Sendable (TurnState) -> [ModelEvent] = { _ in
            [.textDelta("看到了"), .usage(TokenUsage(inputTokens: 50, outputTokens: 10)), .finished(reason: .stop)]
        }
        let (final, events, _) = TurnRunner.run(resumed, deps: deps(executor, script: noCalls), config: fixConfig)

        #expect(events.contains { $0.kind == .orphanCallsReaped })
        // 不变式：每一个 tool_call 都有对应结果，且一一对应不重复
        let callIDs = final.messages.flatMap { $0.blocks.compactMap(\.toolCallValue) }.map(\.id)
        let resultIDs = final.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }.map(\.callID)
        #expect(Set(callIDs) == Set(resultIDs))
        #expect(callIDs.count == resultIDs.count)
        // 补记的结果必须说清"它没执行"，否则模型会以为文件已经读过了
        let b1 = final.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }.first { $0.callID == "b1" }
        #expect(b1?.summary.contains("没有执行") == true)
    }

    @Test("⚠️ 用户中途转向必须真的送进请求（这里曾经是个哑掉的功能）")
    func steerNotesReachTheModel() {
        let executor = PickyExecutor()
        // 记录"模型每一轮实际能看到的对话"，就能验证转向到底有没有进去
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var rounds: [[Message]] = []
            func append(_ messages: [Message]) { lock.lock(); rounds.append(messages); lock.unlock() }
            var last: [Message] { lock.lock(); defer { lock.unlock() }; return rounds.last ?? [] }
        }
        let seen = Seen()

        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            if state.round == 0 {
                return oneCall("c1", ToolName.readFile, .object(["path": .string("a.py")]))
            }
            return []
        }
        let depsWithCapture = TurnRunner.Dependencies(
            modelEvents: { s in
                seen.append(s.messages)
                return script(s)
            },
            executor: executor,
            policy: PolicyEngine(),
            policyContext: fullContext(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        var state = TurnState(objective: "读文件")
        for _ in 0..<12 {
            state = TurnRunner.step(state, deps: depsWithCapture, config: fixConfig).state
            if !state.canAdvance { break }
            // 第一轮跑完（工具已执行）之后用户插话
            if state.round == 1, state.steerNotes.isEmpty {
                state.steerNotes.append("顺便也把 README 更新一下")
            }
        }

        let guidance = seen.last.filter { $0.origin == .runtimeGuidance }
        #expect(!guidance.isEmpty)
        #expect(guidance.contains { $0.plainText.contains("README") })
        // 注入之后要清空，不能每一轮都重复塞一遍
        #expect(state.steerNotes.isEmpty)
    }

    @Test("⚠️ 对已中断的 Turn 调 run() 必须立刻返回，不能空转上万次")
    func runOnStableStateTerminatesImmediately() {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let counter = Counter()
        let script: @Sendable (TurnState) -> [ModelEvent] = { _ in
            counter.bump()
            return []
        }
        var state = TurnState(objective: "已停下的任务")
        state.status = .interrupted
        #expect(!state.canAdvance)

        let (final, events, _) = TurnRunner.run(state, deps: deps(PickyExecutor(), script: script), config: fixConfig)
        #expect(final.status == .interrupted)
        #expect(events.isEmpty)
        // 一次都没调用模型 —— 空转的实现在这里会变成 10000
        #expect(counter.value == 0)
    }

    @Test("⚠️【崩溃一致性】在任意一步被杀，恢复后的对话历史仍必须满足协议不变式")
    func protocolInvariantSurvivesAnyCrash() {
        // 基线：不中断跑完
        let baseline = deps(PickyExecutor(failUntil: 0), script: { state in
            guard state.round == 0 else { return [] }
            return multiCallEvents([
                (id: "a1", name: ToolName.readFile, args: .object(["path": .string("a.py")])),
                (id: "b1", name: ToolName.readFile, args: .object(["path": .string("b.py")])),
                // 故意混一个**没注册**的工具：走"工具名幻觉"兜底，同样必须留下结果
                (id: "c1", name: ToolName.writeFile, args: .object(["path": .string("c.py"), "content": .string("x")])),
            ])
        })
        let noCalls: @Sendable (TurnState) -> [ModelEvent] = { _ in [] }

        // 在**每一个**步数上切断，然后恢复跑完
        for cut in 0..<14 {
            let state = TurnState(objective: "多调用")
            let (partial, _, _) = TurnRunner.run(state, deps: baseline, config: fixConfig, maxSteps: cut)

            var restored = partial
            restored.wasRestored = true
            let (final, _, _) = TurnRunner.run(restored, deps: deps(PickyExecutor(failUntil: 0), script: noCalls), config: fixConfig)

            let callIDs = final.messages.flatMap { $0.blocks.compactMap(\.toolCallValue) }.map(\.id)
            let resultIDs = final.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }.map(\.callID)
            #expect(Set(callIDs) == Set(resultIDs), "第 \(cut) 步切断后历史里出现了没有结果的工具调用")
            #expect(callIDs.count == resultIDs.count, "第 \(cut) 步切断后出现了重复的工具结果")
        }
    }

    @Test("⚠️ 越权调用不会因为「工具改不了」而无限重复")
    func deniedCallsDoNotLoopForever() {
        struct DenyExecutor: ToolExecuting {
            func execute(_ call: ToolCall) throws -> ToolResult {
                .failure(callID: call.id, error: ToolError(
                    kind: .capabilityDenied,
                    modelFacingMessage: "没有权限",
                    suggestion: "请让用户授权。"
                ))
            }
        }
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            oneCall("d-\(state.round)", ToolName.readFile, .object(["path": .string("a.py")]))
        }
        var state = TurnState(objective: "读")
        var steps = 0
        for _ in 0..<30 {
            let outcome = TurnRunner.step(state, deps: deps(DenyExecutor(), script: script), config: fixConfig)
            state = outcome.state
            steps += 1
            if !state.canAdvance { break }
        }
        // 原样重发 → 逐字重复 → 第 2 次就停下来
        #expect(state.status == .awaitingUser)
        #expect(state.toolCallCount == 2)
        #expect(steps < 12)
    }
}
