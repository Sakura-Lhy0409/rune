import Foundation

// MARK: - 审批票据

/// 一次待用户决定的审批请求。
///
/// 设计依据（docs/08 §5.1 的三条铁律）：**非阻塞、批量、可记忆**。
public struct ApprovalTicket: Sendable, Codable, Hashable, Identifiable {
    public enum State: String, Sendable, Codable, Hashable {
        case pending
        case approved
        case denied
        /// 低风险的"内联允许"到期自动通过（**可撤销**）
        case autoApproved
        /// 超时未处理 → **等同拒绝**（fail closed）
        case expired

        /// 这个状态是否等于"拒绝"
        public var isDenial: Bool { self == .denied || self == .expired }

        /// 是否已经不需要用户再看它
        public var isSettled: Bool { self != .pending }
    }

    public enum DecidedBy: String, Sendable, Codable, Hashable {
        case userTap
        case autoAllow
        case timeout
        case batchApproval
        case biometric
        /// 命中已记住的策略（无需再问）
        case rememberedPolicy
    }

    public let id: UUID
    public let call: ToolCall
    public let toolName: String
    public let requirement: ApprovalRequirement
    public let risk: ToolSpec.RiskLevel
    /// 面向用户的理由（必须回答"做什么/影响什么/能否撤销/为什么现在做"）
    public let reason: String
    public let paths: [VFSPath]
    public let createdAt: Date
    /// 低风险项自动允许的时刻（nil = 永不自动允许）
    public let autoAllowAt: Date?
    /// 超时时刻
    public let expiresAt: Date
    public var state: State
    public var decidedAt: Date?
    public var decidedBy: DecidedBy?

    public init(
        id: UUID = UUID(),
        call: ToolCall,
        requirement: ApprovalRequirement,
        risk: ToolSpec.RiskLevel,
        reason: String,
        paths: [VFSPath] = [],
        createdAt: Date,
        autoAllowAt: Date? = nil,
        expiresAt: Date
    ) {
        self.id = id
        self.call = call
        self.toolName = call.name
        self.requirement = requirement
        self.risk = risk
        self.reason = reason
        self.paths = paths
        self.createdAt = createdAt
        self.autoAllowAt = autoAllowAt
        self.expiresAt = expiresAt
        self.state = .pending
    }

    /// 是否允许"记住这次选择"（写回策略）
    ///
    /// ⚠️ 高危与不可逆操作**一律不允许记住** ——
    /// "以后都自动允许推送"这种设置，一旦被误点就是长期的安全债。
    public var isRememberable: Bool {
        requirement.isRememberable && risk != .dangerous && risk != .irreversible
    }
}

// MARK: - 策略覆盖（"记住这次选择"的落地形态）

/// 用户在本设备上做出的**宽松授权**记录。
///
/// 它必须可审计、可撤销、可过期 —— 这是 docs/12 的 `policy_override` 表在运行时的形态。
public struct PolicyOverride: Sendable, Codable, Hashable, Identifiable {
    public enum Scope: Sendable, Codable, Hashable {
        /// 该工具一律允许
        case tool(String)
        /// 该工具在某个路径前缀下允许
        case toolInPath(tool: String, prefix: VFSPath)
        /// 某个域名允许访问
        case egressHost(String)
    }

    public var id: UUID
    public var scope: Scope
    /// 限定在某个工作区（nil = 全局）
    public var workspaceID: UUID?
    public var grantedBy: ApprovalTicket.DecidedBy
    public var grantedAt: Date
    public var expiresAt: Date?
    public var revokedAt: Date?
    /// 用户当时看到的理由（审计时能还原上下文）
    public var reason: String

    public init(
        id: UUID = UUID(),
        scope: Scope,
        workspaceID: UUID? = nil,
        grantedBy: ApprovalTicket.DecidedBy,
        grantedAt: Date,
        expiresAt: Date? = nil,
        revokedAt: Date? = nil,
        reason: String
    ) {
        self.id = id
        self.scope = scope
        self.workspaceID = workspaceID
        self.grantedBy = grantedBy
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.reason = reason
    }

    public func isActive(at now: Date, workspaceID: UUID? = nil) -> Bool {
        guard revokedAt == nil else { return false }
        if let expiresAt, now >= expiresAt { return false }
        if let scoped = self.workspaceID, let ask = workspaceID, scoped != ask { return false }
        return true
    }

    /// 审计/设置页展示用
    public var displayString: String {
        switch scope {
        case .tool(let name): return "允许使用「\(name)」"
        case .toolInPath(let name, let prefix): return "允许「\(name)」操作 \(prefix.description)/**"
        case .egressHost(let host): return "允许访问 \(host)"
        }
    }
}

// MARK: - 批量展示

/// 一批待审批项（**一次展示完**，而不是一个个弹）。
public struct ApprovalBatch: Sendable, Equatable {
    public var tickets: [ApprovalTicket]
    /// 标题（"3 项操作需要你确认"）
    public var headline: String
    public var highestRisk: ToolSpec.RiskLevel
    /// 是否给出"全部允许"按钮
    ///
    /// ⚠️ 只要批里含**不可逆**操作，就不给这个按钮 ——
    /// 一键批准一堆含不可逆操作的东西，是审批体验里最危险的便利。
    public var canApproveAll: Bool
    /// 整批是否需要生物识别（任一票据需要就要）
    public var requiresBiometric: Bool
    /// 被挤到下一批的（超过单批上限）
    public var deferredCount: Int

    public var count: Int { tickets.count }
}

// MARK: - 审批代理

/// 审批的总入口。
///
/// 它解决四件事：
///   1. **批量**：同一轮里的多个待批项合并成一次展示
///   2. **分级**：低风险内联允许（3 秒自动通过且可撤销）、高风险要看清细节、不可逆要生物识别
///   3. **记忆**：可记住的选择写回 `PolicyOverride`，下次不再问（**高危不可记忆**）
///   4. **失败关闭**：超时未处理 = 拒绝，不是允许
public struct ApprovalBroker: Sendable {

    public struct Config: Sendable {
        /// 低风险"内联允许"的自动通过延迟（秒）
        public var inlineAutoAllowDelay: TimeInterval
        /// 票据存活时间（秒）；超时即**拒绝**
        public var ticketTTL: TimeInterval
        /// 单批最多展示几项（手机上超过这个数用户就不看了）
        public var maxBatchSize: Int
        /// 允许"全部允许"的最高风险等级
        public var approveAllRiskCeiling: ToolSpec.RiskLevel

        public init(
            inlineAutoAllowDelay: TimeInterval = 3,
            ticketTTL: TimeInterval = 300,
            maxBatchSize: Int = 6,
            approveAllRiskCeiling: ToolSpec.RiskLevel = .modifying
        ) {
            self.inlineAutoAllowDelay = inlineAutoAllowDelay
            self.ticketTTL = ticketTTL
            self.maxBatchSize = maxBatchSize
            self.approveAllRiskCeiling = approveAllRiskCeiling
        }

        public static let `default` = Config()
    }

    public enum Decision: Sendable, Equatable {
        case approveOnce
        /// 批准并记住（**仅限可记忆的票据**）
        case approveAndRemember(expiresIn: TimeInterval?)
        case deny(reason: String?)
    }

    public enum BrokerError: Error, Sendable, Equatable {
        case ticketNotFound(UUID)
        case ticketAlreadySettled(UUID, ApprovalTicket.State)
        case cannotRemember(risk: ToolSpec.RiskLevel)
        case emptyBatch

        public var userFacingMessage: String {
            switch self {
            case .ticketNotFound: return "这条待确认项已经不存在了。"
            case .ticketAlreadySettled(_, let state): return "这条待确认项已经处理过了（\(state.rawValue)）。"
            case .cannotRemember(let risk):
                return risk == .irreversible
                    ? "不可逆操作不允许「记住选择」—— 每次都请你亲自确认。"
                    : "危险操作不允许「记住选择」，避免以后误放行。"
            case .emptyBatch: return "没有待确认的事项。"
            }
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var ticket: ApprovalTicket
        /// 如果这次选择被记住了，这里是对应的策略记录
        public var override: PolicyOverride?
        /// 这次决定是否允许继续执行
        public var isAllowed: Bool { ticket.state == .approved || ticket.state == .autoApproved }
    }

    public private(set) var tickets: [UUID: ApprovalTicket] = [:]
    public private(set) var overrides: [PolicyOverride] = []
    private let config: Config

    public init(config: Config = .default) {
        self.config = config
    }

    // MARK: 提交

    /// 提交一个待批项。
    ///
    /// 若命中**已记住的策略**，票据会被直接标记为已批准（`decidedBy = .rememberedPolicy`），
    /// 不打扰用户 —— 这正是"记住选择"的意义。
    ///
    /// ⚠️ `paths` 省略时**会自动从调用参数里提取**。
    /// 不能默认成空数组：那样"记住这次选择"会退化成**整个工具的白名单**
    /// （用户以为只是允许改这个目录，实际允许了所有路径）。
    @discardableResult
    public mutating func submit(
        call: ToolCall,
        requirement: ApprovalRequirement,
        risk: ToolSpec.RiskLevel,
        reason: String,
        paths: [VFSPath]? = nil,
        workspaceID: UUID? = nil,
        now: Date
    ) -> ApprovalTicket {
        let resolvedPaths = paths ?? CallPaths.extract(from: call)
        var ticket = ApprovalTicket(
            call: call,
            requirement: requirement,
            risk: risk,
            reason: reason,
            paths: resolvedPaths,
            createdAt: now,
            autoAllowAt: autoAllowDate(for: requirement, now: now),
            expiresAt: now.addingTimeInterval(config.ticketTTL)
        )

        if preApproval(for: call, paths: resolvedPaths, workspaceID: workspaceID, now: now) != nil {
            ticket.state = .approved
            ticket.decidedAt = now
            ticket.decidedBy = .rememberedPolicy
        }

        tickets[ticket.id] = ticket
        return ticket
    }

    /// 从运行时的审批请求直接提交
    @discardableResult
    public mutating func submit(
        _ request: TurnRunner.ApprovalRequest,
        paths: [VFSPath]? = nil,
        workspaceID: UUID? = nil,
        now: Date
    ) -> ApprovalTicket {
        submit(
            call: request.call,
            requirement: request.requirement,
            risk: request.risk,
            reason: request.reason,
            paths: paths,
            workspaceID: workspaceID,
            now: now
        )
    }

    private func autoAllowDate(for requirement: ApprovalRequirement, now: Date) -> Date? {
        // ⚠️ 只有"内联允许"这一档才自动通过。
        //    `singleTap` 及以上必须有人真的点一下 —— "3 秒后自动允许删除文件"是灾难。
        requirement == .inlineAllow ? now.addingTimeInterval(config.inlineAutoAllowDelay) : nil
    }

    // MARK: 查询

    public var pendingTickets: [ApprovalTicket] {
        tickets.values.filter { $0.state == .pending }.sorted { $0.createdAt < $1.createdAt }
    }

    public var pendingCount: Int { pendingTickets.count }

    public func ticket(_ id: UUID) -> ApprovalTicket? { tickets[id] }

    /// 生成一批展示（最多 `maxBatchSize` 项；其余延后，`deferredCount` 告知）
    public func batch() -> ApprovalBatch? {
        let pending = pendingTickets
        guard !pending.isEmpty else { return nil }
        let shown = Array(pending.prefix(config.maxBatchSize))
        let highest = shown.map(\.risk).max { ToolRunnerRank($0) < ToolRunnerRank($1) } ?? .safe
        let canApproveAll = highest != .irreversible
            && shown.allSatisfy { $0.requirement != .biometricPlusPhrase }
            && ToolRunnerRank(highest) <= ToolRunnerRank(config.approveAllRiskCeiling)

        return ApprovalBatch(
            tickets: shown,
            headline: shown.count == 1
                ? "1 项操作需要你确认"
                : "\(shown.count) 项操作需要你确认",
            highestRisk: highest,
            canApproveAll: canApproveAll,
            requiresBiometric: shown.contains { $0.requirement == .biometric || $0.requirement == .biometricPlusPhrase },
            deferredCount: max(0, pending.count - shown.count)
        )
    }

    /// 查是否有已记住的策略覆盖了这次调用
    public func preApproval(
        for call: ToolCall,
        paths: [VFSPath],
        workspaceID: UUID? = nil,
        now: Date
    ) -> PolicyOverride? {
        overrides.first { override in
            guard override.isActive(at: now, workspaceID: workspaceID) else { return false }
            switch override.scope {
            case .tool(let name):
                return name == call.name
            case .toolInPath(let name, let prefix):
                guard name == call.name else { return false }
                // 路径为空时不能靠"路径前缀"放行（否则等于给该工具开了全局白名单）
                guard !paths.isEmpty else { return false }
                return paths.allSatisfy { $0.isWithin(prefix) }
            case .egressHost:
                return false
            }
        }
    }

    // MARK: 决定

    @discardableResult
    public mutating func decide(
        _ id: UUID,
        _ decision: Decision,
        now: Date,
        workspaceID: UUID? = nil,
        decidedBy: ApprovalTicket.DecidedBy = .userTap
    ) throws -> Outcome {
        guard var ticket = tickets[id] else { throw BrokerError.ticketNotFound(id) }
        guard !ticket.state.isSettled else {
            throw BrokerError.ticketAlreadySettled(id, ticket.state)
        }

        var createdOverride: PolicyOverride?

        switch decision {
        case .approveOnce:
            ticket.state = .approved
            ticket.decidedBy = decidedBy

        case .approveAndRemember(let expiresIn):
            guard ticket.isRememberable else {
                throw BrokerError.cannotRemember(risk: ticket.risk)
            }
            ticket.state = .approved
            ticket.decidedBy = .rememberedPolicy
            createdOverride = PolicyOverride(
                scope: overrideScope(for: ticket),
                workspaceID: workspaceID,
                grantedBy: .rememberedPolicy,
                grantedAt: now,
                expiresAt: expiresIn.map { now.addingTimeInterval($0) },
                reason: ticket.reason
            )
            overrides.append(createdOverride!)

        case .deny:
            ticket.state = .denied
            ticket.decidedBy = decidedBy
        }

        ticket.decidedAt = now
        tickets[id] = ticket
        return Outcome(ticket: ticket, override: createdOverride)
    }

    /// "全部允许"（仅在 `ApprovalBatch.canApproveAll` 为真时才应被 UI 提供）
    ///
    /// ⚠️ **先全量校验、再逐条应用**。
    /// 第一版是"边校验边应用"，结果遇到不合格项抛错时**前面的已经被批准了**——
    /// 声称"整批不生效"却留下了半批已批准，这正是审批系统最不该有的行为。
    @discardableResult
    public mutating func approveAll(
        now: Date,
        workspaceID: UUID? = nil,
        decidedBy: ApprovalTicket.DecidedBy = .batchApproval
    ) throws -> [Outcome] {
        let pending = pendingTickets
        guard !pending.isEmpty else { throw BrokerError.emptyBatch }

        // 第一阶段：全量校验（不改任何状态）
        for ticket in pending {
            guard ticket.risk != .irreversible, ticket.requirement != .biometricPlusPhrase else {
                throw BrokerError.cannotRemember(risk: ticket.risk)
            }
        }

        // 第二阶段：全部合规才逐条应用
        var outcomes: [Outcome] = []
        for ticket in pending {
            outcomes.append(try decide(ticket.id, .approveOnce, now: now, workspaceID: workspaceID, decidedBy: decidedBy))
        }
        return outcomes
    }

    /// 把一批**同一轮**的待批项一次性拒绝（用户点"都拒绝"）
    @discardableResult
    public mutating func denyAll(reason: String?, now: Date) -> [Outcome] {
        let pending = pendingTickets
        var outcomes: [Outcome] = []
        for ticket in pending {
            if let outcome = try? decide(ticket.id, .deny(reason: reason), now: now) {
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    // MARK: 时间推进（自动允许与超时）

    /// 处理到期项：低风险自动通过；其余**超时即拒绝**。
    /// 返回本次发生变化的票据（供 UI 提示"刚才那 2 项已经自动允许了"）。
    @discardableResult
    public mutating func tick(now: Date) -> [ApprovalTicket] {
        var changed: [ApprovalTicket] = []
        for (id, var ticket) in tickets where ticket.state == .pending {
            if let autoAllowAt = ticket.autoAllowAt, now >= autoAllowAt {
                ticket.state = .autoApproved
                ticket.decidedAt = now
                ticket.decidedBy = .autoAllow
                tickets[id] = ticket
                changed.append(ticket)
                continue
            }
            if now >= ticket.expiresAt {
                // ⚠️ **失败关闭**：超时 = 拒绝。绝不能因为"用户没看见"就默认允许。
                ticket.state = .expired
                ticket.decidedAt = now
                ticket.decidedBy = .timeout
                tickets[id] = ticket
                changed.append(ticket)
            }
        }
        return changed.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: 策略撤销

    /// 撤销一条"记住的选择"（设置页用）
    @discardableResult
    public mutating func revoke(_ overrideID: UUID, at now: Date) -> Bool {
        guard let index = overrides.firstIndex(where: { $0.id == overrideID }) else { return false }
        overrides[index].revokedAt = now
        return true
    }

    public var activeOverrides: [PolicyOverride] {
        overrides.filter { $0.revokedAt == nil }
    }

    /// 设置页展示用
    public func overrideSummary(at now: Date, workspaceID: UUID? = nil) -> [String] {
        overrides
            .filter { $0.isActive(at: now, workspaceID: workspaceID) }
            .map(\.displayString)
    }

    // MARK: 内部

    private func overrideScope(for ticket: ApprovalTicket) -> PolicyOverride.Scope {
        // 有明确路径 → 按路径前缀记住（更精确）；没有路径 → 按工具记住
        if ticket.paths.count == 1, let prefix = ticket.paths.first {
            // 记住到"所在目录"，而不是那个具体文件 —— 否则下一个文件又要问一次
            let directory = prefix.parent ?? prefix
            return .toolInPath(tool: ticket.toolName, prefix: directory)
        }
        return .tool(ticket.toolName)
    }
}

/// 风险等级排序（内部用；与 `TurnRunner.rank` 同源但独立，避免跨类型耦合）
private func ToolRunnerRank(_ risk: ToolSpec.RiskLevel) -> Int {
    switch risk {
    case .safe: return 0
    case .modifying: return 1
    case .dangerous: return 2
    case .irreversible: return 3
    }
}
