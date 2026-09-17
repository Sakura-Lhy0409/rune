import Foundation

// MARK: - 沙箱：资源限额、输出纪律、来源分级
//
// 设计依据（docs/05 §3 / §7）。这一层只做**决策**，不做执行 ——
// 真正的执行是 CPython / WasmKit / JSC 的事（都要 macOS），
// 但**"给多少额度""超了怎么算""超了该说什么""这段代码该进哪个环境"** 全是纯逻辑，
// 而且每一条错了都不会报错、只会静默地烧钱或让用户莫名其妙。
//
// 三个职责分开看：
//
//   ① **输出纪律**（§7，设计文档称之为"手机上最重要的一条工程纪律"）：
//      单工具 2MB 进制品、8KB 进上下文。这一条不做，一次 pytest 就能吃掉整个上下文。
//   ② **资源限额**：墙钟 / CPU / 内存 / 指令数。超了要给出**该怎么做**，不是一句"超限"。
//   ③ **来源分级**（§3.1.1）：按代码来源选隔离强度 ——
//      设计文档称之为"本设计里最重要的安全补偿机制之一"。
//      因为原生 CPython 的隔离**弱于 WASM**，我们**不假装它们一样强**，
//      而是按来源选择：用户自己写的走 CPython，模型生成的走 WASM。

// MARK: - 输出纪律

/// 一份输出的去向。
///
/// ⚠️ 这是 docs/05 §7 那一条纪律的**唯一实现**。
/// 分散在几十个工具里各写一遍"要不要截断"是不可能的 ——
/// 而漏掉任何一个，模型就会在某次调用里收到 2MB 的日志。
public struct OutputBudget: Sendable, Codable, Hashable {

    public enum Disposition: String, Sendable, Codable, Hashable {
        /// 直接内联给模型
        case inline
        /// 存为制品，上下文里只放"摘要 + 句柄"
        case artifact
        /// 大到连制品都不该落（流式处理或拒绝）
        case refuse
    }

    /// 内联给模型的字节上限（设计值 8KB）
    public var inlineLimit: Int
    /// 允许落为制品的上限（设计值 2MB）
    public var artifactLimit: Int
    /// 制品预览的字节数（模型靠它决定要不要去读全文）
    public var previewBytes: Int

    public init(inlineLimit: Int = 8 * 1024, artifactLimit: Int = 2 * 1024 * 1024, previewBytes: Int = 2 * 1024) {
        self.inlineLimit = max(256, inlineLimit)
        self.artifactLimit = max(self.inlineLimit, artifactLimit)
        self.previewBytes = max(128, previewBytes)
    }

    public static let standard = OutputBudget()
    /// 执行类工具（`run_tests` / `run_build`）用：内联更小，因为它们的输出通常又长又重复
    public static let exec = OutputBudget(inlineLimit: 4 * 1024, artifactLimit: 4 * 1024 * 1024)

    public func disposition(byteCount: Int) -> Disposition {
        if byteCount <= inlineLimit { return .inline }
        if byteCount <= artifactLimit { return .artifact }
        return .refuse
    }

    /// 制品在上下文里的样子（docs/05 §7 的那一行）。
    ///
    /// ⚠️ 必须给 **5W**：多大的、多少行、里面大概有什么、去哪读。
    /// 只说"输出过大已截断"的话，模型只能选择"再跑一遍"或"猜" —— 两个都在烧钱。
    public func artifactNote(
        handle: String,
        displayName: String,
        byteCount: Int,
        lineCount: Int?,
        headline: String? = nil
    ) -> String {
        var parts = ["已生成 \(displayName)（\(Self.humanBytes(byteCount))"]
        if let lineCount { parts.append("，\(lineCount) 行") }
        parts.append("）")
        var text = parts.joined()
        if let headline, !headline.isEmpty {
            text += "，摘要：\(headline)"
        }
        text += "\n用 `read_artifact(handle: \"\(handle)\")` 按需读取片段（支持关键字定位）。"
        return text
    }

    /// 预览：**保头也保尾**（结论通常在最后几行 —— `12 passed`、错误栈的最后一行）
    public func preview(_ text: String) -> String {
        let data = Data(text.utf8)
        guard data.count > previewBytes else { return text }
        let headBytes = previewBytes * 3 / 5
        let tailBytes = previewBytes - headBytes
        var slice = data.prefix(headBytes)
        slice.append(Data("\n…（中间省略 \(data.count - previewBytes) 字节）…\n".utf8))
        slice.append(data.suffix(tailBytes))
        return String(decoding: slice, as: UTF8.self)
    }

    public static func humanBytes(_ count: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(count)
        var index = 0
        while value >= 1024, index < units.count - 1 { value /= 1024; index += 1 }
        return index == 0 ? "\(count)B" : String(format: "%.1f%@", value, units[index])
    }
}

// MARK: - 资源限额

public struct SandboxLimits: Sendable, Codable, Hashable {
    /// 墙钟（秒）
    public var wallClockSeconds: Int
    /// CPU 时间（秒）—— 与墙钟分开：等待 IO 的时间不该算进 CPU 额度
    public var cpuSeconds: Int
    public var memoryMB: Int
    /// WASM 指令数上限（0 = 不适用）
    public var instructionLimit: UInt64
    /// 输出上限（超过即按 `OutputBudget` 处理）
    public var outputBytes: Int
    /// 调用栈深度（防无限递归把进程打挂）
    public var stackDepth: Int

    public init(
        wallClockSeconds: Int = 120,
        cpuSeconds: Int = 60,
        memoryMB: Int = 512,
        instructionLimit: UInt64 = 0,
        outputBytes: Int = 2 * 1024 * 1024,
        stackDepth: Int = 1_000
    ) {
        self.wallClockSeconds = max(1, wallClockSeconds)
        self.cpuSeconds = max(1, cpuSeconds)
        self.memoryMB = max(16, memoryMB)
        self.instructionLimit = instructionLimit
        self.outputBytes = max(1024, outputBytes)
        self.stackDepth = max(32, stackDepth)
    }

    /// 各运行时的默认额度（取自 docs/05 §3 的表格）。
    ///
    /// ⚠️ 手机上**墙钟比桌面紧得多**：iOS 会在后台很快挂起进程，
    /// 前台跑 120 秒不响应也会被用户杀掉。所以默认 120s，
    /// 而真正的长任务应该转成后台作业（`start_job`）。
    public static func defaults(for runtime: SandboxRuntime) -> SandboxLimits {
        switch runtime {
        case .python:
            // 原生 CPython 与宿主同进程：内存给得更紧，因为超了是整个 App 一起死
            return SandboxLimits(wallClockSeconds: 120, cpuSeconds: 90, memoryMB: 512,
                                 outputBytes: 2 * 1024 * 1024)
        case .javascript:
            // 设计文档：墙钟 30s、内存 256MB（agent() 调用期间不计时，那是编排层的事）
            return SandboxLimits(wallClockSeconds: 30, cpuSeconds: 30, memoryMB: 256,
                                 outputBytes: 1024 * 1024, stackDepth: 512)
        case .wasm:
            // WASM 有指令计数器 → 用指令数做**确定性**限额，比墙钟可靠得多
            return SandboxLimits(wallClockSeconds: 60, cpuSeconds: 60, memoryMB: 256,
                                 instructionLimit: 5_000_000_000,
                                 outputBytes: 1024 * 1024, stackDepth: 1_024)
        case .shell:
            return SandboxLimits(wallClockSeconds: 120, cpuSeconds: 60, memoryMB: 256,
                                 outputBytes: 2 * 1024 * 1024)
        }
    }
}

/// 一次执行实际用掉的资源
public struct SandboxUsage: Sendable, Codable, Hashable {
    public var wallClockMS: Int
    public var cpuMS: Int
    public var peakMemoryMB: Int
    public var instructions: UInt64
    public var outputBytes: Int
    public var maxStackDepth: Int

    public init(wallClockMS: Int = 0, cpuMS: Int = 0, peakMemoryMB: Int = 0,
                instructions: UInt64 = 0, outputBytes: Int = 0, maxStackDepth: Int = 0) {
        self.wallClockMS = wallClockMS
        self.cpuMS = cpuMS
        self.peakMemoryMB = peakMemoryMB
        self.instructions = instructions
        self.outputBytes = outputBytes
        self.maxStackDepth = maxStackDepth
    }
}

/// 超限的判定与**该怎么做**。
///
/// ⚠️ 只说"超限"是没用的 —— 模型唯一能做的就是"再跑一遍"（大概率还是超）。
/// 每种超限都有**不同的正确做法**：
///   墙钟超时 → 转后台作业；内存超限 → 分批处理；指令超限 → 换原生工具或缩小规模。
/// 所以这个类型的主要价值在 `suggestion`。
public struct SandboxViolation: Sendable, Hashable, CustomStringConvertible {
    public var kind: RuneError.SandboxFailureKind
    public var measured: String
    public var limit: String
    public var suggestion: String
    /// 换更大的额度重跑有没有意义（不是所有超限都值得重试）
    public var isRetryableWithBiggerLimit: Bool

    public init(kind: RuneError.SandboxFailureKind, measured: String, limit: String,
                suggestion: String, isRetryableWithBiggerLimit: Bool) {
        self.kind = kind
        self.measured = measured
        self.limit = limit
        self.suggestion = suggestion
        self.isRetryableWithBiggerLimit = isRetryableWithBiggerLimit
    }

    public var description: String { "\(kind.displayName)：\(measured) 超过 \(limit)" }

    public var modelFacingText: String {
        "\(kind.displayName)：实际 \(measured)，上限 \(limit)。\n👉 \(suggestion)"
    }
}

public extension SandboxLimits {

    /// 按**严重程度**找出第一个被突破的额度（返回 nil = 没超）。
    ///
    /// ⚠️ 顺序是有意的：**内存与指令数排在墙钟前面**。
    /// 因为墙钟超时往往是内存/指令超限的**后果**（内存打满之后疯狂 GC，或者死循环），
    /// 先报"超时"会把真正的原因藏起来，模型就会去改一个无关的地方。
    func violation(for usage: SandboxUsage) -> SandboxViolation? {
        if usage.peakMemoryMB > memoryMB {
            return SandboxViolation(
                kind: .memoryExceeded,
                measured: "\(usage.peakMemoryMB)MB", limit: "\(memoryMB)MB",
                suggestion: "把数据**分批处理**（例如按行块迭代 CSV），而不是整表加载；或者先把大文件用 `grep_search` 缩小范围。",
                isRetryableWithBiggerLimit: false
            )
        }
        if instructionLimit > 0, usage.instructions > instructionLimit {
            return SandboxViolation(
                kind: .cpuExceeded,
                measured: "\(usage.instructions) 条指令", limit: "\(instructionLimit) 条",
                suggestion: "这段计算太密了。**换成原生工具**（例如用 `grep_search` 而不是自己写循环扫文件），或者把规模减小。单纯加大额度只会让它跑更久。",
                isRetryableWithBiggerLimit: false
            )
        }
        if usage.maxStackDepth > stackDepth {
            return SandboxViolation(
                kind: .crashed,
                measured: "栈深 \(usage.maxStackDepth)", limit: "\(stackDepth)",
                suggestion: "递归太深。改成迭代（显式用栈/队列），或者先加一个终止条件。",
                isRetryableWithBiggerLimit: false
            )
        }
        if usage.cpuMS > cpuSeconds * 1_000 {
            return SandboxViolation(
                kind: .cpuExceeded,
                measured: String(format: "%.1fs CPU", Double(usage.cpuMS) / 1000), limit: "\(cpuSeconds)s",
                suggestion: "CPU 时间用完了。先确认不是死循环；确实是重计算的话，考虑把它写成后台作业（`start_job`），或者换个算法。",
                isRetryableWithBiggerLimit: true
            )
        }
        if usage.wallClockMS > wallClockSeconds * 1_000 {
            return SandboxViolation(
                kind: .timedOut,
                measured: String(format: "%.1fs", Double(usage.wallClockMS) / 1000), limit: "\(wallClockSeconds)s",
                suggestion: "跑太久了。iOS 上超过这个时间的执行会被系统挂起 —— 请把它转成**后台作业**（`start_job`），那样可以跑很久、还能增量读输出。",
                isRetryableWithBiggerLimit: true
            )
        }
        if outputBytes > 0, usage.outputBytes > outputBytes {
            return SandboxViolation(
                kind: .outputExceeded,
                measured: OutputBudget.humanBytes(usage.outputBytes), limit: OutputBudget.humanBytes(outputBytes),
                suggestion: "输出太多了。请**只输出结论**（例如汇总统计），或者把结果写进文件再用 `read_file` 取需要的部分。",
                isRetryableWithBiggerLimit: false
            )
        }
        return nil
    }

    /// 沙箱能拿到的内存上限：**物理内存的 1/4**。
    ///
    /// ⚠️ 一开始写的是 3/4，那是错的：iOS 的 jetsam 会在 App 占用过多时**直接杀掉进程**，
    /// 而那一刻被限额拦住的不是脚本，是整个 App（连同用户没保存的东西）。
    /// 剩下的 3/4 要留给系统、App 本体、UI，以及运行时自己（CPython 解释器、JIT 之外的各种缓冲）。
    ///
    /// 换算一下也对得上设计文档的默认值：2GB 机型 → 512MB（= CPython 的默认额度）。
    static func memoryCap(onDeviceMemoryMB: Int) -> Int {
        max(64, onDeviceMemoryMB / 4)
    }

    /// 这台设备上**能不能**给出这个额度
    func isAchievable(onDeviceMemoryMB: Int) -> Bool {
        memoryMB <= Self.memoryCap(onDeviceMemoryMB: onDeviceMemoryMB)
    }
}

// MARK: - 来源分级（docs/05 §3.1.1）

/// 一段代码的来源。
///
/// ⚠️ 这个类型存在的理由是一条**诚实的设计判断**：
/// 原生 CPython 与宿主同进程，隔离**弱于** WASM。
/// 我们**不假装它们一样强**，而是按来源选择隔离强度。
/// 设计文档把它称为"本设计里最重要的安全补偿机制之一"。
public enum CodeProvenance: String, Sendable, Codable, Hashable, CaseIterable {
    /// 用户自己写的脚本（在工作区里、由用户创建）
    case userAuthored
    /// 内置技能/夹具携带的脚本（随包分发，已审计）
    case bundledSkill
    /// **模型生成的临时脚本**（半可信）
    case modelGenerated
    /// 来自工作区但来源不明的脚本（例如克隆来的仓库里的 `setup.py`）
    case unknownFromWorkspace

    public var displayName: String {
        switch self {
        case .userAuthored: return "用户自写"
        case .bundledSkill: return "内置技能"
        case .modelGenerated: return "模型生成"
        case .unknownFromWorkspace: return "来源不明"
        }
    }
}

public struct SandboxSelection: Sendable, Hashable {
    public var runtime: SandboxRuntime
    public var provenance: CodeProvenance
    /// 是否必须人工确认
    public var requiresApproval: Bool
    /// 是否打污点标记（会传染给派生的动作）
    public var isTainted: Bool
    /// 为什么这么选（**UI 上要显示** —— 用户有权知道为什么这次要确认）
    public var rationale: String

    public init(runtime: SandboxRuntime, provenance: CodeProvenance,
                requiresApproval: Bool, isTainted: Bool, rationale: String) {
        self.runtime = runtime
        self.provenance = provenance
        self.requiresApproval = requiresApproval
        self.isTainted = isTainted
        self.rationale = rationale
    }
}

public enum SandboxPolicy {

    /// 按来源选执行环境（docs/05 §3.1.1 的表）。
    public static func select(provenance: CodeProvenance, runtime requested: SandboxRuntime) -> SandboxSelection {
        switch provenance {
        case .userAuthored:
            return SandboxSelection(
                runtime: requested, provenance: provenance,
                requiresApproval: false, isTainted: false,
                rationale: "这是你自己写的脚本，等价于在编辑器里按「运行」。"
            )

        case .bundledSkill:
            return SandboxSelection(
                runtime: requested, provenance: provenance,
                requiresApproval: false, isTainted: false,
                rationale: "随包分发的技能脚本，已审计。"
            )

        case .modelGenerated:
            // ⚠️ 模型生成的代码走更强的隔离。
            //    做不到（例如请求的是 Python 而 WASM 编译不可用）时**降级但强制审批** ——
            //    绝不"因为隔离做不到就直接放行"。
            if requested == .python {
                return SandboxSelection(
                    runtime: .wasm, provenance: provenance,
                    requiresApproval: true, isTainted: false,
                    rationale: "这段代码是模型生成的，所以在更严格的 WASM 沙箱里跑。"
                        + "如果它需要 CPython 的生态（例如 pandas），会降级到原生 CPython 并要求你确认。"
                )
            }
            return SandboxSelection(
                runtime: requested, provenance: provenance,
                requiresApproval: true, isTainted: false,
                rationale: "这段代码是模型生成的，运行前需要你确认。"
            )

        case .unknownFromWorkspace:
            return SandboxSelection(
                runtime: requested, provenance: provenance,
                requiresApproval: true, isTainted: true,
                rationale: "这份脚本来自工作区、但不是你自己写的（例如从克隆来的仓库里带来的）。"
                    + "这类脚本是供应链攻击的典型入口，所以需要你确认，并且它读到的内容会带上污点标记。"
            )
        }
    }

    /// 从路径推断来源（`Runes/` 下的、以及工作区里用户创建的）
    public static func inferProvenance(
        path: VFSPath,
        isBundledSkill: Bool = false,
        wasGeneratedThisTurn: Bool = false
    ) -> CodeProvenance {
        if wasGeneratedThisTurn { return .modelGenerated }
        if isBundledSkill { return .bundledSkill }

        // ⚠️ 只在**收尾**判断：`vendor/` / `node_modules/` / 克隆来的仓库
        //    都属于"用户没有亲手写过"的那一类。这个判断是保守的 ——
        //    误判成"来源不明"的代价是一次确认，误判成"用户自写"的代价是静默执行别人的代码。
        let components = path.components.map { $0.lowercased() }
        let suspicious: Set<String> = [
            "vendor", "node_modules", "third_party", "thirdparty", "external",
            "deps", "site-packages", ".build", "packages",
        ]
        if components.contains(where: { suspicious.contains($0) }) {
            return .unknownFromWorkspace
        }
        return .userAuthored
    }
}

// MARK: - 请求与结果

public struct SandboxRequest: Sendable {
    public var runtime: SandboxRuntime
    /// 要执行的代码（Python / JS）
    public var code: String?
    /// 要执行的模块路径（WASM）/ 命令（shell）
    public var entryPath: String?
    public var arguments: [String]
    public var stdin: Data
    public var limits: SandboxLimits
    public var provenance: CodeProvenance
    /// 额外要投喂进沙箱的文件（工作区相对路径）
    public var inputFiles: [String]

    public init(runtime: SandboxRuntime, code: String? = nil, entryPath: String? = nil,
                arguments: [String] = [], stdin: Data = Data(),
                limits: SandboxLimits? = nil, provenance: CodeProvenance = .modelGenerated,
                inputFiles: [String] = []) {
        self.runtime = runtime
        self.code = code
        self.entryPath = entryPath
        self.arguments = arguments
        self.stdin = stdin
        self.limits = limits ?? SandboxLimits.defaults(for: runtime)
        self.provenance = provenance
        self.inputFiles = inputFiles
    }
}

public struct SandboxResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var usage: SandboxUsage
    /// 被哪个额度拦住了（nil = 正常结束）
    public var violation: SandboxViolation?
    /// 用户/系统在中途取消
    public var wasCancelled: Bool
    /// 输出太大被转成制品时的句柄（由调用方落盘后回填）
    public var artifactHandle: String?

    public init(
        exitCode: Int32 = 0,
        stdout: Data = Data(),
        stderr: Data = Data(),
        usage: SandboxUsage = SandboxUsage(),
        violation: SandboxViolation? = nil,
        wasCancelled: Bool = false,
        artifactHandle: String? = nil
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.usage = usage
        self.violation = violation
        self.wasCancelled = wasCancelled
        self.artifactHandle = artifactHandle
    }

    public var succeeded: Bool { exitCode == 0 && violation == nil && !wasCancelled }

    /// 转成统一的工具结果（**这就是"输出纪律"的落点**）。
    ///
    /// ⚠️ 所有执行类工具都必须经过它 —— 否则总有一个工具会忘记截断，
    /// 而那一次调用就会把 2MB 日志塞进上下文。
    public func asToolResult(
        callID: String,
        budget: OutputBudget = .exec,
        displayName: String = "输出",
        headline: String? = nil
    ) -> ToolResult {
        let combined = stdout + stderr
        let byteCount = combined.count
        let text = String(decoding: combined, as: UTF8.self)
        let lineCount = text.isEmpty ? 0 : text.components(separatedBy: "\n").count

        var summary: String
        var artifacts: [ArtifactRef] = []

        switch budget.disposition(byteCount: byteCount) {
        case .inline:
            summary = text

        case .artifact:
            let handle = artifactHandle ?? "artifacts/\(UUID().uuidString.prefix(8)).txt"
            artifacts = [ArtifactRef(
                relPath: handle,
                kind: .log,
                displayName: displayName,
                mime: "text/plain",
                byteSize: Int64(byteCount),
                lineCount: lineCount,
                sha256: nil
            )]
            summary = budget.artifactNote(handle: handle, displayName: displayName,
                                          byteCount: byteCount, lineCount: lineCount,
                                          headline: headline)
            summary += "\n\n预览：\n" + budget.preview(text)

        case .refuse:
            // ⚠️ 连制品都不落：这种量级该做的是**改做法**（流式/缩小范围），
            //    而不是把它存下来再让模型去读。
            let error = ToolError(
                kind: .outputTooLarge,
                modelFacingMessage: "这次输出有 \(OutputBudget.humanBytes(byteCount))，超过了单次上限 \(OutputBudget.humanBytes(budget.artifactLimit))，已丢弃。",
                suggestion: "请缩小范围重跑（例如只统计汇总、或先过滤再输出），不要把这么大的内容一次吐出来。",
                candidates: []
            )
            return .failure(callID: callID, error: error)
        }

        if let violation {
            let error = ToolError(
                kind: .sandboxFailure,
                modelFacingMessage: "\(violation.modelFacingText)\n\n最后一次输出：\n\(budget.preview(text))",
                suggestion: violation.suggestion
            )
            return ToolResult(callID: callID, status: .error, summary: error.modelFacingText,
                              artifacts: artifacts, metrics: metrics(), error: error)
        }

        if wasCancelled {
            let error = ToolError(
                kind: .sandboxFailure,
                modelFacingMessage: "执行被取消（是用户或系统中断的，不是脚本的问题）。",
                suggestion: "如果还需要这个结果，重新跑一次；如果它会跑很久，改用 `start_job`。"
            )
            return ToolResult(callID: callID, status: .error, summary: error.modelFacingText,
                              artifacts: artifacts, metrics: metrics(), error: error)
        }

        if exitCode != 0 {
            let error = ToolError(
                kind: .other,
                modelFacingMessage: "脚本以退出码 \(exitCode) 结束。\n\(budget.preview(text))",
                suggestion: "看上面的输出定位原因；如果是依赖或权限问题，说明你打算怎么绕开。"
            )
            return ToolResult(callID: callID, status: .error, summary: error.modelFacingText,
                              artifacts: artifacts, metrics: metrics(), error: error)
        }

        return ToolResult(callID: callID, status: .ok, summary: summary,
                          artifacts: artifacts, metrics: metrics())
    }

    private func metrics() -> ToolResult.Metrics {
        ToolResult.Metrics(
            wallClockMS: usage.wallClockMS,
            bytesIn: 0,
            bytesOut: usage.outputBytes,
            exitCode: Int(exitCode),
            sandboxInstructions: usage.instructions > 0 ? usage.instructions : nil,
            peakMemoryMB: usage.peakMemoryMB > 0 ? usage.peakMemoryMB : nil
        )
    }
}

// MARK: - 执行器契约

/// 沙箱执行器。真实实现是 CPython / WasmKit / JSC 适配器（都要 macOS）。
public protocol SandboxExecuting: Sendable {
    var runtime: SandboxRuntime { get }
    /// 执行。**实现方必须支持协作式取消**（循环内检查取消标记），
    /// 并如实填 `usage`（限额判定完全依赖它）。
    func run(_ request: SandboxRequest, cancellation: SandboxCancellation) throws -> SandboxResult
}

/// 协作式取消标记。
///
/// ⚠️ 为什么不用 `Task.isCancelled`：沙箱里的执行往往跑在**独立线程**上
/// （CPython 的强杀就是靠"独立执行线程 + 主动中止"），那个线程看不到 Swift 的任务树。
/// 而且限额触发时也需要一个**统一的**"停下来"信号。
public final class SandboxCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var reason: String?

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public var cancellationReason: String? {
        lock.lock(); defer { lock.unlock() }
        return reason
    }

    /// 取消。**幂等，且第一次的原因胜出。**
    ///
    /// ⚠️ 后来的取消不该覆盖先到的原因：真正的取消是"用户按了停止"，
    /// 而清理路径上的第二次 `cancel(reason: "收尾")` 会把那条信息抹掉 ——
    /// 于是用户看到的解释与实际发生的事不符。
    public func cancel(reason: String) {
        lock.lock()
        if !cancelled { cancelled = true; self.reason = reason }
        lock.unlock()
    }

    /// 让实现方在循环里调用它（抛错即中止）
    public func checkCancellation() throws {
        if isCancelled {
            throw SandboxAbort.cancelled(reason: cancellationReason ?? "已取消")
        }
    }
}

public enum SandboxAbort: Error, Sendable, CustomStringConvertible {
    case cancelled(reason: String)
    case limitExceeded(SandboxViolation)

    public var description: String {
        switch self {
        case .cancelled(let reason): return "已取消：\(reason)"
        case .limitExceeded(let violation): return violation.description
        }
    }
}

// MARK: - 沙箱路由

/// 把"要跑一段代码"这件事路由到正确的执行器。
///
/// ⚠️ 它做三件**必须集中做**的事（分散到各工具里一定会漏）：
///   1. **来源分级**决定隔离强度（模型生成的走 WASM）；
///   2. **限额**按运行时给默认值，并按设备内存收敛；
///   3. **输出纪律**统一在这一层落。
public struct SandboxRouter: Sendable {
    public var executors: [SandboxRuntime: any SandboxExecuting]
    /// 设备物理内存（MB）—— 用来把限额收敛到物理可行的范围
    public var deviceMemoryMB: Int

    public init(executors: [SandboxRuntime: any SandboxExecuting], deviceMemoryMB: Int = 4_096) {
        self.executors = executors
        self.deviceMemoryMB = max(512, deviceMemoryMB)
    }

    public struct Routing: Sendable {
        public var selection: SandboxSelection
        public var limits: SandboxLimits
        /// 原本想要的运行时被降级了（UI 要告诉用户）
        public var wasDowngraded: Bool
        public var notes: [String]
    }

    /// 决定这次该用哪个环境、给多少额度（**不执行**）
    public func route(_ request: SandboxRequest) -> Routing {
        var notes: [String] = []
        let selection = SandboxPolicy.select(provenance: request.provenance, runtime: request.runtime)
        var limits = request.limits

        var wasDowngraded = false
        if selection.runtime != request.runtime {
            wasDowngraded = true
            limits = SandboxLimits.defaults(for: selection.runtime)
            notes.append("原本请求 \(request.runtime.displayName)，按来源分级改用 \(selection.runtime.displayName)。")
        }

        // ⚠️ 限额必须**收敛到设备物理内存之内**：
        //    在 4GB 设备上给 2GB 的沙箱额度，结果不是"脚本被限额拦住"，
        //    而是**整个 App 被 iOS 杀掉** —— 那比限额失败糟得多。
        if !limits.isAchievable(onDeviceMemoryMB: deviceMemoryMB) {
            // ⚠️ 上限只有一份实现（`memoryCap`）—— 两处各写一遍一定会分叉
            let capped = SandboxLimits.memoryCap(onDeviceMemoryMB: deviceMemoryMB)
            notes.append("内存额度从 \(limits.memoryMB)MB 收敛到 \(capped)MB（设备物理内存 \(deviceMemoryMB)MB）。")
            limits.memoryMB = capped
        }

        if !selection.requiresApproval, request.provenance == .modelGenerated {
            notes.append("注意：模型生成的代码本应需要确认，这里被放行了。")
        }
        return Routing(selection: selection, limits: limits, wasDowngraded: wasDowngraded, notes: notes)
    }

    /// 执行（路由 + 限额判定 + 输出纪律一次做完）
    public func execute(_ request: SandboxRequest, cancellation: SandboxCancellation = SandboxCancellation()) -> SandboxResult {
        let routing = route(request)
        guard let executor = executors[routing.selection.runtime] else {
            return SandboxResult(
                exitCode: 127,
                stderr: Data("这台设备上没有 \(routing.selection.runtime.displayName) 的执行环境。".utf8)
            )
        }
        var effective = request
        effective.limits = routing.limits
        effective.runtime = routing.selection.runtime

        do {
            var result = try executor.run(effective, cancellation: cancellation)
            // 限额判定在**这一层**统一做（执行器只管如实上报用量）
            if result.violation == nil, let violation = routing.limits.violation(for: result.usage) {
                result.violation = violation
                result.exitCode = result.exitCode == 0 ? 137 : result.exitCode
            }
            return result
        } catch let abort as SandboxAbort {
            switch abort {
            case .cancelled(let reason):
                return SandboxResult(exitCode: 130, stderr: Data("已取消：\(reason)".utf8), wasCancelled: true)
            case .limitExceeded(let violation):
                return SandboxResult(exitCode: 137, violation: violation)
            }
        } catch {
            return SandboxResult(
                exitCode: 1,
                stderr: Data("执行器异常：\(error)".utf8),
                usage: SandboxUsage()
            )
        }
    }
}

