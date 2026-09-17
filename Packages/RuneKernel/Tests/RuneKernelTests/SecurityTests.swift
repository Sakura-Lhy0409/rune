import Testing
import Foundation
@testable import RuneKernel

// MARK: - 虚拟路径（安全边界）

@Suite("VFSPath —— 路径安全边界")
struct VFSPathTests {

    @Test("合法路径解析")
    func validPaths() throws {
        let p = try VFSPath.parse("/workspace/src/main.swift")
        #expect(p.mount == .workspace)
        #expect(p.components == ["src", "main.swift"])
        #expect(p.description == "/workspace/src/main.swift")
        #expect(p.fileName == "main.swift")
        #expect(p.fileExtension == "swift")

        let root = try VFSPath.parse("/workspace")
        #expect(root.isMountRoot)
        #expect(root.components.isEmpty)
    }

    @Test("规范化：反斜杠、重复斜杠、尾部斜杠、挂载点大小写")
    func normalization() throws {
        // 模型经常写 Windows 风格路径
        #expect(try VFSPath.parse(#"/workspace/src\main.swift"#).components == ["src", "main.swift"])
        #expect(try VFSPath.parse("/workspace//src///a.txt").components == ["src", "a.txt"])
        #expect(try VFSPath.parse("/workspace/src/").components == ["src"])
        #expect(try VFSPath.parse("/Workspace/SRC/A.swift").mount == .workspace)
        // "." 被忽略（不是错误）
        #expect(try VFSPath.parse("/workspace/./src").components == ["src"])
    }

    @Test("⚠️ 必须拒绝 `..` 逃逸（这是最重要的一条）")
    func rejectsParentTraversal() {
        #expect(throws: VFSPath.ParseError.self) { try VFSPath.parse("/workspace/../etc/passwd") }
        #expect(throws: VFSPath.ParseError.self) { try VFSPath.parse("/workspace/src/../../..") }
        #expect(throws: VFSPath.ParseError.self) { try VFSPath.parse("/workspace/..") }
        // 注意：百分号编码**不会**被解码，所以 "%2e%2e" 只是一个普通文件名 —— 这是正确行为，
        // 不是漏洞（我们从不做 URL 解码后再当路径用）。真正的风险在"解码之后才校验"，
        // 因此 VFS 层的规则是：**先解码，再 parse**，且解析后必须重新校验。
    }

    @Test("拒绝 NUL 字节、未知挂载点、非绝对路径")
    func rejectsMalformed() {
        #expect(throws: VFSPath.ParseError.self) { try VFSPath.parse("/workspace/a\u{0}b") }
        #expect(throws: VFSPath.ParseError.self) { try VFSPath.parse("/nonexistent/a") }
        #expect(throws: VFSPath.ParseError.self) { try VFSPath.parse("workspace/a") }
        #expect(throws: VFSPath.ParseError.self) { try VFSPath.parse("") }
        #expect(throws: VFSPath.ParseError.self) { try VFSPath.parse("/") }
    }

    @Test("拒绝超长组件与超深路径")
    func rejectsOversize() {
        let longName = String(repeating: "x", count: 300)
        #expect(throws: VFSPath.ParseError.self) { try VFSPath.parse("/workspace/\(longName)") }
        let deep = "/workspace/" + Array(repeating: "d", count: 100).joined(separator: "/")
        #expect(throws: VFSPath.ParseError.self) { try VFSPath.parse(deep) }
    }

    @Test("⚠️ isWithin 必须是组件级比较——不能因前缀字符串相同就放行")
    func isWithinIsComponentLevel() throws {
        let workspace = try VFSPath.parse("/workspace")
        let src = try VFSPath.parse("/workspace/src")

        #expect(try VFSPath.parse("/workspace/src/a.swift").isWithin(src))
        #expect(try VFSPath.parse("/workspace/src").isWithin(src))
        #expect(workspace.isWithin(workspace))

        // 关键：`src2` / `src-backup` 与 `src` 的**字符串前缀**相同，但**不是同一目录**。
        // 如果实现用 `hasPrefix(字符串)` 而不是组件级比较，这两个就会被错误放行。
        #expect(!(try VFSPath.parse("/workspace/src2/a.swift").isWithin(src)))
        #expect(!(try VFSPath.parse("/workspace/src-backup/a.swift").isWithin(src)))
        // 绕过 parse 直接构造（模拟 VFS 内部组合出的路径）也必须成立
        #expect(!VFSPath(mount: .workspace, components: ["src2"]).isWithin(src))
        #expect(!VFSPath(mount: .workspace, components: ["src"]).isWithin(
            VFSPath(mount: .workspace, components: ["src", "a"])))

        // 反向不成立
        #expect(!src.isWithin(try VFSPath.parse("/workspace/src/a.swift")))
        // 不同挂载点
        #expect(!(try VFSPath.parse("/tmp/a").isWithin(workspace)))
    }

    @Test("isWithin 大小写不敏感（APFS 默认不敏感，必须与真实文件系统一致）")
    func isWithinCaseInsensitive() throws {
        let prefix = try VFSPath.parse("/workspace/Src")
        #expect(try VFSPath.parse("/workspace/src/a.swift").isWithin(prefix))
    }

    @Test("相对路径解析：钳制在挂载点内，绝不逃逸")
    func resolveClamps() throws {
        let base = try VFSPath.parse("/workspace/a/b")

        let (up, clamped1) = VFSPath.resolve(base: base, relative: "../c")
        #expect(up.description == "/workspace/a/c")
        #expect(!clamped1)

        // 逃逸尝试 → 钳制到挂载点根，并报告 clamped
        let (escaped, clamped2) = VFSPath.resolve(base: base, relative: "../../../../../../etc/passwd")
        #expect(escaped.mount == .workspace)
        #expect(clamped2)
        #expect(!escaped.description.contains(".."))

        // 绝对路径直接接管
        let (absolute, _) = VFSPath.resolve(base: base, relative: "/tmp/x")
        #expect(absolute.description == "/tmp/x")
    }

    @Test("解析失败的错误信息是给模型看的（可读、可执行）")
    func errorMessagesAreActionable() {
        let err = VFSPath.ParseError.parentTraversal(index: 1)
        #expect(err.modelFacingMessage.contains(".."))
        #expect(err.modelFacingMessage.contains("绝对路径"))
        let unknown = VFSPath.ParseError.unknownMount("foo")
        #expect(unknown.modelFacingMessage.contains("workspace"))
    }

    @Test("parent / appending 组合行为")
    func composition() throws {
        let p = try VFSPath.parse("/workspace/a/b/c.txt")
        #expect(p.parent?.description == "/workspace/a/b")
        #expect(p.appending("d").description == "/workspace/a/b/c.txt/d")
        // appending 危险组件被忽略
        #expect(p.appending("..").description == p.description)
        #expect(p.appending(".").description == p.description)
        #expect(try VFSPath.parse("/workspace").parent == nil)
    }
}

// MARK: - 出口规则（SSRF / 域名冒名）

@Suite("EgressRule —— 出口白名单")
struct EgressRuleTests {

    @Test("精确域名匹配")
    func exactHost() {
        let rule = EgressRule(host: "api.github.com", methods: ["GET", "POST"], reason: "Git")
        #expect(rule.allows(host: "api.github.com", method: "GET", bytes: 0))
        #expect(rule.allows(host: "API.GitHub.com", method: "post", bytes: 0))
        #expect(!rule.allows(host: "evil.com", method: "GET", bytes: 0))
        #expect(!rule.allows(host: "api.github.com.evil.com", method: "GET", bytes: 0))
        #expect(!rule.allows(host: "api.github.com", method: "DELETE", bytes: 0))
    }

    @Test("⚠️ 后缀匹配必须在点边界上——`evil-githubusercontent.com` 绝不能被放行")
    func suffixBoundarySafety() {
        let rule = EgressRule(hostSuffix: ".githubusercontent.com", methods: ["GET"], reason: "raw 内容")
        #expect(rule.allows(host: "raw.githubusercontent.com", method: "GET", bytes: 0))
        #expect(rule.allows(host: "objects.githubusercontent.com", method: "GET", bytes: 0))
        // 这是最典型的绕过手法
        #expect(!rule.allows(host: "evil-githubusercontent.com", method: "GET", bytes: 0))
        #expect(!rule.allows(host: "githubusercontent.com.evil.com", method: "GET", bytes: 0))
        #expect(!rule.allows(host: "notgithubusercontent.com", method: "GET", bytes: 0))
    }

    @Test("不带点的后缀：要求整体相等或前面是点")
    func suffixWithoutDot() {
        let rule = EgressRule(hostSuffix: "github.com", methods: ["GET"], reason: "test")
        #expect(rule.allows(host: "github.com", method: "GET", bytes: 0))
        #expect(rule.allows(host: "api.github.com", method: "GET", bytes: 0))
        #expect(!rule.allows(host: "notgithub.com", method: "GET", bytes: 0))
    }

    @Test("字节上限")
    func maxBytes() {
        let rule = EgressRule(host: "example.com", methods: ["POST"], maxBytes: 1024, reason: "test")
        #expect(rule.allows(host: "example.com", method: "POST", bytes: 1024))
        #expect(!rule.allows(host: "example.com", method: "POST", bytes: 1025))
    }

    @Test("通配方法")
    func wildcardMethod() {
        let rule = EgressRule(host: "example.com", methods: ["*"], reason: "test")
        #expect(rule.allows(host: "example.com", method: "PATCH", bytes: 0))
    }
}

// MARK: - 能力令牌

@Suite("CapabilityToken —— 能力授权")
struct CapabilityTokenTests {

    private func token(
        scopes: Set<CapabilityToken.Scope>,
        expiresIn: TimeInterval = 300
    ) -> CapabilityToken {
        CapabilityToken(
            issuedForTurn: UUID(),
            scopes: scopes,
            expiresAt: Date().addingTimeInterval(expiresIn),
            grantedBy: .planApproval,
            reason: "测试"
        )
    }

    @Test("文件授权：范围判定")
    func fileAuthorization() throws {
        let t = token(scopes: [.fsWrite(try VFSPath.parse("/workspace/src"))])

        #expect(t.authorizeFile(try VFSPath.parse("/workspace/src/a.swift"), need: .readOnly))
        #expect(t.authorizeFile(try VFSPath.parse("/workspace/src/a.swift"), need: .write))
        // 范围外
        #expect(!t.authorizeFile(try VFSPath.parse("/workspace/other/a.swift"), need: .write))
        #expect(!t.authorizeFile(try VFSPath.parse("/workspace/src2/a.swift"), need: .write))
        #expect(!t.authorizeFile(try VFSPath.parse("/tmp/a.swift"), need: .write))
    }

    @Test("⚠️ 写权限不蕴含删除权限（破坏性差异必须显式授权）")
    func writeDoesNotImplyDelete() throws {
        let write = token(scopes: [.fsWrite(try VFSPath.parse("/workspace"))])
        #expect(!write.authorizeFile(try VFSPath.parse("/workspace/a.swift"), need: .delete))

        let delete = token(scopes: [.fsDelete(try VFSPath.parse("/workspace/build"))])
        #expect(delete.authorizeFile(try VFSPath.parse("/workspace/build/a.o"), need: .delete))
        #expect(!delete.authorizeFile(try VFSPath.parse("/workspace/src/a.swift"), need: .delete))
    }

    @Test("只读授权不能写")
    func readOnlyCannotWrite() throws {
        let t = token(scopes: [.fsRead(try VFSPath.parse("/workspace"))])
        #expect(t.authorizeFile(try VFSPath.parse("/workspace/a.swift"), need: .readOnly))
        #expect(!t.authorizeFile(try VFSPath.parse("/workspace/a.swift"), need: .write))
    }

    @Test("⚠️ 令牌过期即失效")
    func expiry() throws {
        let expired = token(scopes: [.fsRead(try VFSPath.parse("/workspace"))], expiresIn: -1)
        #expect(expired.isExpired())
        #expect(!expired.authorizeFile(try VFSPath.parse("/workspace/a"), need: .readOnly))
        #expect(!expired.authorizeEgress(host: "api.github.com", method: "GET", bytes: 0))
        #expect(!expired.authorizeExec(runtime: .python))
    }

    @Test("出口与执行授权")
    func egressAndExec() {
        let t = token(scopes: [
            .egress(EgressRule(host: "api.github.com", methods: ["GET"], reason: "test")),
            .exec(runtime: .python),
        ])
        #expect(t.authorizeEgress(host: "api.github.com", method: "GET", bytes: 0))
        #expect(!t.authorizeEgress(host: "evil.com", method: "GET", bytes: 0))
        #expect(t.authorizeExec(runtime: .python))
        #expect(!t.authorizeExec(runtime: .shell))   // 未授予的运行时
    }

    @Test("原生能力授权")
    func nativeAuthorization() {
        let t = token(scopes: [.native(.photos)])
        #expect(t.authorizeNative(.photos))
        #expect(!t.authorizeNative(.contacts))
    }

    @Test("判定结果到工具错误的转换（拒绝理由要能回灌给模型）")
    func decisionToToolError() {
        #expect(CapabilityDecision.allowed.asToolError() == nil)

        let denied = CapabilityDecision.denied(reason: "路径越权", suggestion: "改用 /workspace 下的路径")
        let err = denied.asToolError()
        #expect(err?.kind == .capabilityDenied)
        #expect(err?.suggestion == "改用 /workspace 下的路径")
        // 越权不是"可自我修正"的参数问题，而是策略问题
        #expect(err?.isSelfCorrectable == false)

        let human = CapabilityDecision.humanOnly(zone: .policyFile)
        let humanErr = human.asToolError()
        #expect(humanErr?.kind == .humanOnlyZone)
        #expect(humanErr?.modelFacingMessage.contains("人类专属区域") == true)
    }

    @Test("人类专属区的拒绝理由覆盖全部区域")
    func humanOnlyZones() {
        for zone in HumanOnlyZone.allCases {
            #expect(!zone.denialReason.isEmpty)
            #expect(zone.denialReason.contains("人类专属区域"))
        }
    }
}
