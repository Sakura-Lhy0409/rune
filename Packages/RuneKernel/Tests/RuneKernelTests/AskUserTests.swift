import Foundation
import Testing
@testable import RuneKernel

// MARK: - `ask_user`：模型主动提问
//
// ⚠️ 这一组测的是**状态机行为**，不是"函数返回了什么"。
//    `ask_user` 的语义是"把 Turn 挂起"，所以关键断言是：
//      ① 它真的停在 `.awaitingUser`（而不是继续往下执行）
//      ② **配对结果先补上再挂起**（三家协议都要求 tool_call 有配对结果，T18 ——
//         漏了的话后续所有请求 400，而报错信息与真实原因完全不沾边）
//      ③ 用户的回答以 `.userInstruction` 注入（真实的人说的话，可以驱动危险动作）
//      ④ 坏问题被拒时**不挂起**（否则用户被一个没意义的问题卡住）

/// 一个最小可跑的 TurnRunner 依赖。
///
/// ⚠️ `toolRegistry` 必须有值：`.dispatching` 相位第一步就是查 spec，
///    查不到会走"未知工具"分支 —— 那样测的就不是 `ask_user` 了。
private func makeDeps(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> TurnRunner.Dependencies {
    TurnRunner.Dependencies(
        modelEvents: { _ in [] },
        now: { now }
    )
}

private let testConfig = TurnRunner.Config(toolRegistry: ToolRegistry.byName)

private func askCall(_ question: String, options: [[String: String]] = [],
                     default defaultValue: String? = nil, why: String? = nil) -> ToolCall {
    var payload: [String: JSONValue] = ["question": .string(question)]
    if !options.isEmpty {
        payload["options"] = .array(options.map { dict in
            var object: [String: JSONValue] = [:]
            for (key, value) in dict { object[key] = .string(value) }
            return .object(object)
        })
    }
    if let defaultValue { payload["default"] = .string(defaultValue) }
    if let why { payload["why"] = .string(why) }
    return ToolCall(id: "q1", name: ToolName.askUser,
                    argumentsJSON: Data(JSONValue.object(payload).canonicalString().utf8))
}

/// 造一个"已经拿到模型回复、准备派发"的状态。
private func dispatchingState(_ call: ToolCall) -> TurnState {
    var state = TurnState(objective: "问用户一件事")
    state.status = .dispatching
    state.queuedCalls = [call]
    return state
}

@Suite("ask_user —— 挂起机制")
struct AskUserSuspensionTests {

    @Test("⭐⭐ 合格的问题必须**停在 awaitingUser**，而不是继续执行")
    func validQuestionSuspends() {
        let call = askCall("用哪个币种的精度？",
                           options: [["label": "跟随订单币种"], ["label": "固定两位小数"]],
                           default: "跟随订单币种",
                           why: "美元两位、日元零位，选错会导致退款金额有偏差。")
        let outcome = TurnRunner.step(dispatchingState(call), deps: makeDeps(), config: testConfig)

        #expect(outcome.state.status == .awaitingUser,
                "必须停在等待用户输入，实际：\(outcome.state.status)")
        // ⚠️ didAdvance 必须是 false：这是稳定态，运行时要到此为止
        //    （返回 true 会让运行时立刻再走一步，在稳定态里空转）
        #expect(outcome.didAdvance == false, "稳定态不该继续推进")
        let question = try? #require(outcome.pendingQuestion)
        #expect(question?.question == "用哪个币种的精度？")
        #expect(question?.options.count == 2)
        #expect(question?.defaultValue == "跟随订单币种")
        #expect(question?.why?.contains("退款金额") == true)
        // 问题也必须存进状态（否则进程被回收后问题就消失了）
        #expect(outcome.state.pendingQuestion?.question == "用哪个币种的精度？")
    }

    @Test("⭐⭐ 挂起之前必须**先补上配对结果**（否则后续所有请求 400，T18）")
    func pairedResultIsWrittenBeforeSuspending() {
        let call = askCall("选哪个？")
        let outcome = TurnRunner.step(dispatchingState(call), deps: makeDeps(), config: testConfig)

        // 在历史里找这条调用的配对结果
        var paired: ToolResult?
        for message in outcome.state.messages {
            for block in message.blocks {
                if case .toolResult(let result) = block.kind, result.callID == "q1" { paired = result }
            }
        }
        let result = try? #require(paired)
        #expect(result?.status == .ok, "配对结果必须是 ok（这条调用确实发生了）")
        #expect(result?.summary.contains("等待回答") == true, "实际：\(result?.summary ?? "")")
        #expect(result?.summary.contains("选哪个？") == true, "结果里要带上问题本身")
    }

    @Test("⭐ 事件要记成 userInputRequested（与审批分开，冷启动分诊才分得清）")
    func eventKindIsDistinct() {
        let call = askCall("选哪个？")
        let outcome = TurnRunner.step(dispatchingState(call), deps: makeDeps(), config: testConfig)
        let kinds = outcome.newEvents.map(\.kind)
        #expect(kinds.contains(.userInputRequested), "实际事件：\(kinds)")
        #expect(!kinds.contains(.toolApprovalRequested), "提问不该同时发审批请求（那是两件事）")
    }

    @Test("⚠️ 提问**不进审批路径**（否则用户要点两次才能回答一个问题）")
    func askDoesNotRequireApproval() {
        let spec = ToolRegistry.byName[ToolName.askUser]
        #expect(spec?.needsApproval == .never, "ask_user 不该需要审批")
        #expect(spec?.riskLevel == .safe, "提问本身不是危险动作")
    }
}

@Suite("ask_user —— 坏问题必须被拒（而且不能挂起）")
struct AskUserValidationTests {

    @Test("⭐⭐「要不要我继续」这类废话必须被拒，且**不挂起**")
    func fillerQuestionIsRejected() {
        // ⚠️ 这是工具文档里写死的纪律，也是模型最容易犯的错。
        //    那类问题把决定权推回给用户却没提供任何新信息 ——
        //    它只是让 Agent 显得谨慎，实际是浪费用户的一次点击。
        //    ⚠️ 而且**不能挂起**：挂起了用户就被一个没意义的问题卡住。
        for filler in ["要不要我继续", "是否继续", "可以继续吗"] {
            let outcome = TurnRunner.step(dispatchingState(askCall(filler)), deps: makeDeps(), config: testConfig)
            #expect(outcome.state.status != .awaitingUser, "废话问题不该挂起：\(filler)")
            #expect(outcome.pendingQuestion == nil)
            // 要给模型可执行的纠正
            let denied = outcome.newEvents.filter { $0.kind == .toolCallDenied }
            #expect(!denied.isEmpty, "要记一条被拒事件：\(filler)")
        }
    }

    @Test("⚠️ 空问题必须被拒，并告诉模型该怎么写")
    func emptyQuestionIsRejected() {
        let call = ToolCall(id: "q1", name: ToolName.askUser, argumentsJSON: Data("{}".utf8))
        let outcome = TurnRunner.step(dispatchingState(call), deps: makeDeps(), config: testConfig)
        #expect(outcome.state.status != .awaitingUser)
        var paired: ToolResult?
        for message in outcome.state.messages {
            for block in message.blocks {
                if case .toolResult(let r) = block.kind { paired = r }
            }
        }
        #expect(paired?.status != .ok, "缺 question 必须失败")
        #expect(paired?.error?.suggestion?.contains("ask_user") == true,
                "要给可执行示例，实际：\(paired?.error?.suggestion ?? "无")")
    }

    @Test("⚠️ 选项超过 4 个要被截断（用户在手机上不会读第五个）")
    func optionsAreCapped() {
        let many = (1...6).map { ["label": "选项\($0)"] }
        let outcome = TurnRunner.step(dispatchingState(askCall("选哪个？", options: many)),
                                      deps: makeDeps(), config: testConfig)
        #expect(outcome.pendingQuestion?.options.count == UserQuestion.maxOptions,
                "实际 \(outcome.pendingQuestion?.options.count ?? 0) 个")
    }

    @Test("⚠️ 重复 label 要被拒（否则用户不知道该选哪个）")
    func duplicateLabelsRejected() {
        let outcome = TurnRunner.step(
            dispatchingState(askCall("选哪个？", options: [["label": "A"], ["label": "A"]])),
            deps: makeDeps(), config: testConfig)
        #expect(outcome.state.status != .awaitingUser, "重复选项不该挂起")
    }

    @Test("⭐ 编号选项的渲染要能一眼看懂")
    func displayTextIsReadable() {
        let question = UserQuestion(
            question: "用哪个币种的精度？",
            options: [.init(label: "跟随订单币种", detail: "美元 2 位、日元 0 位"),
                      .init(label: "固定两位小数")],
            defaultValue: "跟随订单币种", why: "选错会导致退款金额有偏差", callID: "q1")
        let text = question.displayText
        #expect(text.contains("1. 跟随订单币种 —— 美元 2 位、日元 0 位"))
        #expect(text.contains("2. 固定两位小数"))
        #expect(text.contains("默认建议：跟随订单币种"))
        #expect(text.contains("为什么需要问："))
    }
}

@Suite("ask_user —— 用户回答后继续")
struct AskUserAnswerTests {

    @Test("⭐⭐ 回答以 userInstruction 注入（真实的人说的话，可以驱动危险动作）")
    func answerIsInjectedAsUserInstruction() {
        let call = askCall("用哪个币种的精度？")
        let suspended = TurnRunner.step(dispatchingState(call), deps: makeDeps(), config: testConfig).state
        #expect(suspended.status == .awaitingUser)

        let resumed = TurnRunner.answer(suspended, text: "跟随订单币种", deps: makeDeps())
        #expect(resumed.status == .reasoning, "回答之后应当回到推理，实际：\(resumed.status)")
        #expect(resumed.pendingQuestion == nil, "回答之后问题必须清掉（否则卡片会再弹一次）")

        let last = try? #require(resumed.messages.last)
        #expect(last?.origin == .userInstruction,
                "⚠️ 必须是 userInstruction —— 降级成 runtimeGuidance 会让 Agent 收到回答却不敢执行（T20 的反面）")
        let text = last?.blocks.compactMap { block -> String? in
            if case .text(let value) = block.kind { return value }
            return nil
        }.joined() ?? ""
        // ⚠️ 要带上"回答的是哪个问题"：模型可能同时问过好几轮
        #expect(text.contains("用哪个币种的精度？"), "要标明回答的是哪一问，实际：\(text)")
        #expect(text.contains("跟随订单币种"))
    }

    @Test("⚠️ 不在 awaitingUser 状态时回答要被拒（与 followUp 的区别正在这里）")
    func answerOnlyWorksWhenWaiting() {
        var state = TurnState(objective: "还没提问")
        state.status = .reasoning
        let after = TurnRunner.answer(state, text: "随便答", deps: makeDeps())
        #expect(after.status == .reasoning, "不该改变状态")
        #expect(after.messages.isEmpty, "不该把回答塞进历史")
    }

    @Test("⚠️ 回答不能重复消费（回答两次只该注入一次）")
    func answerIsIdempotentByState() {
        let suspended = TurnRunner.step(dispatchingState(askCall("选哪个？")), deps: makeDeps(), config: testConfig).state
        let once = TurnRunner.answer(suspended, text: "A", deps: makeDeps())
        let twice = TurnRunner.answer(once, text: "B", deps: makeDeps())
        #expect(once.messages.count == twice.messages.count, "第二次回答不该再注入")
    }

    @Test("⚠️ 待答问题必须随状态**持久化**（用户可能隔很久才回答）")
    func pendingQuestionSurvivesCoding() throws {
        let suspended = TurnRunner.step(dispatchingState(askCall("选哪个？")), deps: makeDeps(), config: testConfig).state
        let encoded = try JSONEncoder().encode(suspended)
        let decoded = try JSONDecoder().decode(TurnState.self, from: encoded)
        #expect(decoded.pendingQuestion?.question == "选哪个？")
        #expect(decoded.status == .awaitingUser)

        // ⚠️ 旧状态（JSON 里没有这个键）也必须能解码 —— 否则所有历史会话都恢复不了
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "pendingQuestion")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let fromLegacy = try JSONDecoder().decode(TurnState.self, from: legacy)
        #expect(fromLegacy.pendingQuestion == nil)
        #expect(fromLegacy.status == .awaitingUser, "其余字段必须完好")
    }
}
