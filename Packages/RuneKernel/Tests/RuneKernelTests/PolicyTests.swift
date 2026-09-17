import Testing
import Foundation
@testable import RuneKernel

// MARK: - 辅助

private func ws(_ s: String) -> VFSPath {
    VFSPath(mount: .workspace, components: s.split(separator: "/").map(String.init))
}

private func tool(
    _ name: String = "read_file",
    risk: ToolSpec.RiskLevel = .safe,
    approval: ToolSpec.ApprovalPolicy = .never,
    idempotent: Bool = true,
    requires: Set<CapabilityKind> = [.fsRead]
) -> ToolSpec {
    ToolSpec(
        name: name,
        description: "测试工具",
        inputSchema: .object(properties: [:], required: [], additionalProperties: false),
        isIdempotent: idempotent,
        riskLevel: risk,
        needsApproval: approval,
        requirements: requires
    )
}

/// 造一个覆盖全部范围的令牌（用于测试各层时排除令牌干扰）
private func fullToken(
    expiresIn: TimeInterval = 300,
    runtime: SandboxRuntime = .python
) -> CapabilityToken {
    CapabilityToken(
        issuedForTurn: UUID(),
        scopes: [
            .fsRead(ws("")),
            .fsWrite(ws("")),
            .fsDelete(ws("")),
            .exec(runtime: runtime),
            .egress(EgressRule(host: "api.github.com", methods: ["GET", "POST"], reason: "测试")),
            .native(.photos),
            .gitWrite(remote: "origin"),
        ],
        expiresAt: Date().addingTimeInterval(expiresIn),
        grantedBy: .planApproval,
        reason: "测试"
    )
}

// MARK: - 信任刻度盘

@Suite("TrustDial —— 信任刻度盘")
struct TrustDialTests {

    @Test("五档能力边界递增")
    func capabilityLadder() {
        #expect(!TrustDial.readOnly.allowsWorkspaceWrite)
        #expect(!TrustDial.readOnly.allowsExecution)
        #expect(!TrustDial.readOnly.allowsLocalCommit)
        #expect(!TrustDial.readOnly.allowsPush)

        #expect(!TrustDial.propose.allowsWorkspaceWrite)   // 提议档不落地
        #expect(TrustDial.propose.allowsExecution)
        #expect(!TrustDial.propose.allowsPush)

        #expect(TrustDial.collaborate.allowsWorkspaceWrite)
        #expect(TrustDial.collaborate.allowsLocalCommit)
        #expect(!TrustDial.collaborate.allowsPush)         // 协作档推送需确认

        #expect(TrustDial.autonomous.allowsPush)
        #expect(!TrustDial.autonomous.skipsDangerousConfirmation)

        #expect(TrustDial.full.skipsDangerousConfirmation)
    }

    @Test("每一档都有可展示的说明（不能只给一个档位名）")
    func everyDialExplainsItself() {
        for dial in TrustDial.allCases {
            #expect(!dial.displayName.isEmpty)
            #expect(dial.explanation.count >= 3, "\(dial) 的说明太少")
        }
        // 全权档必须明确警告
        #expect(TrustDial.full.explanation.contains { $0.contains("⚠️") })
    }

    @Test("⚠️ 信任档是人类专属（工具层不能改）")
    func dialIsHumanOnly() {
        #expect(TrustDial.isHumanOnly)
    }
}

// MARK: - 人类专属区

@Suite("HumanOnlyZoneDetector —— 人类专属区")
struct HumanOnlyZoneTests {

    @Test("⚠️ 凭据类文件一律不可写")
    func credentialsAreProtected() {
        for p in [".env", ".env.local", "config/credentials.json", "certs/server.pem",
                  "keys/id_rsa", ".netrc", ".npmrc", "app.p12", "private.key"] {
            let zone = HumanOnlyZoneDetector.zone(for: ws(p))
            #expect(zone == .credentials, "\(p) 应属于凭据区，实际 \(String(describing: zone))")
        }
    }

    @Test("策略文件受保护")
    func policyFileProtected() {
        #expect(HumanOnlyZoneDetector.zone(for: ws("rune.policy.toml")) == .policyFile)
        #expect(HumanOnlyZoneDetector.zone(for: ws(".rune/policy.toml")) == .policyFile)
    }

    @Test("记忆库与系统区受保护")
    func memoryAndSystemProtected() {
        #expect(HumanOnlyZoneDetector.zone(for: VFSPath(mount: .memory, components: ["knowledge.db"])) == .securityEvents)
        #expect(HumanOnlyZoneDetector.zone(for: VFSPath(mount: .sys, components: ["capabilities.json"])) == .auditLog)
    }

    @Test("普通源码文件不受影响")
    func normalFilesUnaffected() {
        for p in ["src/main.swift", "README.md", "tests/test_api.py", "docs/note.md"] {
            #expect(HumanOnlyZoneDetector.zone(for: ws(p)) == nil, "\(p) 不该被判定为人类专属区")
        }
    }

    @Test("拒绝说明是可执行的（告诉模型该怎么办）")
    func denialIsActionable() {
        let err = HumanOnlyZoneDetector.denial(for: .policyFile, path: ws(".env"))
        #expect(err.kind == .humanOnlyZone)
        #expect(err.modelFacingMessage.contains("人类专属区域"))
        #expect(err.suggestion?.contains("用户") == true)
        #expect(!err.isSelfCorrectable)     // 策略类拒绝不是"改改参数就能过"
    }
}

// MARK: - 出口守卫

@Suite("EgressGuard —— SSRF 防护")
struct EgressGuardTests {

    @Test("⚠️ 私有网段一律拒绝（默认）")
    func privateAddressesDenied() {
        let privateHosts = [
            "localhost", "127.0.0.1", "10.0.0.5", "192.168.1.1", "172.16.0.1",
            "169.254.169.254",   // 云元数据接口 —— 最经典的 SSRF 目标
            "0.0.0.0", "::1", "fc00::1", "something.internal", "printer.local",
        ]
        for host in privateHosts {
            let v = EgressGuard.check(host: host, allowPrivateNetwork: false)
            #expect(!v.allowed, "\(host) 应被拒绝")
            #expect(v.reason?.contains("SSRF") == true)
        }
    }

    @Test("公网地址放行")
    func publicAddressesAllowed() {
        for host in ["api.github.com", "8.8.8.8", "raw.githubusercontent.com"] {
            #expect(EgressGuard.check(host: host, allowPrivateNetwork: false).allowed)
        }
    }

    @Test("用户显式开启后可访问局域网（Ollama / LM Studio 场景）")
    func lanAllowedWhenOptedIn() {
        #expect(EgressGuard.check(host: "192.168.1.50", allowPrivateNetwork: true).allowed)
        #expect(EgressGuard.check(host: "localhost", allowPrivateNetwork: true).allowed)
        // 但公网仍照常
        #expect(EgressGuard.check(host: "api.github.com", allowPrivateNetwork: true).allowed)
    }

    @Test("非 http/https 的 scheme 被拒绝")
    func schemeWhitelist() {
        #expect(!EgressGuard.check(host: "example.com", scheme: "file", allowPrivateNetwork: false).allowed)
        #expect(!EgressGuard.check(host: "example.com", scheme: "data", allowPrivateNetwork: false).allowed)
        #expect(EgressGuard.check(host: "example.com", scheme: "HTTPS", allowPrivateNetwork: false).allowed)
    }

    @Test("⚠️ 重定向链每一跳都要校验（只查第一跳会被绕过）")
    func redirectChainChecked() {
        // 白名单域名 → 内网地址
        let attack = ["api.github.com", "169.254.169.254"]
        let v = EgressGuard.checkRedirectChain(attack, allowPrivateNetwork: false)
        #expect(!v.allowed)
        #expect(v.reason?.contains("重定向") == true)

        // 全是公网 → 放行
        #expect(EgressGuard.checkRedirectChain(["a.com", "b.com", "c.com"], allowPrivateNetwork: false).allowed)

        // 超过跳数上限
        let tooMany = Array(repeating: "a.com", count: EgressGuard.maxRedirects + 2)
        #expect(!EgressGuard.checkRedirectChain(tooMany, allowPrivateNetwork: false).allowed)
    }
}

// MARK: - 策略引擎

@Suite("PolicyEngine —— 工具调用的唯一裁判")
struct PolicyEngineTests {

    private let engine = PolicyEngine()

    // MARK: 人类专属区

    @Test("⚠️ 人类专属区：任何信任档都拒绝写入")
    func humanOnlyZoneBlocksAllDials() {
        for dial in TrustDial.allCases {
            let ctx = PolicyEngine.Context(trustDial: dial, token: fullToken(), planApproved: true)
            let decision = engine.evaluate(
                .init(tool: tool("write_file", risk: .modifying, approval: .perProject),
                      path: ws(".env"), access: .write),
                context: ctx
            )
            guard case .humanOnly(let zone) = decision else {
                Issue.record("信任档 \(dial) 竟然允许写 .env：\(decision)"); return
            }
            #expect(zone == .credentials)
        }
    }

    @Test("读审计日志允许，写审计日志拒绝")
    func auditLogReadableButNotWritable() {
        let ctx = PolicyEngine.Context(token: fullToken())
        let readDecision = engine.evaluate(
            .init(tool: tool(), path: VFSPath(mount: .sys, components: ["audit.jsonl"]), access: .readOnly),
            context: ctx
        )
        #expect(!readDecision.isDenied)

        let writeDecision = engine.evaluate(
            .init(tool: tool("write_file", risk: .modifying), path: VFSPath(mount: .sys, components: ["audit.jsonl"]), access: .write),
            context: ctx
        )
        if case .humanOnly = writeDecision {} else { Issue.record("应拒绝写审计日志：\(writeDecision)") }
    }

    @Test("声明 humanOnly 能力的工具直接被拒（防自我提权）")
    func humanOnlyRequirementRejected() {
        let ctx = PolicyEngine.Context(token: fullToken())
        let decision = engine.evaluate(
            .init(tool: tool("update_trust", requires: [.humanOnly])),
            context: ctx
        )
        if case .humanOnly = decision {} else { Issue.record("应拒绝：\(decision)") }
    }

    // MARK: 信任档约束

    @Test("只读档：不允许写文件、不允许执行脚本")
    func readOnlyDialBlocksWrites() {
        let ctx = PolicyEngine.Context(trustDial: .readOnly, token: fullToken())
        let write = engine.evaluate(
            .init(tool: tool("write_file", risk: .modifying), path: ws("src/a.swift"), access: .write),
            context: ctx
        )
        #expect(write.isDenied)

        let exec = engine.evaluate(
            .init(tool: tool("run_python", risk: .modifying, requires: [.exec]), runtime: .python),
            context: ctx
        )
        #expect(exec.isDenied)
    }

    @Test("提议档：不落地写入，但允许读与执行")
    func proposeDialNoWrite() {
        let ctx = PolicyEngine.Context(trustDial: .propose, token: fullToken())
        let write = engine.evaluate(
            .init(tool: tool("write_file", risk: .modifying), path: ws("src/a.swift"), access: .write),
            context: ctx
        )
        #expect(write.isDenied)
        #expect(write.asToolError()?.modelFacingMessage.contains("不会把修改落到文件上") == true)

        let read = engine.evaluate(
            .init(tool: tool(), path: ws("src/a.swift"), access: .readOnly), context: ctx
        )
        #expect(read.isAllowed)

        let exec = engine.evaluate(
            .init(tool: tool("run_python", requires: [.exec]), runtime: .python), context: ctx
        )
        #expect(exec.isAllowed)
    }

    @Test("协作档：工作区可写；推送需确认")
    func collaborateDial() {
        let ctx = PolicyEngine.Context(trustDial: .collaborate, token: fullToken(), planApproved: true)
        let write = engine.evaluate(
            .init(tool: tool("write_file", risk: .modifying, approval: .perProject),
                  path: ws("src/a.swift"), access: .write),
            context: ctx
        )
        #expect(write.isAllowed, "计划已批准 + 协作档，工作区写入应放行")

        let push = engine.evaluate(
            .init(tool: tool("git_push", risk: .dangerous, approval: .always, idempotent: false),
                  gitRemote: "origin/main"),
            context: ctx
        )
        #expect(!push.isAllowed)
    }

    // MARK: 能力令牌

    @Test("⚠️ 令牌过期 → 拒绝（且提示重新授权）")
    func expiredTokenDenied() {
        let ctx = PolicyEngine.Context(token: fullToken(expiresIn: -60))
        let decision = engine.evaluate(
            .init(tool: tool(), path: ws("src/a.swift"), access: .readOnly), context: ctx
        )
        #expect(decision.isDenied)
        #expect(decision.asToolError()?.modelFacingMessage.contains("过期") == true)
    }

    @Test("⚠️ 路径越权 → 拒绝（范围外）")
    func pathOutOfScopeDenied() {
        let token = CapabilityToken(
            issuedForTurn: UUID(),
            scopes: [.fsRead(ws("src"))],     // 只授权 src/
            expiresAt: Date().addingTimeInterval(300),
            grantedBy: .planApproval, reason: "测试"
        )
        let ctx = PolicyEngine.Context(token: token)
        #expect(engine.evaluate(.init(tool: tool(), path: ws("src/a.swift"), access: .readOnly), context: ctx).isAllowed)
        #expect(engine.evaluate(.init(tool: tool(), path: ws("docs/a.md"), access: .readOnly), context: ctx).isDenied)
    }

    @Test("⚠️ 出口不在白名单 → 拒绝")
    func egressOutOfScopeDenied() {
        let ctx = PolicyEngine.Context(token: fullToken())
        #expect(engine.evaluate(
            .init(tool: tool("fetch_url", requires: [.egress]), egressHost: "api.github.com"),
            context: ctx).isAllowed)
        let denied = engine.evaluate(
            .init(tool: tool("fetch_url", requires: [.egress]), egressHost: "evil.com"),
            context: ctx)
        #expect(denied.isDenied)
        #expect(denied.asToolError()?.modelFacingMessage.contains("白名单") == true)
    }

    @Test("未授予的运行时被拒绝")
    func runtimeOutOfScopeDenied() {
        let ctx = PolicyEngine.Context(token: fullToken(runtime: .python))
        #expect(engine.evaluate(.init(tool: tool("run_python"), runtime: .python), context: ctx).isAllowed)
        #expect(engine.evaluate(.init(tool: tool("run_shell"), runtime: .shell), context: ctx).isDenied)
    }

    @Test("未授予的原生能力被拒绝")
    func nativeOutOfScopeDenied() {
        let ctx = PolicyEngine.Context(token: fullToken())
        #expect(engine.evaluate(.init(tool: tool("photos_search"), nativeAPI: .photos), context: ctx).isAllowed)
        #expect(engine.evaluate(.init(tool: tool("contacts_search"), nativeAPI: .contacts), context: ctx).isDenied)
    }

    @Test("无令牌但动资源 → 需要审批（而不是静默放行）")
    func noTokenRequiresApproval() {
        let ctx = PolicyEngine.Context(token: nil)
        let decision = engine.evaluate(
            .init(tool: tool(), path: ws("src/a.swift"), access: .readOnly), context: ctx
        )
        guard case .requiresApproval = decision else {
            Issue.record("应要求审批：\(decision)"); return
        }
    }

    // MARK: 污点

    @Test("⚠️ 污点驱动的高危动作：即使域名/路径在令牌内也必须确认")
    func taintForcesConfirmationForDangerous() {
        let ctx = PolicyEngine.Context(token: fullToken(), planApproved: true)
        let origin = TaintOrigin(source: "web:https://example.com/issue/42", fetchedAt: Date())

        let dangerous = engine.evaluate(
            .init(tool: tool("git_push", risk: .dangerous, approval: .always), gitRemote: "origin/main", taint: origin),
            context: ctx
        )
        guard case .requiresApproval(let reason, _) = dangerous else {
            Issue.record("污点驱动的高危动作必须确认：\(dangerous)"); return
        }
        #expect(reason.contains("不可信内容"))
        #expect(reason.contains("example.com"))
        #expect(reason.contains("提示注入"))
    }

    @Test("污点驱动的低危动作允许（但审计层会留痕）")
    func taintAllowsLowRisk() {
        let ctx = PolicyEngine.Context(token: fullToken())
        let origin = TaintOrigin(source: "web:https://example.com", fetchedAt: Date())
        let decision = engine.evaluate(
            .init(tool: tool(), path: ws("README.md"), access: .readOnly, taint: origin),
            context: ctx
        )
        #expect(decision.isAllowed)
    }

    // MARK: SSRF

    @Test("⚠️ SSRF：内网地址被策略层拦下")
    func ssrfBlocked() {
        let token = CapabilityToken(
            issuedForTurn: UUID(),
            scopes: [.egress(EgressRule(host: "169.254.169.254", methods: ["GET"], reason: "测试"))],
            expiresAt: Date().addingTimeInterval(300),
            grantedBy: .planApproval, reason: "测试"
        )
        let ctx = PolicyEngine.Context(token: token, allowPrivateNetwork: false)
        let decision = engine.evaluate(
            .init(tool: tool("fetch_url", requires: [.egress]), egressHost: "169.254.169.254"),
            context: ctx
        )
        #expect(decision.isDenied)
        #expect(decision.asToolError()?.modelFacingMessage.contains("SSRF") == true)
    }

    // MARK: 审批分级

    @Test("⚠️ 危险操作必须人工确认（不可被策略静默放行）")
    func dangerousAlwaysRequiresHuman() {
        let ctx = PolicyEngine.Context(trustDial: .collaborate, token: fullToken(), planApproved: true)
        let req = engine.approvalRequirement(
            for: .init(tool: tool("git_push", risk: .dangerous, approval: .always), gitRemote: "origin/feature"),
            context: ctx
        )
        #expect(req == .showDetails)
        #expect(req.interrupts)
    }

    @Test("⚠️ 不可逆操作要生物识别 + 手输确认词")
    func irreversibleNeedsBiometricAndPhrase() {
        let ctx = PolicyEngine.Context(trustDial: .autonomous, token: fullToken())
        let req = engine.approvalRequirement(
            for: .init(tool: tool("pay_invoice", risk: .irreversible, approval: .biometric)),
            context: ctx
        )
        #expect(req == .biometricPlusPhrase)
        #expect(!req.isRememberable)   // 不可逆操作不允许"记住选择"
    }

    @Test("⚠️ 推送受保护分支要生物识别（比普通推送更严）")
    func protectedBranchNeedsBiometric() {
        let ctx = PolicyEngine.Context(trustDial: .collaborate, token: fullToken())
        let main = engine.approvalRequirement(
            for: .init(tool: tool("git_push", risk: .dangerous, approval: .always), gitRemote: "origin/main"),
            context: ctx
        )
        let feature = engine.approvalRequirement(
            for: .init(tool: tool("git_push", risk: .dangerous, approval: .always), gitRemote: "origin/feature-x"),
            context: ctx
        )
        #expect(main == .biometric)
        #expect(feature == .showDetails)
    }

    @Test("大批量外发数据要生物识别")
    func largeEgressNeedsBiometric() {
        let ctx = PolicyEngine.Context(token: fullToken())
        let req = engine.approvalRequirement(
            for: .init(tool: tool("http_request", risk: .dangerous, approval: .always),
                       egressHost: "api.github.com", egressBytes: 100 * 1024),
            context: ctx
        )
        #expect(req == .biometric)
    }

    @Test("计划已批准 → 修改类操作免于逐次审批（这是手机体验的关键）")
    func planApprovalEnablesBatch() {
        let token = fullToken()
        let without = engine.approvalRequirement(
            for: .init(tool: tool("write_file", risk: .modifying, approval: .perProject), path: ws("a.swift"), access: .write),
            context: PolicyEngine.Context(token: token, planApproved: false)
        )
        let with = engine.approvalRequirement(
            for: .init(tool: tool("write_file", risk: .modifying, approval: .perProject), path: ws("a.swift"), access: .write),
            context: PolicyEngine.Context(token: token, planApproved: true)
        )
        #expect(without == .singleTap)
        #expect(with == .none)
    }

    @Test("只读工具不打扰用户")
    func readOnlyToolsAreSilent() {
        let ctx = PolicyEngine.Context(token: fullToken())
        #expect(engine.approvalRequirement(for: .init(tool: tool()), context: ctx) == .none)
    }

    @Test("全权档跳过危险操作确认（但不可逆仍需看清细节）")
    func fullDialSkipsDangerous() {
        let ctx = PolicyEngine.Context(trustDial: .full, token: fullToken())
        let dangerous = engine.approvalRequirement(
            for: .init(tool: tool("git_push", risk: .dangerous, approval: .always), gitRemote: "origin/main"),
            context: ctx
        )
        #expect(dangerous == .inlineAllow)

        let irreversible = engine.approvalRequirement(
            for: .init(tool: tool("pay", risk: .irreversible, approval: .biometric)),
            context: ctx
        )
        #expect(irreversible == .showDetails)   // 仍要求看清细节
    }

    @Test("审批理由必须回答四件事（做什么/影响什么/能否撤销/为什么现在）")
    func approvalReasonIsComplete() {
        let ctx = PolicyEngine.Context(token: fullToken())
        let decision = engine.evaluate(
            .init(tool: tool("delete_path", risk: .dangerous, approval: .always, idempotent: false),
                  path: ws("build/"), access: .delete),
            context: ctx
        )
        guard case .requiresApproval(let reason, let risk) = decision else {
            Issue.record("应要求确认：\(decision)"); return
        }
        #expect(risk == .dangerous)
        #expect(reason.contains("delete_path"))       // 做什么
        #expect(reason.contains("/workspace/build"))  // 影响什么
        #expect(reason.contains("回滚"))              // 能否撤销
    }

    // MARK: 判定结果的可用性

    @Test("所有拒绝都能转成可回灌给模型的错误（含建议）")
    func denialsAreActionable() {
        let cases: [(PolicyEngine.Invocation, PolicyEngine.Context)] = [
            (.init(tool: tool(), path: ws(".env"), access: .write), PolicyEngine.Context(token: fullToken())),
            (.init(tool: tool(), path: ws("x"), access: .write), PolicyEngine.Context(trustDial: .readOnly, token: fullToken())),
            (.init(tool: tool(), path: ws("outside/x"), access: .readOnly), PolicyEngine.Context(token: CapabilityToken(
                issuedForTurn: UUID(), scopes: [.fsRead(ws("src"))],
                expiresAt: Date().addingTimeInterval(300), grantedBy: .planApproval, reason: "t"))),
        ]
        for (inv, ctx) in cases {
            let decision = engine.evaluate(inv, context: ctx)
            #expect(!decision.isAllowed)
            let err = decision.asToolError()
            #expect(err != nil)
            #expect(!(err?.modelFacingMessage.isEmpty ?? true))
            #expect(err?.suggestion != nil, "拒绝必须给出可执行的下一步：\(decision)")
        }
    }
}
