import Foundation

// MARK: - 事件日志：唯一的真相源
//
// 设计依据（docs/12 §1 / §2.3 / §5）：
// **事件日志是唯一真相源** —— 会话、检查点、记忆、审计、成本账本**全部可以从事件重建**。
//
// 这句话在桌面端是一句架构上的漂亮话，在手机上是一条**硬需求**：
//
//   * App 随时会被系统杀掉（内存压力、后台超时、用户划掉），
//     所以"内存里的状态"根本不能当成真相 —— 只有落盘的事件能；
//   * 用户会怀疑"它到底往外发了什么、花了多少钱" —— 那必须能**从日志算出来**，
//     而不是靠某个界面上的数字（那个数字本身也可能算错）；
//   * 排查"为什么它当时那么做"时，唯一的依据是**当时发生了什么**。
//
// 所以这一层有两个不可分割的职责：
//   ① **写入**：单调序号 + 哈希链 + 定期锚点（防篡改，可校验）；
//   ② **投影**：从事件重建出各种只读视图（会话摘要 / 成本账本 / 审计 / 恢复计划）。
//
// ⚠️ 投影有一条**必须成立**的性质：**增量投影 == 全量重放**。
// 这条一破，缓存视图与真相就会分叉，而分叉之后没有任何东西能告诉你哪个对。

// MARK: - 锚点

/// 哈希链锚点。
///
/// ⚠️ **锚点必须存在 Agent 够不到的地方**（Keychain 或 VFS 之外的容器文件）。
/// 如果锚点和事件存在同一个可写位置，篡改者可以把两边一起改掉 —— 校验就变成了自证清白。
/// 这是 `HumanOnlyZone.hashAnchors`（docs/09）在数据层的对应物。
/// 这里的 `AnchorStore` 是协议：真实实现由 RuneStore 走 Keychain，测试用内存版。
public struct EventAnchor: Sendable, Codable, Hashable {
    /// 这个锚点覆盖到第几条（含）
    public var sequence: Int64
    /// 第 `sequence` 条事件的哈希 —— 由于链式结构，它同时钉住了它之前的全部事件
    public var hash: Data
    public var createdAt: Date

    public init(sequence: Int64, hash: Data, createdAt: Date) {
        self.sequence = sequence
        self.hash = hash
        self.createdAt = createdAt
    }
}

public protocol AnchorStore: Sendable {
    func loadLatest() -> EventAnchor?
    func save(_ anchor: EventAnchor)
}

public final class InMemoryAnchorStore: AnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var anchor: EventAnchor?
    public init() {}
    public func loadLatest() -> EventAnchor? { lock.lock(); defer { lock.unlock() }; return anchor }
    public func save(_ anchor: EventAnchor) { lock.lock(); self.anchor = anchor; lock.unlock() }
}

// MARK: - 校验结果

public struct ChainVerification: Sendable, Hashable {
    public enum Outcome: String, Sendable, Hashable {
        case ok
        /// 链断了：某条事件的 `previousHash` 与上一条的 `hash` 对不上
        case brokenLink
        /// 事件内容被改过（哈希自校验失败）
        case tampered
        /// 锚点之后的事件少于锚点覆盖的范围 —— 说明事件被**删掉了**
        case truncated
    }

    public var outcome: Outcome
    public var checkedFrom: Int64
    public var checkedCount: Int
    public var firstBadSequence: Int64?
    public var detail: String

    public var isOK: Bool { outcome == .ok }

    public init(outcome: Outcome, checkedFrom: Int64, checkedCount: Int,
                firstBadSequence: Int64? = nil, detail: String) {
        self.outcome = outcome
        self.checkedFrom = checkedFrom
        self.checkedCount = checkedCount
        self.firstBadSequence = firstBadSequence
        self.detail = detail
    }

    /// 给用户看的一句话（**不要吓人，要说清下一步**）
    public var userFacingText: String {
        guard !isOK else { return "历史记录校验通过。" }
        var text = "历史记录校验未通过（第 \(firstBadSequence ?? 0) 条附近有问题）。\n"
        switch outcome {
        case .truncated:
            text += "有记录被删掉了。"
        case .tampered:
            text += "有记录的内容被改动过。"
        case .brokenLink:
            text += "记录之间的衔接断了。"
        case .ok:
            break
        }
        text += "\n为了避免基于错误的历史继续执行，**自动续跑已停止**。你可以导出原始数据，或重建索引。"
        return text
    }
}

// MARK: - 事件日志

/// 追加式事件日志。
///
/// 真实实现落在 SQLite（RuneStore，macOS 阶段）；这里的内存实现是**同一套语义**，
/// 因此投影与恢复计划的逻辑可以在本机被完整验证。
public final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RuntimeEvent] = []
    private var anchors: [EventAnchor] = []

    public let sessionID: UUID
    /// 每多少条打一个锚点（docs/12 §2.3 取 1000）
    public let anchorInterval: Int
    private let anchorStore: (any AnchorStore)?
    private let now: @Sendable () -> Date

    public init(
        sessionID: UUID,
        anchorInterval: Int = 1_000,
        anchorStore: (any AnchorStore)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionID = sessionID
        self.anchorInterval = max(1, anchorInterval)
        self.anchorStore = anchorStore
        self.now = now
        if let existing = anchorStore?.loadLatest() {
            // 锚点只用来校验，不重建事件本身（事件由存储层读出）
            anchors.append(existing)
        }
    }

    // MARK: 写入

    public struct Draft: Sendable {
        public var kind: EventKind
        public var payload: JSONValue
        public var turnID: UUID?
        public var goalID: UUID?
        public var subagentID: UUID?
        public var originTrust: TrustLevel
        public var tainted: Bool

        public init(kind: EventKind, payload: JSONValue = .object([:]),
                    turnID: UUID? = nil, goalID: UUID? = nil, subagentID: UUID? = nil,
                    originTrust: TrustLevel = .toolResultTrusted, tainted: Bool = false) {
            self.kind = kind
            self.payload = payload
            self.turnID = turnID
            self.goalID = goalID
            self.subagentID = subagentID
            self.originTrust = originTrust
            self.tainted = tainted
        }
    }

    @discardableResult
    public func append(_ draft: Draft) -> RuntimeEvent {
        lock.lock(); defer { lock.unlock() }
        let timestamp = now()
        let event = RuntimeEvent(
            sequence: Int64(events.count + 1),
            sessionID: sessionID,
            turnID: draft.turnID,
            goalID: draft.goalID,
            subagentID: draft.subagentID,
            kind: draft.kind,
            payload: draft.payload,
            originTrust: draft.originTrust,
            tainted: draft.tainted,
            createdAt: timestamp,
            previousHash: events.last?.hash
        )
        events.append(event)

        // 定期打锚点：校验时只需验「最近锚点 + 尾部」，不必每次扫全表
        if events.count % anchorInterval == 0 {
            let anchor = EventAnchor(sequence: event.sequence, hash: event.hash, createdAt: timestamp)
            anchors.append(anchor)
            anchorStore?.save(anchor)
        }
        return event
    }

    @discardableResult
    public func append(contentsOf drafts: [Draft]) -> [RuntimeEvent] {
        drafts.map { append($0) }
    }

    /// 导入既有事件（从存储层读回时用）。
    ///
    /// ⚠️ 只在**初始化**时可用；日志一旦开始被追加就不该再导入 ——
    /// 否则序号会与已有事件冲突，而冲突之后哈希链会静默地变成一段胡说。
    public func loadHistorical(_ historical: [RuntimeEvent]) {
        lock.lock(); defer { lock.unlock() }
        guard events.isEmpty else { return }
        events = historical.sorted { $0.sequence < $1.sequence }
        for index in stride(from: anchorInterval - 1, to: events.count, by: anchorInterval) {
            let event = events[index]
            anchors.append(EventAnchor(sequence: event.sequence, hash: event.hash, createdAt: event.createdAt))
        }
    }

    // MARK: 读取

    public var all: [RuntimeEvent] { lock.lock(); defer { lock.unlock() }; return events }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return events.count }
    public var tail: RuntimeEvent? { lock.lock(); defer { lock.unlock() }; return events.last }
    public var allAnchors: [EventAnchor] { lock.lock(); defer { lock.unlock() }; return anchors }

    public func events(kind: EventKind) -> [RuntimeEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0.kind == kind }
    }

    public func events(turnID: UUID) -> [RuntimeEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0.turnID == turnID }
    }

    /// 从某条之后读（增量投影用）
    public func events(after sequence: Int64) -> [RuntimeEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0.sequence > sequence }
    }

    // MARK: 校验

    /// 校验哈希链。
    ///
    /// - Parameter full: `false`（默认）时只验「最近锚点 + 之后的事件」——
    ///   与 docs/12 §2.3 一致，手机上不必每次扫全表。
    ///
    /// 三种损坏都能被发现，而且**分别报出来**（用户看到"内容被改了"和"记录少了"的感受完全不同）：
    ///   * 内容被改 → 该条自身哈希对不上（`tampered`）
    ///   * 中间插了/删了 → `previousHash` 与上一条对不上（`brokenLink`）
    ///   * 尾部被砍 → 事件数少于锚点覆盖的范围（`truncated`）
    public func verify(full: Bool = false) -> ChainVerification {
        lock.lock(); defer { lock.unlock() }

        guard !events.isEmpty else {
            return ChainVerification(outcome: .ok, checkedFrom: 1, checkedCount: 0,
                                     detail: "日志是空的。")
        }

        let startIndex: Int
        let expectedPrevious: Data?
        if full || anchors.isEmpty {
            startIndex = 0
            expectedPrevious = nil
        } else {
            let anchor = anchors.last!
            // 锚点覆盖到 `anchor.sequence`：从它之后开始验，且第一条应当指向锚点的哈希
            guard let anchorIndex = events.firstIndex(where: { $0.sequence == anchor.sequence }) else {
                // 锚点指着的那条事件不在了 —— 说明尾部被砍掉了一截
                return ChainVerification(
                    outcome: .truncated,
                    checkedFrom: anchor.sequence, checkedCount: 0,
                    firstBadSequence: anchor.sequence,
                    detail: "锚点指向的第 \(anchor.sequence) 条事件已经不在了，记录被删过。"
                )
            }
            guard anchor.hash == events[anchorIndex].hash else {
                return ChainVerification(
                    outcome: .tampered,
                    checkedFrom: anchor.sequence, checkedCount: 1,
                    firstBadSequence: anchor.sequence,
                    detail: "第 \(anchor.sequence) 条事件的内容与锚点不符。"
                )
            }
            startIndex = anchorIndex + 1
            expectedPrevious = anchor.hash
        }

        // ⚠️ 锚点正好覆盖到最后一条时，`startIndex == events.count` ——
        //    下面那个 `events[startIndex]` 会**越界崩掉**。
        //    （这条是被测试逼出来的：10 条事件、每 5 条一个锚点，
        //      最近锚点是第 10 条，于是"之后要验的"一条都没有。）
        //    语义上也说得通：锚点已经覆盖到末尾，没有新东西要验。
        guard startIndex < events.count else {
            return ChainVerification(
                outcome: .ok,
                checkedFrom: events.last?.sequence ?? 1,
                checkedCount: 0,
                detail: "锚点已覆盖到最后一条（第 \(anchors.last?.sequence ?? 0) 条），没有新事件需要校验。"
            )
        }

        var previous = expectedPrevious
        var checked = 0
        for index in startIndex..<events.count {
            let event = events[index]
            // ① 内容自校验（改了 payload / kind / 时间都会被发现）
            guard event.verifyHash() else {
                return ChainVerification(outcome: .tampered, checkedFrom: events[startIndex].sequence,
                                         checkedCount: checked, firstBadSequence: event.sequence,
                                         detail: "第 \(event.sequence) 条事件的内容被改动过（哈希对不上）。")
            }
            // ② 衔接校验
            if let previous, event.previousHash != previous {
                return ChainVerification(outcome: .brokenLink, checkedFrom: events[startIndex].sequence,
                                         checkedCount: checked, firstBadSequence: event.sequence,
                                         detail: "第 \(event.sequence) 条与前一条的衔接断了（中间可能被插入或删除过）。")
            }
            previous = event.hash
            checked += 1
        }
        return ChainVerification(
            outcome: .ok,
            checkedFrom: events[startIndex].sequence,
            checkedCount: checked,
            detail: full ? "全量校验通过（\(checked) 条）。" : "从最近锚点起的 \(checked) 条校验通过。"
        )
    }
}

// MARK: - 投影

/// 从事件重建出来的会话视图。
///
/// ⚠️ 它是**只读的派生数据**：任何字段都不该被直接"修正"，
/// 要改就改事件 —— 否则缓存视图与真相就分叉了。
public struct SessionProjection: Sendable, Hashable {
    public var sessionID: UUID
    public var title: String?
    public var createdAt: Date?
    public var isArchived: Bool = false
    public var memoryDisabled: Bool = false

    public var turns: [UUID: TurnProjection] = [:]
    public var turnOrder: [UUID] = []
    public var cost: CostProjection = CostProjection()
    public var toolUsage: [String: ToolUsageStat] = [:]
    public var security: [SecurityRecord] = []
    public var egress: [EgressRecord] = []
    public var artifacts: [ArtifactRecord] = []
    public var checkpoints: [CheckpointRecord] = []
    public var goals: [UUID: GoalRecord] = [:]
    /// 已投影到哪一条（增量投影的游标）
    public var lastSequence: Int64 = 0

    public init(sessionID: UUID) { self.sessionID = sessionID }

    public var turnList: [TurnProjection] { turnOrder.compactMap { turns[$0] } }
    public var activeGoal: GoalRecord? { goals.values.first { $0.isActive } }
    public var lastUpdatedAt: Date? {
        turnList.compactMap(\.endedAt).max() ?? createdAt
    }
}

public struct TurnProjection: Sendable, Hashable {
    public var id: UUID
    public var objective: String = ""
    public var startedAt: Date
    public var endedAt: Date?
    /// 由事件推出的终态（nil = 还没终结）
    public var terminalKind: EventKind?
    public var rounds: Int = 0
    public var toolCalls: Int = 0
    public var failedToolCalls: Int = 0
    public var deniedToolCalls: Int = 0
    public var correctedOnce: Bool = false
    public var escalations: Int = 0
    public var costMicroUSD: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var lastCheckpointSeq: Int64?
    /// 是否发生过**不可重放的副作用**（推送 / 外发 / 支付）——
    /// 恢复流程靠它决定"能不能自动重做"
    public var hasIrreversibleSideEffect: Bool = false
    public var wasRecovered: Bool = false
    public var recoveredTimes: Int = 0
    public var queueDepthAtEnd: Int?

    public var isFinished: Bool { terminalKind != nil }

    public var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}

public struct CostProjection: Sendable, Hashable {
    public var totalMicroUSD: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cachedInputTokens: Int = 0
    /// 缓存省下的钱（正反馈：UI 上要显示"帮你省了多少"）
    public var savedMicroUSD: Int = 0
    public var byProvider: [String: Int] = [:]
    public var byModel: [String: Int] = [:]

    public var displayString: String {
        String(format: "$%.4f", Double(totalMicroUSD) / 1_000_000)
    }
}

public struct ToolUsageStat: Sendable, Hashable {
    public var calls: Int = 0
    public var failures: Int = 0
    public var denials: Int = 0
    public var totalBytes: Int = 0

    public var failureRate: Double {
        calls == 0 ? 0 : Double(failures) / Double(calls)
    }
}

public struct SecurityRecord: Sendable, Hashable {
    public var sequence: Int64
    public var kind: EventKind
    public var tool: String?
    public var reason: String?
    public var at: Date
}

public struct EgressRecord: Sendable, Hashable {
    public var sequence: Int64
    public var host: String
    public var method: String
    public var bytes: Int
    public var tool: String?
    public var wasBlocked: Bool
    public var at: Date
}

public struct ArtifactRecord: Sendable, Hashable {
    public var sequence: Int64
    public var handle: String
    public var displayName: String
    public var byteSize: Int
    public var at: Date
}

public struct CheckpointRecord: Sendable, Hashable {
    public var sequence: Int64
    public var turnID: UUID?
    public var label: String
    public var kind: String
    public var isRestorable: Bool
    public var at: Date
}

public struct GoalRecord: Sendable, Hashable {
    public var id: UUID
    public var objective: String
    public var status: String
    public var roundsUsed: Int = 0
    public var isActive: Bool { status == "active" }
    public var lastActivityAt: Date?
}

// MARK: - 投影器

/// 把事件折叠成视图。
///
/// ⚠️ **增量与全量必须产出同一个结果** —— 这是这一层唯一重要的性质。
/// 它一破，界面上显示的会话摘要与"从日志重算"的结果就会分叉，
/// 而分叉之后没有任何东西能告诉你哪个是对的。
public enum EventProjector {

    public static func project(_ events: [RuntimeEvent], sessionID: UUID) -> SessionProjection {
        var projection = SessionProjection(sessionID: sessionID)
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            apply(event, to: &projection)
        }
        return projection
    }

    /// 增量应用一个事件。
    ///
    /// ⚠️ 幂等：同一条事件应用两次不会改变结果（靠 `lastSequence` 挡住）。
    /// 事件日志在崩溃后**可能重放一段**，不幂等的投影会在重放时把计数翻倍 ——
    /// 那是"用户看到的花费比实际多一倍"这类 bug 的来源。
    public static func apply(_ event: RuntimeEvent, to projection: inout SessionProjection) {
        guard event.sequence > projection.lastSequence else { return }
        projection.lastSequence = event.sequence

        let payload = event.payload

        // ---------- 会话级 ----------
        switch event.kind {
        case .sessionCreated:
            projection.createdAt = event.createdAt
            if let title = payload.value(at: ["title"])?.stringValue { projection.title = title }
        case .sessionTitleSet:
            if let title = payload.value(at: ["title"])?.stringValue { projection.title = title }
        case .sessionArchived:
            projection.isArchived = true
        case .memoryDisabled:
            projection.memoryDisabled = true
        default:
            break
        }

        // ---------- 目标 ----------
        if let goalID = event.goalID {
            var goal = projection.goals[goalID] ?? GoalRecord(id: goalID, objective: "", status: "active")
            if let objective = payload.value(at: ["objective"])?.stringValue, !objective.isEmpty {
                goal.objective = objective
            }
            if let status = payload.value(at: ["status"])?.stringValue { goal.status = status }
            if let round = payload.value(at: ["round"])?.intValue { goal.roundsUsed = round }
            goal.lastActivityAt = event.createdAt
            projection.goals[goalID] = goal
        }

        // ---------- 轮次级 ----------
        if let turnID = event.turnID {
            if projection.turns[turnID] == nil {
                projection.turns[turnID] = TurnProjection(id: turnID, startedAt: event.createdAt)
                projection.turnOrder.append(turnID)
            }
            var turn = projection.turns[turnID]!
            applyToTurn(event, payload: payload, turn: &turn)

            // 成本按轮次累计
            if let micro = payload.value(at: ["microUSD"])?.intValue {
                turn.costMicroUSD += micro
                projection.cost.totalMicroUSD += micro
                if let provider = payload.value(at: ["provider"])?.stringValue {
                    projection.cost.byProvider[provider, default: 0] += micro
                }
                if let model = payload.value(at: ["model"])?.stringValue {
                    projection.cost.byModel[model, default: 0] += micro
                }
            }
            if let input = payload.value(at: ["inputTokens"])?.intValue {
                turn.inputTokens += input
                projection.cost.inputTokens += input
            }
            if let output = payload.value(at: ["outputTokens"])?.intValue {
                turn.outputTokens += output
                projection.cost.outputTokens += output
            }
            if let cached = payload.value(at: ["cachedInputTokens"])?.intValue {
                projection.cost.cachedInputTokens += cached
            }
            if let saved = payload.value(at: ["savedMicroUSD"])?.intValue {
                projection.cost.savedMicroUSD += saved
            }
            projection.turns[turnID] = turn
        }

        // ---------- 工具用量 ----------
        if let tool = payload.value(at: ["tool"])?.stringValue {
            var stat = projection.toolUsage[tool] ?? ToolUsageStat()
            switch event.kind {
            case .toolCallRequested, .toolCallStarted:
                stat.calls += 1
            case .toolCallFinished:
                if payload.value(at: ["status"])?.stringValue != "ok" { stat.failures += 1 }
            case .toolCallFailed:
                stat.failures += 1
            case .toolCallDenied, .capabilityDenied:
                stat.denials += 1
            default:
                break
            }
            projection.toolUsage[tool] = stat
        }

        // ---------- 安全与出口 ----------
        if event.kind.isSecurityRelevant {
            projection.security.append(SecurityRecord(
                sequence: event.sequence, kind: event.kind,
                tool: payload.value(at: ["tool"])?.stringValue,
                reason: payload.value(at: ["reason"])?.stringValue,
                at: event.createdAt
            ))
        }
        if event.kind == .egressAudited || event.kind == .egressBlocked {
            projection.egress.append(EgressRecord(
                sequence: event.sequence,
                host: payload.value(at: ["host"])?.stringValue ?? "",
                method: payload.value(at: ["method"])?.stringValue ?? "",
                bytes: payload.value(at: ["bytes"])?.intValue ?? 0,
                tool: payload.value(at: ["tool"])?.stringValue,
                wasBlocked: event.kind == .egressBlocked,
                at: event.createdAt
            ))
        }

        // ---------- 制品与检查点 ----------
        if event.kind == .artifactCreated {
            projection.artifacts.append(ArtifactRecord(
                sequence: event.sequence,
                handle: payload.value(at: ["handle"])?.stringValue ?? "",
                displayName: payload.value(at: ["displayName"])?.stringValue
                    ?? payload.value(at: ["summary"])?.stringValue ?? "产物",
                byteSize: payload.value(at: ["bytes"])?.intValue ?? 0,
                at: event.createdAt
            ))
        }
        if event.kind == .checkpointCreated {
            projection.checkpoints.append(CheckpointRecord(
                sequence: event.sequence, turnID: event.turnID,
                label: payload.value(at: ["label"])?.stringValue ?? "",
                kind: payload.value(at: ["kind"])?.stringValue ?? "",
                isRestorable: payload.value(at: ["restorable"])?.boolValue ?? true,
                at: event.createdAt
            ))
        }
    }

    private static func applyToTurn(_ event: RuntimeEvent, payload: JSONValue, turn: inout TurnProjection) {
        switch event.kind {
        case .userMessage:
            if let objective = payload.value(at: ["objective"])?.stringValue, !objective.isEmpty {
                turn.objective = objective
            }
        case .modelCallFinished:
            turn.rounds += 1
        case .toolCallRequested, .toolCallStarted:
            turn.toolCalls += 1
        case .toolCallFinished:
            if payload.value(at: ["status"])?.stringValue != "ok" { turn.failedToolCalls += 1 }
        case .toolCallFailed:
            turn.failedToolCalls += 1
        case .toolCallDenied, .capabilityDenied, .humanOnlyZoneTouched:
            turn.deniedToolCalls += 1
        case .modelSelfCorrected:
            turn.correctedOnce = true
        case .correctionEscalated:
            turn.escalations += 1
        case .turnRecovered:
            turn.wasRecovered = true
            turn.recoveredTimes += 1
        case .checkpointCreated:
            turn.lastCheckpointSeq = event.sequence
        case .gitPushAttempted, .gitPushSucceeded, .egressAudited, .fileReturned, .notificationSent:
            // ⚠️ 这几个是**外部副作用**：它们一旦发生，"重做"就不再是安全的
            turn.hasIrreversibleSideEffect = true
            turn.terminalKind = event.kind == .gitPushAttempted ? turn.terminalKind : turn.terminalKind
        // ---------- 终态 ----------
        case .artifactCreated:
            if payload.value(at: ["summary"])?.stringValue != nil, turn.rounds > 0,
               payload.value(at: ["toolCalls"]) == nil {
                // 模型没产出工具调用 → 这一轮结束了（TurnRunner 用 artifactCreated 表示"完成"）
                turn.terminalKind = .artifactCreated
                turn.endedAt = event.createdAt
            }
        case .toolApprovalRequested:
            turn.terminalKind = nil
        case .turnInterrupted:
            turn.terminalKind = .turnInterrupted
            turn.endedAt = event.createdAt
        case .budgetExceeded:
            turn.terminalKind = .budgetExceeded
            turn.endedAt = event.createdAt
        case .correctionEscalated:
            turn.escalations += 1
            turn.terminalKind = .correctionEscalated
            turn.endedAt = event.createdAt
        case .turnPaused:
            turn.terminalKind = .turnPaused
            turn.endedAt = event.createdAt
        case .turnResumed:
            turn.terminalKind = nil
            turn.endedAt = nil
        default:
            break
        }
    }
}

// MARK: - 崩溃恢复计划（docs/12 §5）

/// 启动时的分诊结果。
///
/// ⚠️ 这是**每次冷启动都会跑**的一段逻辑，而它做错的代价是：
///   * 太保守 → 用户每次打开 App 都被问一遍"要不要继续"（烦到关掉自动续跑）
///   * 太激进 → 半夜自己跑起来花钱、或者把一个有外部副作用的动作做了两遍
///
/// 所以每条动作都带 `reason`，UI 要能把"为什么这么决定"说清楚。
public struct RecoveryPlan: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        /// 有活跃目标 → 继续推进
        case resumeGoal(id: UUID, objective: String, reason: String)
        /// 可安全重做 → 从最后一个检查点重放
        case replayTurn(id: UUID, fromSequence: Int64, reason: String)
        /// 含不可重放的副作用 → 必须问用户
        case askUser(turnID: UUID, reason: String)
        /// 僵尸（太久没动）→ 标记为中断，**不自动续跑**
        case markInterrupted(turnID: UUID, reason: String)
    }

    public var chain: ChainVerification
    public var actions: [Action]
    public var notes: [String]

    /// 首页上显示的一句话
    public var headline: String {
        if !chain.isOK { return chain.userFacingText }
        if actions.isEmpty { return "没有需要恢复的任务。" }
        var parts: [String] = []
        let resumable = actions.filter { if case .resumeGoal = $0 { return true }; if case .replayTurn = $0 { return true }; return false }.count
        let needsUser = actions.filter { if case .askUser = $0 { return true }; return false }.count
        let zombies = actions.filter { if case .markInterrupted = $0 { return true }; return false }.count
        if resumable > 0 { parts.append("已从检查点恢复 \(resumable) 个任务") }
        if needsUser > 0 { parts.append("\(needsUser) 个任务需要你确认后继续") }
        if zombies > 0 { parts.append("\(zombies) 个任务太久没动，已标记为中断") }
        return parts.joined(separator: "；") + "。"
    }

    public var needsUserAttention: Bool {
        actions.contains { if case .askUser = $0 { return true }; return false }
    }
}

public enum RecoveryPlanner {

    /// 超过多少小时没动就算僵尸（docs/12 §5：**不自动续跑**）
    public static let zombieHours = 24

    public static func plan(
        _ projection: SessionProjection,
        verification: ChainVerification,
        now: Date
    ) -> RecoveryPlan {
        // ⚠️ 校验没过就**什么都不要自动做**。
        //    基于一份可能被改过的历史去执行动作，比停下来问用户糟得多。
        guard verification.isOK else {
            return RecoveryPlan(chain: verification, actions: [],
                                notes: ["历史记录校验未通过，已停止自动续跑。"])
        }

        var actions: [RecoveryPlan.Action] = []
        var notes: [String] = []

        // ---------- ① 未完成的轮次 ----------
        for turn in projection.turnList where !turn.isFinished {
            let idleHours = now.timeIntervalSince(turn.startedAt) / 3_600

            if turn.hasIrreversibleSideEffect {
                // 有外部副作用（推送/外发/支付）→ 重做可能造成重复效果，必须问人
                actions.append(.askUser(
                    turnID: turn.id,
                    reason: "这个任务里已经发生过对外部的操作（推送/外发），"
                        + "它是否成功无法确定，重做可能造成重复效果。"
                ))
                continue
            }

            if idleHours > Double(zombieHours) {
                // 僵尸：三天前忘了的任务不该突然开始跑并花钱
                actions.append(.markInterrupted(
                    turnID: turn.id,
                    reason: "这个任务已经 \(Int(idleHours)) 小时没有动静了，"
                        + "不会再自动继续（避免你不在的时候它自己跑起来花钱）。要接着做请手动点一下。"
                ))
                continue
            }

            let from = turn.lastCheckpointSeq ?? 0
            actions.append(.replayTurn(
                id: turn.id, fromSequence: from,
                reason: from > 0
                    ? "这个任务可以从第 \(from) 条之后的检查点安全重做。"
                    : "这个任务还没执行过有副作用的操作，可以安全重做。"
            ))
        }

        // ---------- ② 活跃目标 ----------
        for goal in projection.goals.values where goal.isActive {
            // 只对"没有对应未完成轮次"的目标单独续跑（否则会与上一步重复）
            let hasPendingTurn = projection.turnList.contains { !$0.isFinished && $0.objective == goal.objective }
            guard !hasPendingTurn else { continue }
            let idleHours = goal.lastActivityAt.map { now.timeIntervalSince($0) / 3_600 } ?? 0
            if idleHours > Double(zombieHours) {
                notes.append("目标「\(goal.objective)」已 \(Int(idleHours)) 小时没动，不自动续跑。")
                continue
            }
            actions.append(.resumeGoal(id: goal.id, objective: goal.objective,
                                       reason: "这个目标还没完成，且最近有过进展。"))
        }

        if actions.isEmpty {
            notes.append("没有发现未完成的任务。")
        }
        return RecoveryPlan(chain: verification, actions: actions, notes: notes)
    }
}

