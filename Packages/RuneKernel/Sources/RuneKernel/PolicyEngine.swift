import Foundation

// MARK: - 信任刻度盘
//
// 设计依据（docs/08 §3.4）：把 Codex 的 `sandbox policy × approval policy` 二维矩阵
// 折叠成**一根人类可读的滑杆**，每档都有一句"这档允许做什么"。
//
// 两条硬规则：
//   1. **Agent 不能改自己的刻度盘**（工具层不可写）—— 防自我提权
//   2. 每次上调解锁都要有"为什么这次需要"的一句话解释

public enum TrustDial: String, Sendable, Codable, Hashable, CaseIterable {
    /// 只读：让你先看看、代码审计、陌生仓库
    case readOnly
    /// 提议：生成 diff 但不落地（"我想看方案，别动我的文件"）
    case propose
    /// 协作（默认）：工作区内可写、可跑沙箱、可本地提交
    case collaborate
    /// 自治：熟悉项目、放手干
    case autonomous
    /// 全权：高级用户 / 一次性沙箱项目
    case full

    /// 是否允许在**工作区**内写文件
    public var allowsWorkspaceWrite: Bool {
        switch self {
        case .readOnly, .propose: return false
        case .collaborate, .autonomous, .full: return true
        }
    }

    /// 是否允许执行脚本
    public var allowsExecution: Bool {
        self != .readOnly
    }

    /// 是否允许本地 git 提交
    public var allowsLocalCommit: Bool {
        switch self {
        case .readOnly, .propose: return false
        default: return true
        }
    }

    /// 是否允许推送到远端
    public var allowsPush: Bool {
        switch self {
        case .autonomous, .full: return true
        default: return false
        }
    }

    /// 是否允许向**新域名**发起请求（未在白名单内的）
    public var allowsNewDomains: Bool {
        switch self {
        case .autonomous, .full: return true
        default: return false
        }
    }

    /// 是否绕过危险操作的人工确认（**只有全权档**）
    public var skipsDangerousConfirmation: Bool {
        self == .full
    }

    public var displayName: String {
        switch self {
        case .readOnly: return "只读"
        case .propose: return "提议"
        case .collaborate: return "协作"
        case .autonomous: return "自治"
        case .full: return "全权"
        }
    }

    /// UI 上"这档允许做什么"的清单（**必须展示，不能只给一个档位名**）
    public var explanation: [String] {
        switch self {
        case .readOnly:
            return ["可以读取工作区文件", "可以搜索与分析", "不写文件、不执行脚本", "一切网络访问都需确认"]
        case .propose:
            return ["可以读取与分析", "可以生成修改方案（diff）但**不落到文件**", "可以执行只读类脚本", "网络访问走白名单"]
        case .collaborate:
            return ["可以在工作区内读写文件", "可以执行沙箱脚本", "可以本地 git 提交",
                    "推送 / 外发 / 删除 / 花钱 → 每次询问", "网络访问走白名单"]
        case .autonomous:
            return ["上一条的全部", "可以推送到远端（受保护分支除外）", "新域名首次访问会询问", "仅不可逆操作需要确认"]
        case .full:
            return ["可以操作任意已授权目录", "可以访问任意域名", "可以推送任意分支",
                    "⚠️ 不再逐次确认危险操作 —— 仅建议用于一次性沙箱项目"]
        }
    }

    /// ⚠️ 人类专属：**工具层永远不能修改它**
    public static let isHumanOnly = true
}

// MARK: - 审批要求

/// 审批的"档位"。
///
/// 设计取舍（docs/08 §5.3）：**不能所有事都弹同一个确认框** ——
/// 那会让用户对所有确认都无脑点"允许"，安全模型就废了。
/// 因此按风险分级：低风险不打扰、高风险要看清、不可逆要生物识别。
public enum ApprovalRequirement: String, Sendable, Hashable, CaseIterable {
    /// 不需要审批
    case none
    /// 卡片内联"允许一次"（3 秒后自动允许，可撤销）
    case inlineAllow
    /// 一次点击
    case singleTap
    /// 需要看清细节（展示 diff / payload / 影响面）后点击
    case showDetails
    /// 需要生物识别
    case biometric
    /// 生物识别 + 手输确认词（不可逆且高危）
    case biometricPlusPhrase

    /// 是否会打断用户
    public var interrupts: Bool { self != .none && self != .inlineAllow }

    /// 是否可以"记住本次选择"（写回策略文件）
    public var isRememberable: Bool {
        switch self {
        case .showDetails, .singleTap: return true
        case .none, .inlineAllow, .biometric, .biometricPlusPhrase: return false
        }
    }

    public var displayName: String {
        switch self {
        case .none: return "无需确认"
        case .inlineAllow: return "内联允许"
        case .singleTap: return "点击确认"
        case .showDetails: return "查看细节后确认"
        case .biometric: return "需要生物识别"
        case .biometricPlusPhrase: return "生物识别 + 手输确认词"
        }
    }
}

// MARK: - 人类专属区判定

public enum HumanOnlyZoneDetector {

    /// 判定一个路径是否属于人类专属区。
    ///
    /// ⚠️ 这些区域**任何来源都不可写**——包括用户明确要求。
    /// 理由（docs/04 §12.3）：Agent 不能给自己提权；审计记录不能由被审计者改写。
    public static func zone(for path: VFSPath) -> HumanOnlyZone? {
        let comps = path.components.map { $0.lowercased() }
        let name = comps.last ?? ""

        // 记忆库与审计（属于 App 容器内的受管区域）
        if path.mount == .memory || path.mount == .sys {
            return path.mount == .sys ? .auditLog : .securityEvents
        }

        // 策略文件
        if name == "rune.policy.toml" || name == "policy.toml",
           comps.contains(".rune") || comps.count <= 1 {
            return .policyFile
        }

        // 凭据类文件
        if name.hasPrefix(".env") { return .credentials }
        if name.contains("credential") || name.contains("secret") { return .credentials }
        if name.hasSuffix(".pem") || name.hasSuffix(".p12") || name.hasSuffix(".key") { return .credentials }
        if name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") { return .credentials }
        if name == ".netrc" || name == ".npmrc" || name == ".pypirc" { return .credentials }

        // 信任档 / 审计日志的元数据文件
        if name == "trust.json" || name == "trust.toml" { return .trustDial }
        if name == "audit.jsonl" || name == "audit.db" { return .auditLog }
        if name == "anchors.db" { return .hashAnchors }

        return nil
    }

    /// 给模型的拒绝说明（必须**可执行**：告诉它该怎么办）
    public static func denial(for zone: HumanOnlyZone, path: VFSPath) -> ToolError {
        ToolError(
            kind: .humanOnlyZone,
            modelFacingMessage: "\(path.description) 属于人类专属区域。\(zone.denialReason)",
            suggestion: "不要尝试绕过。请在回复中说明你想改什么、为什么，让用户自己处理；或改为在 /workspace 下创建新的配置文件。"
        )
    }
}

// MARK: - 出口守卫（SSRF / 重定向）

public enum EgressGuard {

    public struct Verdict: Sendable, Equatable {
        public var allowed: Bool
        public var reason: String?
        /// 是否需要额外的用户确认（例如污点来源的首次访问）
        public var requiresConfirmation: Bool

        public static let ok = Verdict(allowed: true, reason: nil, requiresConfirmation: false)
        public static func deny(_ reason: String) -> Verdict {
            Verdict(allowed: false, reason: reason, requiresConfirmation: false)
        }
        public static func confirm(_ reason: String) -> Verdict {
            Verdict(allowed: true, reason: reason, requiresConfirmation: true)
        }
    }

    public static let maxRedirects = 3

    /// 私有网段（SSRF 防护的核心）
    public static func isPrivateAddress(_ host: String) -> Bool {
        let h = host.lowercased()

        // 主机名形式的本地地址
        if h == "localhost" || h.hasSuffix(".localhost") || h == "localhost.localdomain" { return true }
        if h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".lan") { return true }

        // IPv6
        if h == "::1" || h == "[::1]" { return true }
        if h.hasPrefix("fc") || h.hasPrefix("fd") { return true }   // fc00::/7 唯一本地地址
        if h.hasPrefix("fe80") { return true }                      // 链路本地

        // IPv4 字面量
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        let (a, b) = (parts[0], parts[1])
        if a == 10 { return true }                          // 10.0.0.0/8
        if a == 127 { return true }                         // 127.0.0.0/8
        if a == 169 && b == 254 { return true }             // 169.254.0.0/16（云元数据！）
        if a == 172 && (16...31).contains(b) { return true } // 172.16.0.0/12
        if a == 192 && b == 168 { return true }             // 192.168.0.0/16
        if a == 0 { return true }                           // 0.0.0.0/8
        if a == 100 && (64...127).contains(b) { return true } // 运营商级 NAT
        return false
    }

    /// scheme 白名单
    public static func isAllowedScheme(_ scheme: String) -> Bool {
        ["https", "http"].contains(scheme.lowercased())
    }

    /// 单跳检查
    public static func check(
        host: String,
        scheme: String = "https",
        allowPrivateNetwork: Bool
    ) -> Verdict {
        guard isAllowedScheme(scheme) else {
            return .deny("只允许 http/https，收到的是 \(scheme)。file://、data: 等 scheme 一律拒绝。")
        }
        if isPrivateAddress(host) && !allowPrivateNetwork {
            return .deny("""
            \(host) 是私有/本地地址，已被拒绝（防止 SSRF：Agent 不应能访问你的内网设备或云元数据接口）。
            如果你确实需要访问局域网服务（例如本机的 Ollama / LM Studio），请在设置里显式开启"允许局域网"。
            """)
        }
        return .ok
    }

    /// 重定向链检查：**每一跳都要重新校验**，且限制跳数
    ///
    /// 攻击手法：白名单域名 302 到内网地址 —— 只在第一跳校验就会被绕过。
    public static func checkRedirectChain(
        _ hosts: [String],
        allowPrivateNetwork: Bool
    ) -> Verdict {
        guard hosts.count <= maxRedirects + 1 else {
            return .deny("重定向超过 \(maxRedirects) 跳，已中止（可能是重定向环或规避尝试）。")
        }
        for (index, host) in hosts.enumerated() {
            let verdict = check(host: host, allowPrivateNetwork: allowPrivateNetwork)
            if !verdict.allowed {
                return .deny("重定向第 \(index + 1) 跳到 \(host) 被拒绝：\(verdict.reason ?? "")")
            }
        }
        return .ok
    }
}

// MARK: - 策略引擎

/// 策略引擎：**所有工具调用的唯一裁判**。
///
/// 它把四样东西合成一个决定：
///   1. 工具的**声明需求**（`ToolSpec.requirements`）
///   2. 当前的**能力令牌**（范围 + 有效期）
///   3. **信任刻度盘**（人类设定的粗粒度授权）
///   4. **污点**（这次调用是不是由不可信内容驱动的）
///
/// 设计原则（docs/09 §4.4）：**防线在前三条，教育在第四条**。
/// 即使用户模型完全被注入说服，前三层仍然独立生效。
public struct PolicyEngine: Sendable {

    public struct Context: Sendable {
        public var trustDial: TrustDial
        public var token: CapabilityToken?
        /// 计划是否已被用户批准（批量授权的依据）
        public var planApproved: Bool
        public var allowPrivateNetwork: Bool
        /// 本项目是否为"仅端侧模型"的敏感项目
        public var sensitiveProject: Bool

        public init(
            trustDial: TrustDial = .collaborate,
            token: CapabilityToken? = nil,
            planApproved: Bool = false,
            allowPrivateNetwork: Bool = false,
            sensitiveProject: Bool = false
        ) {
            self.trustDial = trustDial
            self.token = token
            self.planApproved = planApproved
            self.allowPrivateNetwork = allowPrivateNetwork
            self.sensitiveProject = sensitiveProject
        }
    }

    /// 一次调用的完整语境
    public struct Invocation: Sendable {
        public var tool: ToolSpec
        /// 涉及的文件路径（若有）
        public var path: VFSPath?
        public var access: PathScope.Access
        /// 网络出口（若有）
        public var egressHost: String?
        public var egressMethod: String
        public var egressBytes: Int
        /// 沙箱运行时（若有）
        public var runtime: SandboxRuntime?
        /// 原生能力（若有）
        public var nativeAPI: NativeAPI?
        /// Git 远端（若有）
        public var gitRemote: String?
        /// 污点来源（若这次调用是由不可信内容驱动的）
        public var taint: TaintOrigin?

        public init(
            tool: ToolSpec,
            path: VFSPath? = nil,
            access: PathScope.Access = .readOnly,
            egressHost: String? = nil,
            egressMethod: String = "GET",
            egressBytes: Int = 0,
            runtime: SandboxRuntime? = nil,
            nativeAPI: NativeAPI? = nil,
            gitRemote: String? = nil,
            taint: TaintOrigin? = nil
        ) {
            self.tool = tool
            self.path = path
            self.access = access
            self.egressHost = egressHost
            self.egressMethod = egressMethod
            self.egressBytes = egressBytes
            self.runtime = runtime
            self.nativeAPI = nativeAPI
            self.gitRemote = gitRemote
            self.taint = taint
        }
    }

    public init() {}

    /// 作出判定。**每个分支都必须能解释**——用户随时可以问"为什么这次被拦了"。
    public func evaluate(_ invocation: Invocation, context: Context) -> CapabilityDecision {

        // ---------- 第 0 层：人类专属区（最高优先级，任何来源都拒绝） ----------
        if invocation.tool.requirements.contains(.humanOnly) {
            return .humanOnly(zone: .trustDial)
        }
        if let path = invocation.path, let zone = HumanOnlyZoneDetector.zone(for: path) {
            // 读审计日志是允许的（用户在 UI 上看），写才拒绝
            if invocation.access != .readOnly {
                return .humanOnly(zone: zone)
            }
        }

        // ---------- 第 1 层：只读档的硬约束 ----------
        if context.trustDial == .readOnly {
            if invocation.access != .readOnly && invocation.path != nil {
                return .denied(
                    reason: "当前信任级别是「只读」，不允许修改文件。",
                    suggestion: "请先给出方案与 diff，由用户决定是否提高到「协作」。"
                )
            }
            if invocation.runtime != nil {
                return .denied(
                    reason: "当前信任级别是「只读」，不允许执行脚本。",
                    suggestion: "可以改用只读类工具（读文件 / 搜索 / git 只读）来完成任务。"
                )
            }
        }

        // ---------- 第 2 层：信任档决定的能力边界 ----------
        if invocation.access != .readOnly, let path = invocation.path {
            if !context.trustDial.allowsWorkspaceWrite {
                return .denied(
                    reason: "当前信任级别是「\(context.trustDial.displayName)」，不会把修改落到文件上。",
                    suggestion: "可以产出 diff 供用户查看；若需要落地，请请求用户把信任级别提到「协作」。"
                )
            }
            // ① 提议档之外，仍要求路径在已授权的挂载点内
            if path.mount == .sys {
                return .denied(reason: "/sys 是只读区域。", suggestion: "改为在工作区内操作。")
            }
        }

        if invocation.runtime != nil && !context.trustDial.allowsExecution {
            return .denied(
                reason: "当前信任级别不允许执行脚本。",
                suggestion: "改用内置工具完成任务，或请求用户提高信任级别。"
            )
        }

        if invocation.gitRemote != nil && !context.trustDial.allowsLocalCommit {
            return .denied(
                reason: "当前信任级别不允许 Git 写操作。",
                suggestion: "先把改动展示给用户。"
            )
        }

        // ---------- 第 3 层：能力令牌（范围 + 有效期） ----------
        //
        // ⚠️ 例外：**对 `/sys` 的只读访问不需要令牌**。
        // 理由：`/sys` 是运行时自己暴露的元数据（版本、设备能力、限额、已授予能力清单），
        // 不是用户数据；模型需要它来判断"我还能做什么"，若也要授权会变成纯粹的摩擦。
        // 但**写 `/sys` 一律拒绝**（上面第 2 层已处理）。
        let isRuntimeMetadataRead = invocation.path?.mount == .sys && invocation.access == .readOnly

        if let token = context.token, !isRuntimeMetadataRead {
            if token.isExpired() {
                return .denied(
                    reason: "本次授权已过期（能力令牌在 Turn 结束后即失效）。",
                    suggestion: "请重新发起这一步，让用户重新授权。"
                )
            }
            if let path = invocation.path {
                if !token.authorizeFile(path, need: invocation.access) {
                    return .denied(
                        reason: "\(path.description) 不在本次授权范围内（需要 \(invocation.access.rawValue) 权限）。",
                        suggestion: "如需访问，请在计划里说明用途；若属于新目录，请让用户用文件选择器授权。"
                    )
                }
            }
            if let host = invocation.egressHost {
                if !token.authorizeEgress(host: host, method: invocation.egressMethod, bytes: invocation.egressBytes) {
                    return .denied(
                        reason: "\(host) 不在本次授权的出口白名单内。",
                        suggestion: "请说明为什么要访问该域名；若确有必要，请让用户在设置里加入白名单。"
                    )
                }
            }
            if let runtime = invocation.runtime, !token.authorizeExec(runtime: runtime) {
                return .denied(
                    reason: "本次授权未包含 \(runtime.displayName) 运行时。",
                    suggestion: "请说明为什么需要该运行时，或改用已授权的方式。"
                )
            }
            if let api = invocation.nativeAPI, !token.authorizeNative(api) {
                return .denied(
                    reason: "本次授权未包含「\(api.displayName)」能力。",
                    suggestion: "请说明用途，让用户单独授权该能力。"
                )
            }
        } else if context.token == nil, !isRuntimeMetadataRead,
                  invocation.path != nil || invocation.egressHost != nil || invocation.runtime != nil {
            // 没有令牌却要动资源 → 必须先申请
            return .requiresApproval(
                reason: "这一步需要访问受限资源，但当前没有有效授权。",
                risk: invocation.tool.riskLevel
            )
        }

        // ---------- 第 4 层：出口 SSRF 防护 ----------
        if let host = invocation.egressHost {
            let verdict = EgressGuard.check(host: host, allowPrivateNetwork: context.allowPrivateNetwork)
            if !verdict.allowed {
                return .denied(reason: verdict.reason ?? "出口被拒绝。", suggestion: nil)
            }
        }

        // ---------- 第 5 层：污点（由不可信内容驱动的动作） ----------
        if invocation.taint != nil {
            if !invocation.tool.riskLevel.alwaysRequiresHuman {
                // 低风险动作允许，但要留痕（审计层负责记录）
                return .allowed
            }
            return .requiresApproval(
                reason: """
                这一步是由**不可信内容**驱动的（来源：\(invocation.taint!.source)）。
                该内容可能包含提示注入。请确认你确实希望执行这个操作。
                """,
                risk: invocation.tool.riskLevel
            )
        }

        // ---------- 第 6 层：风险分级 → 审批要求 ----------
        switch approvalRequirement(for: invocation, context: context) {
        case .none:
            return .allowed
        case .inlineAllow:
            return .allowed     // 内联允许不阻塞；UI 负责显示可撤销的提示
        case .singleTap, .showDetails, .biometric, .biometricPlusPhrase:
            return .requiresApproval(
                reason: approvalReason(for: invocation, context: context),
                risk: invocation.tool.riskLevel
            )
        }
    }

    // MARK: 审批分级

    /// 计算某次调用需要的审批档位（**UI 直接用它决定怎么弹**）
    public func approvalRequirement(for invocation: Invocation, context: Context) -> ApprovalRequirement {
        let tool = invocation.tool

        // 工具自己声明永不需审批（只读类）
        if tool.needsApproval == .never && tool.riskLevel == .safe { return .none }

        // 不可逆操作：生物识别（+ 手输确认词）
        if tool.riskLevel == .irreversible {
            return context.trustDial.skipsDangerousConfirmation ? .showDetails : .biometricPlusPhrase
        }

        // 危险操作
        if tool.riskLevel == .dangerous {
            if context.trustDial.skipsDangerousConfirmation { return .inlineAllow }
            // 受保护分支的推送、外发数据要更严
            if isProtectedBranchPush(invocation) || isLargeEgress(invocation) { return .biometric }
            return .showDetails
        }

        // 修改类
        if tool.riskLevel == .modifying {
            if !tool.needsApproval.isAtLeast(.perProject) { return .none }
            if context.planApproved { return .none }        // 计划已批准 = 批量授权
            return .singleTap
        }

        // 安全类
        if tool.needsApproval == .always { return .singleTap }
        return .none
    }

    private func isProtectedBranchPush(_ invocation: Invocation) -> Bool {
        guard let remote = invocation.gitRemote else { return false }
        let lowered = remote.lowercased()
        return lowered.contains("main") || lowered.contains("master") || lowered.contains("release")
    }

    private func isLargeEgress(_ invocation: Invocation) -> Bool {
        invocation.egressBytes > 64 * 1024
    }

    /// 给用户看的审批理由（**必须回答四件事**：做什么、影响什么、能不能撤销、为什么现在做）
    private func approvalReason(for invocation: Invocation, context: Context) -> String {
        let tool = invocation.tool
        var parts: [String] = ["\(tool.name)：\(tool.description.split(separator: "\n").first.map(String.init) ?? "")"]

        if let path = invocation.path {
            parts.append("目标：\(path.description)（\(invocation.access == .readOnly ? "只读" : invocation.access == .write ? "写入" : "删除")）")
        }
        if let host = invocation.egressHost {
            parts.append("网络：\(invocation.egressMethod) \(host)")
        }
        if let remote = invocation.gitRemote {
            parts.append("远端：\(remote)")
        }
        switch tool.riskLevel {
        case .irreversible: parts.append("⚠️ 不可逆：此操作无法自动回滚")
        case .dangerous: parts.append("可撤销性：\(tool.isIdempotent ? "可以回滚" : "部分可回滚（可能有外部副作用）")")
        default: break
        }
        if context.planApproved {
            parts.append("（本次操作在你的已批准计划内）")
        }
        return parts.joined(separator: "\n")
    }
}

extension ToolSpec.ApprovalPolicy {
    /// 审批策略的强度序（用于比较）
    public func isAtLeast(_ other: ToolSpec.ApprovalPolicy) -> Bool {
        func rank(_ p: ToolSpec.ApprovalPolicy) -> Int {
            switch p {
            case .never: return 0
            case .perProject: return 1
            case .always: return 2
            case .biometric: return 3
            }
        }
        return rank(self) >= rank(other)
    }
}
