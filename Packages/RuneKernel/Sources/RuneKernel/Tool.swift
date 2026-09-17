import Foundation

// MARK: - 工具调用

/// 一次工具调用。**注意 `argumentsJSON` 是原始 JSON**（延迟解码）：
/// 部分厂商会流式吐半成品参数，过早解码会失败；schema 校验在调度器里做（以便回灌精确的错误）。
public struct ToolCall: Sendable, Codable, Hashable, Identifiable {
    /// provider 侧 id —— **跨轮引用必需**（例如 Anthropic 的 `tool_use_id`）
    public let id: String
    public let name: String
    public let argumentsJSON: Data
    /// 该调用是由哪个 index 拼装出来的（用于诊断流式拼装问题）
    public let sourceIndex: Int?

    public init(id: String, name: String, argumentsJSON: Data, sourceIndex: Int? = nil) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.sourceIndex = sourceIndex
    }

    /// 解析参数。失败时抛出**带位置**的错误，供"修正性重试"回灌给模型。
    public func arguments() throws -> JSONValue {
        try JSONValue.parse(argumentsJSON)
    }

    public var argumentsPreview: String {
        let s = String(decoding: argumentsJSON, as: UTF8.self)
        return s.count > 200 ? String(s.prefix(200)) + "…" : s
    }
}

// MARK: - 工具结果

/// 工具执行结果。
///
/// 设计要点（docs/03 §4.2）：**工具结果永不完整回灌上下文**。
/// `summary` 给模型看（受预算约束），全文进 `artifacts`，模型按需 `read_artifact`。
public struct ToolResult: Sendable, Codable, Hashable {
    public enum Status: String, Sendable, Codable, Hashable {
        case ok
        case error
        /// 被策略拒绝（**不是错误**，是设计上的拦截；理由要回灌给模型让它换方案）
        case denied
        case timeout
        /// 被截断（内容过大，已转制品）
        case truncated
    }

    public let callID: String
    public let status: Status
    /// 给模型看的压缩文本（≤ 预算）
    public let summary: String
    /// 全文另存
    public let artifacts: [ArtifactRef]
    public let metrics: Metrics
    /// 结构化错误（status != .ok 时非空）——用于"修正性重试"
    public let error: ToolError?

    public init(
        callID: String,
        status: Status,
        summary: String,
        artifacts: [ArtifactRef] = [],
        metrics: Metrics = .init(),
        error: ToolError? = nil
    ) {
        self.callID = callID
        self.status = status
        self.summary = summary
        self.artifacts = artifacts
        self.metrics = metrics
        self.error = error
    }

    public struct Metrics: Sendable, Codable, Hashable {
        public var wallClockMS: Int
        public var bytesIn: Int
        public var bytesOut: Int
        public var exitCode: Int?
        /// CPU 指令数（WASM 沙箱）/ 峰值内存（MB）等资源计量
        public var sandboxInstructions: UInt64?
        public var peakMemoryMB: Int?

        public init(
            wallClockMS: Int = 0,
            bytesIn: Int = 0,
            bytesOut: Int = 0,
            exitCode: Int? = nil,
            sandboxInstructions: UInt64? = nil,
            peakMemoryMB: Int? = nil
        ) {
            self.wallClockMS = wallClockMS
            self.bytesIn = bytesIn
            self.bytesOut = bytesOut
            self.exitCode = exitCode
            self.sandboxInstructions = sandboxInstructions
            self.peakMemoryMB = peakMemoryMB
        }
    }

    public static func ok(callID: String, summary: String, artifacts: [ArtifactRef] = [], metrics: Metrics = .init()) -> ToolResult {
        ToolResult(callID: callID, status: .ok, summary: summary, artifacts: artifacts, metrics: metrics)
    }

    public static func failure(callID: String, error: ToolError) -> ToolResult {
        // ⚠️ 必须用 `modelFacingText`（含建议与候选）而不是 `modelFacingMessage`：
        //    `summary` 是**唯一**会被发给模型的字段（见 ProtocolEncoders），
        //    只送 message 等于把 `suggestion` / `candidates` 直接丢掉 ——
        //    那样「修正性重试」整条设计就是空转的。
        ToolResult(callID: callID, status: .error, summary: error.modelFacingText, error: error)
    }
}

// MARK: - 工具错误（结构化，供模型自我修正）

/// 工具失败的**结构化**描述。
///
/// 设计依据（docs/04 §4.4 "修正性重试"）：这三类高频错误必须由运行时主动救，
/// 而不是直接失败——这是"长任务成功率"从"看模型运气"变成"看工程质量"的关键。
public struct ToolError: Sendable, Codable, Hashable, Error {
    public enum Kind: String, Sendable, Codable, Hashable {
        /// 参数不合 schema → 回灌精确校验错误，让模型重发（最多 2 次）
        case invalidArguments
        /// 工具名幻觉 → 给出最接近的可用工具名
        case unknownTool
        /// 路径不存在 → 给出相似路径候选
        case pathNotFound
        /// 越权（路径/出口/能力）→ **不重试**，明确拒绝理由
        case capabilityDenied
        /// 命中人类专属区 → 记录安全事件
        case humanOnlyZone
        /// 沙箱崩溃/超时/超限
        case sandboxFailure
        /// 网络失败
        case networkFailure
        /// 输出过大已转制品（**不是失败**，但模型要知道去哪读）
        case outputTooLarge
        case other
    }

    public let kind: Kind
    /// 给模型看的详细原因（可以是英文，模型读起来无差别；但建议与用户界面语言一致）
    public let modelFacingMessage: String
    /// **建议的下一步**（这条最有价值：把"失败"变成"可执行的纠正"）
    public let suggestion: String?
    /// 候选（相似路径、最接近的工具名等）
    public let candidates: [String]

    public init(
        kind: Kind,
        modelFacingMessage: String,
        suggestion: String? = nil,
        candidates: [String] = []
    ) {
        self.kind = kind
        self.modelFacingMessage = modelFacingMessage
        self.suggestion = suggestion
        self.candidates = candidates
    }

    /// **真正回灌给模型**的完整错误文本。
    ///
    /// ⚠️ 这个属性存在的唯一理由是修一个「看着像做了、其实全丢了」的洞：
    /// 三家协议编码器都只发 `ToolResult.summary`，而 `summary` 原先只填了
    /// `modelFacingMessage` —— 于是模型看到的永远是「参数不合 schema」，
    /// 既看不到**错在哪个字段**，也看不到我们辛苦算出来的最接近工具名与相似路径候选。
    /// 结果是：设计文档里写得很漂亮的「修正性重试」，实际退化成"让模型再猜一次"。
    ///
    /// `suggestion` 与 `candidates` 是运行时**确定知道**的信息（schema、真实目录、工具表），
    /// 把它们送到模型面前，是"把长任务成功率从看运气变成看工程质量"最便宜的一步。
    public var modelFacingText: String {
        var lines = [modelFacingMessage]
        if let suggestion, !suggestion.isEmpty { lines.append("👉 \(suggestion)") }
        if !candidates.isEmpty { lines.append("候选：\(candidates.joined(separator: "、"))") }
        return lines.joined(separator: "\n")
    }

    /// 是否值得让模型自己改一次参数再试
    public var isSelfCorrectable: Bool {
        switch kind {
        case .invalidArguments, .unknownTool, .pathNotFound, .outputTooLarge: return true
        case .capabilityDenied, .humanOnlyZone, .sandboxFailure, .networkFailure, .other: return false
        }
    }
}

// MARK: - 工具规格

public struct ToolSpec: Sendable, Codable, Hashable {
    public let name: String
    /// 给模型看的描述。**必须回答四个问题**（docs/05 §... ）：
    ///   做什么 / 何时用 / **何时不要用** / 一个最小示例
    /// 实测经验："何时不要用"这一条比任何系统提示词优化都更能降低误调用率。
    public let description: String
    public let inputSchema: JSONSchema
    public let concurrency: Concurrency
    public let isIdempotent: Bool
    public let riskLevel: RiskLevel
    public let needsApproval: ApprovalPolicy
    public let outputShape: OutputShape
    /// 声明所需能力（策略引擎据此判定，**不允许运行时偷偷访问**）
    public let requirements: Set<CapabilityKind>

    public init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        concurrency: Concurrency = .parallelSafe,
        isIdempotent: Bool = true,
        riskLevel: RiskLevel = .safe,
        needsApproval: ApprovalPolicy = .never,
        outputShape: OutputShape = .inline(maxBytes: 8 * 1024),
        requirements: Set<CapabilityKind> = []
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.concurrency = concurrency
        self.isIdempotent = isIdempotent
        self.riskLevel = riskLevel
        self.needsApproval = needsApproval
        self.outputShape = outputShape
        self.requirements = requirements
    }

    public enum Concurrency: String, Sendable, Codable, Hashable {
        /// 可以与其他工具并行（只读类）
        case parallelSafe
        /// 写同一路径的必须串行
        case serialPerPath
        /// 独占（例如重建索引）
        case exclusive
    }

    /// 风险等级 → 决定审批方式（docs/08 §5.3）
    public enum RiskLevel: String, Sendable, Codable, Hashable, CaseIterable {
        case safe
        /// 修改类（写文件、本地提交）
        case modifying
        /// 危险（推送、外发、删除）
        case dangerous
        /// 不可逆（支付、凭据变更）
        case irreversible

        /// 是否必须人工确认（不可被策略静默放行）
        public var alwaysRequiresHuman: Bool {
            self == .dangerous || self == .irreversible
        }

        /// 是否需要生物识别
        public var requiresBiometric: Bool { self == .irreversible }
    }

    public enum ApprovalPolicy: String, Sendable, Codable, Hashable {
        case never
        /// 每个项目第一次确认，之后记住
        case perProject
        case always
        case biometric
    }

    public enum OutputShape: Sendable, Codable, Hashable {
        /// 小输出直接内联
        case inline(maxBytes: Int)
        /// 超过阈值转制品
        case artifact(threshold: Int)
    }
}

/// 工具实现所需的**能力种类**（不是具体范围——具体范围在能力令牌里）。
public enum CapabilityKind: String, Sendable, Codable, Hashable, CaseIterable {
    case fsRead
    case fsWrite
    case fsDelete
    /// 执行脚本（python / javascript / shell / wasm）
    case exec
    /// 网络出口
    case egress
    /// iOS 原生能力（相册/日历/定位/…）
    case native
    /// MCP 外部工具
    case mcp
    /// Git 写操作（提交/推送）
    case gitWrite
    /// 修改人类专属区（**任何工具都不应声明此项**，声明即拒绝注册）
    case humanOnly
}

// MARK: - JSON Schema（最小可用子集）

/// 工具参数的 schema。**只支持模型真正需要的子集**（见 docs/06 附录 A §9 的 schema 约束），
/// 不做完整 JSON Schema 实现——完整性在这里没有收益，可校验性才有。
public indirect enum JSONSchema: Sendable, Codable, Hashable {
    case object(properties: [String: JSONSchema], required: [String], additionalProperties: Bool)
    case array(items: JSONSchema, minItems: Int?, maxItems: Int?)
    case string(enumValues: [String]?, minLength: Int?, maxLength: Int?)
    case integer(minimum: Int?, maximum: Int?)
    case number(minimum: Double?, maximum: Double?)
    case boolean
    /// 任意 JSON（用于透传类参数）
    case any

    /// 生成给模型看的 schema JSON
    public func jsonSchemaValue() -> JSONValue {
        switch self {
        case .object(let props, let required, let additional):
            var dict: [String: JSONValue] = [
                "type": "object",
                "properties": .object(props.mapValues { $0.jsonSchemaValue() }),
                "additionalProperties": .bool(additional),
            ]
            if !required.isEmpty {
                dict["required"] = .array(required.sorted().map { .string($0) })
            }
            return .object(dict)
        case .array(let items, let minItems, let maxItems):
            var dict: [String: JSONValue] = [
                "type": "array",
                "items": items.jsonSchemaValue(),
            ]
            if let minItems { dict["minItems"] = .int(minItems) }
            if let maxItems { dict["maxItems"] = .int(maxItems) }
            return .object(dict)
        case .string(let enumValues, let minLength, let maxLength):
            var dict: [String: JSONValue] = ["type": "string"]
            if let enumValues { dict["enum"] = .array(enumValues.map { .string($0) }) }
            if let minLength { dict["minLength"] = .int(minLength) }
            if let maxLength { dict["maxLength"] = .int(maxLength) }
            return .object(dict)
        case .integer(let minimum, let maximum):
            var dict: [String: JSONValue] = ["type": "integer"]
            if let minimum { dict["minimum"] = .int(minimum) }
            if let maximum { dict["maximum"] = .int(maximum) }
            return .object(dict)
        case .number(let minimum, let maximum):
            var dict: [String: JSONValue] = ["type": "number"]
            if let minimum { dict["minimum"] = .double(minimum) }
            if let maximum { dict["maximum"] = .double(maximum) }
            return .object(dict)
        case .boolean:
            return .object(["type": "boolean"])
        case .any:
            return .object([:])
        }
    }
}

// MARK: - 内置工具名（避免拼写错误）
//
// ⚠️ 这里是**唯一**的工具名真相源。任何地方都不要写字符串字面量工具名。
// 新增工具时必须同时在此登记，并更新 docs/05 §2 的工具目录表。

public enum ToolName {
    // 文件与工作区
    public static let listDir = "list_dir"
    public static let readFile = "read_file"
    public static let readArtifact = "read_artifact"
    public static let writeFile = "write_file"
    public static let editFile = "edit_file"
    public static let applyPatch = "apply_patch"
    public static let deletePath = "delete_path"
    public static let movePath = "move_path"
    public static let copyPath = "copy_path"
    public static let statPath = "stat_path"
    public static let makeDir = "make_dir"
    public static let setWorkspace = "set_workspace"

    // 检索
    public static let glob = "glob"
    public static let grepSearch = "grep_search"
    public static let findSymbol = "find_symbol"
    public static let semanticSearch = "semantic_search"
    public static let outlineFile = "outline_file"

    // 执行
    public static let runPython = "run_python"
    public static let runJavaScript = "run_javascript"
    public static let runShell = "run_shell"
    public static let runWasm = "run_wasm"
    public static let runTests = "run_tests"
    public static let runBuild = "run_build"
    public static let startJob = "start_job"
    public static let jobStatus = "job_status"
    public static let jobOutput = "job_output"
    public static let jobKill = "job_kill"
    public static let sandboxSnapshot = "sandbox_snapshot"
    public static let sandboxRestore = "sandbox_restore"

    // Git
    public static let gitStatus = "git_status"
    public static let gitDiff = "git_diff"
    public static let gitLog = "git_log"
    public static let gitShow = "git_show"
    public static let gitAdd = "git_add"
    public static let gitCommit = "git_commit"
    public static let gitBranch = "git_branch"
    public static let gitCheckout = "git_checkout"
    public static let gitStash = "git_stash"
    public static let gitClone = "git_clone"
    public static let gitFetch = "git_fetch"
    public static let gitPull = "git_pull"
    public static let gitPush = "git_push"
    public static let createPullRequest = "create_pull_request"

    // 网络
    public static let fetchURL = "fetch_url"
    public static let searchWeb = "search_web"
    public static let httpRequest = "http_request"
    public static let downloadFile = "download_file"
    public static let openURL = "open_url"

    // 数据
    public static let readTable = "read_table"
    public static let writeTable = "write_table"
    public static let readPDF = "read_pdf"
    public static let readDocx = "read_docx"
    public static let readPptx = "read_pptx"
    public static let imageResize = "image_resize"
    public static let imageConvert = "image_convert"
    public static let ocrImage = "ocr_image"
    public static let describeImage = "describe_image"
    public static let renderChart = "render_chart"
    public static let hashFile = "hash_file"

    // iOS 原生能力
    public static let photosSearch = "photos_search"
    public static let cameraCapture = "camera_capture"
    public static let calendarRead = "calendar_read"
    public static let calendarWrite = "calendar_write"
    public static let remindersRead = "reminders_read"
    public static let remindersWrite = "reminders_write"
    public static let locationCurrent = "location_current"
    public static let clipboardRead = "clipboard_read"
    public static let clipboardWrite = "clipboard_write"
    public static let speechTranscribe = "speech_transcribe"
    public static let notifyUser = "notify_user"
    public static let shortcutsRun = "shortcuts_run"

    // 编排与元工具
    public static let todoWrite = "todo_write"
    public static let useSkill = "use_skill"
    public static let searchSkills = "search_skills"
    public static let spawnSubagent = "spawn_subagent"
    public static let sendSubagentMessage = "send_subagent_message"
    public static let interruptSubagent = "interrupt_subagent"
    public static let createGoal = "create_goal"
    public static let updateGoal = "update_goal"
    public static let getGoalTool = "get_goal"
    public static let runWorkflow = "run_workflow"
    public static let askUser = "ask_user"
    public static let returnFile = "return_file"
    public static let memorySave = "memory_save"
    public static let memorySearch = "memory_search"
    public static let memoryReflect = "memory_reflect"
}
