import Foundation

/// Rune 的统一错误模型。
///
/// 分类的**唯一目的**是决定"谁来处理"（docs/03 §7）：
/// 自动重试 / 暂停存检查点 / 直接拒绝 / 请求审批 / 让模型自我修正 / 引导修复 / 静默。
///
/// 规则：**`model` 类错误至少要给模型一次自我修正的机会**（回灌 schema 校验错误），
/// 这是长任务成功率的关键差异之一——桌面 Agent 常常在这里直接放弃。
public enum RuneError: Error, Sendable, CustomStringConvertible {
    /// 网络抖动、429、5xx、超时 → GatewayRouter 自动重试/降级
    case transient(message: String, retryAfterSeconds: Int?)
    /// token 超预算、电量低、成本熔断 → Runtime 暂停 Turn 并存检查点
    case budget(reason: String, suggestion: BudgetSuggestion)
    /// 越权访问、出口被拒、无授权目录 → PolicyEngine 直接拒绝（不重试）
    case capability(message: String, suggestion: String?)
    /// 需要用户确认
    case approval(reason: String, risk: ToolSpec.RiskLevel)
    /// 脚本崩溃、超时、内存超限
    case sandbox(kind: SandboxFailureKind, detail: String)
    /// 模型拒绝、工具名幻觉、参数不合 schema（可自我修正）
    case model(message: String, isSelfCorrectable: Bool)
    /// 数据库损坏、密钥丢失 → 恢复流程
    case fatal(message: String, recovery: String)
    /// 用户取消（**正常路径，不是错误**，UI 上不该弹错误框）
    case userAbort(partialResult: String?)

    public var description: String {
        switch self {
        case .transient(let m, _):      return "网络波动：\(m)"
        case .budget(let r, _):         return "预算限制：\(r)"
        case .capability(let m, _):     return "权限不足：\(m)"
        case .approval(let r, _):       return "需要确认：\(r)"
        case .sandbox(let k, let d):    return "沙箱失败（\(k.displayName)）：\(d)"
        case .model(let m, _):          return "模型问题：\(m)"
        case .fatal(let m, _):          return "致命错误：\(m)"
        case .userAbort:                return "用户已取消"
        }
    }

    /// 面向用户的一句话（中文，可直接显示在卡片上）
    public var userFacingMessage: String {
        switch self {
        case .transient(let m, let after):
            if let after { return "\(m)（建议 \(after) 秒后重试）" }
            return m
        case .budget(let reason, let suggestion):
            return "\(reason)\n\n\(suggestion.userFacingText)"
        case .capability(let m, let s):
            if let s { return "\(m)\n\n\(s)" }
            return m
        case .approval(let r, _):
            return r
        case .sandbox(let kind, let detail):
            return "\(kind.userFacingText)：\(detail)"
        case .model(let m, _):
            return m
        case .fatal(let m, let recovery):
            return "\(m)\n\n\(recovery)"
        case .userAbort:
            return "已取消"
        }
    }

    /// 是否应该静默处理（不给用户弹任何东西）
    public var isSilent: Bool {
        switch self {
        case .transient: return true
        case .userAbort: return true
        case .model(_, let correctable): return correctable
        default: return false
        }
    }

    public enum SandboxFailureKind: String, Sendable, Codable, Hashable {
        case crashed
        case timedOut
        case memoryExceeded
        case cpuExceeded
        case outputExceeded
        case killed

        public var displayName: String {
            switch self {
            case .crashed: return "崩溃"
            case .timedOut: return "超时"
            case .memoryExceeded: return "内存超限"
            case .cpuExceeded: return "CPU 超限"
            case .outputExceeded: return "输出超限"
            case .killed: return "被强制终止"
            }
        }

        public var userFacingText: String {
            switch self {
            case .crashed: return "脚本异常退出"
            case .timedOut: return "脚本超时已停止"
            case .memoryExceeded: return "脚本占用内存过多已停止"
            case .cpuExceeded: return "脚本运行时间过长已停止"
            case .outputExceeded: return "脚本输出过多已停止"
            case .killed: return "脚本已被终止"
            }
        }
    }

    /// 熔断后的三选一（docs/04 §14：**不要弹报错框，要给可执行的选项**）
    public enum BudgetSuggestion: Sendable, Codable, Hashable {
        /// 提高上限继续
        case raiseLimit(newLimitMicroUSD: Int)
        /// 换成便宜模型继续
        case switchToCheaperModel(estimatedMicroUSD: Int)
        /// 只交付当前成果
        case deliverSoFar

        public var userFacingText: String {
            switch self {
            case .raiseLimit(let micro):
                return String(format: "可以提高到 $%.2f 继续，或只看当前成果。", Double(micro) / 1_000_000)
            case .switchToCheaperModel(let micro):
                return String(format: "也可以换成更便宜的模型继续（预计 $%.2f）。", Double(micro) / 1_000_000)
            case .deliverSoFar:
                return "可以先交付当前已完成的部分。"
            }
        }
    }
}

// MARK: - 结果包装（用于不抛错的路径）

/// 显式的成败包装。用于"失败是预期内的一种结果"的场景（例如工具执行），
/// 避免为了表达失败而滥用 `throws`。
public enum RuneOutcome<Success: Sendable, Failure: Sendable>: Sendable {
    case success(Success)
    case failure(Failure)

    public var successValue: Success? {
        if case .success(let v) = self { return v }
        return nil
    }

    public var failureValue: Failure? {
        if case .failure(let f) = self { return f }
        return nil
    }

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
