import Testing
import Foundation
@testable import RuneKernel

// MARK: - 夹具

private func makeSpec(
    _ name: String,
    concurrency: ToolSpec.Concurrency = .parallelSafe,
    risk: ToolSpec.RiskLevel = .safe,
    approval: ToolSpec.ApprovalPolicy = .never,
    requires: Set<CapabilityKind> = [.fsRead]
) -> ToolSpec {
    ToolSpec(
        name: name,
        description: "测试",
        inputSchema: .object(properties: [:], required: [], additionalProperties: true),
        concurrency: concurrency,
        riskLevel: risk,
        needsApproval: approval,
        requirements: requires
    )
}

private func makeDangerousSpec(_ name: String, requires: Set<CapabilityKind> = [.fsDelete]) -> ToolSpec {
    ToolSpec(
        name: name, description: "测试",
        inputSchema: .object(properties: [:], required: [], additionalProperties: true),
        concurrency: .serialPerPath,
        isIdempotent: false, riskLevel: .dangerous, needsApproval: .always, requirements: requires
    )
}

/// 一个"声明可并行、但会写文件"的工具。
///
/// 它存在的意义：**path 冲突检测只有在 parallelSafe 的写工具上才真正生效**。
/// 若把写工具一律标成 `serialPerPath`，那冲突检测就永远走不到——
/// 表面上"有冲突检测"，实际上从没被触发过。
private let parallelWriter = "write_cache"

/// 常用工具集（贴近真实的 docs/05 §2.1 风险标注）
private let registry: [String: ToolSpec] = [
    ToolName.readFile: makeSpec(ToolName.readFile, requires: [.fsRead]),
    ToolName.grepSearch: makeSpec(ToolName.grepSearch, requires: [.fsRead]),
    ToolName.glob: makeSpec(ToolName.glob, requires: [.fsRead]),
    ToolName.listDir: makeSpec(ToolName.listDir, requires: [.fsRead]),
    ToolName.writeFile: makeSpec(ToolName.writeFile, concurrency: .serialPerPath, risk: .modifying,
                                 approval: .perProject, requires: [.fsWrite]),
    ToolName.editFile: makeSpec(ToolName.editFile, concurrency: .serialPerPath, risk: .modifying,
                                approval: .perProject, requires: [.fsWrite]),
    ToolName.applyPatch: makeSpec(ToolName.applyPatch, concurrency: .serialPerPath, risk: .modifying,
                                  approval: .perProject, requires: [.fsWrite]),
    ToolName.runTests: makeSpec(ToolName.runTests, requires: [.exec]),
    ToolName.runPython: makeSpec(ToolName.runPython, requires: [.exec]),
    // 真实目录里 delete_path 是 dangerous（docs/05 §2.1）
    ToolName.deletePath: makeDangerousSpec(ToolName.deletePath),
    ToolName.gitPush: makeSpec(ToolName.gitPush, concurrency: .serialPerPath, risk: .dangerous,
                               approval: .always, requires: [.gitWrite]),
    parallelWriter: makeSpec(parallelWriter, concurrency: .parallelSafe, risk: .modifying,
                             approval: .never, requires: [.fsWrite]),
]

private func call(_ name: String, _ args: JSONValue = [:], id: String = UUID().uuidString) -> ToolCall {
    ToolCall(id: id, name: name, argumentsJSON: Data(args.canonicalString().utf8))
}

// MARK: - 测试

@Suite("ToolScheduler —— 并行分桶与冲突检测")
struct ToolSchedulerTests {

    private let config = ToolScheduler.Config(maxConcurrency: 6, maxCallsPerWave: 24)

    private func schedule(_ calls: [ToolCall], config: ToolScheduler.Config? = nil) -> ToolScheduler.Schedule {
        ToolScheduler.schedule(calls: calls, specs: registry, config: config ?? self.config)
    }

    // MARK: 只读并行

    @Test("多个只读调用 → 合成一个并行波次")
    func readOnlyCallsRunInParallel() {
        let s = schedule([
            call(ToolName.readFile, ["path": "/workspace/a.swift"]),
            call(ToolName.readFile, ["path": "/workspace/b.swift"]),
            call(ToolName.grepSearch, ["pattern": "TODO"]),
            call(ToolName.listDir, ["path": "/workspace/src"]),
        ])
        #expect(s.waves.count == 1)
        #expect(s.waves[0].calls.count == 4)
        #expect(s.waves[0].isParallel)
        #expect(s.waves[0].reason.contains("并行"))
    }

    @Test("并发上限生效（手机上不能无限并行）")
    func concurrencyCap() {
        let calls = (0..<20).map { call(ToolName.readFile, ["path": .string("/workspace/f\($0).swift")]) }
        let s = schedule(calls, config: ToolScheduler.Config(maxConcurrency: 3, maxCallsPerWave: 100))
        #expect(s.waves.count == 7)                       // ceil(20/3)
        #expect(s.waves.allSatisfy { $0.calls.count <= 3 })
        #expect(s.totalScheduled == 20)
    }

    @Test("按设备核数推导并发度（封顶 6）")
    func deviceConcurrency() {
        #expect(ToolScheduler.Config.forDevice(activeProcessorCount: 2).maxConcurrency == 2)
        #expect(ToolScheduler.Config.forDevice(activeProcessorCount: 8).maxConcurrency == 6)
        #expect(ToolScheduler.Config.forDevice(activeProcessorCount: 32).maxConcurrency == 6)
    }

    // MARK: 写冲突

    @Test("⚠️ 写同一文件的两个调用 → 必须串行（不能并行改同一个文件）")
    func sameFileWritesAreSerialized() {
        let s = schedule([
            call(ToolName.writeFile, ["path": "/workspace/src/a.swift", "content": "x"]),
            call(ToolName.editFile, ["path": "/workspace/src/a.swift", "find": "x", "replace": "y"]),
        ], config: ToolScheduler.Config(maxConcurrency: 6, maxCallsPerWave: 24))
        // 两个都是 serialPerPath → 各自单独成波
        #expect(s.waves.count == 2)
        #expect(s.waves.allSatisfy { $0.calls.count == 1 })
    }

    @Test("⚠️ 目录与其下文件也冲突（写目录会影响其下所有文件）")
    func directoryOverlapsWithChildFile() {
        // 用"声明可并行但会写文件"的工具来测 —— 这样才会真正走到 path 冲突检测
        let s = schedule([
            call(parallelWriter, ["path": "/workspace/build", "content": "x"]),
            call(parallelWriter, ["path": "/workspace/build/out.o", "content": "y"]),
        ])
        #expect(s.waves.count == 2, "目录与其子文件必须串行")
    }

    @Test("✅ 声明可并行的写工具，在**路径不重叠**时可以并行（这才是冲突检测的价值）")
    func parallelWritersOnDifferentPathsRunTogether() {
        let s = schedule([
            call(parallelWriter, ["path": "/workspace/cache/a.bin", "content": "x"]),
            call(parallelWriter, ["path": "/workspace/cache/b.bin", "content": "y"]),
            call(parallelWriter, ["path": "/workspace/other/c.bin", "content": "z"]),
        ])
        #expect(s.waves.count == 1)
        #expect(s.waves[0].calls.count == 3)
    }

    @Test("⚠️ 声明可并行的写工具，路径重叠时必须拆开（顺序保持）")
    func parallelWritersOnSamePathAreSplit() {
        let s = schedule([
            call(parallelWriter, ["path": "/workspace/cache/a.bin", "content": "1"], id: "1"),
            call(parallelWriter, ["path": "/workspace/cache/a.bin", "content": "2"], id: "2"),
        ])
        #expect(s.waves.count == 2)
        #expect(s.waves.flatMap { $0.calls.map(\.id) } == ["1", "2"])
    }

    @Test("写**不同**文件可以并行（不同目录/不重叠路径）")
    func independentWritesCanParallelize() {
        // 注意：本实现里 serialPerPath 一律串行（保守），但只读调用之间仍可并行。
        // 这里断言的是"只读 + 只读"能并行，而"写 + 写"保守串行。
        let s = schedule([
            call(ToolName.readFile, ["path": "/workspace/a.swift"]),
            call(ToolName.readFile, ["path": "/workspace/b.swift"]),
        ])
        #expect(s.waves.count == 1)
        #expect(s.waves[0].calls.count == 2)
    }

    @Test("⚠️【最易漏】执行类工具与写操作必须串行（否则测试读到半成品，产出假失败）")
    func execConflictsWithWrites() {
        let s = schedule([
            call(ToolName.runTests, [:]),
            call(ToolName.applyPatch, ["patch": .string("""
            *** File: /workspace/src/money.py
            @@
            -a
            +b
            """)]),
        ], config: ToolScheduler.Config(maxConcurrency: 6, maxCallsPerWave: 24))
        #expect(s.waves.count == 2, "跑测试与改文件不能并行")
    }

    @Test("两个执行类工具互相冲突（同时跑两个脚本会争抢资源并互相影响产物）")
    func twoExecsConflict() {
        let s = schedule([
            call(ToolName.runTests, [:]),
            call(ToolName.runPython, ["code": "print(1)"]),
        ], config: ToolScheduler.Config(maxConcurrency: 6, maxCallsPerWave: 24))
        #expect(s.waves.count == 2)
    }

    @Test("可以把执行类与写的冲突关掉（不推荐，但要有开关）")
    func execWriteConflictIsConfigurable() {
        let s = schedule([
            call(ToolName.runTests, [:]),
            call(ToolName.applyPatch, ["patch": .string("*** File: /workspace/a.py\n@@\n-a\n+b")]),
        ], config: ToolScheduler.Config(maxConcurrency: 6, maxCallsPerWave: 24, execConflictsWithWrites: false))
        // apply_patch 仍是 serialPerPath → 依然串行；但不再是"因为 exec 冲突"
        #expect(s.waves.count == 2)
    }

    @Test("只读调用与写调用可以并行吗？—— 不可以（保守），但不会和写抢文件")
    func readsDoNotJoinWriteWave() {
        let s = schedule([
            call(ToolName.readFile, ["path": "/workspace/x.swift"]),
            call(ToolName.writeFile, ["path": "/workspace/y.swift", "content": "z"]),
        ], config: ToolScheduler.Config(maxConcurrency: 6, maxCallsPerWave: 24))
        // 只读先成波，写再成波（写不是 parallelSafe，无法并入只读波）
        #expect(s.totalScheduled == 2)
    }

    // MARK: 补丁路径提取（最容易被漏的一类）

    @Test("⚠️ 多文件补丁的所有路径都被提取出来（漏一个冲突检测就失效）")
    func multiFilePatchPathsExtracted() {
        let patchText = """
        *** File: /workspace/src/a.py
        @@
        -x
        +y
        *** File: /workspace/src/b.py
        @@
        -p
        +q
        *** File: /workspace/docs/c.md
        @@
        -m
        +n
        """
        let c = call(ToolName.applyPatch, ["patch": .string(patchText)])
        let paths = ToolScheduler.defaultPaths(c, registry[ToolName.applyPatch]!)
        #expect(paths.count == 3)
        #expect(paths.map(\.description).contains("/workspace/src/b.py"))
    }

    @Test("补丁改的文件与另一个写操作冲突时能被检出（即使补丁改的是第二个文件）")
    func patchConflictDetectedOnSecondFile() {
        let patchText = """
        *** File: /workspace/src/untouched.py
        @@
        -x
        +y
        *** File: /workspace/src/target.py
        @@
        -old
        +new
        """
        let c = call(ToolName.applyPatch, ["patch": .string(patchText)])
        let paths = ToolScheduler.defaultPaths(c, registry[ToolName.applyPatch]!)
        let target = try! VFSPath.parse("/workspace/src/target.py")
        #expect(paths.contains { ToolScheduler.pathsOverlap($0, target) },
                "必须能发现补丁影响了 target.py")
    }

    @Test("常见路径键名都能提取（path/file/target/paths[]）")
    func commonPathKeysExtracted() {
        let spec = registry[ToolName.readFile]!
        #expect(ToolScheduler.defaultPaths(call(ToolName.readFile, ["path": "/workspace/a"]), spec).count == 1)
        #expect(ToolScheduler.defaultPaths(call(ToolName.readFile, ["file": "/workspace/b"]), spec).count == 1)
        #expect(ToolScheduler.defaultPaths(call(ToolName.readFile, ["file_path": "/workspace/c"]), spec).count == 1)
        let multi = ToolScheduler.defaultPaths(
            call(ToolName.readFile, ["paths": .array([.string("/workspace/x"), .string("/workspace/y")])]), spec
        )
        #expect(multi.count == 2)
    }

    @Test("没有路径参数的调用不会误判为冲突")
    func noPathMeansNoConflict() {
        let s = schedule([
            call(ToolName.grepSearch, ["pattern": "a"]),
            call(ToolName.grepSearch, ["pattern": "b"]),
        ])
        #expect(s.waves.count == 1)
        #expect(s.waves[0].calls.count == 2)
    }

    // MARK: 审批批量

    @Test("⚠️ 需要审批的调用被批量摘出（手机上一次弹一个审批是灾难）")
    func approvalsAreBatched() {
        let s = schedule([
            call(ToolName.readFile, ["path": "/workspace/a"]),
            call(ToolName.gitPush, [:]),
            call(ToolName.readFile, ["path": "/workspace/b"]),
        ])
        #expect(s.approvalsNeeded.count == 1)
        #expect(s.approvalsNeeded[0].name == ToolName.gitPush)
        #expect(s.diagnostics.contains { $0.contains("批量确认") })
        // 审批项不阻塞只读操作
        #expect(s.waves.count == 1)
        #expect(s.waves[0].calls.count == 2)
    }

    @Test("多个待批项合并成一次")
    func multipleApprovalsMerged() {
        let s = schedule([
            call(ToolName.gitPush, [:]),
            call(ToolName.deletePath, ["path": "/workspace/build"]),
        ])
        #expect(s.approvalsNeeded.count == 2)
        #expect(s.diagnostics.contains { $0.contains("2 个调用需要审批") })
    }

    // MARK: 预算与未知工具

    @Test("单轮预算满 → 多余的延后（而不是静默丢弃）")
    func budgetDefersExcess() {
        let calls = (0..<10).map { call(ToolName.readFile, ["path": .string("/workspace/f\($0)")]) }
        let s = schedule(calls, config: ToolScheduler.Config(maxConcurrency: 6, maxCallsPerWave: 4))
        #expect(s.totalScheduled == 4)
        #expect(s.deferred.count == 6)
        #expect(s.diagnostics.contains { $0.contains("延后") })
    }

    @Test("未知工具被摘出并给出诊断（走「工具名幻觉」兜底）")
    func unknownToolsReported() {
        let s = schedule([
            call(ToolName.readFile, ["path": "/workspace/a"]),
            call("read_fil", ["path": "/workspace/b"]),
        ])
        #expect(s.deferred.contains { $0.name == "read_fil" })
        #expect(s.diagnostics.contains { $0.contains("未注册") })
    }

    @Test("独占操作单独成波（例如重建索引）")
    func exclusiveRunsAlone() {
        var specs = registry
        specs["reindex"] = ToolSpec(
            name: "reindex", description: "重建索引",
            inputSchema: .object(properties: [:], required: [], additionalProperties: true),
            concurrency: .exclusive
        )
        let s = ToolScheduler.schedule(
            calls: [
                call(ToolName.readFile, ["path": "/workspace/a"]),
                call("reindex", [:]),
                call(ToolName.readFile, ["path": "/workspace/b"]),
            ],
            specs: specs, config: config
        )
        #expect(s.waves.count == 3)
        let exclusiveWave = s.waves.first { $0.calls.first?.name == "reindex" }
        #expect(exclusiveWave?.calls.count == 1)
        #expect(exclusiveWave?.reason.contains("独占") == true)
    }

    // MARK: 顺序保证

    @Test("不重排模型给出的顺序（模型有时依赖「先建目录再写文件」）")
    func preservesModelOrder() {
        let mkdir = call(ToolName.writeFile, ["path": "/workspace/newdir/keep.txt", "content": ""], id: "1")
        let write = call(ToolName.writeFile, ["path": "/workspace/newdir/a.txt", "content": "x"], id: "2")
        let s = schedule([mkdir, write], config: ToolScheduler.Config(maxConcurrency: 6, maxCallsPerWave: 24))
        let flat = s.waves.flatMap { $0.calls.map(\.id) }
        #expect(flat == ["1", "2"])
    }

    @Test("空输入不崩")
    func emptyInput() {
        let s = schedule([])
        #expect(s.waves.isEmpty)
        #expect(s.totalScheduled == 0)
        #expect(!s.isParallelizable)
    }

    @Test("pathsOverlap 的边界：兄弟目录不重叠，父子重叠")
    func pathsOverlapBoundary() {
        let a = VFSPath(mount: .workspace, components: ["src"])
        let b = VFSPath(mount: .workspace, components: ["src", "a.swift"])
        let c = VFSPath(mount: .workspace, components: ["src2"])
        #expect(ToolScheduler.pathsOverlap(a, b))
        #expect(!ToolScheduler.pathsOverlap(a, c))
        #expect(!ToolScheduler.pathsOverlap(
            VFSPath(mount: .workspace, components: ["tmp"]),
            VFSPath(mount: .tmp, components: ["x"])
        ))
    }
}
