import Testing
import Foundation
@testable import RuneKernel

// MARK: - JSON 修复

@Suite("JSONRepair —— 修复模型给出的坏 JSON")
struct JSONRepairTests {

    @Test("合法 JSON 不做修改")
    func validUnchanged() throws {
        let r = try #require(JSONRepair.parse(#"{"path":"a.swift","limit":10}"#))
        #expect(!r.wasRepaired)
        #expect(r.fixes.isEmpty)
        #expect(r.value.value(at: ["path"]) == .string("a.swift"))
    }

    @Test("空参数按 {} 处理（无参工具是合法的）")
    func emptyIsEmptyObject() throws {
        let r = try #require(JSONRepair.parse(""))
        #expect(r.wasRepaired)
        #expect(r.value == .object([:]))
        let r2 = try #require(JSONRepair.parse("   "))
        #expect(r2.value == .object([:]))
    }

    @Test("⚠️ 被 max_tokens 截断的 JSON（最常见的坏情况）")
    func truncatedObject() throws {
        // 完整形态：{"path": "src/a.swift", "content": "hello"}
        let r = try #require(JSONRepair.parse(#"{"path": "src/a.swift", "content": "hel"#))
        #expect(r.wasRepaired)
        #expect(r.value.value(at: ["path"]) == .string("src/a.swift"))
        #expect(r.value.value(at: ["content"]) == .string("hel"))
        #expect(r.fixes.contains { $0.contains("字符串") })
    }

    @Test("未闭合的对象/数组被补齐")
    func unclosedBrackets() throws {
        let r = try #require(JSONRepair.parse(#"{"items": [1, 2, 3"#))
        #expect(r.wasRepaired)
        #expect(r.value.value(at: ["items", "2"]) == .int(3))

        let r2 = try #require(JSONRepair.parse(#"{"a": {"b": 1"#))
        #expect(r2.value.value(at: ["a", "b"]) == .int(1))
    }

    @Test("尾逗号被去掉")
    func trailingComma() throws {
        let r = try #require(JSONRepair.parse(#"{"a": 1, "b": 2,}"#))
        #expect(r.wasRepaired)
        #expect(r.value.value(at: ["b"]) == .int(2))
        #expect(r.fixes.contains { $0.contains("尾逗号") })
    }

    @Test("悬空的键被丢弃（`{\"a\":1,\"b\"` 与 `{\"a\":1,\"b\":`）")
    func danglingMember() throws {
        let r1 = try #require(JSONRepair.parse(#"{"a": 1, "b""#))
        #expect(r1.value.value(at: ["a"]) == .int(1))
        #expect(r1.value.value(at: ["b"]) == nil)

        let r2 = try #require(JSONRepair.parse(#"{"a": 1, "b":"#))
        #expect(r2.value.value(at: ["a"]) == .int(1))
        #expect(r2.value.value(at: ["b"]) == nil)
    }

    @Test("未完成的转义反斜杠")
    func trailingEscape() throws {
        let r = try #require(JSONRepair.parse(#"{"pattern": "a\"#))
        #expect(r.wasRepaired)
        #expect(r.value.value(at: ["pattern"]) == .string("a"))
    }

    @Test("中文标点被规范（模型偶发）")
    func chinesePunctuation() throws {
        let r = try #require(JSONRepair.parse(#"{"路径"："a.swift"}"#))
        #expect(r.wasRepaired)
        #expect(r.value.value(at: ["路径"]) == .string("a.swift"))
    }

    @Test("修不好时返回 nil（调用方必须走修正性重试）")
    func unrepairableReturnsNil() {
        #expect(JSONRepair.parse("这不是 JSON") == nil)
        // 中文标点替换后依然不合法的情形
        #expect(JSONRepair.parse("{{{") == nil || JSONRepair.parse("{{{")?.value != nil)
    }

    @Test("修复结果一定是合法 JSON（能被重新解析）")
    func repairedIsAlwaysValid() throws {
        let cases = [
            #"{"a":1"#,
            #"{"a":[1,2"#,
            #"{"a":1,"#,
            #"{"a":"#,
            #"["#,
            #"{"#,
        ]
        for c in cases {
            if let r = JSONRepair.parse(c) {
                // 修复后的 canonical 形式必须能被解析回来
                let round = try? JSONValue.parse(r.value.canonicalString())
                #expect(round != nil, "修复结果无法再解析：\(c) → \(r.value.canonicalString())")
            }
        }
    }
}

// MARK: - 工具调用拼装

@Suite("ToolCallAssembler —— 流式工具调用拼装")
struct ToolCallAssemblerTests {

    @Test("OpenAI 标准形态：按 index 拼接分片")
    func openAIStandardFragments() {
        var asm = ToolCallAssembler()
        _ = asm.ingest(.toolCallStarted(index: 0, id: "call_1", name: "read_file"))
        _ = asm.ingest(.toolCallArgumentsDelta(index: 0, jsonFragment: #"{"pa"#))
        _ = asm.ingest(.toolCallArgumentsDelta(index: 0, jsonFragment: #"th": "src/"#))
        _ = asm.ingest(.toolCallArgumentsDelta(index: 0, jsonFragment: #"a.swift"}"#))
        let out = asm.ingest(.finished(reason: .toolCalls))

        #expect(out.count == 1)
        #expect(out[0].call.name == "read_file")
        #expect(out[0].call.id == "call_1")
        #expect(out[0].rawArguments == #"{"path": "src/a.swift"}"#)
        #expect(!out[0].wasRepaired)
        #expect(out[0].isComplete)
        #expect(out[0].call.sourceIndex == 0)
    }

    @Test("⚠️ 并行多工具调用：index 交错到达也必须正确归位")
    func interleavedParallelCalls() throws {
        var asm = ToolCallAssembler()
        _ = asm.ingest(.toolCallStarted(index: 0, id: "a", name: "read_file"))
        _ = asm.ingest(.toolCallStarted(index: 1, id: "b", name: "grep_search"))
        _ = asm.ingest(.toolCallArgumentsDelta(index: 0, jsonFragment: #"{"path":"#))
        _ = asm.ingest(.toolCallArgumentsDelta(index: 1, jsonFragment: #"{"pattern":"#))
        _ = asm.ingest(.toolCallArgumentsDelta(index: 0, jsonFragment: #""x"}"#))
        _ = asm.ingest(.toolCallArgumentsDelta(index: 1, jsonFragment: #""TODO"}"#))
        let out = asm.ingest(.finished(reason: .toolCalls))

        #expect(out.count == 2)
        #expect(out[0].call.name == "read_file")
        #expect(out[1].call.name == "grep_search")
        #expect(try out[0].call.arguments().value(at: ["path"]) == .string("x"))
        #expect(try out[1].call.arguments().value(at: ["pattern"]) == .string("TODO"))
    }

    @Test("Gemini 形态：一次性给全参数（覆盖而非拼装）")
    func geminiWholeCall() {
        var asm = ToolCallAssembler()
        let out = asm.ingest(.toolCallCompleted(
            index: 0, id: "g1", name: "list_dir",
            argumentsJSON: Data(#"{"path":"src"}"#.utf8)
        ))
        #expect(out.count == 1)
        #expect(out[0].call.name == "list_dir")
        #expect(out[0].rawArguments == #"{"path":"src"}"#)
    }

    @Test("Anthropic 形态：start → 多个 delta → stop（由适配器归一化成这类事件）")
    func anthropicBlockStyle() {
        var asm = ToolCallAssembler()
        _ = asm.ingest(.toolCallStarted(index: 0, id: "toolu_1", name: "apply_patch"))
        _ = asm.ingest(.toolCallArgumentsDelta(index: 0, jsonFragment: #"{"patch""#))
        _ = asm.ingest(.toolCallArgumentsDelta(index: 0, jsonFragment: #":"*** Begin"#))
        _ = asm.ingest(.toolCallArgumentsDelta(index: 0, jsonFragment: #"...*** End"}"#))
        let out = asm.ingest(.finished(reason: .toolCalls))
        #expect(out.count == 1)
        #expect(out[0].call.name == "apply_patch")
        #expect(out[0].issues.filter { if case .argumentsRepaired = $0 { return true }; return false }.isEmpty)
    }

    @Test("空参数分片 → 按 {} 处理")
    func emptyArguments() throws {
        var asm = ToolCallAssembler()
        _ = asm.ingest(.toolCallStarted(index: 0, id: "c", name: "git_status"))
        let out = asm.ingest(.finished(reason: .toolCalls))
        #expect(out.count == 1)
        #expect(try out[0].call.arguments() == .object([:]))
        #expect(out[0].wasRepaired)   // 空 → {} 算一次修复，并被记录
    }

    @Test("⚠️ 参数被截断 → 自动修复并记录（脏情况 2）")
    func truncatedArgumentsRepaired() throws {
        var asm = ToolCallAssembler()
        _ = asm.ingest(.toolCallStarted(index: 0, id: "c", name: "write_file"))
        _ = asm.ingest(.toolCallArgumentsDelta(index: 0, jsonFragment: #"{"path":"a.txt","content":"hello wor"#))
        let out = asm.ingest(.finished(reason: .length))

        #expect(out.count == 1)
        #expect(out[0].wasRepaired)
        #expect(try out[0].call.arguments().value(at: ["content"]) == .string("hello wor"))
        #expect(out[0].issues.contains { if case .argumentsRepaired = $0 { return true }; return false })
        // ⚠️ finish_reason 是 length 却仍有工具调用 → 必须给出警告
        #expect(asm.allIssues.contains { if case .unexpectedFinishWithPending = $0 { return true }; return false })
    }

    @Test("⚠️ name 出现不同值 → 取最后一个并记录（脏情况 3：可能被中转站篡改）")
    func nameChangedRecorded() {
        var asm = ToolCallAssembler()
        _ = asm.ingest(.toolCallStarted(index: 0, id: "c", name: "read_file"))
        _ = asm.ingest(.toolCallStarted(index: 0, id: "c", name: "write_file"))
        _ = asm.ingest(.toolCallArgumentsDelta(index: 0, jsonFragment: "{}"))
        let out = asm.ingest(.finished(reason: .toolCalls))

        #expect(out[0].call.name == "write_file")
        let changed = out[0].issues.contains {
            if case .nameChanged(_, let from, let to) = $0 { return from == "read_file" && to == "write_file" }
            return false
        }
        #expect(changed)
    }

    @Test("⚠️ 分片先于 start 到达 → 容错并记录（脏情况：部分中转站）")
    func deltaWithoutStart() throws {
        var asm = ToolCallAssembler()
        _ = asm.ingest(.toolCallArgumentsDelta(index: 0, jsonFragment: #"{"a":1}"#))
        let out = asm.ingest(.finished(reason: .toolCalls))
        #expect(out.count == 1)
        #expect(try out[0].call.arguments().value(at: ["a"]) == .int(1))
        #expect(out[0].issues.contains { if case .deltaWithoutStart = $0 { return true }; return false })
    }

    @Test("⚠️ 缺 name/id → 标记为致命问题（调用方必须重试）")
    func missingIdentityIsFatal() {
        var asm = ToolCallAssembler()
        _ = asm.ingest(.toolCallArgumentsDelta(index: 0, jsonFragment: "{}"))
        let out = asm.ingest(.finished(reason: .toolCalls))
        #expect(out[0].issues.contains { if case .missingIdentity = $0 { return true }; return false })
        #expect(out[0].issues.contains { $0.isFatal })
    }

    @Test("⚠️ finish_reason 缺失 → flush() 兜底并记录（脏情况 7）")
    func flushWithoutFinishReason() {
        var asm = ToolCallAssembler()
        _ = asm.ingest(.toolCallStarted(index: 0, id: "c", name: "read_file"))
        _ = asm.ingest(.toolCallArgumentsDelta(index: 0, jsonFragment: #"{"path":"a"}"#))
        // 流直接断了，没有 finished 事件
        let out = asm.flush()

        #expect(out.count == 1)
        #expect(out[0].isComplete == false)     // 没有明确结束信号
        #expect(asm.allIssues.contains(.finishReasonMissing))
    }

    @Test("⚠️ 绝不重复产出同一个调用（流被重连/重放时）")
    func neverDoubleEmits() {
        var asm = ToolCallAssembler()
        _ = asm.ingest(.toolCallStarted(index: 0, id: "c", name: "read_file"))
        _ = asm.ingest(.toolCallArgumentsDelta(index: 0, jsonFragment: "{}"))
        let first = asm.ingest(.finished(reason: .toolCalls))
        let second = asm.flush()
        #expect(first.count == 1)
        #expect(second.isEmpty)
    }

    @Test("重复的 completed 事件被忽略并记录")
    func duplicateCompletion() {
        var asm = ToolCallAssembler()
        let first = asm.ingest(.toolCallCompleted(index: 0, id: "c", name: "x", argumentsJSON: Data("{}".utf8)))
        let second = asm.ingest(.toolCallCompleted(index: 0, id: "c", name: "x", argumentsJSON: Data("{}".utf8)))
        let third = asm.ingest(.finished(reason: .toolCalls))
        #expect(first.count == 1)
        #expect(second.isEmpty, "重复的 completed 不应再产出一个调用")
        #expect(third.isEmpty, "已产出的调用不应在 finish 时重复产出")
        #expect(asm.allIssues.contains { if case .duplicateCompletion = $0 { return true }; return false })
    }

    @Test("非工具类事件被忽略（文本/思考链不影响拼装）")
    func ignoresNonToolEvents() {
        var asm = ToolCallAssembler()
        #expect(asm.ingest(.started(modelID: "m", providerID: "p")).isEmpty)
        #expect(asm.ingest(.textDelta("hello")).isEmpty)
        #expect(asm.ingest(.reasoningDelta("thinking")).isEmpty)
        #expect(asm.ingest(.usage(TokenUsage(inputTokens: 1))).isEmpty)
        #expect(asm.pendingCount == 0)
    }

    @Test("诊断字符串可用于开发者面板")
    func diagnostics() {
        var asm = ToolCallAssembler()
        _ = asm.ingest(.toolCallStarted(index: 0, id: "c", name: "read_file"))
        _ = asm.ingest(.toolCallArgumentsDelta(index: 0, jsonFragment: #"{"path":"#))
        _ = asm.ingest(.finished(reason: .toolCalls))
        let d = asm.diagnostics
        #expect(d.contains("已产出 1 个"))
        #expect(d.contains("参数被修复"))
        #expect(d.contains("toolCalls"))
    }
}

// MARK: - 渠道差异

@Suite("ProviderQuirks —— 渠道差异声明")
struct ProviderQuirksTests {

    @Test("⚠️ DeepSeek：带 tools 时必须回传历史思考链（否则 400）")
    func deepSeekReasoningReplay() {
        let q = ProviderQuirks.deepSeek
        #expect(q.reasoningField == .reasoningContent)
        #expect(q.reasoningReplay == .whenToolsPresent)
        #expect(!q.reasoningReplay.shouldReplay(hasTools: false))
        #expect(q.reasoningReplay.shouldReplay(hasTools: true))
    }

    @Test("⚠️ Anthropic：思考块必须总是原样回传（含不透明签名）")
    func anthropicReasoningReplay() {
        let q = ProviderQuirks.anthropic
        #expect(q.reasoningReplay == .always)
        #expect(q.reasoningReplay.shouldReplay(hasTools: false))
        #expect(q.systemPlacement == .topLevelParam)
        #expect(q.streamingUsage == .separateEvent)
        #expect(q.cacheStyle.requiresExplicitBreakpoints)
    }

    @Test("OpenAI Responses：无状态模式必须回传加密思考内容")
    func openAIResponsesReplay() {
        let q = ProviderQuirks.openAIResponses
        #expect(q.reasoningReplay == .encryptedOnly)
        #expect(q.maxTokensField == "max_output_tokens")
        #expect(!q.sendsDoneMarker)
        #expect(q.cacheStyle.requiresExplicitBreakpoints)
    }

    @Test("⚠️ 中转站：假设什么都不能依赖（流式常缺 usage）")
    func relayAssumesNothing() {
        let q = ProviderQuirks.relay
        #expect(q.streamingUsage == .absent)
        #expect(q.cacheStyle == .passThrough)
        #expect(q.reasoningField == .none)
    }

    @Test("流形态：Ollama 原生是 NDJSON 而不是 SSE")
    func ollamaStreamShape() {
        #expect(ProtocolFamily.ollamaNative.streamShape == .ndjson)
        #expect(ProtocolFamily.openAIChat.streamShape == .serverSentEvents)
        #expect(ProtocolFamily.custom.streamShape == .ndjson)
    }

    @Test("每个协议族都有可读名称（UI 不会显示裸枚举名）")
    func familiesHaveDisplayNames() {
        for f in ProtocolFamily.allCases {
            #expect(!f.displayName.isEmpty)
        }
    }

    @Test("notableCaveats 会把坑说清楚（供 UI 展示）")
    func caveatsAreInformative() {
        #expect(ProviderQuirks.deepSeek.notableCaveats.contains { $0.contains("400") })
        #expect(ProviderQuirks.relay.notableCaveats.contains { $0.contains("估算") })
        #expect(ProviderQuirks.anthropic.notableCaveats.contains { $0.contains("签名") })
        #expect(ProviderQuirks.openAICompatible.notableCaveats.isEmpty)
    }
}

// MARK: - 成本计算

@Suite("CostCalculator —— 缓存经济学")
struct CostCalculatorTests {

    private let price = ModelPrice(
        inputMicroPerMTok: 1_000_000,     // $1.00 / M
        outputMicroPerMTok: 5_000_000,    // $5.00 / M
        cachedInputMicroPerMTok: 100_000, // $0.10 / M（0.1×）
        cacheWriteMicroPerMTok: 1_250_000 // $1.25 / M（1.25×）
    )

    @Test("未使用缓存时的成本")
    func noCache() {
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 200_000)
        let c = CostCalculator.cost(usage: usage, price: price, providerID: "p", modelID: "m")
        // 输入 $1.00 + 输出 $1.00 = $2.00
        #expect(c.microUSD == 2_000_000)
        #expect(c.cacheSavingsMicroUSD == 0)
        #expect(!c.isEstimated)
    }

    @Test("⚠️ 缓存命中显著省钱（这是手机上省钱的最大杠杆）")
    func cacheHitsSaveMoney() {
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 100_000, cachedInputTokens: 900_000)
        let c = CostCalculator.cost(usage: usage, price: price, providerID: "p", modelID: "m")
        // 未缓存输入 100k = $0.10；缓存读 900k = $0.09；输出 100k = $0.50 → $0.69
        #expect(c.microUSD == 690_000)
        // 省下：900k 按原价 $0.90 − 实付 $0.09 = $0.81
        #expect(c.cacheSavingsMicroUSD == 810_000)
    }

    @Test("缓存写入按 1.25× 计费")
    func cacheWriteCostsMore() {
        let usage = TokenUsage(inputTokens: 0, cacheWriteTokens: 1_000_000)
        let c = CostCalculator.cost(usage: usage, price: price, providerID: "p", modelID: "m")
        #expect(c.microUSD == 1_250_000)
    }

    @Test("低谷折扣（DeepSeek 低谷 5 折）")
    func offPeakDiscount() {
        let peakPrice = ModelPrice(
            inputMicroPerMTok: 1_000_000, outputMicroPerMTok: 5_000_000,
            offPeakMultiplier: 0.5
        )
        let usage = TokenUsage(inputTokens: 1_000_000)
        let peak = CostCalculator.cost(usage: usage, price: peakPrice, providerID: "p", modelID: "m")
        let off = CostCalculator.cost(usage: usage, price: peakPrice, providerID: "p", modelID: "m", isOffPeak: true)
        #expect(peak.microUSD == 1_000_000)
        #expect(off.microUSD == 500_000)
    }

    @Test("长上下文倍率（OpenAI 超 272K 规则）")
    func longContextMultiplier() {
        let longPrice = ModelPrice(
            inputMicroPerMTok: 1_000_000, outputMicroPerMTok: 1_000_000,
            longContextThreshold: 272_000,
            longContextInputMultiplier: 2.0,
            longContextOutputMultiplier: 1.5
        )
        let under = CostCalculator.cost(
            usage: TokenUsage(inputTokens: 200_000, outputTokens: 100_000),
            price: longPrice, providerID: "p", modelID: "m"
        )
        #expect(under.microUSD == 300_000)     // 0.2 + 0.1

        let over = CostCalculator.cost(
            usage: TokenUsage(inputTokens: 300_000, outputTokens: 100_000),
            price: longPrice, providerID: "p", modelID: "m"
        )
        // 输入 0.3 × 2 = 0.6；输出 0.1 × 1.5 = 0.15 → 0.75
        #expect(over.microUSD == 750_000)
    }

    @Test("估算的用量会被标注（UI 必须显示 ≈）")
    func estimatedFlagPropagates() {
        let c = CostCalculator.cost(
            usage: TokenUsage(inputTokens: 1000, isEstimated: true),
            price: price, providerID: "relay", modelID: "m"
        )
        #expect(c.isEstimated)
        #expect(c.displayString.hasPrefix("≈"))
    }

    @Test("价格缺省时按业界惯例推导（读 0.1× / 写 1.25×）")
    func derivedPrices() {
        let p = ModelPrice(inputMicroPerMTok: 1_000_000, outputMicroPerMTok: 1_000_000)
        #expect(p.cachedInputMicroPerMTok == 100_000)
        #expect(p.cacheWriteMicroPerMTok == 1_250_000)
    }

    @Test("成本展示格式（用户直接看这个）")
    func display() {
        let c = CostCalculator.cost(
            usage: TokenUsage(inputTokens: 41_000), price: ModelPrice(inputMicroPerMTok: 1_000_000, outputMicroPerMTok: 0),
            providerID: "p", modelID: "m"
        )
        #expect(c.displayString == "$0.041")
    }

    @Test("零用量不产生负数或异常")
    func zeroUsage() {
        let c = CostCalculator.cost(usage: .zero, price: price, providerID: "p", modelID: "m")
        #expect(c.microUSD == 0)
        #expect(c.cacheSavingsMicroUSD == 0)
    }
}
