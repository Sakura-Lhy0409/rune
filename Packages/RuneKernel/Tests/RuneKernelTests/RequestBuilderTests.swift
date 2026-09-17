import Testing
import Foundation
@testable import RuneKernel

// MARK: - 出站请求的构建与体检
//
// 这一组守的是"花钱之前的那一道闸"：请求一旦发出去，三家协议里只要有一条配对不成立，
// 就是**后续所有请求 400**，而报错信息与真实原因毫不相干（T18）。
//
// ⚠️ 特别注意本组里有两条测试是**跨里程碑**的：
//   · 工具顺序稳定（否则 Prompt Cache 每次启动都失效 → 用户多付钱，而没有任何报错）
//   · 真实跑一轮 TurnRunner，然后把**每一轮的聊天历史**都送去体检
//     （这比手搓样例强得多：它检查的是运行时真的会产出的东西）

private func call(_ id: String, _ name: String, _ args: String = "{}") -> ToolCall {
    ToolCall(id: id, name: name, argumentsJSON: Data(args.utf8))
}

private func result(_ id: String, _ summary: String = "内容") -> ContentBlock {
    ContentBlock(kind: .toolResult(.ok(callID: id, summary: summary)), origin: .toolResultTrusted)
}

private func callBlock(_ id: String, _ name: String) -> ContentBlock {
    ContentBlock(kind: .toolCall(call(id, name)), origin: .modelOutput)
}

private func user(_ text: String, origin: TrustLevel = .userInstruction) -> Message {
    Message(role: .user, blocks: [.text(text, origin: origin)], origin: origin)
}

private func assistant(_ blocks: [ContentBlock]) -> Message {
    Message(role: .assistant, blocks: blocks, origin: .modelOutput)
}

private func tool(_ blocks: [ContentBlock]) -> Message {
    Message(role: .tool, blocks: blocks, origin: .toolResultTrusted)
}

/// 一次正常的并发波次：三个调用 + 三条紧跟在后面的结果
private func healthyWave() -> [Message] {
    [
        user("把这三个文件都读一下"),
        assistant([.init(kind: .text("好"), origin: .modelOutput),
                   callBlock("c1", "read_file"), callBlock("c2", "read_file"),
                   callBlock("c3", "stat_path")]),
        tool([result("c1", "a 的内容")]),
        tool([result("c2", "b 的内容")]),
        tool([result("c3", "c 的大小")]),
    ]
}

private func specs(_ names: [String]) -> [String: ToolSpec] {
    let empty = JSONSchema.object(properties: [:], required: [], additionalProperties: true)
    var out: [String: ToolSpec] = [:]
    for name in names {
        out[name] = ToolSpec(name: name, description: "\(name) 的描述", inputSchema: empty,
                             riskLevel: .safe, needsApproval: .never, requirements: [.fsRead])
    }
    return out
}

@Suite("出站体检 —— 三种坏法要给三种改法")

struct OutboundCheckTests {

    @Test("健康的并发波次能发出去")
    func healthyHistoryIsSendable() {
        let report = OutboundCheck.review(healthyWave(), family: .openAIChat)
        #expect(report.isSendable, "不该有问题：\(report.blockingIssues.map(\.detail))")
        #expect(report.summary == nil, "没问题时不要产出提示语（避免刷屏）")
    }

    @Test("⭐ 结果根本没记 → 让调用方去「补记」，而不是重发")
    func missingResultIsDiagnosedAsUnrecorded() {
        var messages = healthyWave()
        messages.removeLast()          // c3 的结果丢了
        let report = OutboundCheck.review(messages, family: .anthropicMessages)
        #expect(!report.isSendable)
        let issue = report.blockingIssues.first
        #expect(issue?.detail.contains("没有配对结果") == true)
        #expect(issue?.detail.contains("stat_path") == true, "要说清是哪个工具：\(issue?.detail ?? "")")
        #expect(issue?.fix.contains("400") == true, "要让读的人知道后果有多严重")
        #expect(issue?.fix.contains("补记") == true)
    }

    @Test("⭐ 结果记了但没紧跟 → 改法是「挪回调用后面」（与上一条完全不同）")
    func nonAdjacentResultIsDiagnosedAsMisplaced() {
        let messages = [
            user("读一下"),
            assistant([callBlock("c1", "read_file"), callBlock("c2", "read_file")]),
            tool([result("c1")]),
            // 引导语插到了两个结果中间
            user("顺便注意路径要用相对路径", origin: .runtimeGuidance),
            tool([result("c2")]),
        ]
        let report = OutboundCheck.review(messages, family: .openAIChat)
        #expect(!report.isSendable)
        #expect(report.blockingIssues.contains { $0.detail.contains("没有紧跟") })
        #expect(report.blockingIssues.contains { $0.fix.contains("引导语") },
                "改法要指到「把引导语放到整批结果之后」")
    }

    @Test("⭐ 多出来的结果 → 改法是「对应关系串了」（第三种改法）")
    func extraResultIsDiagnosedAsMismatch() {
        let messages = [
            assistant([callBlock("c1", "read_file")]),
            tool([result("c1")]),
            tool([result("c99", "来自别的轮次的结果")]),
        ]
        let report = OutboundCheck.review(messages, family: .openAIChat)
        #expect(!report.isSendable)
        // c99 本身没有对应调用 → 孤儿；同时它也不是 c1 的结果
        #expect(report.blockingIssues.contains { $0.detail.contains("孤儿结果") })
    }

    @Test("⚠️ 结果出现在它的调用之前 → 报出来")
    func resultBeforeCall() {
        let messages = [
            tool([result("c1")]),
            assistant([callBlock("c1", "read_file")]),
        ]
        let report = OutboundCheck.review(messages, family: .openAIChat)
        #expect(!report.isSendable)
        #expect(report.blockingIssues.contains { $0.detail.contains("调用之前") })
    }

    @Test("⚠️ 重复的 call id → 报出来（配对会变成一对多）")
    func duplicateCallID() {
        let messages = [
            assistant([callBlock("c1", "read_file")]),
            tool([result("c1")]),
            assistant([callBlock("c1", "read_file")]),
            tool([result("c1")]),
        ]
        let report = OutboundCheck.review(messages, family: .openAIChat)
        #expect(report.blockingIssues.contains { $0.detail.contains("重复") })
    }

    @Test("⚠️ 空的 assistant 消息 → 报出来（它会让后面的结果失去宿主）")
    func emptyAssistantMessage() {
        let messages = [user("读一下"), assistant([])]
        let report = OutboundCheck.review(messages, family: .anthropicMessages)
        #expect(report.blockingIssues.contains { $0.detail.contains("空的 assistant") })
    }

    @Test("空历史 → 报出来")
    func emptyHistory() {
        #expect(!OutboundCheck.review([], family: .openAIChat).isSendable)
    }

    @Test("⭐ 拦下时的说明包含「哪一条 + 怎么改」，可以直接显示给用户")
    func summaryIsActionable() {
        var messages = healthyWave()
        messages.removeLast()
        let report = OutboundCheck.review(messages, family: .geminiGenerate)
        let summary = report.summary ?? ""
        #expect(summary.contains("已拦下"))
        #expect(summary.contains("改法："))
    }
}

@Suite("请求构建 —— 顺序必须由这里定死")

struct RequestBuilderTests {

    @Test("⭐ 工具顺序按名字排序：**跨进程稳定**才谈得上 Prompt Cache")
    func toolOrderIsStable() {
        // 同一批工具，两种插入顺序（模拟字典的哈希顺序随进程变化）
        let a = RequestBuilder.build(
            history: healthyWave(), toolRegistry: specs(["write_file", "glob", "read_file"]),
            maxOutputTokens: 4096, family: .openAIChat
        )
        let b = RequestBuilder.build(
            history: healthyWave(), toolRegistry: specs(["read_file", "write_file", "glob"]),
            maxOutputTokens: 4096, family: .openAIChat
        )
        guard case .ready(let ra, _) = a, case .ready(let rb, _) = b else {
            Issue.record("两份都应当可发"); return
        }
        #expect(ra.tools.map(\.name) == ["glob", "read_file", "write_file"])
        #expect(rb.tools.map(\.name) == ["glob", "read_file", "write_file"])
        // ⚠️ 这条是最要命的：顺序一变，请求指纹就变 → 去重失效 + 缓存失效（都是钱）
        #expect(ra.fingerprintBody() == rb.fingerprintBody(),
                "同一批工具必须得到**同一个**请求指纹，否则每次启动都多花钱")
    }

    @Test("⭐ 诊断里说的改法要能照着做：坏历史被拦下，且**不返回**请求")
    func blockedHistoryNeverProducesARequest() {
        var messages = healthyWave()
        messages.removeLast()
        let outcome = RequestBuilder.build(history: messages, maxOutputTokens: 4096, family: .anthropicMessages)
        switch outcome {
        case .ready:
            Issue.record("坏历史不该产出请求 —— 失败必须关闭")
        case .blocked(let blocked):
            #expect(blocked.userFacingText.contains("改法："))
            #expect(!blocked.report.isSendable)
        }
    }

    @Test("`require` 在坏历史上抛错")
    func requireThrows() {
        var messages = healthyWave()
        messages.removeLast()
        #expect(throws: OutboundBlocked.self) {
            try RequestBuilder.require(history: messages, maxOutputTokens: 4096, family: .geminiGenerate)
        }
    }

    @Test("输出预留必须是正数（装配器要求 ≥ 窗口 10%）")
    func outputReserveMustBePositive() {
        let outcome = RequestBuilder.build(history: healthyWave(), maxOutputTokens: 0, family: .openAIChat)
        guard case .blocked(let blocked) = outcome else { Issue.record("应当拦下"); return }
        #expect(blocked.report.blockingIssues.contains { $0.location == "maxOutputTokens" })
    }

    @Test("⚠️ 允许了但没实现的工具只是**警告**，不拦（否则一个笔误就让整个 Turn 发不出去）")
    func allowedButMissingToolIsOnlyAWarning() {
        let outcome = RequestBuilder.build(
            history: healthyWave(), toolRegistry: specs(["read_file"]),
            allowedTools: ["read_file", "git_push"],
            maxOutputTokens: 4096, family: .openAIChat
        )
        guard case .ready(let request, let report) = outcome else {
            Issue.record("只是警告，不该拦下"); return
        }
        #expect(request.tools.map(\.name) == ["read_file"])
        #expect(report.issues.contains { $0.severity == .warning && $0.detail.contains("git_push") })
        #expect(report.isSendable)
    }

    @Test("系统块按层排好（缓存断点只认层 1/2）")
    func systemBlocksAreOrdered() {
        let outcome = RequestBuilder.build(
            history: healthyWave(),
            systemBlocks: [
                SystemBlock(layer: .sessionVolatile, label: "本轮目标", text: "修复退款 bug"),
                SystemBlock(layer: .identity, label: "身份", text: "你是 Rune"),
                SystemBlock(layer: .projectStable, label: "项目指令", text: "用中文注释"),
            ],
            maxOutputTokens: 4096, family: .anthropicMessages
        )
        guard case .ready(let request, _) = outcome else { Issue.record("应当可发"); return }
        #expect(request.systemBlocks.map(\.layer) == [.identity, .projectStable, .sessionVolatile])
        #expect(request.systemBlocks.filter(\.isCacheCandidate).count == 2)
    }

    @Test("⭐ 建出来的请求能真的编码出去，且分组符合各协议族（与 C30 接上）")
    func builtRequestEncodesCorrectlyForEveryFamily() {
        let spec = specs(["read_file", "stat_path"])
        let families: [ProtocolFamily] = [.openAIChat, .anthropicMessages, .geminiGenerate, .openAIResponses]
        for family in families {
            let outcome = RequestBuilder.build(history: healthyWave(), toolRegistry: spec,
                                               maxOutputTokens: 4096, family: family)
            guard case .ready(let request, _) = outcome else {
                Issue.record("\(family.rawValue) 应当可发"); continue
            }
            let body = RequestEncoder.encode(request, family: family, model: "m", quirks: .openAICompatible)
            // 三个结果必须都在请求体里（编码成功 = 构建出来的东西是真能用的）
            let rendered = body.canonicalString()
            #expect(rendered.contains("a 的内容") && rendered.contains("b 的内容") && rendered.contains("c 的大小"),
                    "\(family.rawValue) 的结果没进请求体")
            #expect(rendered.contains("read_file"), "\(family.rawValue) 的工具定义没进请求体")
        }

        // Anthropic/Gemini：三条结果要合成**一条**（C30 的不变式，从构建入口再验一次）
        let anthropic = try? RequestBuilder.require(history: healthyWave(), toolRegistry: spec,
                                                   maxOutputTokens: 4096, family: .anthropicMessages)
        guard let anthropic else { Issue.record("anthropic 应当可发"); return }
        let aBody = RequestEncoder.encode(anthropic, family: .anthropicMessages, model: "m", quirks: .openAICompatible)
        guard case .array(let aMessages)? = aBody.value(at: ["messages"]) else {
            Issue.record("没有 messages"); return
        }
        #expect(aMessages.count == 3, "user / assistant / user（三条结果合成一条）")

        let gemini = try? RequestBuilder.require(history: healthyWave(), toolRegistry: spec,
                                                maxOutputTokens: 4096, family: .geminiGenerate)
        guard let gemini else { Issue.record("应当可发"); return }
        let gBody = RequestEncoder.encode(gemini, family: .geminiGenerate, model: "m", quirks: .openAICompatible)
        guard case .array(let contents)? = gBody.value(at: ["contents"]) else {
            Issue.record("没有 contents"); return
        }
        #expect(contents.count == 3, "user / model / user（三条结果合成一条）")
    }
}

// MARK: - 真实跑一轮，把每一轮的历史都送去体检

/// 一个"读文件 → 改文件 → 跑测试 → 收工"的脚本
private func scriptedCoder() -> @Sendable (TurnState) -> [ModelEvent] {
    { state in
        switch state.round {
        case 0:
            return [
                .toolCallStarted(index: 0, id: "r0", name: ToolName.readFile),
                .toolCallArgumentsDelta(index: 0, jsonFragment: #"{"path":"/workspace/notes.md"}"#),
                .usage(TokenUsage(inputTokens: 900, outputTokens: 40)),
                .finished(reason: .toolCalls),
            ]
        case 1:
            // 一次并发两个调用 —— 这正是"多工具结果"最容易出错的地方
            return [
                .toolCallStarted(index: 0, id: "w1", name: ToolName.readFile),
                .toolCallArgumentsDelta(index: 0, jsonFragment: #"{"path":"/workspace/notes.md"}"#),
                .toolCallStarted(index: 1, id: "w2", name: ToolName.readFile),
                .toolCallArgumentsDelta(index: 1, jsonFragment: #"{"path":"/workspace/notes.md"}"#),
                .usage(TokenUsage(inputTokens: 1_200, outputTokens: 60)),
                .finished(reason: .toolCalls),
            ]
        default:
            return [
                .textDelta("看完了，notes.md 里记的是部署步骤。"),
                .usage(TokenUsage(inputTokens: 1_400, outputTokens: 30)),
                .finished(reason: .stop),
            ]
        }
    }
}

private struct EchoReader: ToolExecuting {
    func execute(_ call: ToolCall) throws -> ToolResult {
        .ok(callID: call.id, summary: "notes.md 的内容（\(call.name)）")
    }
}

/// 只读工作区的授权（这一组只关心协议形态，不要被审批拦住）
private func liveContext() -> PolicyEngine.Context {
    let token = CapabilityToken(
        issuedForTurn: UUID(),
        scopes: [.fsRead(VFSPath(mount: .workspace))],
        expiresAt: Date(timeIntervalSince1970: 1_700_000_000 + 3600),
        grantedBy: .planApproval,
        reason: "出站体检的实盘测试"
    )
    return PolicyEngine.Context(trustDial: .collaborate, token: token, planApproved: true)
}

private func liveDeps() -> TurnRunner.Dependencies {
    TurnRunner.Dependencies(
        modelEvents: scriptedCoder(),
        executor: EchoReader(),
        policy: PolicyEngine(),
        policyContext: liveContext(),
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
}

private func liveConfig() -> TurnRunner.Config {
    var config = TurnRunner.Config(maxRounds: 6, maxToolCalls: 8,
                                   toolRegistry: specs([ToolName.readFile]))
    config.maxCostMicroUSD = 0          // 这一组不测钱
    return config
}

@Suite("⭐ 目标必须进对话历史（否则请求发不出去）")

struct ObjectiveReachesTheConversationTests {

    @Test("⭐⭐ `.start` 之后，目标就是历史里的第一条 user 消息")
    func objectiveBecomesTheFirstUserMessage() {
        let state = TurnRunner.step(TurnState(objective: "修复退款测试失败"),
                                    deps: liveDeps(), config: liveConfig()).state
        #expect(state.status == .reasoning)
        guard let first = state.messages.first else {
            Issue.record("历史是空的 —— 目标没进对话"); return
        }
        #expect(first.role == .user)
        #expect(first.plainText == "修复退款测试失败")
        #expect(first.origin == .userInstruction)
        // 它是**用户指令**，所以可以驱动危险动作 —— 这一点必须是对的，
        // 否则"用户让它做的事"会被当成运行时的建议而处处要审批
        #expect(first.origin.canDriveDangerousAction)
    }

    @Test("⚠️ 只有 system、没有 messages 的请求是发不出去的（这就是上一条存在的原因）")
    func requestWithoutAnyMessageIsRefused() {
        let outcome = RequestBuilder.build(
            history: [],
            systemBlocks: [SystemBlock(layer: .identity, label: "身份", text: "你是 Rune")],
            maxOutputTokens: 4096, family: .anthropicMessages
        )
        guard case .blocked(let blocked) = outcome else {
            Issue.record("三家协议都要求 messages 至少有一条，应当拦下"); return
        }
        #expect(blocked.report.blockingIssues.contains { $0.location == "messages" })
        // 同一个毛病**只报一条**（报两条会稀释真正的问题）
        #expect(blocked.report.issues.filter { $0.location == "messages" }.count == 1)
    }

    @Test("⭐ `.start` 之后立刻就能建出可发的请求（这是运行时的第一步）")
    func firstRequestIsImmediatelySendable() {
        let state = TurnRunner.step(TurnState(objective: "看一下 notes.md"),
                                    deps: liveDeps(), config: liveConfig()).state
        let request = try? RequestBuilder.require(
            history: state.messages, toolRegistry: liveConfig().toolRegistry,
            maxOutputTokens: 4096, family: .anthropicMessages
        )
        #expect(request != nil)
        #expect(request?.messages.count == 1)
        #expect(request?.messages.first?.plainText == "看一下 notes.md")
    }

    @Test("⚠️ 幂等：再走一次 `.start` 不会把目标记两遍（恢复/重放会走到这里）")
    func objectiveIsNotDuplicated() {
        let once = TurnRunner.step(TurnState(objective: "修复退款测试失败"),
                                   deps: liveDeps(), config: liveConfig()).state
        #expect(once.messages.count == 1)

        // 模拟"状态退回 .start 再走一遍"（重放/恢复的最坏情况）
        var replayed = once
        replayed.status = .start
        let twice = TurnRunner.step(replayed, deps: liveDeps(), config: liveConfig()).state
        #expect(twice.messages.count == 1, "目标被记了两遍：\(twice.messages.map(\.plainText))")
        #expect(twice.messages.filter { $0.role == .user }.count == 1)
    }
}

@Suite("⭐ 真实 TurnRunner 的每一轮历史都要能发出去")

struct LiveHistorySendabilityTests {

    @Test("⭐⭐ 跑完整一轮，**每一步**的聊天历史对**每个协议族**都通过体检")
    func everyRoundIsSendable() {
        let deps = liveDeps()
        let config = liveConfig()

        var state = TurnState(objective: "看一下 notes.md 里写了什么")
        var checked = 0
        var steps = 0
        var reasoningStates = 0
        while state.canAdvance, steps < 40 {
            state = TurnRunner.step(state, deps: deps, config: config).state
            steps += 1
            // ⚠️⚠️ 只在**"下一步就会调模型"**的状态上体检（即 `.reasoning`）。
            //
            //     不能"每一步都体检"：三步落盘协议（写意图 → 执行 → 写事实）保证了一个
            //     **本来就不合法的中间态** —— 模型刚给出 tool_calls、结果还没写出来的那一瞬，
            //     历史里就是"调用没有配对结果"。在那时判定"不许发"会把运行时**判死**，
            //     而实际上那一刻根本不会发请求。
            //
            //     所以闸门长在"要发出去的那一刻"（`RequestBuilder`），不是长在每一步上。
            guard state.status == .reasoning else { continue }
            reasoningStates += 1
            for family in [ProtocolFamily.openAIChat, .anthropicMessages, .geminiGenerate, .openAIResponses] {
                let outcome = RequestBuilder.build(
                    history: state.messages, toolRegistry: config.toolRegistry,
                    maxOutputTokens: 4096, family: family
                )
                if case .blocked(let blocked) = outcome {
                    Issue.record("第 \(steps) 步、\(family.rawValue) 被拦下：\(blocked.userFacingText)")
                }
                checked += 1
            }
        }
        #expect(reasoningStates >= 3, "至少经过了 3 个「要调模型」的状态，实际 \(reasoningStates)")
        #expect(checked > 8, "至少体检了若干次，实际 \(checked)")
        #expect(state.status == .completed, "这一轮应当正常跑完（实际 \(state.status)）")
    }

    @Test("⭐ 每一次真实调用都留下了配对结果（体检之外的独立断言）")
    func everyCallIsPaired() {
        let (state, _, _) = TurnRunner.run(TurnState(objective: "看一下 notes.md"),
                                           deps: liveDeps(), config: liveConfig())

        let calls = state.messages.flatMap { $0.blocks.compactMap(\.toolCallValue) }
        let results = state.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }
        #expect(!calls.isEmpty, "这一轮确实调了工具")
        for call in calls {
            #expect(results.contains { $0.callID == call.id }, "调用 \(call.id) 没有配对结果")
        }
        #expect(Set(calls.map(\.id)).count == calls.count, "call id 不能重复")
    }

    @Test("⭐ 并发那一轮的请求体里，三个调用与三个结果都在同一个请求里")
    func concurrentWaveReachesTheWire() {
        let deps = liveDeps()
        let config = liveConfig()
        var state = TurnState(objective: "看一下 notes.md")

        // 走到"波次里有两个调用"的那一步之后，再体检一次
        for _ in 0..<12 where state.canAdvance {
            state = TurnRunner.step(state, deps: deps, config: config).state
            let calls = state.messages.flatMap { $0.blocks.compactMap(\.toolCallValue) }
            let results = state.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }
            if calls.count >= 3 && results.count >= 3 {
                let request = try? RequestBuilder.require(
                    history: state.messages, toolRegistry: config.toolRegistry,
                    maxOutputTokens: 4096, family: .anthropicMessages
                )
                guard let request else { Issue.record("应当可发"); return }
                let body = RequestEncoder.encode(request, family: .anthropicMessages,
                                                 model: "m", quirks: .openAICompatible)
                guard case .array(let messages)? = body.value(at: ["messages"]) else {
                    Issue.record("没有 messages"); return
                }
                // 三个结果必须落在同一条 user 消息里（C30 的不变式）
                let resultCount = messages.reduce(0) { total, message in
                    guard case .array(let content)? = message.value(at: ["content"]) else { return total }
                    return total + content.filter { $0.value(at: ["type"]) == .string("tool_result") }.count
                }
                #expect(resultCount == results.count, "每个结果都要出现在请求体里")
                #expect(messages.count <= calls.count + 2,
                        "消息数不该随结果数线性增长（说明同角色被合并了）")
                return
            }
        }
        Issue.record("没有走到并发那一轮")
    }
}
