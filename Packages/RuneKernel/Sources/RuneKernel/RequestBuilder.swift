import Foundation

// MARK: - 出站请求的构建与体检
//
// 这是"历史 → 真正发出去的请求"这一段。之前它**不存在**：
// `TurnRunner` 通过 `Dependencies.modelEvents` 拿到的是已经解好的 `[ModelEvent]`，
// 谁把这些消息编成请求、用什么顺序放工具、发之前检查什么，没有任何地方回答。
//
// ## 为什么"发之前必须体检"值得单独做一层
//
// 三家的协议里有一条最容易踩、代价也最高的规则（T18）：
// **assistant 里的每个 tool_call 都必须有恰好一个配对结果，且必须紧跟在它后面。**
// 违反它的后果不是"少一个功能"，而是**后续所有请求 400**，报错信息还和真实原因毫不相干。
//
// `TurnRunner.reapOrphanCalls` 已经在 `.reasoning` 入口兜了一次底，但那**只在 TurnRunner 里**。
// 而历史还能从别处来：崩溃恢复、修正后重放、子代理、Workflow。
// 所以这道闸必须长在**构建请求的地方**，而不是只长在运行时的一个分支里 ——
// 否则它迟早会被绕过（这正是 T48 的教训：规则要有唯一执行入口）。

/// 体检发现的问题
public struct OutboundIssue: Sendable, Hashable {
    public enum Severity: String, Sendable, Hashable {
        /// **不许发出去**（发出去就是三家全 400，而且报错与原因不相干）
        case blocking
        /// 值得看一眼（不拦）
        case warning
    }

    public var severity: Severity
    /// 出问题在哪（"messages[3]" / "tools"）
    public var location: String
    public var detail: String
    /// **可执行的下一步**（只报错不给出路的诊断等于没诊断）
    public var fix: String

    public init(severity: Severity, location: String, detail: String, fix: String) {
        self.severity = severity
        self.location = location
        self.detail = detail
        self.fix = fix
    }
}

/// 体检报告
public struct OutboundReport: Sendable, Hashable {
    public var issues: [OutboundIssue]
    /// 这一份历史编码后会用到哪个协议族（诊断用）
    public var family: ProtocolFamily

    public init(issues: [OutboundIssue], family: ProtocolFamily) {
        self.issues = issues
        self.family = family
    }

    public var blockingIssues: [OutboundIssue] { issues.filter { $0.severity == .blocking } }
    public var isSendable: Bool { blockingIssues.isEmpty }

    /// 给用户/模型看的一句话（空报告返回 nil，避免刷屏）
    public var summary: String? {
        guard !blockingIssues.isEmpty else { return nil }
        var lines = ["这个请求有 \(blockingIssues.count) 处会让模型直接报错的问题，已拦下："]
        for issue in blockingIssues.prefix(3) {
            lines.append("· \(issue.location)：\(issue.detail)")
            lines.append("  改法：\(issue.fix)")
        }
        return lines.joined(separator: "\n")
    }
}

/// 出站请求被拦下（**失败关闭**：有问题就绝不发，而不是"发出去试试"）
public struct OutboundBlocked: Sendable, Hashable, Error {
    public var report: OutboundReport
    public var userFacingText: String
    public init(report: OutboundReport) {
        self.report = report
        self.userFacingText = report.summary ?? "请求未通过出站体检。"
    }
}

// MARK: - 体检

public enum OutboundCheck {

    /// 一份历史能不能发出去。
    ///
    /// 检查的就是"会让请求 400"的那几条，不多不少 —— 检查项越多越容易被当成噪音关掉。
    ///
    /// 分四遍扫，因为**三种坏法要给出三种不同的改法**（这是这一层真正的价值）：
    ///   · 结果**根本没记**      → 去补记（`reapOrphanCalls`）
    ///   · 结果记了但**没紧跟**  → 把它挪回调用后面（引导语要放在整批结果之后）
    ///   · 结果是**多出来的**    → 对应关系串了（串行波次最容易出这个）
    public static func review(_ messages: [Message], family: ProtocolFamily) -> OutboundReport {
        var issues: [OutboundIssue] = []

        // ① 空历史：没有任何东西可发（正常流程不会出现，出现了说明状态机走错了）
        if messages.isEmpty {
            issues.append(.init(
                severity: .blocking, location: "messages",
                detail: "历史是空的，没有任何内容可发",
                fix: "确认目标（objective）已经拼进上下文 —— 装配器要求「含当前目标」是无条件的"
            ))
        }

        // 第一遍：收集每个调用的位置；顺手抓重复 id（配对会变成一对多，两家都拒）
        var callIndex: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            for call in message.blocks.compactMap(\.toolCallValue) {
                if let first = callIndex[call.id] {
                    issues.append(.init(
                        severity: .blocking, location: "messages[\(index)]",
                        detail: "工具调用 id「\(call.id)」重复了（\(call.name)，第一次在 messages[\(first)]）",
                        fix: "call id 必须唯一 —— 大概率是恢复或重放时把同一次调用记了两遍"
                    ))
                } else {
                    callIndex[call.id] = index
                }
            }
        }

        // 第二遍：每个结果的归属与顺序
        var answered: Set<String> = []
        for (index, message) in messages.enumerated() {
            for result in message.blocks.compactMap(\.toolResultValue) {
                answered.insert(result.callID)
                guard let owner = callIndex[result.callID] else {
                    issues.append(.init(
                        severity: .blocking, location: "messages[\(index)]",
                        detail: "工具结果「\(result.callID)」在历史里找不到对应的调用（孤儿结果）",
                        fix: "结果必须对应一次真实调用；多余的要么删掉，要么补一个对应的调用"
                    ))
                    continue
                }
                if owner > index {
                    issues.append(.init(
                        severity: .blocking, location: "messages[\(index)]",
                        detail: "结果出现在它的调用之前（调用在 messages[\(owner)]）",
                        fix: "把结果挪到调用之后 —— 顺序错了上游会认为这次调用没有结果"
                    ))
                }
            }
        }

        // 第三遍：assistant 里的每个调用，后面**紧邻**的那些消息必须正好覆盖它
        for (index, message) in messages.enumerated() {
            let calls = message.blocks.compactMap(\.toolCallValue)
            guard !calls.isEmpty else { continue }
            let wanted = Set(calls.map(\.id))

            var adjacent: Set<String> = []
            var cursor = index + 1
            while cursor < messages.count, messages[cursor].role == .tool {
                for result in messages[cursor].blocks.compactMap(\.toolResultValue) {
                    adjacent.insert(result.callID)
                }
                cursor += 1
            }

            let extra = adjacent.subtracting(wanted)
            if !extra.isEmpty {
                issues.append(.init(
                    severity: .blocking, location: "messages[\(index + 1)]",
                    detail: "紧跟在工具调用后面出现了不属于它的结果：\(extra.sorted().joined(separator: "、"))",
                    fix: "结果与调用必须一一对应 —— 串行波次的结果不要挪到别的轮次后面"
                ))
            }

            let notAdjacent = wanted.subtracting(adjacent)
            if !notAdjacent.isEmpty {
                // 结果**在**历史里、只是没紧跟 → 与"根本没记"是完全不同的两种改法
                let recordedLater = notAdjacent.filter { answered.contains($0) }
                let neverRecorded = notAdjacent.subtracting(recordedLater)
                let names = calls.filter { notAdjacent.contains($0.id) }.map(\.name).joined(separator: "、")

                if !neverRecorded.isEmpty {
                    issues.append(.init(
                        severity: .blocking, location: "messages[\(index)]",
                        detail: "有 \(neverRecorded.count) 个工具调用没有配对结果：\(names)",
                        fix: "每个 tool_call 都要有一条配对结果 —— 缺一条，之后**所有**请求都会 400（去补记，不是重发）"
                    ))
                }
                if !recordedLater.isEmpty {
                    issues.append(.init(
                        severity: .blocking, location: "messages[\(index)]",
                        detail: "有 \(recordedLater.count) 个结果记了但**没有紧跟**在调用之后：\(names)",
                        fix: "结果必须紧跟在调用之后、中间不插任何别的消息（运行时引导语要放在整批结果之后）"
                    ))
                }
            }
        }

        // 第四遍：空 assistant 消息 —— 编码器会把它整条丢掉，
        // 而"丢掉一条 assistant 消息"会让它后面的工具结果失去宿主
        for (index, message) in messages.enumerated()
        where message.role == .assistant && message.blocks.isEmpty {
            issues.append(.init(
                severity: .blocking, location: "messages[\(index)]",
                detail: "有一条空的 assistant 消息（没有任何内容块）",
                fix: "空消息会让后面那条工具结果失去宿主 —— 要么补内容，要么删掉这条"
            ))
        }

        return OutboundReport(issues: issues, family: family)
    }
}

// MARK: - 构建

public enum RequestBuilder {

    /// 一次构建的结果：要么给出可发的请求，要么给出"为什么发不出去"。
    public enum Outcome: Sendable {
        case ready(ChatRequest, report: OutboundReport)
        case blocked(OutboundBlocked)
    }

    /// 把（历史 + 系统块 + 工具表）拼成一份可以发出去的请求。
    ///
    /// ⚠️ **工具顺序必须由这里定死（按名字排序）**，不能让调用方递一个字典进来就直接用：
    ///    Swift 的 `Dictionary` 迭代顺序**跨进程不稳定**（String 的 hash 每进程重新播种）。
    ///    而工具定义在请求最前面、是 Prompt Cache 前缀的一部分 ——
    ///    顺序一变，缓存**每次启动都失效**，用户为此多付的钱不会有任何报错提示。
    ///    同一条也适用于请求指纹去重（`fingerprintBody` 按数组顺序拼）。
    public static func build(
        history: [Message],
        systemBlocks: [SystemBlock] = [],
        toolRegistry: [String: ToolSpec] = [:],
        allowedTools: [String]? = nil,
        maxOutputTokens: Int,
        reasoning: ReasoningRequest? = nil,
        toolChoice: ToolChoice = .auto,
        stream: Bool = true,
        family: ProtocolFamily
    ) -> Outcome {
        var issues: [OutboundIssue] = []

        if maxOutputTokens <= 0 {
            issues.append(.init(
                severity: .blocking, location: "maxOutputTokens",
                detail: "输出预留是 \(maxOutputTokens) —— 模型没有空间回答",
                fix: "给一个正数（装配器要求输出预留 ≥ 窗口的 10%）"
            ))
        }
        // ⚠️ 空历史**不再在这里重复报一次**：`review` 已经报了，而且它那条带"缺当前目标"的改法。
        //    同一个毛病报两条会稀释真正的问题（用户看到两行字，以为是两件事）。
        let report = OutboundCheck.review(history, family: family)
        issues.append(contentsOf: report.issues)

        let names = allowedTools ?? toolRegistry.keys.sorted()
        // ⚠️ 排序是这一步的重点，不是顺手为之（见上面那段注释）
        let tools = names.sorted().compactMap { toolRegistry[$0] }

        // 声明了可用但没有实现的工具：静默少一个工具比报错更难查
        let missing = names.sorted().filter { toolRegistry[$0] == nil }
        if !missing.isEmpty {
            issues.append(.init(
                severity: .warning, location: "tools",
                detail: "这些工具被允许但不在注册表里：\(missing.joined(separator: "、"))",
                fix: "要么补上实现，要么把它从允许列表里去掉 —— 悄悄少一个工具会让模型反复试"
            ))
        }

        let finalReport = OutboundReport(issues: issues, family: family)
        guard finalReport.isSendable else {
            return .blocked(OutboundBlocked(report: finalReport))
        }

        let request = ChatRequest(
            systemBlocks: systemBlocks,
            messages: history,
            tools: tools,
            toolChoice: toolChoice,
            maxOutputTokens: maxOutputTokens,
            reasoning: reasoning,
            stream: stream
        )
        return .ready(request, report: finalReport)
    }

    /// 只要请求、失败就抛（给"出错必须立刻停"的调用方用）
    public static func require(
        history: [Message],
        systemBlocks: [SystemBlock] = [],
        toolRegistry: [String: ToolSpec] = [:],
        maxOutputTokens: Int,
        reasoning: ReasoningRequest? = nil,
        toolChoice: ToolChoice = .auto,
        stream: Bool = true,
        family: ProtocolFamily
    ) throws -> ChatRequest {
        switch build(history: history, systemBlocks: systemBlocks, toolRegistry: toolRegistry,
                     maxOutputTokens: maxOutputTokens, reasoning: reasoning,
                     toolChoice: toolChoice, stream: stream, family: family) {
        case .ready(let request, _): return request
        case .blocked(let blocked): throw blocked
        }
    }
}
