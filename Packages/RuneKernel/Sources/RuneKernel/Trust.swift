import Foundation

/// 内容来源的信任级。
///
/// 这是对抗提示注入的**结构性基础**（见 docs/09-安全与隐私威胁模型.md §4）：
/// 不是"在提示词里请求模型不要听坏人的话"，而是**让不可信内容在结构上无法成为指令**。
///
/// 规则（写入运行时断言，不靠模型自觉）：
///   R1 只有 `.userInstruction` 与 `.projectInstruction` 可以作为指令
///   R2 污点会传染：由不可信内容派生的动作（URL、命令、路径）继承污点
///   R3 决策类动作（改策略/信任档/凭据/删除工作区）永不由污点来源触发
///   R4 不可信来源不能自动写入长期记忆
///   R5 多跳不衰减：经过 2 次以上模型转换仍保留污点
public enum TrustLevel: String, Sendable, Codable, CaseIterable, Hashable {
    /// 用户本人输入的指令
    case userInstruction
    /// 项目指令文件（RUNE.md / AGENTS.md / CLAUDE.md）—— 用户自己的仓库，半可信
    case projectInstruction
    /// 模型自己生成的输出（可信度中等，但不是指令）
    case modelOutput
    /// 我们自己的原生工具返回的结构化结果（如 git status）
    case toolResultTrusted
    /// 网页、issue、克隆来的仓库文件、邮件、PDF、MCP 返回、图片 OCR
    case untrustedContent

    /// 是否**可以**作为指令被执行。
    public var isInstruction: Bool {
        switch self {
        case .userInstruction, .projectInstruction: return true
        case .modelOutput, .toolResultTrusted, .untrustedContent: return false
        }
    }

    /// 是否携带污点（需要触发附加确认、不可自动入库）。
    public var isTainted: Bool { self == .untrustedContent }

    /// 是否可用于触发"人类专属区"之外的危险动作。
    ///
    /// 人类专属区（策略文件、信任档、凭据、审计日志）**任何**来源都不可写；
    /// 而"推送/外发/删除"这类高危动作，模型输出可以**提议**，但不可信内容不可以**直接驱动**。
    public var canDriveDangerousAction: Bool {
        self != .untrustedContent
    }

    /// 序列化给模型看时的边界标签。见 docs/09 §4.3。
    public var boundaryTag: String {
        switch self {
        case .userInstruction: return "user"
        case .projectInstruction: return "project"
        case .modelOutput: return "model"
        case .toolResultTrusted: return "tool"
        case .untrustedContent: return "untrusted"
        }
    }
}

/// 人类专属区域：**工具层永远不可写**。
///
/// 设计依据（docs/04-Agent运行时核心.md §12.3）：Agent 不能给自己提权。
/// 任何对这些目标的写入尝试都必须被拒绝、记录为安全事件、并把拒绝理由回灌给模型。
public enum HumanOnlyZone: String, Sendable, Codable, CaseIterable, Hashable {
    /// 能力策略文件（rune.policy.toml）
    case policyFile
    /// 信任刻度盘档位
    case trustDial
    /// 凭据与 API Key
    case credentials
    /// 审计日志与出口记录
    case auditLog
    /// 安全事件记录
    case securityEvents
    /// 事件日志的哈希锚点
    case hashAnchors

    public var denialReason: String {
        switch self {
        case .policyFile:     return "策略文件属于人类专属区域：Agent 不能修改自己的权限配置。请让用户手动修改，或说明为什么需要放宽。"
        case .trustDial:      return "信任级别属于人类专属区域：Agent 不能为自己提权。请在回复中说明为什么需要更高的信任档，由用户决定。"
        case .credentials:    return "凭据属于人类专属区域：Agent 不能读写 API Key 或 Git 凭据。"
        case .auditLog:       return "审计日志属于人类专属区域：Agent 不能修改出口记录与安全事件。"
        case .securityEvents: return "安全事件记录属于人类专属区域：Agent 不能修改。"
        case .hashAnchors:    return "事件日志锚点属于人类专属区域：Agent 不能修改校验链。"
        }
    }
}

/// 一次"污点传播"的记录：说明某个派生值为什么不可信。
///
/// 用途：当一个 URL / 路径 / 命令是从不可信内容里提取出来的，它必须携带来源，
/// 走到出口检查或执行检查时触发附加确认（docs/09 §4.2 R2）。
public struct TaintOrigin: Sendable, Codable, Hashable {
    /// 例如 "web:https://example.com/issue/42"、"repo-file:README.md@a1b2c3"
    public let source: String
    /// 抓取时间
    public let fetchedAt: Date
    /// 备注（例如"来自你克隆的仓库，非用户本人所写"）
    public let note: String?

    public init(source: String, fetchedAt: Date, note: String? = nil) {
        self.source = source
        self.fetchedAt = fetchedAt
        self.note = note
    }
}
