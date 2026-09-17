import Testing
import Foundation
@testable import RuneKernel

// MARK: - 上下文装配的夹具
//
// 这一组测试守住 docs/07 §1 的三条红线：
//   ① 预算制（先算钱再分配，超了就压；缺必进项就不许发出去）
//   ② 装配器**永不自己花钱**（L3 主模型压缩只报告、不执行）
//   ③ 字节稳定（层 1+2 两次装配必须逐字节一致，否则 Prompt Cache 永不命中）

private func item(
    _ id: String,
    _ block: ContextItem.Block,
    tokens: Int = 100,
    text: String? = nil,
    relevance: Double = 0.5,
    recency: Double = 0.5,
    pinned: ContextItem.PinnedRole? = nil,
    handle: String? = nil,
    dedupe: String? = nil,
    trust: TrustLevel = .toolResultTrusted,
    taint: TaintOrigin? = nil
) -> ContextItem {
    // 造一段"估算后约等于 tokens"的文本：用中文最直接（1 字符 ≈ 1 token）
    let body = text ?? String(repeating: "内", count: max(1, tokens))
    return ContextItem(
        id: id, block: block, text: body, tokens: tokens,
        trust: trust, taint: taint,
        relevance: relevance, recency: recency,
        pinnedRole: pinned, artifactHandle: handle, dedupeKey: dedupe
    )
}

private func objective(_ id: String = "obj") -> ContextItem {
    item(id, .systemLayer1, tokens: 50, text: "目标：修好退款测试", relevance: 1.0, pinned: .objective)
}

private func budget(_ window: Int) -> ContextBudget { ContextBudget(window: window) }

// MARK: - Token 估算

@Suite("TokenEstimator —— 估准才有预算制")

struct TokenEstimatorTests {

    @Test("⚠️ 中文绝不能被低估：1 字符 ≈ 1 token，而不是 1/4")
    func chineseNotUnderestimated() {
        let text = String(repeating: "退款金额计算有误", count: 50)   // 400 个汉字
        let estimated = TokenEstimator.estimate(text)
        // 教科书式的 count/4 会给出 100，那意味着**实际花 4 倍的钱**
        #expect(estimated >= 380)
        #expect(estimated <= 440)
    }

    @Test("英文按 ~3.5 字符/token 折算，且宁可略高估")
    func englishEstimate() {
        let text = String(repeating: "the quick brown fox ", count: 40)   // 800 字符
        let estimated = TokenEstimator.estimate(text)
        #expect(estimated >= 180)
        #expect(estimated <= 260)
    }

    @Test("中英混排：两边分别算")
    func mixedText() {
        let chinese = TokenEstimator.estimate("修复退款测试")
        let english = TokenEstimator.estimate("fix the refund test")
        let mixed = TokenEstimator.estimate("修复退款测试 fix the refund test")
        #expect(mixed >= chinese + english - 4)
    }

    @Test("日文 / 韩文同样按 1 字符 ≈ 1 token")
    func kanaAndHangul() {
        #expect(TokenEstimator.estimate(String(repeating: "あ", count: 100)) >= 95)
        #expect(TokenEstimator.estimate(String(repeating: "한", count: 100)) >= 95)
    }

    @Test("空串是 0，短串不为 0")
    func edgeCases() {
        #expect(TokenEstimator.estimate("") == 0)
        #expect(TokenEstimator.estimate("a") >= 1)
    }

    @Test("消息估算：包含工具调用的参数与图片的固定开销")
    func messageEstimate() {
        let call = ToolCall(id: "c1", name: "read_file", argumentsJSON: Data(#"{"path":"src/a.py"}"#.utf8))
        let message = Message(
            role: .assistant,
            blocks: [
                ContentBlock(kind: .text("我先看一下这个文件"), origin: .modelOutput),
                ContentBlock(kind: .toolCall(call), origin: .modelOutput),
            ],
            origin: .modelOutput
        )
        let plain = Message(role: .user, blocks: [ContentBlock(kind: .text("你好"), origin: .userInstruction)], origin: .userInstruction)
        #expect(TokenEstimator.estimate(message) > TokenEstimator.estimate(plain))

        let ref = ArtifactRef(
            relPath: "artifacts/a.png", kind: .image, displayName: "a.png",
            mime: "image/png", byteSize: 1000, lineCount: nil, sha256: nil
        )
        let withImage = Message(
            role: .user,
            blocks: [ContentBlock(kind: .image(ref: ref, mime: "image/png"), origin: .userInstruction)],
            origin: .userInstruction
        )
        // 图片按固定开销估（约 1100），不能当成 0 —— 否则多图请求会撑爆窗口
        #expect(TokenEstimator.estimate(withImage) >= 1100)
    }
}

// MARK: - 预算

@Suite("ContextBudget —— 先算钱，再分配")

struct ContextBudgetTests {

    @Test("⭐ 按目标成本倒推窗口：窗口大 ≠ 应该用满")
    func deriveFromCostCeiling() {
        // $0.05 上限，输入价 $3/M → 能买 16666 token，尽管模型窗口有 200k
        let b = ContextBudget.derive(
            modelWindow: 200_000,
            costCeilingMicroUSD: 50_000,
            inputPriceMicroUSDPerMillion: 3_000_000
        )
        #expect(b.window == 16_666)
        #expect(b.costCeilingMicroUSD == 50_000)
    }

    @Test("倒推不会超过模型窗口（便宜但窗口小的渠道仍受窗口限制）")
    func deriveNeverExceedsModelWindow() {
        let b = ContextBudget.derive(
            modelWindow: 8_000,
            costCeilingMicroUSD: 5_000_000,      // $5，买得起远超窗口的量
            inputPriceMicroUSDPerMillion: 1_000_000
        )
        #expect(b.window == 8_000)
    }

    @Test("没有价格信息就不倒推（不猜）")
    func noPriceNoDerivation() {
        let a = ContextBudget.derive(modelWindow: 32_000, costCeilingMicroUSD: 50_000, inputPriceMicroUSDPerMillion: nil)
        #expect(a.window == 32_000)
        let b = ContextBudget.derive(modelWindow: 32_000, costCeilingMicroUSD: nil, inputPriceMicroUSDPerMillion: 3_000_000)
        #expect(b.window == 32_000)
    }

    @Test("窗口有下限，不会算出 0")
    func windowFloor() {
        let b = ContextBudget.derive(modelWindow: 100, costCeilingMicroUSD: nil, inputPriceMicroUSDPerMillion: nil)
        #expect(b.window >= 1024)
    }

    @Test("⚠️ 输出预留绝不能被挤占")
    func outputReserveIsProtected() {
        let b = budget(10_000)
        let a = b.allocation(pinnedTokens: 4_000)
        #expect(a.outputReserve == 1_000)                  // 10% 先扣出来
        #expect(a.pinned == 4_000)
        // 可分配的只有扣掉预留与必进项之后剩下的
        #expect(a.fillable <= 10_000 - 1_000 - 4_000 + 1)
        #expect(a.systemLayers + a.history + a.toolResults + a.memory <= 5_000)
    }

    @Test("必进项 > 窗口时配额归零而不是负数")
    func pinnedLargerThanWindow() {
        let b = budget(5_000)
        let a = b.allocation(pinnedTokens: 9_000)
        #expect(a.systemLayers == 0)
        #expect(a.history == 0)
        #expect(a.toolResults == 0)
        #expect(a.memory == 0)
        #expect(a.outputReserve > 0)      // 预留仍然是自己的，不被负数吃掉
    }

    @Test("配额表与 docs/07 §1.1 一致")
    func documentedRatios() {
        let r = ContextBudget.Ratios.documented
        #expect(r.systemLayers == 0.25)
        #expect(r.history == 0.30)
        #expect(r.toolResults == 0.25)
        #expect(r.memory == 0.10)
        #expect(r.outputReserve == 0.10)
        // 加起来正好是 100%（少一分就是"说不清去哪了"的额度）
        let sum = r.systemLayers + r.history + r.toolResults + r.memory + r.outputReserve
        #expect(abs(sum - 1.0) < 0.0001)
    }
}

// MARK: - 装配与自检

@Suite("ContextAssembler —— 装配管线与硬性自检")

struct ContextAssemblerTests {

    @Test("⭐ 正常装配：必进项都在，自检全过")
    func happyPath() {
        let items = [
            objective(),
            item("todo", .systemLayer1, tokens: 30, pinned: .openTodos),
            item("fail", .history, tokens: 40, pinned: .lastFailure),
            item("h1", .history, tokens: 200, relevance: 0.9),
            item("t1", .toolResult, tokens: 300, relevance: 0.8),
            item("m1", .memory, tokens: 100, relevance: 0.6),
        ]
        let assembly = ContextAssembler.assemble(items: items, budget: budget(10_000))
        #expect(assembly.passed)
        #expect(assembly.degradationRounds == 0)
        #expect(assembly.blocks.contains { $0.id == "obj" })
        #expect(assembly.blocks.contains { $0.id == "todo" })
        #expect(assembly.blocks.contains { $0.id == "fail" })
        #expect(assembly.selfChecks.allSatisfy { $0.passed })
    }

    @Test("⚠️ 缺「当前目标」→ 自检必须失败（这是 Agent 跑偏的第一大原因）")
    func missingObjectiveFailsCheck() {
        let items = [item("h1", .history, tokens: 200)]
        let assembly = ContextAssembler.assemble(items: items, budget: budget(10_000))
        let check = assembly.selfChecks.first { $0.kind == .objectivePresent }
        #expect(check?.passed == false)
        #expect(assembly.passed == false)
        #expect(check?.detail.contains("跑偏") == true)
    }

    @Test("⚠️ 失败上报时要说清是哪里不满足，而不是笼统的「装配失败」")
    func checkDetailsAreActionable() {
        let assembly = ContextAssembler.assemble(items: [], budget: budget(10_000))
        let failing = assembly.selfChecks.filter { !$0.passed }
        #expect(failing.count == 1)
        #expect(failing[0].kind == .objectivePresent)
        #expect(!failing[0].detail.isEmpty)
    }

    @Test("没有 todo / 没有失败 → 不该要求它们在场（有条件必进）")
    func conditionalChecksDoNotOverreach() {
        let assembly = ContextAssembler.assemble(items: [objective()], budget: budget(10_000))
        #expect(assembly.passed)
        #expect(assembly.selfChecks.first { $0.kind == .openTodosPresent }?.passed == true)
        #expect(assembly.selfChecks.first { $0.kind == .lastFailurePresent }?.passed == true)
    }

    @Test("⚠️ 不可信内容在场时必须带上边界标记（否则提示注入防线就没了）")
    func untrustedBoundaryRequired() {
        let web = item(
            "web", .toolResult, tokens: 200,
            trust: .untrustedContent,
            taint: TaintOrigin(source: "web:https://evil.test/x", fetchedAt: Date(), note: nil)
        )
        let assembly = ContextAssembler.assemble(items: [objective(), web], budget: budget(10_000))
        #expect(assembly.hasUntrustedContent)
        #expect(assembly.selfChecks.first { $0.kind == .untrustedBoundaryPresent }?.passed == true)
    }

    @Test("有不可信内容但一个都没进上下文 → 边界检查通过（因为没东西需要标记）")
    func untrustedNotIncludedIsFine() {
        let assembly = ContextAssembler.assemble(items: [objective()], budget: budget(10_000))
        #expect(!assembly.hasUntrustedContent)
        #expect(assembly.selfChecks.first { $0.kind == .untrustedBoundaryPresent }?.passed == true)
    }

    @Test("⚠️ 必进项本身就撑爆窗口 → 自检失败，**调用方必须不许发出去**")
    func mustHavesTooBigMustFail() {
        let huge = item("obj", .systemLayer1, tokens: 50_000, text: String(repeating: "目标", count: 25_000), pinned: .objective)
        let assembly = ContextAssembler.assemble(items: [huge], budget: budget(4_000))
        #expect(!assembly.passed)
        let within = assembly.selfChecks.first { $0.kind == .withinWindow }
        #expect(within?.passed == false)
        // 必进项**不能**为了腾地方被丢掉
        #expect(assembly.blocks.contains { $0.id == "obj" })
    }

    @Test("⚠️ 去重：同样的内容不该占两份预算")
    func dedupeByContentKey() {
        let items = [
            objective(),
            item("r1", .toolResult, tokens: 500, dedupe: "sha:src/a.py"),
            item("r2", .toolResult, tokens: 500, dedupe: "sha:src/a.py"),
        ]
        let assembly = ContextAssembler.assemble(items: items, budget: budget(10_000))
        #expect(assembly.blocks.filter { $0.block == .toolResult }.count == 1)
        #expect(assembly.dropped.contains { $0.reason == .duplicate })
    }

    @Test("⭐ 打分：用户显式引用排在普通工具结果之前")
    func userReferenceScoresHigher() {
        let referenced = item("u1", .userExplicit, tokens: 200, relevance: 0.5, pinned: .userReference)
        let plain = item("t1", .toolResult, tokens: 200, relevance: 0.5)
        let cfg = ContextAssembler.Config.default
        #expect(ContextAssembler.score(referenced, config: cfg) > ContextAssembler.score(plain, config: cfg))
    }

    @Test("⚠️ 污点内容打分要受罚（同样的相关性下优先排除）")
    func taintPenalised() {
        let clean = item("c", .toolResult, tokens: 200, relevance: 0.9)
        let tainted = item(
            "d", .toolResult, tokens: 200, relevance: 0.9,
            trust: .untrustedContent,
            taint: TaintOrigin(source: "web:x", fetchedAt: Date(), note: nil)
        )
        let cfg = ContextAssembler.Config.default
        #expect(ContextAssembler.score(tainted, config: cfg) < ContextAssembler.score(clean, config: cfg))
    }

    @Test("大块内容要按 token 成本扣分（否则一个 20k 的日志会把整个预算吃掉）")
    func tokenCostPenalty() {
        let small = item("s", .toolResult, tokens: 100, relevance: 0.8)
        let huge = item("b", .toolResult, tokens: 20_000, relevance: 0.8)
        let cfg = ContextAssembler.Config.default
        #expect(ContextAssembler.score(huge, config: cfg) < ContextAssembler.score(small, config: cfg))
    }

    @Test("超配额的非必进项会被丢弃，并记录原因")
    func overQuotaIsRecorded() {
        var items = [objective()]
        for i in 0..<30 {
            items.append(item("t\(i)", .toolResult, tokens: 500, relevance: 0.5))
        }
        let assembly = ContextAssembler.assemble(items: items, budget: budget(6_000))
        #expect(assembly.dropped.contains { $0.reason == .overQuota })
        let toolTokens = assembly.blocks.filter { $0.block == .toolResult }.reduce(0) { $0 + $1.tokens }
        #expect(toolTokens <= assembly.allocation.toolResults)
    }

    @Test("⚠️ 必进项不受配额约束（用户点名要看的东西不能被悄悄丢掉）")
    func pinnedBypassesQuota() {
        var items = [objective()]
        for i in 0..<20 { items.append(item("t\(i)", .toolResult, tokens: 500)) }
        items.append(item("ref", .userExplicit, tokens: 900, pinned: .userReference))
        let assembly = ContextAssembler.assemble(items: items, budget: budget(6_000))
        #expect(assembly.blocks.contains { $0.id == "ref" })
    }
}

// MARK: - 稳定性（Prompt Cache 的前提）

@Suite("ContextAssembler —— 字节稳定")

struct ContextStabilityTests {

    private func sample() -> [ContextItem] {
        [
            objective(),
            item("l2", .systemLayer2, tokens: 120, text: "项目指令：不要动 vendor/", recency: 1.0),
            item("map", .workspaceMap, tokens: 200, recency: 0.9),
            item("h1", .history, tokens: 200, recency: 0.8),
            item("h2", .history, tokens: 200, recency: 0.7),
            item("t1", .toolResult, tokens: 300, recency: 0.9),
            item("m1", .memory, tokens: 100, recency: 0.5),
        ]
    }

    @Test("⭐ 同一批素材装配两次，字节必须完全一致")
    func sameInputSameBytes() {
        let a = ContextAssembler.assemble(items: sample(), budget: budget(20_000))
        let b = ContextAssembler.assemble(items: sample(), budget: budget(20_000))
        #expect(a.renderedText == b.renderedText)
        #expect(a.blocks.map(\.id) == b.blocks.map(\.id))
    }

    @Test("⭐ 只追加新的工具结果时，系统层的字节前缀必须不变（否则缓存永不命中）")
    func systemLayerPrefixIsStable() {
        let base = sample()
        let withMore = base + [item("t2", .toolResult, tokens: 300, recency: 1.0)]

        let a = ContextAssembler.assemble(items: base, budget: budget(20_000))
        let b = ContextAssembler.assemble(items: withMore, budget: budget(20_000))

        let prefixA = a.blocks.filter { $0.block == .systemLayer1 || $0.block == .systemLayer2 }.map(\.text)
        let prefixB = b.blocks.filter { $0.block == .systemLayer1 || $0.block == .systemLayer2 }.map(\.text)
        #expect(prefixA == prefixB)
        #expect(b.renderedText.hasPrefix(prefixB.joined(separator: "\n\n")))
    }

    @Test("渲染顺序固定：系统层 → 工作区 → 转向/引用 → 记忆 → 历史 → 工具结果")
    func blockOrderIsFixed() {
        let assembly = ContextAssembler.assemble(items: sample(), budget: budget(20_000))
        let order = assembly.blocks.map { ContextAssembler.blockOrder.firstIndex(of: $0.block) ?? 99 }
        #expect(order == order.sorted())
    }
}

// MARK: - L1 结构化裁剪

@Suite("L1 结构化裁剪 —— 结论 + 关键行 + 制品句柄")

struct StructuralTrimTests {

    private func bigToolResult() -> ContextItem {
        var lines = ["$ pytest -q", "收集 412 个测试", "运行 412 个测试"]
        for i in 0..<400 { lines.append("第 \(i) 行：这是一堆无关紧要的中间过程输出，用来把上下文撑大") }
        lines.append("FAILED tests/test_refund.py::test_round_amount - AssertionError: 12.30 != 12.3")
        lines.append("1 failed, 411 passed")
        let text = lines.joined(separator: "\n")
        return ContextItem(
            id: "ci-log", block: .toolResult, text: text,
            tokens: TokenEstimator.estimate(text),
            recency: 0.9, artifactHandle: "artifacts/ci-log-0912.txt"
        )
    }

    @Test("⭐ 裁剪后必须**大幅变小**，且关键行与制品句柄都还在")
    func trimsButKeepsWhatMatters() {
        let original = bigToolResult()
        let trimmed = ContextAssembler.structuralTrim(original, to: 300)
        #expect(trimmed.tokens < original.tokens)
        #expect(trimmed.tokens <= 300 + 40)
        // 「关键行」：失败那条断言必须留住
        #expect(trimmed.text.contains("test_round_amount"))
        // 「制品句柄」：模型靠它按需拉全文
        #expect(trimmed.text.contains("artifacts/ci-log-0912.txt"))
        // 「结论」：头部保留
        #expect(trimmed.text.contains("pytest"))
        // 省略了多少行要如实告知（不然模型以为这就是全部输出）
        #expect(trimmed.text.contains("已省略"))
    }

    @Test("裁剪不能改变身份与安全相关字段")
    func trimPreservesIdentity() {
        let original = bigToolResult()
        let trimmed = ContextAssembler.structuralTrim(original, to: 300)
        #expect(trimmed.id == original.id)
        #expect(trimmed.block == original.block)
        #expect(trimmed.artifactHandle == original.artifactHandle)
        #expect(trimmed.trust == original.trust)
        #expect(trimmed.taint == original.taint)
    }

    @Test("本来就够小 → 一个字都不改")
    func noTrimWhenFits() {
        let small = item("s", .toolResult, tokens: 50, text: "只有一行")
        #expect(ContextAssembler.structuralTrim(small, to: 1000) == small)
    }

    @Test("裁到比下限还小 → 干脆不动（只剩标题不如整块丢掉）")
    func refusesToTrimToNothing() {
        let big = bigToolResult()
        let trimmed = ContextAssembler.structuralTrim(big, to: 5)
        #expect(trimmed == big)
    }
}

// MARK: - 压缩的分工

@Suite("压缩分工 —— 装配器永不自己花钱")

struct CompactionSplitTests {

    private func bulky() -> [ContextItem] {
        var items = [objective()]
        for i in 0..<40 {
            items.append(item("h\(i)", .history, tokens: 300, recency: Double(i) / 40.0))
        }
        return items
    }

    @Test("⚠️ 历史超阈值 → **报告**需要主模型压缩，但不自己去调模型")
    func reportsButDoesNotSpend() {
        let assembly = ContextAssembler.assemble(items: bulky(), budget: budget(6_000))
        #expect(assembly.needsMainModelCompaction)
        #expect(!assembly.compactionCandidates.isEmpty)
        // 返回的候选是 id，钱的决策留给运行时（它才会落事件、扣预算）
        #expect(assembly.compactionCandidates.allSatisfy { $0.hasPrefix("h") })
    }

    @Test("⭐ 端侧摘要（零成本）能解决就不必花主模型的钱")
    func endSideDigestAvoidsPaidCompaction() {
        let summarizer: ContextAssembler.Summarizer = { items in
            "已压缩 \(items.count) 轮对话：退款金额计算在 src/money.py:12；失败原因是 Decimal 与 float 比较。"
        }
        let assembly = ContextAssembler.assemble(
            items: bulky(), budget: budget(6_000), endSideSummarizer: summarizer
        )
        // 端侧压过之后总占用显著下降
        let withoutDigest = ContextAssembler.assemble(items: bulky(), budget: budget(6_000))
        #expect(assembly.usedTokens < withoutDigest.usedTokens)
        #expect(assembly.blocks.contains { $0.id == "end-side-digest" })
    }

    @Test("端侧摘要器返回 nil（压不动）→ 不崩，仍然给出主模型压缩建议")
    func summarizerFailureIsNotFatal() {
        let assembly = ContextAssembler.assemble(
            items: bulky(), budget: budget(6_000), endSideSummarizer: { _ in nil }
        )
        #expect(assembly.needsMainModelCompaction)
    }

    @Test("摘要的结果标记为模型输出（不是不可信内容，也不是用户指令）")
    func digestTrustLevel() {
        let summarizer: ContextAssembler.Summarizer = { _ in "要点若干" }
        let assembly = ContextAssembler.assemble(
            items: bulky(), budget: budget(6_000), endSideSummarizer: summarizer
        )
        let digest = assembly.blocks.first { $0.id == "end-side-digest" }
        #expect(digest?.trust == .modelOutput)
    }

    @Test("历史没超阈值 → 不报压缩（不要没事找事花钱）")
    func noCompactionWhenComfortable() {
        let items = [objective(), item("h1", .history, tokens: 100)]
        let assembly = ContextAssembler.assemble(items: items, budget: budget(100_000))
        #expect(!assembly.needsMainModelCompaction)
        #expect(assembly.compactionCandidates.isEmpty)
    }
}

// MARK: - 可观测

@Suite("上下文可观测 —— 用户要看得懂钱花在哪")

struct ObservabilityTests {

    @Test("一行报出：用量 / 丢弃 / 降级 / 成本")
    func observabilityLine() {
        var items = [objective()]
        for i in 0..<30 { items.append(item("t\(i)", .toolResult, tokens: 800)) }
        let assembly = ContextAssembler.assemble(items: items, budget: budget(6_000))
        let line = assembly.observabilityLine
        #expect(line.contains("token"))
        #expect(line.contains("丢弃"))
    }

    @Test("没有丢弃 / 没有降级时不要显示噪音")
    func quietWhenNothingToSay() {
        let assembly = ContextAssembler.assemble(items: [objective()], budget: budget(10_000))
        let line = assembly.observabilityLine
        #expect(!line.contains("丢弃"))
        #expect(!line.contains("降级"))
        #expect(!line.contains("建议压缩"))
    }
}
