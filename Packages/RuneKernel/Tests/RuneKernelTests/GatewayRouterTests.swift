import Testing
import Foundation
@testable import RuneKernel

// MARK: - 网关的测试
//
// 这一组守的是用户最关心的两件事：**接入主流模型** 与 **支持中转站**。
// 而其中三条是"硬规则"，做错了不会有报错、只会让用户吃亏：
//   ① **禁止静默降级**（换了模型必须让用户看见）
//   ② **`verify` 必须与执行用不同模型**
//   ③ **敏感项目里中转渠道不出现在可选列表**

private func model(
    _ id: String,
    alias: String? = nil,
    context: Int = 128_000,
    tools: Bool = true,
    vision: Bool = false,
    reasoning: Bool = false,
    price: ModelPrice? = nil
) -> ModelDescriptor {
    ModelDescriptor(id: id, alias: alias, contextWindow: context,
                    supportsTools: tools, supportsVision: vision,
                    supportsReasoning: reasoning, price: price)
}

private func channel(
    _ id: String,
    _ family: ProtocolFamily = .openAIChat,
    category: ProviderCategory = .official,
    aliases: [String: String] = [:],
    priceOverrides: [String: ModelPrice] = [:],
    enabled: Bool = true,
    models: [ModelDescriptor]
) -> ProviderConfig {
    ProviderConfig(
        id: id, displayName: id.capitalized, protocolFamily: family,
        baseURL: "https://\(id).example.com/v1",
        auth: .bearer(keyRef: "keychain://\(id)"),
        category: category, modelAliases: aliases,
        priceOverrides: priceOverrides, isEnabled: enabled, models: models
    )
}

/// 一套典型配置：一个官方 + 一个中转 + 一个端侧
private func channels() -> [ProviderConfig] {
    [
        channel("on_device", category: .onDevice,
                models: [model("apple-fm", alias: "apple-fm", context: 4_096, tools: true)]),
        channel("plan", .anthropicMessages,
                models: [model("claude-opus-5", alias: "strong", context: 200_000, reasoning: true)]),
        channel("code", .openAIChat,
                models: [model("deepseek-v4-pro", alias: "default", context: 128_000, reasoning: true)]),
        channel("relay", .openAIChat, category: .thirdPartyRelay,
                aliases: ["gpt-4o": "some-other-model-v2"],
                models: [model("some-other-model-v2", alias: "gpt-4o", context: 64_000, vision: true)]),
    ]
}

// MARK: - 渠道配置

@Suite("ProviderConfig —— 中转站是一等公民，风险要透明")

struct ProviderConfigTests {

    @Test("⭐ 鉴权只存引用，不存密钥本身")
    func authNeverHoldsTheSecret() {
        let config = channel("relay", category: .thirdPartyRelay, models: [model("m")])
        #expect(config.auth.keyRef == "keychain://relay")
        #expect(config.auth.headerName == "Authorization")
        // 把配置编码成 JSON 也带不出密钥 —— 泄密面缩到 Keychain 一处
        let json = String(decoding: (try? JSONEncoder().encode(config)) ?? Data(), as: UTF8.self)
        // ⚠️ `JSONEncoder` 默认把 `/` 转义成 `\/`（Foundation 的 `.withoutEscapingSlashes`
        //    才是关掉它的开关）—— 直接 `contains("keychain://relay")` 必然是假的。
        let unescaped = json.replacingOccurrences(of: "\\/", with: "/")
        #expect(unescaped.contains("keychain://relay"))
        // 真正的判据：配置里放密钥的字段**只有引用**，没有任何像密钥的东西
        #expect(unescaped.contains("\"keyRef\""))
        #expect(!unescaped.contains("sk-"))
        #expect(!unescaped.contains("Bearer "))
        // 往返不丢信息（引用能原样还原）
        let back = try? JSONDecoder().decode(ProviderConfig.self, from: Data(json.utf8))
        #expect(back?.auth == config.auth)
    }

    @Test("三种鉴权方式都能表达（中转站的自定义头很常见）")
    func authVariants() {
        #expect(AuthConfig.bearer(keyRef: "a").displayName == "Bearer")
        #expect(AuthConfig.header(name: "X-Relay-Token", keyRef: "a").headerName == "X-Relay-Token")
        #expect(AuthConfig.query(name: "api_key", keyRef: "a").headerName == nil)
        #expect(AuthConfig.none.keyRef == nil)
    }

    @Test("⭐ 中转站的隐私提示必须存在（首次使用要弹一次说明）")
    func relayHasPrivacyNote() {
        let note = ProviderCategory.thirdPartyRelay.privacyNote
        #expect(note?.contains("服务方可见") == true)
        // 官方直连不需要提示（不要用噪音淹没真正的提示）
        #expect(ProviderCategory.official.privacyNote == nil)
        #expect(ProviderCategory.onDevice.privacyNote?.contains("不离开") == true)
    }

    @Test("⭐ 敏感项目白名单：只允许官方直连 / 官方云 / 端侧")
    func sensitiveProjectWhitelist() {
        #expect(ProviderCategory.official.isAllowedInSensitiveProject)
        #expect(ProviderCategory.officialCloud.isAllowedInSensitiveProject)
        #expect(ProviderCategory.onDevice.isAllowedInSensitiveProject)
        #expect(!ProviderCategory.thirdPartyRelay.isAllowedInSensitiveProject)
        // ⚠️ 局域网自建**不在**白名单：用户勾"敏感项目"时想的是"别出去"，
        //    而不是"只出到局域网"。
        #expect(!ProviderCategory.selfHostedLAN.isAllowedInSensitiveProject)
    }

    @Test("⭐ 模型名映射要声明式、可展示（中转常用别名指向别家模型）")
    func aliasMappingIsVisible() {
        let relay = channel("relay", category: .thirdPartyRelay,
                            aliases: ["gpt-4o": "some-other-model-v2"],
                            models: [model("some-other-model-v2", alias: "gpt-4o")])
        #expect(relay.resolve("gpt-4o") == "some-other-model-v2")
        let notice = relay.mappingNotice("gpt-4o")
        #expect(notice?.contains("实际映射为") == true)
        #expect(notice?.contains("some-other-model-v2") == true)

        // 名字没被改过就不提示
        #expect(relay.mappingNotice("some-other-model-v2") == nil)
        #expect(relay.resolve("根本不存在") == nil)
    }

    @Test("ModelRef 的显示名把实际模型写出来")
    func displayStringShowsRealModel() {
        let ref = GatewayRouter.resolve("relay:gpt-4o", channels: channels())
        #expect(ref?.modelID == "some-other-model-v2")
        #expect(ref?.displayString.contains("some-other-model-v2") == true,
                "用户有权知道自己到底在用哪个模型：\(ref?.displayString ?? "")")
    }
}

// MARK: - 路由

@Suite("GatewayRouter —— 选渠道、给降级链、说清为什么")

struct GatewayRouterTests {

    @Test("按任务类型选主渠道")
    func routesByTaskKind() {
        let decision = GatewayRouter.route(task: .plan, requirements: .init(), channels: channels())
        #expect(decision.primary?.modelID == "claude-opus-5")
        #expect(decision.explanation.contains("claude-opus-5"))
    }

    @Test("⭐ 降级链按规则里的顺序排")
    func fallbackChainIsOrdered() {
        let rules = [
            RouteRule(task: .code, model: "code:default", fallback: ["plan:strong", "on_device:apple-fm"]),
        ]
        let decision = GatewayRouter.route(task: .code, requirements: .init(), channels: channels(), rules: rules)
        #expect(decision.chain.map(\.modelID) == ["deepseek-v4-pro", "claude-opus-5", "apple-fm"])
        #expect(decision.hasFallback)
    }

    @Test("⚠️ 不支持工具的模型会被排除，并说清原因")
    func rejectsModelWithoutTools() {
        let rules = [RouteRule(task: .code, model: "no_tools:m", fallback: ["code:default"])]
        let list = [
            channel("no_tools", models: [model("m", tools: false)]),
            channel("code", models: [model("deepseek-v4-pro", alias: "default")]),
        ]
        let decision = GatewayRouter.route(task: .code, requirements: .init(needsTools: true),
                                          channels: list, rules: rules)
        #expect(decision.primary?.providerID == "code")
        #expect(decision.rejections.contains { $0.reason.contains("不支持工具调用") })
    }

    @Test("看图任务会排除不支持视觉的模型")
    func rejectsModelWithoutVision() {
        let rules = [RouteRule(task: .vision, model: "code:default", fallback: ["relay:gpt-4o"])]
        let decision = GatewayRouter.route(task: .vision, requirements: .init(needsVision: true),
                                          channels: channels(), rules: rules)
        #expect(decision.primary?.modelID == "some-other-model-v2")
        #expect(decision.rejections.contains { $0.reason.contains("不支持图片") })
    }

    @Test("⚠️ 上下文装不下就排除（不是硬失败，而是换一个）")
    func rejectsTooSmallContext() {
        let rules = [RouteRule(task: .longContext, model: "on_device:apple-fm", fallback: ["plan:strong"])]
        let decision = GatewayRouter.route(
            task: .longContext,
            requirements: .init(contextTokens: 150_000),
            channels: channels(), rules: rules
        )
        #expect(decision.primary?.modelID == "claude-opus-5")
        #expect(decision.rejections.contains { $0.reason.contains("装不下") })
    }

    @Test("⚠️ 成本超上限就排除（按本次上下文估算）")
    func rejectsOverCostCeiling() {
        let cheap = ModelPrice(inputMicroPerMTok: 100_000, outputMicroPerMTok: 100_000)
        let expensive = ModelPrice(inputMicroPerMTok: 50_000_000, outputMicroPerMTok: 50_000_000)
        let list = [
            channel("pricey", models: [model("p", alias: "p", price: expensive)]),
            channel("cheap", models: [model("c", alias: "c", price: cheap)]),
        ]
        let rules = [RouteRule(task: .code, model: "pricey:p", fallback: ["cheap:c"])]
        let decision = GatewayRouter.route(
            task: .code, requirements: .init(contextTokens: 50_000, maxCostMicroUSD: 100_000),
            channels: list, rules: rules
        )
        #expect(decision.primary?.providerID == "cheap")
        #expect(decision.rejections.contains { $0.reason.contains("超过这一步的上限") })
    }

    @Test("⭐ 不健康的渠道被摘掉，并带上最后一次的错误")
    func unhealthyChannelIsRemoved() {
        var health = HealthTracker()
        let now = Date()
        for _ in 0..<HealthTracker.failureThreshold {
            health.recordFailure("code", error: "429 限流", now: now)
        }
        #expect(!health.isUsable("code"))

        let rules = [RouteRule(task: .code, model: "code:default", fallback: ["plan:strong"])]
        let decision = GatewayRouter.route(task: .code, requirements: .init(),
                                          channels: channels(), rules: rules, health: health)
        #expect(decision.primary?.providerID == "plan")
        #expect(decision.rejections.contains { $0.reason.contains("429 限流") })
    }

    @Test("⭐⭐ 硬规则：独立验证必须与执行用不同的模型")
    func verifyMustUseADifferentModel() {
        let executor = GatewayRouter.resolve("code:default", channels: channels())
        let rules = [RouteRule(task: .verify, model: "code:default",
                               fallback: ["plan:strong"], mustDifferFromExecutor: true)]
        let decision = GatewayRouter.route(
            task: .verify,
            requirements: .init(executorModel: executor),
            channels: channels(), rules: rules
        )
        #expect(decision.primary?.modelID == "claude-opus-5", "应当跳到别的模型")
        #expect(decision.rejections.contains { $0.reason.contains("同模型自我验证") })
    }

    @Test("⭐⭐ 敏感项目：中转渠道被排除，且理由写清楚")
    func sensitiveProjectExcludesRelay() {
        let rules = [RouteRule(task: .vision, model: "relay:gpt-4o", fallback: ["on_device:apple-fm"])]
        let decision = GatewayRouter.route(
            task: .vision,
            requirements: .init(needsVision: true, sensitiveProject: true),
            channels: channels(), rules: rules
        )
        // 中转被排除 → 端侧不支持视觉 → 没得选
        #expect(decision.isEmpty)
        #expect(decision.rejections.contains { $0.reason.contains("敏感项目") })
        // 解释里要能说清"为什么一个都没选"
        #expect(decision.explanation.contains("没有可用的渠道"))
    }

    @Test("解析不到的别名**不算拒绝**（用户没配那个渠道是正常的，别刷屏）")
    func unresolvedAliasIsNotARejection() {
        let rules = [RouteRule(task: .plan, model: "根本没这个渠道:x", fallback: ["plan:strong"])]
        let decision = GatewayRouter.route(task: .plan, requirements: .init(),
                                          channels: channels(), rules: rules)
        #expect(decision.primary?.modelID == "claude-opus-5")
        #expect(!decision.rejections.contains { $0.ref.contains("根本没这个渠道") })
    }

    @Test("没有配规则时兜底（保证有得用），并说明走了兜底")
    func fallsBackToAnyChannel() {
        let decision = GatewayRouter.route(task: .triage, requirements: .init(),
                                          channels: channels(), rules: [])
        #expect(!decision.isEmpty)
        #expect(decision.notes.contains { $0.contains("兜底") })
    }

    @Test("禁用的渠道不出现在候选里")
    func disabledChannelIsSkipped() {
        let list = [
            channel("off", enabled: false, models: [model("m", alias: "default")]),
            channel("on", models: [model("n", alias: "default")]),
        ]
        let rules = [RouteRule(task: .code, model: "off:default", fallback: ["on:default"])]
        let decision = GatewayRouter.route(task: .code, requirements: .init(), channels: list, rules: rules)
        #expect(decision.chain.map(\.providerID) == ["on"])
    }

    @Test("⭐ 一个候选都不剩时，解释里要列出去哪儿改（不是只说「失败」）")
    func emptyRoutingExplainsWhy() {
        var health = HealthTracker()
        for id in ["code", "plan", "on_device", "relay"] {
            for _ in 0..<HealthTracker.failureThreshold {
                health.recordFailure(id, error: "挂了", now: Date())
            }
        }
        let decision = GatewayRouter.route(task: .plan, requirements: .init(),
                                          channels: channels(), health: health)
        #expect(decision.isEmpty)
        #expect(decision.rejections.count >= 4)
        #expect(decision.explanation.contains("挂了"))
    }
}

// MARK: - 健康

@Suite("HealthTracker —— 连续失败就摘掉，成功就恢复")

struct HealthTrackerTests {

    @Test("⭐ 连续 3 次失败标记不可用；成功一次立刻恢复")
    func failureThresholdAndRecovery() {
        var health = HealthTracker()
        let now = Date()
        health.recordFailure("a", error: "1", now: now)
        health.recordFailure("a", error: "2", now: now)
        #expect(health.isUsable("a"), "还没到阈值")
        health.recordFailure("a", error: "3", now: now)
        #expect(!health.isUsable("a"))

        health.recordSuccess("a", latencyMS: 320, firstTokenMS: 180, now: now)
        #expect(health.isUsable("a"))
        #expect(health.health("a").consecutiveFailures == 0)
        #expect(health.health("a").lastLatencyMS == 320)
        #expect(health.health("a").lastError == nil)
    }

    @Test("⭐ 探活调度：超过 6 小时没动静的渠道要被探一次")
    func probeScheduling() {
        var health = HealthTracker()
        let now = Date()
        health.recordSuccess("fresh", now: now)
        health.recordSuccess("stale", now: now.addingTimeInterval(-7 * 3_600))
        // 从没成功也没失败过的也要探
        health.recordFailure("never", error: "刚建好", now: now)
        let due = health.needsProbe(now: now)
        #expect(due.contains("stale"))
        #expect(!due.contains("fresh"))
    }
}

// MARK: - 重试

@Suite("RetryPolicy —— 每种错误都有不同的正确处理方式")

struct RetryPolicyTests {

    private func error(_ kind: ProviderError.Kind, status: Int? = nil, retryAfter: Int? = nil) -> ProviderError {
        ProviderError(kind: kind, providerID: "p", statusCode: status,
                      message: "原始信息", userFacingMessage: "面向用户的一句话",
                      retryAfterSeconds: retryAfter)
    }

    @Test("⭐ 退避序列是 1s / 2s / 4s，厂商给了 Retry-After 就听它的")
    func backoff() {
        #expect(RetryPolicy.backoffSeconds(attempt: 1, retryAfter: nil) == 1)
        #expect(RetryPolicy.backoffSeconds(attempt: 2, retryAfter: nil) == 2)
        #expect(RetryPolicy.backoffSeconds(attempt: 3, retryAfter: nil) == 4)
        #expect(RetryPolicy.backoffSeconds(attempt: 1, retryAfter: 17) == 17)
        // 别被一个荒唐的 Retry-After 卡住整个 Turn
        #expect(RetryPolicy.backoffSeconds(attempt: 1, retryAfter: 9_999) == 60)
    }

    @Test("429 重试 3 次；5xx 只重试 2 次然后换渠道")
    func transientLimits() {
        guard case .retrySameChannel(let after) = RetryPolicy.decide(error: error(.transient, status: 429), attempt: 3).action else {
            Issue.record("429 第 3 次仍应重试"); return
        }
        #expect(after == 4)

        guard case .switchChannel = RetryPolicy.decide(error: error(.transient, status: 429), attempt: 4).action else {
            Issue.record("429 第 4 次应当换渠道"); return
        }
        guard case .switchChannel = RetryPolicy.decide(error: error(.transient, status: 503), attempt: 3).action else {
            Issue.record("5xx 第 3 次应当换渠道"); return
        }
    }

    @Test("⭐ 鉴权/余额问题**绝不重试**（重试只会让用户看到反复失败）")
    func configurationAsksUser() {
        let decision = RetryPolicy.decide(error: error(.configuration, status: 401), attempt: 1)
        guard case .askUserToFixConfig(let message) = decision.action else {
            Issue.record("配置问题应当让用户去改：\(decision.action)"); return
        }
        #expect(message == "面向用户的一句话")
        #expect(decision.rationale.contains("重试不会变好"))
    }

    @Test("上下文超限 → 先压缩再重试一次（而不是直接放弃）")
    func contextOverflowRecompresses() {
        guard case .recompressAndRetry = RetryPolicy.decide(error: error(.contextOverflow), attempt: 1).action else {
            Issue.record("应当先压缩"); return
        }
    }

    @Test("⚠️ 内容过滤**不重试**（不要偷偷改写 prompt 绕过）")
    func contentFilterDoesNotRetry() {
        // 内容过滤在协议层被归到 .request
        let decision = RetryPolicy.decide(error: error(.request, status: 400), attempt: 1)
        guard case .giveUp(let userFacing) = decision.action else {
            Issue.record("内容过滤不该重试：\(decision.action)"); return
        }
        #expect(userFacing == "面向用户的一句话")
    }

    @Test("流中途被截断 → 重发一次（有缓存，重发很便宜）")
    func truncatedStreamRetries() {
        guard case .retrySameChannel = RetryPolicy.decide(error: error(.truncated), attempt: 1, isStreaming: true).action else {
            Issue.record("截断应当重发一次"); return
        }
        // 反复截断就别硬扛了
        guard case .giveUp = RetryPolicy.decide(error: error(.truncated), attempt: 3, isStreaming: true).action else {
            Issue.record("反复截断应当放弃"); return
        }
    }

    @Test("首 token 超时阈值是 8 秒（渠道卡住的判定）")
    func firstTokenThreshold() {
        #expect(RetryPolicy.firstTokenTimeoutSeconds == 8)
    }
}

// MARK: - 降级

@Suite("Degradation —— 禁止静默降级")

struct DegradationTests {

    private func ref(_ modelID: String, reasoning: Bool, context: Int = 128_000,
                     family: ProtocolFamily = .openAIChat) -> ModelRef {
        ModelRef(providerID: "p", providerName: "P", modelID: modelID,
                 category: .official, contextWindow: context,
                 supportsTools: true, supportsVision: false, supportsReasoning: reasoning,
                 protocolFamily: family)
    }

    @Test("⚠️ 思考链支持变了 → **必须重建上下文**（旧渠道的思考块新渠道不认）")
    func reasoningChangeRequiresRebuild() {
        let plan = Degradation.plan(from: ref("a", reasoning: false), to: ref("b", reasoning: true))
        #expect(plan.mustRebuildContext)
        #expect(plan.capabilityChanged)
        #expect(plan.notice.contains("思考块"))
        // ⚠️ 这一位永远是 true —— "禁止静默降级"在代码里必须是显式的一行
        #expect(plan.isVisibleToUser)
    }

    @Test("⚠️ 窗口变小 → **必须压缩**")
    func narrowerWindowRequiresCompression() {
        let plan = Degradation.plan(from: ref("big", reasoning: false, context: 200_000),
                                    to: ref("small", reasoning: false, context: 32_000))
        #expect(plan.mustRecompress)
        #expect(plan.notice.contains("32"), "要说清新窗口多大：\(plan.notice)")
    }

    @Test("⭐ 那句话必须出现 —— 用户付费买的是特定模型的能力")
    func noticeIsExplicit() {
        let plan = Degradation.plan(from: ref("opus", reasoning: true), to: ref("flash", reasoning: false))
        #expect(plan.notice.contains("降级"))
        #expect(plan.notice.contains("opus"))
        #expect(plan.notice.contains("flash"))
        #expect(plan.notice.contains("能力可能变化"))
    }

    @Test("协议族变了要说出来（同一份请求编码方式不同）")
    func protocolFamilyChange() {
        let plan = Degradation.plan(from: ref("a", reasoning: false, family: .anthropicMessages),
                                    to: ref("b", reasoning: false, family: .openAIChat))
        #expect(plan.capabilityChanged)
        #expect(plan.notice.contains("协议族"))
    }

    @Test("能力没变时不要瞎喊「能力可能变化」")
    func noFalseAlarm() {
        let plan = Degradation.plan(from: ref("a", reasoning: false), to: ref("b", reasoning: false))
        #expect(!plan.capabilityChanged)
        #expect(!plan.mustRebuildContext)
        #expect(!plan.notice.contains("能力可能变化"))
    }
}

// MARK: - 请求去重

@Suite("RequestDeduplicator —— 没有厂商幂等键时的省钱手段")

struct RequestDeduplicatorTests {

    @Test("⭐ 同一个请求指纹在同一个 Turn 内只发一次")
    func dedupesIdenticalRequests() {
        var dedupe = RequestDeduplicator()
        let body = Data(#"{"messages":[{"role":"user","content":"你好"}]}"#.utf8)
        let first = dedupe.begin(providerID: "deepseek", modelID: "v4", body: body)
        #expect(dedupe.cachedResponder(for: first) == nil, "第一次还没有缓存")

        let ref = ModelRef(providerID: "deepseek", providerName: "DeepSeek", modelID: "v4",
                           category: .official, contextWindow: 128_000,
                           supportsTools: true, supportsVision: false, supportsReasoning: false,
                           protocolFamily: .openAIChat)
        dedupe.record(fingerprint: first, answeredBy: ref)

        // 重试/降级重发时 → 认出来这是同一个请求
        let again = dedupe.begin(providerID: "deepseek", modelID: "v4", body: body)
        #expect(again == first)
        #expect(dedupe.cachedResponder(for: again)?.modelID == "v4")
    }

    @Test("⚠️ 换了渠道或换了参数就不是同一个请求（不能错误复用）")
    func differentRequestsAreNotDeduped() {
        var dedupe = RequestDeduplicator()
        let body = Data("{}".utf8)
        let a = dedupe.begin(providerID: "deepseek", modelID: "v4", body: body)
        let b = dedupe.begin(providerID: "openai", modelID: "v4", body: body)
        let c = dedupe.begin(providerID: "deepseek", modelID: "v4", body: Data("{\"x\":1}".utf8))
        #expect(a != b)
        #expect(a != c)
    }
}
