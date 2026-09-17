import Foundation

// MARK: - 修正性重试
//
// 设计依据（docs/04 §4.4）：**三类高频错误必须由运行时主动救**，而不是直接判失败。
// 这是"长任务成功率"从「看模型运气」变成「看工程质量」的关键差异之一，
// 也是桌面 Agent 与手机上真正好用的 Agent 之间最容易被忽略的一道分水岭。
//
// ⚠️ 这里有一个**极容易写错、而且写错了也不报错**的地方，必须写在最前面：
//
//   「重试」**不是**"运行时把同一个调用再发一次"。
//
//   三家协议都要求每一个 `tool_result` 必须对应一个**真实存在**的 `tool_use` id
//   （Anthropic 的 `tool_use_id` / OpenAI 的 `tool_call_id` / Gemini 的 functionCall 配对）。
//   运行时凭空造一个"模型发出的调用"，会让**该会话后续所有请求全部 400** —— 而且是那种
//   本地测试完全看不出来、真机上必崩的错误。
//
//   所以"重试"的真实含义只有一个：**回灌一条精确到能照着改的错误**，
//   然后让模型在下一轮自己重发。运行时的全部价值，在于那条错误写得够不够准。
//
// 由此推出本文件的两个核心职责：
//   1. **写准错误**：把 schema 签名、最接近的工具名、相似路径候选都摆到模型面前
//      （见 `ToolError.modelFacingText`）；
//   2. **记账与止损**：同一个根因改不过来时**别再问同一个模型第五遍**，
//      停下来带着具体选项问用户（见 `Escalation` 与 `Option`）。

public enum Correction {

    // MARK: 参数

    public struct Limits: Sendable, Codable, Hashable {
        /// 同一个根因最多给模型几次自己改的机会
        public var maxSelfCorrections: Int
        /// 连续多少次失败（任何一次成功都清零）就认为它在乱试
        public var maxConsecutiveFailures: Int
        /// 保留多少个不同根因的记账（防止长任务里字典无限增长）
        public var maxTrackedRoots: Int

        public init(
            maxSelfCorrections: Int = 2,
            maxConsecutiveFailures: Int = 5,
            maxTrackedRoots: Int = 16
        ) {
            self.maxSelfCorrections = max(1, maxSelfCorrections)
            self.maxConsecutiveFailures = max(2, maxConsecutiveFailures)
            self.maxTrackedRoots = max(4, maxTrackedRoots)
        }
    }

    // MARK: 决策

    public enum Decision: Sendable, Codable, Hashable {
        /// 成功了。`isRecovery == true` 说明它刚把上一个错误自己改好了（**这是我们想展示给用户的信任信号**）
        case progress(isRecovery: Bool)
        /// 回灌错误，让它自己改。`isFinalAllowance` 时额外给一条"这是最后一次"的强提示
        case allowRetry(used: Int, limit: Int, isFinalAllowance: Bool, nudge: String?)
        /// 这个错误**模型改不了**（越权 / 沙箱 / 网络）→ 不计入任何计数，直接由上层处理
        case notCorrectable(kind: ToolError.Kind)
        /// 不是失败：输出过大已转制品，模型该去 `read_artifact` 取
        case pointer(hint: String)
        /// 需要停下来问用户
        case escalate(Escalation)

        /// 这个决策是否会在回灌正文里插入**运行时写的话**。
        ///
        /// 用于审计：对话里出现的每一段文字都必须能追溯到出处。
        /// 运行时往上下文里加东西不是小事 —— 它会影响模型接下来的每一个判断。
        public var injectsGuidance: Bool {
            switch self {
            case .allowRetry(_, _, _, let nudge): return nudge != nil
            case .pointer: return true
            case .progress, .notCorrectable, .escalate: return false
            }
        }
    }

    // MARK: 可选项（给用户看的三选一，而不是一个报错框）

    /// 一个**可执行**的恢复选项。
    ///
    /// 设计依据（docs/04 §14）：熔断/受阻时**不要弹报错框，要给可执行的选项**。
    /// 用户在手机上是单手操作，"下一步该干什么"必须是按钮，不是一段解释。
    public struct Option: Sendable, Codable, Hashable, Identifiable {
        public enum Action: String, Sendable, Codable, Hashable {
            /// 注入一条定向提示，让模型带着正确信息重试（**不是伪造工具调用**，见文件头注释）
            case nudge
            /// 让模型换一个完全不同的方案（避免它在原参数上无限微调）
            case changeApproach
            /// 请用户直接补一个运行时拿不到的参数
            case askUser
            /// 停止，交付当前成果
            case stop
        }

        public var id: String
        public var action: Action
        /// 按钮文字
        public var title: String
        /// 展开说明（一句话，说清代价）
        public var detail: String?
        /// `action == .nudge` 时注入对话的原文
        public var nudgeText: String?

        public init(action: Action, title: String, detail: String? = nil, nudgeText: String? = nil) {
            self.id = action.rawValue
            self.action = action
            self.title = title
            self.detail = detail
            self.nudgeText = nudgeText
        }
    }

    // MARK: 上报

    public struct Escalation: Sendable, Codable, Hashable {
        public enum Cause: String, Sendable, Codable, Hashable {
            /// 同一个根因反复出现，修正机会已用尽
            case correctionsExhausted
            /// 模型把**参数一字未改**的同一个调用又发了一遍
            case verbatimRepeat
            /// 连续多次失败，但每次根因都不同（在乱试）
            case thrashing
        }

        public var cause: Cause
        public var toolName: String
        public var errorKind: ToolError.Kind?
        public var failureCount: Int
        public var limit: Int
        /// 一句话（UI 卡片标题）
        public var headline: String
        /// 详情（含最后一次的精确错误；用户想知道"到底卡在哪"时展开看）
        public var detail: String
        public var options: [Option]

        public init(
            cause: Cause,
            toolName: String,
            errorKind: ToolError.Kind?,
            failureCount: Int,
            limit: Int,
            headline: String,
            detail: String,
            options: [Option]
        ) {
            self.cause = cause
            self.toolName = toolName
            self.errorKind = errorKind
            self.failureCount = failureCount
            self.limit = limit
            self.headline = headline
            self.detail = detail
            self.options = options
        }
    }

    // MARK: 根因键

    /// 根因键 = `错误种类:工具名`。
    ///
    /// ⚠️ 为什么按「工具名」而不是按「具体参数」分桶：模型路径写错时，
    /// 它会**每次试一个不同的错路径**。若按路径分桶，每个桶都只出现一次，
    /// 计数永远到不了阈值 —— 熔断就废了。按工具分桶才抓得住「在这个工具上就是搞不定」。
    ///
    /// 唯一的例外是 `unknownTool`：那时工具根本不存在，用**模型瞎编的那个名字**做键。
    /// `unknownTool:read_files` 出现三次（就是改不过来）
    /// 与 `unknownTool:read_files` / `unknownTool:ls_dir` / `unknownTool:cat` 各一次（只是不熟工具表）
    /// 是两件完全不同的事，混在一个桶里数会误伤。
    static func rootKey(kind: ToolError.Kind, toolName: String) -> String {
        "\(kind.rawValue):\(toolName)"
    }

    // MARK: 参数签名（回灌用）

    /// 把一个 `ToolSpec` 的入参压成一行"参数清单"。
    ///
    /// ⚠️ 为什么值得单独写：模型参数出错时，**只告诉它「参数不合法」几乎等于没说** ——
    /// 它看不到自己错在哪，只能再猜一次。把必填/类型/枚举值原样再摆一遍，
    /// 修正率会明显上升，而且这条信息是**确定的**（来自我们自己的 schema），不是猜的。
    public static func signature(of spec: ToolSpec?) -> String {
        guard let spec else { return "" }
        return signature(of: spec.inputSchema)
    }

    public static func signature(of schema: JSONSchema) -> String {
        guard case .object(let props, let required, _) = schema, !props.isEmpty else { return "" }
        let requiredSet = Set(required)
        return props.keys.sorted().map { key in
            let optional = requiredSet.contains(key) ? "必填" : "选填"
            return "`\(key)`：\(typeName(props[key] ?? .any))（\(optional)）"
        }.joined(separator: "、")
    }

    static func typeName(_ schema: JSONSchema) -> String {
        switch schema {
        case .object:   return "对象"
        case .array:    return "数组"
        case .string(let enumValues, _, _):
            if let enumValues, !enumValues.isEmpty {
                return "枚举（只能是 \(enumValues.joined(separator: " / ")) 之一）"
            }
            return "字符串"
        case .integer:  return "整数"
        case .number:   return "数字"
        case .boolean:  return "布尔"
        case .any:      return "任意值"
        }
    }

    // MARK: 选项构造

    /// 按错误种类生成**可执行**的恢复选项。
    static func options(
        for attempt: CorrectionLedger.Attempt,
        spec: ToolSpec?,
        cause: Escalation.Cause
    ) -> [Option] {
        var options: [Option] = []

        switch attempt.errorKind {
        case .unknownTool:
            if let correct = attempt.lastCandidates.first {
                options.append(Option(
                    action: .nudge,
                    title: "让它改用 `\(correct)` 重试",
                    detail: "参数沿用上一条，你刚才给的参数是对的。",
                    nudgeText: """
                    你上一条调用的工具名「\(attempt.toolName)」不存在，我们这边**没有**这个工具。
                    请立刻改用 `\(correct)`，**参数沿用你刚才给的那一份**（参数本身没有问题）。
                    不要再使用「\(attempt.toolName)」。
                    """
                ))
            }

        case .invalidArguments:
            let sig = signature(of: spec)
            let fieldHint = attempt.lastCandidates.isEmpty
                ? ""
                : "\n出错的字段：\(attempt.lastCandidates.map { "`\($0)`" }.joined(separator: "、"))"
            options.append(Option(
                action: .nudge,
                title: "把准确的参数格式再讲一遍",
                detail: sig.isEmpty ? "把 schema 原文与出错字段重新回灌一次。" : "参数清单：\(sig)",
                nudgeText: """
                你上一条对 `\(attempt.toolName)` 的调用参数不合法。
                \(sig.isEmpty ? "" : "它的参数是：\(sig)")\(fieldHint)
                请**只改正参数**，重新发一次这个调用；不要放弃这个工具，也不要换成别的工具。
                """
            ))
            options.append(Option(
                action: .askUser,
                title: "我来告诉它正确的参数",
                detail: "适合你自己知道该填什么、而模型猜不到的情况（例如某个内部路径）。"
            ))

        case .pathNotFound:
            let candidates = attempt.lastCandidates
            if !candidates.isEmpty {
                options.append(Option(
                    action: .nudge,
                    title: "用候选路径重试（\(candidates.prefix(3).joined(separator: "、"))）",
                    detail: "这些是本工作区里名字最接近的真实路径。",
                    nudgeText: """
                    你给的路径不存在。工作区里名字最接近的真实路径是：\(candidates.prefix(6).joined(separator: "、"))。
                    其中若有你要找的那个，请直接用它重试；**若都不对，先用 `list_dir` 把所在目录看一遍再动手。**
                    """
                ))
            }
            options.append(Option(
                action: .nudge,
                title: "先列目录确认，再动手",
                detail: "让它停下来看一眼真实结构，而不是继续猜路径。",
                nudgeText: """
                你连续给了不存在的路径。**停止猜路径。**
                请先用 `list_dir` 或 `glob` 把这个项目里真实存在的文件列出来，确认之后再执行原来的操作。
                """
            ))

        default:
            break
        }

        // 「换方案」与「停下」永远可用：任何卡死都应该有一条"别硬扛"的出口。
        options.append(Option(
            action: .changeApproach,
            title: "让它换个完全不同的做法",
            detail: "禁止它在原参数上继续微调——那种试法已经试过了。",
            nudgeText: """
            你在这个步骤上已经连续失败 \(attempt.count) 次，**不要再在原参数上微调了**。
            请换一个**完全不同的做法**完成这一步：先用一句话说明你打算怎么做，再执行。
            如果确实没有别的办法，就直说，不要重复同一个动作。
            """
        ))
        options.append(Option(
            action: .stop,
            title: "就在这里停下",
            detail: "已完成的部分都保留，随时可以再继续。"
        ))

        _ = cause
        return options
    }

    /// 用户直接补上参数之后要注入的引导语。
    public static func userSuppliedNudge(field: String, value: String, toolName: String) -> String {
        """
        用户为 `\(toolName)` 提供了参数 `\(field)`：\(value)
        请用它重新发起这个调用。
        """
    }
}

// MARK: - 用户的选择

/// 用户在"修正失败"卡片上做出的选择。
///
/// 它是**待消费**的：由运行时写进 `TurnState.pendingCorrectionResolution`，
/// 再由 `.awaitingUser` 那一步转成 `CorrectionResolved` 事件并生效。
public struct CorrectionResolution: Sendable, Codable, Hashable {
    public var action: Correction.Option.Action
    /// 要注入对话的定向提示（`nudge` / `askUser` 时必有）。
    ///
    /// ⚠️ 它会作为 `.runtimeGuidance` 来源的文本进入上下文 —— 可以提示模型，
    ///    但**不能**驱动需要审批的危险动作（见 `TrustLevel` 的注释）。
    public var nudge: String?

    public init(action: Correction.Option.Action, nudge: String? = nil) {
        self.action = action
        self.nudge = nudge
    }
}

// MARK: - 记账

/// 修正性重试的**可持久化**记账。
///
/// 为什么必须持久化：手机上"一次 Turn 中途被结束"是常态（切后台、内存回收、用户插话）。
/// 如果不落盘，用户切回来之后 Agent 会从零开始烧同一批 token 犯同一个错。
public struct CorrectionLedger: Sendable, Codable, Hashable {

    /// 单个根因的记账
    public struct Attempt: Sendable, Codable, Hashable {
        public var key: String
        public var errorKind: ToolError.Kind
        public var toolName: String
        /// 已用掉几次修正机会
        public var count: Int
        public var lastMessage: String
        public var lastSuggestion: String?
        public var lastCandidates: [String]
        /// 上一次失败的**参数指纹**（用于识别"参数一字未改又发了一遍"）
        public var lastArgumentsFingerprint: String
        /// 连续逐字重复的次数
        public var repeatedVerbatim: Int
        /// 是否已经为这个根因上报过（防止重复弹卡片）
        public var didEscalate: Bool
    }

    /// 根因键 → 记账
    public private(set) var attempts: [String: Attempt] = [:]
    /// 插入顺序（用于按容量淘汰最旧的）
    public private(set) var order: [String] = []
    /// 最近一次失败的根因键（成功时用来判定"它自己改好了"）
    public private(set) var lastKey: String?
    /// 连续失败数（**任何一次成功都清零**）
    public private(set) var consecutiveFailures: Int = 0
    /// 模型自己改好的次数（给用户看的信任信号）
    public private(set) var recoveredCount: Int = 0
    /// 被放弃的项数
    public private(set) var abandonedCount: Int = 0
    /// 最近几次失败的一行摘要（用于"在乱试"时的解释）
    public private(set) var recentFailures: [String] = []
    /// 当前还在等用户决策的上报
    public private(set) var lastEscalation: Correction.Escalation?

    public init() {}

    /// 给 UI 看的一行统计（没有值得说的就不显示）
    public var summaryLine: String? {
        var parts: [String] = []
        if recoveredCount > 0 { parts.append("已自动修正 \(recoveredCount) 次") }
        if abandonedCount > 0 { parts.append("放弃 \(abandonedCount) 项") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 是否正等着用户对一次"修正失败"做决定
    public var needsUserDecision: Bool { lastEscalation != nil }

    // MARK: 记账主入口

    /// 记录一次工具结果，并给出**下一步该怎么办**。
    public mutating func record(
        call: ToolCall,
        result: ToolResult,
        spec: ToolSpec?,
        limits: Correction.Limits = .init()
    ) -> Correction.Decision {
        guard result.status != .ok else { return recordSuccess() }

        let error = result.error
        let kind = error?.kind ?? .other

        // 输出过大**不是失败**：工具干了活，只是把全文挪到制品里了。
        // 把它算进失败计数会让"读了一个大文件"变成"模型不行"，那是误判。
        if kind == .outputTooLarge {
            let hint = result.artifacts.first.map { "输出过大已存为制品 `\($0.relPath)`，请用 `read_artifact` 分段读取，不要重跑这个工具。" }
                ?? "输出过大已被截断；请缩小范围重试，或用 `read_artifact` 分段读取，不要重跑这个工具。"
            return .pointer(hint: hint)
        }

        let isBudgeted = error?.isSelfCorrectable ?? false
        let key = Correction.rootKey(kind: kind, toolName: toolName(for: kind, call: call))
        let fingerprint = Self.argumentsFingerprint(call)

        // ---------- 1. 取或建记账 ----------
        var attempt = attempts[key] ?? Attempt(
            key: key,
            errorKind: kind,
            toolName: toolName(for: kind, call: call),
            count: 0,
            lastMessage: "",
            lastSuggestion: nil,
            lastCandidates: [],
            lastArgumentsFingerprint: "",
            repeatedVerbatim: 0,
            didEscalate: false
        )
        attempt.lastMessage = error?.modelFacingMessage ?? result.summary
        attempt.lastSuggestion = error?.suggestion
        attempt.lastCandidates = error?.candidates ?? []

        // ---------- 2. 逐字重复检测（**所有错误种类都要做**） ----------
        //
        // 参数一字未改地重发，结果一定一模一样。哪怕这个错误"模型改不了"
        // （比如越权），重复发也说明它没在听 —— 这正是该停下的信号。
        if attempt.lastArgumentsFingerprint == fingerprint {
            attempt.repeatedVerbatim += 1
        } else {
            attempt.repeatedVerbatim = 0
            attempt.lastArgumentsFingerprint = fingerprint
        }

        if isBudgeted {
            attempt.count += 1
            consecutiveFailures += 1
        }

        attempts[key] = attempt
        touch(key: key, limits: limits)
        lastKey = key
        recentFailures.append("\(attempt.toolName)：\(shortReason(attempt))")
        if recentFailures.count > 8 { recentFailures.removeFirst(recentFailures.count - 8) }

        // ---------- 3. 判定 ----------

        // 3a. 逐字重复：**立刻上报**，不必等计数用完。
        //     同一个调用第三次原样发出时，再回灌一次错误只是浪费一次模型往返。
        if attempt.repeatedVerbatim >= 1 {
            return .escalate(makeEscalation(
                cause: .verbatimRepeat, attempt: attempt, spec: spec, limits: limits
            ))
        }

        // 3b. 模型改不了 → 交给上层（策略/沙箱/网络各有各的处理），不计入任何计数
        if !isBudgeted {
            if attempt.didEscalate { attempt.didEscalate = false; attempts[key] = attempt }
            return .notCorrectable(kind: kind)
        }

        // 3c. 修正机会用尽
        if attempt.count > limits.maxSelfCorrections {
            return .escalate(makeEscalation(
                cause: .correctionsExhausted, attempt: attempt, spec: spec, limits: limits
            ))
        }

        // 3d. 在乱试（连续失败但每次根因都不同）
        if consecutiveFailures >= limits.maxConsecutiveFailures {
            return .escalate(makeEscalation(
                cause: .thrashing, attempt: attempt, spec: spec, limits: limits
            ))
        }

        // 3e. 还能救：回灌错误，让它自己改
        let isFinal = attempt.count >= limits.maxSelfCorrections
        return .allowRetry(
            used: attempt.count,
            limit: limits.maxSelfCorrections,
            isFinalAllowance: isFinal,
            nudge: isFinal ? Self.finalAllowanceNudge(attempt: attempt, spec: spec) : nil
        )
    }

    /// 记录一次成功。
    public mutating func recordSuccess() -> Correction.Decision {
        consecutiveFailures = 0
        guard let key = lastKey else { return .progress(isRecovery: false) }
        lastKey = nil
        guard let attempt = attempts[key] else { return .progress(isRecovery: false) }

        // 根因解决 → **把记账删掉**。
        // 不删的话，一小时内十次互不相关的失败会攒成一次假熔断。
        attempts.removeValue(forKey: key)
        order.removeAll { $0 == key }
        recoveredCount += 1
        _ = attempt
        return .progress(isRecovery: true)
    }

    // MARK: 用户决策之后

    /// 用户对一次上报做出选择后调用：清掉上报、给这个根因**重新开一份额度**。
    ///
    /// 为什么要重开额度：用户点了"继续"就是明确表示"我知道它卡在这，还是让它试"。
    /// 沿用旧计数会立刻再次熔断 —— 那等于用户的选择无效。
    public mutating func clearEscalation() {
        lastEscalation = nil
        lastKey = nil
        consecutiveFailures = 0
        guard let key = attempts.keys.first(where: { attempts[$0]?.didEscalate == true }),
              var attempt = attempts[key] else { return }
        attempt.didEscalate = false
        attempt.count = 0
        attempt.repeatedVerbatim = 0
        attempts[key] = attempt
    }

    /// 记一次放弃（用于统计与 UI 展示）
    public mutating func recordAbandon() {
        abandonedCount += 1
    }

    /// 用户直接插话改方向：这是"新情况"，应该给模型干净的记账
    /// —— 否则它会被用户上一段路走错时攒下的失败拖累。
    public mutating func resetForNewDirection() {
        attempts.removeAll()
        order.removeAll()
        lastKey = nil
        consecutiveFailures = 0
        recentFailures.removeAll()
        lastEscalation = nil
    }

    // MARK: 内部

    private mutating func touch(key: String, limits: Correction.Limits) {
        if !order.contains(key) { order.append(key) }
        while order.count > limits.maxTrackedRoots {
            let oldest = order.removeFirst()
            attempts.removeValue(forKey: oldest)
        }
    }

    /// ⚠️ `unknownTool` 用模型瞎编的名字做键，其余用真实工具名。
    private func toolName(for kind: ToolError.Kind, call: ToolCall) -> String {
        call.name
    }

    private func shortReason(_ attempt: Attempt) -> String {
        let message = attempt.lastMessage.replacingOccurrences(of: "\n", with: " ")
        return message.count > 40 ? String(message.prefix(40)) + "…" : message
    }

    /// 参数指纹：工具名 + **规范化**的参数 JSON（键序无关，避免模型换了个键序就被当成新错误）
    static func argumentsFingerprint(_ call: ToolCall) -> String {
        let canonical = (try? call.arguments())?.canonicalString() ?? String(decoding: call.argumentsJSON, as: UTF8.self)
        return SHA256.hexDigest("\(call.name)\u{1}\(canonical)")
    }

    /// 最后一根稻草上的强提示。
    ///
    /// ⚠️ 这条提示**不能**作为新消息追加 —— 它会夹在 assistant 的工具调用与 tool 结果之间，
    /// 那是协议违规。只能挂在工具结果正文里（见 `Correction.delivered`）。
    static func finalAllowanceNudge(attempt: Attempt, spec: ToolSpec?) -> String {
        var text = """
        ⚠️ 这是最后一次自动修正机会。上面对 `\(attempt.toolName)` 的调用已经失败 \(attempt.count) 次，原因都是同一个。
        请**先看懂上面的错误**，再决定怎么做 —— 如果改不出来，就直接说明你卡在哪，不要再重发同样的调用。
        """
        let sig = Correction.signature(of: spec)
        if !sig.isEmpty { text += "\n`\(attempt.toolName)` 的正确参数是：\(sig)" }
        return text
    }

    private mutating func makeEscalation(
        cause: Correction.Escalation.Cause,
        attempt: Attempt,
        spec: ToolSpec?,
        limits: Correction.Limits
    ) -> Correction.Escalation {
        let options = Correction.options(for: attempt, spec: spec, cause: cause)
        let label = "`\(attempt.toolName)`"

        let headline: String
        let detail: String
        switch cause {
        case .correctionsExhausted:
            headline = "\(label) 连续 \(attempt.count) 次失败，原因都是同一个，我已把精确的错误回灌了 \(attempt.count - 1) 次"
            detail = """
            最后一次的错误：\(attempt.lastMessage)
            \(attempt.lastSuggestion.map { "我们的建议：\($0)" } ?? "")
            继续把同样的话重复给同一个模型，大概率还是同样的结果 —— 所以先停下来让你选。
            """
        case .verbatimRepeat:
            headline = "模型把 \(label) 原封不动又发了一遍（参数一字未改）"
            detail = """
            参数完全相同，所以结果一定还是同样的失败：\(attempt.lastMessage)
            这不是"再试一次"，是"卡住了"。
            """
        case .thrashing:
            headline = "连续 \(consecutiveFailures) 次工具调用全部失败，而且每次原因都不一样"
            detail = """
            最近几次：\(recentFailures.suffix(5).joined(separator: "；"))
            每次都换一个错法，通常说明它对当前任务的判断是错的（比如整个目录找错了），
            而不是某一次参数写错了。
            """
        }

        let escalation = Correction.Escalation(
            cause: cause,
            toolName: attempt.toolName,
            errorKind: attempt.errorKind,
            failureCount: cause == .thrashing ? consecutiveFailures : attempt.count,
            limit: limits.maxSelfCorrections,
            headline: headline,
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines),
            options: options
        )
        if var stored = attempts[attempt.key] {
            stored.didEscalate = true
            attempts[attempt.key] = stored
        }
        lastEscalation = escalation
        return escalation
    }
}

// MARK: - 回灌成品

public extension Correction {

    /// 把决策里"要说给模型听的话"挂进工具结果正文。
    ///
    /// ⚠️ 只有这一个地方能改变回灌内容，原因见文件头：
    /// 工具结果是**唯一**可以在 assistant 的 tool_call 之后合法插入文本的位置。
    static func delivered(_ result: ToolResult, decision: Decision) -> ToolResult {
        var extra: [String] = []
        switch decision {
        case .allowRetry(_, _, _, let nudge):
            if let nudge { extra.append(nudge) }
        case .pointer(let hint):
            extra.append(hint)
        case .progress, .notCorrectable, .escalate:
            break
        }
        guard !extra.isEmpty else { return result }

        let merged = ([result.summary] + extra).filter { !$0.isEmpty }.joined(separator: "\n\n")
        return ToolResult(
            callID: result.callID,
            status: result.status,
            summary: merged,
            artifacts: result.artifacts,
            metrics: result.metrics,
            error: result.error
        )
    }
}
