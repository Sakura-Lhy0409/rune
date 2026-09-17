import Testing
import Foundation
@testable import RuneKernel

// MARK: - 工具注册表的测试
//
// 这一组测试守的是一件事：**声明写错不会报错，只会静默地少一层保护**。
// 把写文件标成 `parallelSafe`、漏声明一个路径参数、把删除标成 safe ——
// 这些在运行时都不会抛异常，只会让某一道防线悄悄消失。
// 所以每条规则都必须在测试里被断言，而且**校验器本身**也要被验证"它真的会报"。

@Suite("ToolRegistry —— 注册表自身的完整性")

struct ToolRegistryIntegrityTests {

    @Test("⭐ 注册表必须通过全部校验（任何一条不过都是少了一层保护）")
    func registryPassesValidation() {
        let issues = ToolRegistry.validate()
        // 失败时把问题全列出来，而不是只说"有 3 个问题"
        let report = issues.map(\.description).joined(separator: "\n  ")
        #expect(issues.isEmpty, "注册表有 \(issues.count) 个声明问题：\n  \(report)")
    }

    @Test("⭐ 覆盖率：ToolName 里登记的每个名字都必须有 ToolSpec")
    func everyToolNameIsRegistered() {
        let missing = ToolRegistry.coverageIssues()
        #expect(missing.isEmpty, "这些工具名没有对应的 ToolSpec：\(missing.joined(separator: "、"))")
    }

    @Test("注册表里没有多余的、未登记在 ToolName 的孤儿工具")
    func noOrphanSpecs() {
        let declared = Set(ToolName.all)
        let orphans = ToolRegistry.all.map(\.name).filter { !declared.contains($0) }
        #expect(orphans.isEmpty, "这些 spec 没在 ToolName 里登记：\(orphans.joined(separator: "、"))")
    }

    @Test("工具数量与目录一致（86 个）—— 变动时这条会提醒你去同步文档")
    func toolCount() {
        #expect(ToolRegistry.all.count == 86)
        #expect(ToolName.all.count == 86)
        #expect(ToolRegistry.byName.count == 86)
    }

    @Test("byName 能查到每一个工具")
    func byNameLookup() {
        for name in ToolName.all {
            #expect(ToolRegistry.byName[name] != nil, "查不到 \(name)")
        }
    }

    @Test("⚠️ 示例必须用对工具名（复制粘贴错的示例比没有示例更糟）")
    func exampleUsesItsOwnName() {
        for spec in ToolRegistry.all {
            let example = spec.example ?? ""
            #expect(!example.isEmpty, "\(spec.name) 没有示例")
            #expect(example.contains(spec.name), "\(spec.name) 的示例里写的不是它自己：\(example)")
        }
    }
}

@Suite("ToolRegistry —— 安全声明的硬性断言")

struct ToolRegistrySafetyTests {

    @Test("⚠️ 任何工具都不许声明「人类专属区」写权限")
    func nobodyCanWriteHumanOnlyZones() {
        for spec in ToolRegistry.all {
            #expect(!spec.requirements.contains(.humanOnly), "\(spec.name) 声明了 .humanOnly")
        }
    }

    @Test("⚠️ 会改动持久状态的工具一律不能标成「可并行」")
    func writersAreNeverParallelSafe() {
        for spec in ToolRegistry.all where ToolRegistry.isWriter(spec) {
            #expect(spec.concurrency != .parallelSafe,
                    "\(spec.name) 会写东西却标了 parallelSafe —— 调度器会真的并行执行它")
        }
    }

    @Test("⚠️ 写操作必须声明路径参数（否则「记住选择」会退化成整个工具的白名单）")
    func writersDeclareTheirPaths() {
        for spec in ToolRegistry.all where ToolRegistry.isWriter(spec) {
            #expect(!spec.pathParameters.isEmpty, "\(spec.name) 是写操作但没声明 pathParameters")
        }
    }

    @Test("⚠️ 删除一律按危险处理")
    func deletesAreDangerous() {
        for spec in ToolRegistry.all where spec.requirements.contains(.fsDelete) {
            #expect(spec.riskLevel == .dangerous || spec.riskLevel == .irreversible,
                    "\(spec.name) 能删东西却是 \(spec.riskLevel.rawValue)")
        }
    }

    @Test("⚠️ 危险与不可逆操作都必须真的会弹确认")
    func dangerousAlwaysConfirms() {
        for spec in ToolRegistry.all where spec.riskLevel.alwaysRequiresHuman {
            #expect(spec.needsApproval != .never, "\(spec.name) 是 \(spec.riskLevel.rawValue) 却标了无需确认")
        }
    }

    @Test("⚠️ 不可逆操作必须每次确认（不能被「记住选择」绕过）")
    func irreversibleAlwaysAsks() {
        let irreversible = ToolRegistry.all.filter { $0.riskLevel == .irreversible }
        #expect(!irreversible.isEmpty, "一个不可逆工具都没有？Shortcuts 应该是不可逆的")
        for spec in irreversible {
            #expect(spec.needsApproval == .always, "\(spec.name) 不可逆却不是 .always")
        }
        // 具体点名：快捷指令能做的事没有边界
        #expect(irreversible.contains { $0.name == ToolName.shortcutsRun })
    }

    @Test("⚠️ 执行类工具的输出必须走制品（一次 pytest 就能吃掉整个上下文）")
    func execToolsUseArtifacts() {
        for spec in ToolRegistry.all where spec.requirements.contains(.exec) {
            guard case .artifact = spec.outputShape else {
                Issue.record("\(spec.name) 是执行类工具，输出却内联 —— 手机上会被一次命令输出撑爆")
                continue
            }
        }
    }

    @Test("只读工具不声明写能力，safe 的工具不该有副作用")
    func readOnlyStaysReadOnly() {
        for spec in ToolRegistry.all where spec.riskLevel == .safe {
            #expect(!spec.requirements.contains(.fsWrite), "\(spec.name) 是 safe 却声明了 fsWrite")
            #expect(!spec.requirements.contains(.fsDelete), "\(spec.name) 是 safe 却声明了 fsDelete")
            #expect(!spec.requirements.contains(.gitWrite), "\(spec.name) 是 safe 却声明了 gitWrite")
        }
    }

    @Test("非幂等的工具不能标成 safe")
    func nonIdempotentIsNotSafe() {
        for spec in ToolRegistry.all where !spec.isIdempotent {
            #expect(spec.riskLevel != .safe, "\(spec.name) 非幂等却是 safe")
        }
    }

    @Test("⚠️ 读剪贴板是危险操作（里面经常是密码与验证码）")
    func clipboardReadIsDangerous() {
        let spec = ToolRegistry.byName[ToolName.clipboardRead]
        #expect(spec?.riskLevel == .dangerous)
        #expect(spec?.needsApproval != .never)
    }

    @Test("⚠️ 推送 / 开 PR 必须每次确认")
    func pushAlwaysConfirms() {
        for name in [ToolName.gitPush, ToolName.createPullRequest] {
            #expect(ToolRegistry.byName[name]?.needsApproval == .always, "\(name) 必须每次确认")
            #expect(ToolRegistry.byName[name]?.riskLevel == .dangerous)
        }
    }

    @Test("⚠️ 写工作区的工具必须声明 fsWrite 能力（**授权的防线是能力令牌的作用域，不是逐次弹窗**）")
    func workspaceWritersDeclareCapability() {
        // 这里刻意**不**要求每个写工具都"每次弹窗"：
        // 在已授权的范围内、且计划已批准时，写文件全程零打断 —— 那正是"计划批准 = 批量授权"
        // （PolicyEngine 里 `planApproved → .none`）的设计意图。手机上每改一个文件弹一次窗，
        // Agent 会变得不可用。
        //
        // 真正的防线是：写工具必须声明 `.fsWrite`，于是策略引擎**必须**拿到路径去做作用域判定
        // （第 3 层：能力令牌）。而"路径必须能被提取出来"由 `writersDeclareTheirPaths` 守着 ——
        // 那条一旦失守，作用域判定就会因为"没有路径"而被整条跳过。
        for spec in ToolRegistry.all where spec.requirements.contains(.fsWrite) || spec.requirements.contains(.fsDelete) {
            #expect(spec.requirements.contains(.fsWrite) || spec.requirements.contains(.fsDelete))
            #expect(!spec.pathParameters.isEmpty, "\(spec.name) 会改工作区却没声明路径 → 作用域判定会被跳过")
        }
        // 少数几个"即使在工作区内也每次都值得确认"的：整体回滚（会丢掉快照之后的所有改动）
        #expect(ToolRegistry.byName[ToolName.sandboxRestore]?.needsApproval == .always)
        // 删除是危险的；但它进回收站（可恢复），所以"每个项目确认一次"是合适的粒度
        #expect(ToolRegistry.byName[ToolName.deletePath]?.riskLevel == .dangerous)
        #expect(ToolRegistry.byName[ToolName.deletePath]?.needsApproval != .never)
    }

    @Test("⚠️ schema 里像路径的参数都必须被声明（「声明了但不全」比没声明更危险）")
    func noSilentlyIgnoredPathParameters() {
        // 这条规则来自一次真实漏报：`git_add` 声明了 `["path"]`，但 schema 里还有
        // `files: [string]` —— 模型传 `files` 时那些路径**完全不会被提取**。
        let issues = ToolRegistry.validate().filter { $0.rule == .undeclaredPathParameter }
        for issue in issues { Issue.record("\(issue.description)") }
        #expect(issues.isEmpty)
    }
}

// MARK: - 校验器本身真的会报

@Suite("ToolRegistry.validate —— 校验器必须真的会报错")

struct ToolRegistryValidatorTests {

    private func bare(
        _ name: String = "t",
        schema: JSONSchema = .object(properties: [:], required: [], additionalProperties: false),
        description: String = "做什么：x\n何时用：y\n不要用：z",
        example: String? = "t()",
        concurrency: ToolSpec.Concurrency = .parallelSafe,
        idempotent: Bool = true,
        risk: ToolSpec.RiskLevel = .safe,
        approval: ToolSpec.ApprovalPolicy = .never,
        output: ToolSpec.OutputShape = .inline(maxBytes: 4096),
        needs: Set<CapabilityKind> = [],
        paths: [String] = []
    ) -> ToolSpec {
        ToolSpec(name: name, description: description, inputSchema: schema,
                 pathParameters: paths, example: example, concurrency: concurrency,
                 isIdempotent: idempotent, riskLevel: risk, needsApproval: approval,
                 outputShape: output, requirements: needs)
    }

    private func rules(_ specs: [ToolSpec]) -> Set<ToolRegistry.Issue.Rule> {
        Set(ToolRegistry.validate(specs).map(\.rule))
    }

    @Test("重复名字会被抓到")
    func duplicateName() {
        let specs = [bare("dup"), bare("dup")]
        #expect(rules(specs).contains(.duplicateName))
    }

    @Test("声明 humanOnly 会被抓到")
    func humanOnly() {
        #expect(rules([bare(needs: [.humanOnly])]).contains(.humanOnlyDeclared))
    }

    @Test("⚠️ 危险却标「无需确认」会被抓到")
    func dangerousWithoutApproval() {
        #expect(rules([bare(risk: .dangerous)]).contains(.dangerousWithoutApproval))
    }

    @Test("⚠️ 不可逆却不是「每次确认」会被抓到")
    func irreversibleWithoutAlways() {
        #expect(rules([bare(risk: .irreversible, approval: .perProject)]).contains(.irreversibleWithoutAlways))
    }

    @Test("⚠️ 写操作标成 parallelSafe 会被抓到")
    func writerNotSerial() {
        let spec = bare(concurrency: .parallelSafe, risk: .modifying, approval: .perProject,
                        needs: [.fsWrite], paths: ["path"])
        #expect(rules([spec]).contains(.writerNotSerial))
    }

    @Test("⚠️ 写操作没声明路径会被抓到")
    func writerWithoutPaths() {
        let spec = bare(concurrency: .serialPerPath, risk: .modifying, approval: .perProject, needs: [.fsWrite])
        #expect(rules([spec]).contains(.writerWithoutPathParameters))
    }

    @Test("⚠️ schema 里有 `path` 却没声明会被抓到")
    func undeclaredPathParameter() {
        let schema = JSONSchema.object(
            properties: ["path": .string(enumValues: nil, minLength: nil, maxLength: nil),
                         "files": .array(items: .string(enumValues: nil, minLength: nil, maxLength: nil),
                                         minItems: nil, maxItems: nil)],
            required: ["path"], additionalProperties: false
        )
        // 只声明了 path，漏了 files
        let spec = bare(schema: schema, concurrency: .serialPerPath, risk: .modifying,
                        approval: .perProject, needs: [.fsWrite], paths: ["path"])
        let found = ToolRegistry.validate([spec])
        #expect(found.contains { $0.rule == ToolRegistry.Issue.Rule.undeclaredPathParameter
            && $0.detail.contains("files") })
    }

    @Test("删东西却标 safe 会被抓到")
    func deleteNotDangerous() {
        let spec = bare(concurrency: .serialPerPath, risk: .modifying, approval: .perProject,
                        needs: [.fsDelete], paths: ["path"])
        #expect(rules([spec]).contains(.deleteNotDangerous))
    }

    @Test("⚠️ 描述缺「不要用」会被抓到（四问缺一不可）")
    func descriptionIncomplete() {
        let spec = bare(description: "做什么：只是列一下\n何时用：总是")
        #expect(rules([spec]).contains(.descriptionIncomplete))
    }

    @Test("⚠️ 描述里出现 ASCII 双引号会被抓到（它还会截断字符串字面量）")
    func asciiQuoteCaught() {
        let spec = bare(description: "做什么：读文件\n何时用：需要时\n不要用：不要用\"那个\"工具")
        #expect(rules([spec]).contains(.asciiQuoteInProse))
    }

    @Test("required 里有 properties 之外的键会被抓到")
    func requiredNotInProperties() {
        let schema = JSONSchema.object(properties: ["a": .string(enumValues: nil, minLength: nil, maxLength: nil)],
                                      required: ["a", "b"], additionalProperties: false)
        #expect(rules([bare(schema: schema)]).contains(.schemaRequiredNotInProperties))
    }

    @Test("内联上限过大、执行类输出内联都会被抓到")
    func outputShapeRules() {
        #expect(rules([bare(output: .inline(maxBytes: 200_000))]).contains(.inlineTooLarge))
        let exec = bare(output: .inline(maxBytes: 4096), needs: [.exec])
        #expect(rules([exec]).contains(.execOutputInline))
    }

    @Test("safe 却写东西、非幂等却 safe、生物识别给错对象都会被抓到")
    func miscRules() {
        #expect(rules([bare(concurrency: .serialPerPath, risk: .safe, needs: [.fsWrite], paths: ["path"])])
            .contains(.safeButWrites))
        #expect(rules([bare(idempotent: false)]).contains(.nonIdempotentButSafe))
        #expect(rules([bare(risk: .modifying, approval: .biometric)]).contains(.biometricNotIrreversible))
    }

    @Test("缺示例会被抓到")
    func missingExample() {
        #expect(rules([bare(example: nil)]).contains(.missingExample))
    }

    @Test("一个完全合规的 spec 不报任何问题")
    func cleanSpecPasses() {
        let ok = bare(concurrency: .serialPerPath, risk: .modifying, approval: .perProject,
                      needs: [.fsWrite], paths: ["path"])
        let issues = ToolRegistry.validate([ok])
        for issue in issues { Issue.record("\(issue.description)") }
        #expect(issues.isEmpty)
    }
}

// MARK: - 声明的路径参数真的被用上

@Suite("CallPaths × ToolSpec —— 路径来自声明，不是猜")

struct DeclaredPathTests {

    @Test("⭐ 声明了非常见键名时，旧实现提取不到、新实现能提取到")
    func declaredKeysBeatGuessing() {
        // `target_file` 不在 CallPaths.pathKeys 里 —— 靠猜是猜不到的
        let call = ToolCall(id: "c1", name: "custom_write",
                            argumentsJSON: Data(#"{"target_file": "src/a.py", "content": "x"}"#.utf8))
        let spec = ToolSpec(
            name: "custom_write", description: "x",
            inputSchema: .object(properties: [:], required: [], additionalProperties: true),
            pathParameters: ["target_file"],
            concurrency: .serialPerPath, riskLevel: .modifying,
            needsApproval: .perProject, requirements: [.fsWrite]
        )
        // 旧路径：靠猜键名 → 一个都提取不到（授权与冲突检测同时失效，且不报错）
        #expect(CallPaths.extract(from: call).isEmpty)
        // 新路径：按声明的名字 → 拿到了
        let declared = CallPaths.extract(from: call, spec: spec).paths
        #expect(declared.count == 1)
        #expect(declared[0].description == "/workspace/src/a.py")
    }

    @Test("⚠️ 相对路径必须被解析成工作区内的绝对路径（否则整个作用域判定会被跳过）")
    func relativePathsResolveToWorkspace() {
        // 模型绝大多数时候写的是相对路径。早期实现用 `VFSPath.parseOrNil` 直接解析，
        // 相对路径一律失败 → 返回空数组 → 策略引擎看到的是「这次调用不涉及任何路径」
        // → **路径作用域判定被整条跳过**。这个洞是静默的。
        let call = ToolCall(id: "c1", name: ToolName.writeFile,
                            argumentsJSON: Data(#"{"path": "src/money.py", "content": "x"}"#.utf8))
        let spec = ToolRegistry.byName[ToolName.writeFile]!
        let extraction = CallPaths.extract(from: call, spec: spec)
        #expect(extraction.paths.count == 1)
        #expect(extraction.paths[0].description == "/workspace/src/money.py")
        #expect(extraction.outsideMounts.isEmpty)
    }

    @Test("⚠️ 「绝对但挂载点不认识」的路径必须被标成越界，而不是悄悄映射进工作区")
    func unknownMountIsFlaggedOutside() {
        // `/etc/passwd` 若按相对路径处理会被映射成 `/workspace/etc/passwd` ——
        // 于是**被检查的路径和工具实际操作的路径不是同一个**（混淆代理漏洞）。
        let call = ToolCall(id: "c1", name: ToolName.readFile,
                            argumentsJSON: Data(#"{"path": "/etc/passwd"}"#.utf8))
        let spec = ToolRegistry.byName[ToolName.readFile]!
        let extraction = CallPaths.extract(from: call, spec: spec)
        #expect(extraction.paths.isEmpty)
        #expect(extraction.outsideMounts == ["/etc/passwd"])
        #expect(!extraction.isEmpty)   // 关键：它不是「没有路径参数」
    }

    @Test("`..` 被钳制在挂载点内，而且要如实报告发生了钳制")
    func parentTraversalIsClamped() {
        let call = ToolCall(id: "c1", name: ToolName.readFile,
                            argumentsJSON: Data(#"{"path": "../../../etc/passwd"}"#.utf8))
        let spec = ToolRegistry.byName[ToolName.readFile]!
        let extraction = CallPaths.extract(from: call, spec: spec)
        #expect(extraction.wasClamped)
        // 绝不逃出挂载点
        #expect(extraction.paths.allSatisfy { $0.mount == .workspace })
    }

    @Test("同一路径重复出现会被去重（不必检查两遍）")
    func deduplication() {
        let call = ToolCall(id: "c1", name: "dup",
                            argumentsJSON: Data(#"{"path": "a.py", "file": "a.py"}"#.utf8))
        let spec = ToolSpec(name: "dup", description: "x",
                            inputSchema: .object(properties: [:], required: [], additionalProperties: true),
                            pathParameters: ["path", "file"])
        #expect(CallPaths.extract(from: call, spec: spec).paths.count == 1)
    }

    @Test("⚠️ 多路径写操作的两个路径都要提取到（漏一个就绕过了授权）")
    func bothPathsOfMoveAreExtracted() {
        let call = ToolCall(id: "c1", name: ToolName.movePath,
                            argumentsJSON: Data(#"{"source": "a/x.py", "destination": "b/x.py"}"#.utf8))
        let spec = ToolRegistry.byName[ToolName.movePath]!
        let paths = Set(CallPaths.extract(from: call, spec: spec).paths.map(\.description))
        #expect(paths == ["/workspace/a/x.py", "/workspace/b/x.py"])
    }

    @Test("数组形式的路径参数按声明提取")
    func declaredArrayPaths() {
        let call = ToolCall(id: "c1", name: ToolName.gitAdd,
                            argumentsJSON: Data(#"{"files": ["a.py", "b.py"]}"#.utf8))
        let spec = ToolRegistry.byName[ToolName.gitAdd]!
        let paths = Set(CallPaths.extract(from: call, spec: spec).paths.map(\.description))
        #expect(paths.contains("/workspace/a.py"))
        #expect(paths.contains("/workspace/b.py"))
    }

    @Test("补丁正文里的文件段始终会被提取（这是最容易被漏的一类）")
    func patchBodyPathsAlwaysExtracted() {
        let patch = """
        *** Begin Patch
        *** Update File: src/a.py
        @@
        -old
        +new
        *** End Patch
        """
        let args = JSONValue.object(["patch": .string(patch), "base_path": .string("/workspace")])
        let call = ToolCall(id: "c1", name: ToolName.applyPatch,
                            argumentsJSON: Data(args.canonicalString().utf8))
        let spec = ToolRegistry.byName[ToolName.applyPatch]!
        let paths = CallPaths.extract(from: call, spec: spec).paths.map(\.description)
        #expect(paths.contains { $0.hasSuffix("src/a.py") })
    }

    @Test("没有声明路径的工具回退到旧行为（不会突然什么都提取不到）")
    func fallsBackWhenNoDeclaration() {
        let call = ToolCall(id: "c1", name: "plain_read",
                            argumentsJSON: Data(#"{"path": "src/a.py"}"#.utf8))
        let spec = ToolSpec(name: "plain_read", description: "x",
                            inputSchema: .object(properties: [:], required: [], additionalProperties: true))
        #expect(CallPaths.extract(from: call, spec: spec).paths.count == 1)
    }
}

// MARK: - 端到端：相对路径也必须受授权约束

@Suite("相对路径 × 授权 —— 端到端")

struct RelativePathAuthorizationTests {

    /// 只把 `src` 目录授权为可写
    private func scopedContext() -> PolicyEngine.Context {
        let scope = VFSPath(mount: .workspace, components: ["src"])
        let token = CapabilityToken(
            issuedForTurn: UUID(),
            scopes: [.fsRead(VFSPath(mount: .workspace)), .fsWrite(scope)],
            expiresAt: Date().addingTimeInterval(3600),
            grantedBy: .planApproval,
            reason: "测试"
        )
        return PolicyEngine.Context(trustDial: .collaborate, token: token, planApproved: true)
    }

    private func runner(script: @escaping @Sendable (TurnState) -> [ModelEvent]) -> TurnRunner.Dependencies {
        TurnRunner.Dependencies(
            modelEvents: script,
            executor: NoopToolExecutor(),
            policy: PolicyEngine(),
            policyContext: scopedContext(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            pathsOfCall: ToolScheduler.defaultPaths
        )
    }

    private func runOneWrite(to path: String) -> TurnState {
        let registry = ToolRegistry.byName
        let config = TurnRunner.Config(maxRounds: 4, maxToolCalls: 8, toolRegistry: registry)
        let script: @Sendable (TurnState) -> [ModelEvent] = { state in
            guard state.round == 0 else { return [] }
            return oneCall("w1", ToolName.writeFile, .object([
                "path": .string(path), "content": .string("x"),
            ]))
        }
        let (final, _, _) = TurnRunner.run(TurnState(objective: "写文件"), deps: runner(script: script), config: config)
        return final
    }

    @Test("⭐ 相对路径写到**授权范围内** → 放行")
    func relativePathInsideScopeIsAllowed() {
        let final = runOneWrite(to: "src/money.py")
        let result = final.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }.first
        #expect(result?.status == .ok, "授权范围内的相对路径不该被拒：\(result?.summary ?? "")")
    }

    @Test("⚠️ 相对路径写到**授权范围外** → **必须被拒**（修好之前这里会被放行）")
    func relativePathOutsideScopeIsDenied() {
        // 这条测试的意义：早期实现里相对路径提取不到 → 策略引擎拿到 `path == nil`
        // → 当成「这个工具不涉及路径」→ **跳过作用域判定** → 越权写入被静默放行。
        let final = runOneWrite(to: "lib/other.py")
        let result = final.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }.first
        #expect(result?.status == .denied || result?.status == .error,
                "写 src 之外的相对路径必须被拒，实际：\(result?.status.rawValue ?? "nil")")
        #expect(result?.summary.contains("src") == true || result?.summary.contains("范围") == true
                || result?.summary.contains("授权") == true,
                "拒绝理由要能指导模型：\(result?.summary ?? "")")
    }

    @Test("⚠️ 越出挂载点的绝对路径 → 直接拒绝，且理由可执行")
    func outsideMountIsDeniedWithActionableReason() {
        let final = runOneWrite(to: "/etc/passwd")
        let result = final.messages.flatMap { $0.blocks.compactMap(\.toolResultValue) }.first
        #expect(result?.status == .denied || result?.status == .error)
        #expect(result?.summary.contains("挂载点") == true, "理由没说到点上：\(result?.summary ?? "")")
        // 要告诉模型怎么改，而不是只说"不行"
        #expect(result?.summary.contains("相对形式") == true || result?.summary.contains("set_workspace") == true)
    }
}

// MARK: - 按信任档暴露工具

@Suite("ToolRegistry.visible —— 按信任档裁剪工具表")

struct ToolVisibilityTests {

    @Test("⚠️ 只读档：不给任何写工具、执行工具、网络出口")
    func readOnlyExposesNothingDangerous() {
        let tools = ToolRegistry.visible(trustDial: .readOnly)
        #expect(tools.contains { $0.name == ToolName.readFile })
        #expect(tools.contains { $0.name == ToolName.grepSearch })
        for spec in tools {
            #expect(spec.riskLevel == .safe, "\(spec.name) 不该出现在只读档")
            #expect(!ToolRegistry.isWriter(spec), "\(spec.name) 是写工具，不该出现在只读档")
            #expect(!spec.requirements.contains(.exec), "\(spec.name) 是执行工具，不该出现在只读档")
            #expect(!spec.requirements.contains(.egress), "\(spec.name) 有网络出口，不该出现在只读档")
        }
    }

    @Test("⚠️ 协作档：能改工作区、能跑测试，但不能推送、不能有网络出口")
    func collaborateHasNoPushNoEgress() {
        let tools = ToolRegistry.visible(trustDial: .collaborate)
        #expect(tools.contains { $0.name == ToolName.editFile })
        #expect(tools.contains { $0.name == ToolName.runTests })
        // 推送需要出口能力 → 协作档看不到它（推送不在这个档的能力边界内）
        #expect(!tools.contains { $0.name == ToolName.gitPush })
        #expect(!tools.contains { $0.name == ToolName.fetchURL })
        for spec in tools {
            #expect(!spec.requirements.contains(.egress), "\(spec.name) 有网络出口")
            #expect(spec.riskLevel != .irreversible, "\(spec.name) 不可逆")
        }
        // ⚠️ 但 `run_shell` **在**协作档里：这个档的定义就是"能改工作区、能执行"，
        //    而它是 `.dangerous` → 每次调用仍会弹确认。**"能看到工具"不等于"能随便用"**：
        //    可见性是省 token 与表达能力的边界，真正的闸门在策略引擎的审批分级上。
        #expect(tools.contains { $0.name == ToolName.runShell })
    }

    @Test("自治档有出口但仍不给不可逆操作")
    func autonomousNoIrreversible() {
        let tools = ToolRegistry.visible(trustDial: .autonomous)
        #expect(tools.contains { $0.name == ToolName.fetchURL })
        #expect(tools.contains { $0.name == ToolName.gitPush })
        #expect(!tools.contains { spec in spec.riskLevel == .irreversible })
    }

    @Test("⚠️ 全权档也要看「已授予的能力」（信任档 ≠ 授权）")
    func fullStillRespectsGrants() {
        let granted: Set<CapabilityKind> = [.fsRead, .fsWrite]
        let tools = ToolRegistry.visible(trustDial: .full, granted: granted)
        #expect(tools.contains { $0.name == ToolName.writeFile })
        #expect(!tools.contains { $0.name == ToolName.fetchURL })     // 没有 egress 授权
        #expect(!tools.contains { $0.name == ToolName.runPython })    // 没有 exec 授权
        for spec in tools {
            #expect(spec.requirements.isSubset(of: granted), "\(spec.name) 需要未授予的能力")
        }
    }

    @Test("可见工具数随信任档单调不减（档位越高，能看到的越多）")
    func visibilityIsMonotonic() {
        let dials: [TrustDial] = [.readOnly, .propose, .collaborate, .autonomous, .full]
        let counts = dials.map { ToolRegistry.visible(trustDial: $0).count }
        #expect(counts == counts.sorted())
        #expect(counts.last! > counts.first!)
    }

    @Test("⚠️ 端侧反射子集不超过 5 个工具（端侧窗口只有 4096 token）")
    func reflexSubsetStaysTiny() {
        #expect(ToolRegistry.reflexSubset.count <= 5)
        #expect(ToolRegistry.reflexSubset.count == 5)
        // 端侧只做反射：看状态、能问、能记待办。不许碰文件系统、不许执行、不许联网
        for spec in ToolRegistry.reflexSubset {
            #expect(!spec.requirements.contains(.exec), "\(spec.name) 是执行类，端侧不该有")
            #expect(!spec.requirements.contains(.fsWrite), "\(spec.name) 会写文件，端侧不该有")
            #expect(!spec.requirements.contains(.fsDelete), "\(spec.name) 会删文件，端侧不该有")
            #expect(!spec.requirements.contains(.egress), "\(spec.name) 有网络出口，端侧不该有")
            // `.modifying` 允许：`todo_write` 改的是**运行时状态**，不是文件
            #expect(spec.riskLevel != .dangerous && spec.riskLevel != .irreversible,
                    "\(spec.name) 是 \(spec.riskLevel.rawValue)，端侧不该有")
        }
    }

    @Test("反射子集里的名字都真实存在")
    func reflexSubsetResolves() {
        #expect(ToolRegistry.reflexSubset.count == 5)
        #expect(ToolRegistry.reflexSubset.contains { $0.name == ToolName.askUser })
    }
}
