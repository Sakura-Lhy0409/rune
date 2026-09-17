import Foundation

// MARK: - 历史消息的"按协议族分组"
//
// ## 为什么必须有这么一层
//
// 三家的要求是**相反**的：
//
//   OpenAI Chat  每个工具结果**必须各自一条** `{role:"tool", tool_call_id}` 消息。
//                合成一条会让第二个及之后的 id 找不到宿主 → 400。
//   Anthropic    工具结果要放在 **user** 消息里的 `tool_result` 块；多条合成一条是惯例
//   Gemini       `contents` **必须 user/model 交替**。相邻同角色直接 INVALID_ARGUMENT
//
// 而运行时里的历史是「**一个工具结果一条 `.tool` 消息**」——因为 OpenAI 要求那样。
// 于是同一份历史，三种协议，三种分组规则。
//
// ⚠️ **分组规则属于协议，不属于运行时。**
//    让运行时只写一条来迁就 Anthropic/Gemini，OpenAI 就错了；
//    让运行时写多条来迁就 OpenAI，Anthropic/Gemini 就错了。
//    更不能指望"服务端会帮我合并"：Gemini 那条**用户第一次用就会炸**，
//    而这是一种只要写测试就能提前抓到的错。
//
// ## 这一层抓到的三个真 bug（M1-17）
//
//   ① Gemini 历史里出现相邻同角色 `contents`（运行时的 `.tool` 消息 + 运行时的引导语
//      `injectGuidance` 也是 `.user`）→ INVALID_ARGUMENT
//   ② Gemini 的 `functionResponse.name` 被硬编码成 `"tool"` —— 与 `functionDeclarations`
//      里声明的函数名对不上（新版 API 对"函数响应与调用不匹配"会直接报错）
//   ③ Anthropic 的失败工具结果没有 `is_error: true` → 模型把"权限被拒"当成一次成功输出

/// 一个协议族怎么把历史切成"条目"
public enum HistoryGrouping: Sendable, Hashable {
    /// 一条消息一条条目（OpenAI 系：`tool` 消息**不能**合并）
    case perMessage
    /// 相邻同角色合成一条（Anthropic / Gemini）
    case adjacentSameRole

    /// ⚠️ 默认分支给 `.perMessage`：**少合并**最多是少一层优化，
    ///    而**多合并**会让 id 配不上，是不可恢复的 400。
    public static func forFamily(_ family: ProtocolFamily) -> HistoryGrouping {
        switch family {
        case .anthropicMessages, .geminiGenerate, .geminiInteractions: return .adjacentSameRole
        case .openAIChat, .openAIResponses, .custom, .ollamaNative: return .perMessage
        }
    }
}

public enum MessageGrouping {

    /// 该协议族下的**有效角色** —— 决定相邻两条能不能合成一条。
    ///
    /// Anthropic 与 Gemini 都只有"我方 / 模型方"两种角色，所以 `.tool` 与 `.user`
    /// 在这里是**同一个**角色（这正是"必须合并"的来源）。
    public static func effectiveRole(_ role: Role, family: ProtocolFamily) -> String {
        switch family {
        case .anthropicMessages:
            return role == .assistant ? "assistant" : "user"
        case .geminiGenerate, .geminiInteractions:
            // Gemini 只有 user / model
            return role == .assistant ? "model" : "user"
        default:
            return role.rawValue
        }
    }

    /// 按协议族的规则处理条目 —— **编码器只走这一个入口**。
    ///
    /// ⚠️ 这个入口存在的理由是一次真实的教训：规则表一开始只被测试用到，
    ///    编码器各自无条件调 `merge` —— 于是「表里写着不合并」和「实际行为」是两回事，
    ///    而**规则表那几条断言还照样全绿**（它们在测表，不在测行为）。
    ///    把规则表变成编码器的必经之路，它才是契约而不是文档。
    public static func applying(
        _ family: ProtocolFamily,
        to entries: [(role: String, payload: [JSONValue])]
    ) -> [(role: String, payload: [JSONValue])] {
        HistoryGrouping.forFamily(family) == .adjacentSameRole ? merge(entries) : entries
    }

    /// 把一个"每条消息各自算好内容"的序列，按协议族规则合并。
    ///
    /// ⚠️ **先丢掉空条目，再合并。** 反过来的话会出现这个链条：
    ///    空条目把两个同角色消息**隔开** → 合并没发生 → 空条目自己又被丢掉
    ///    → 剩下的两条变成相邻同角色 → Gemini 报 INVALID_ARGUMENT。
    ///    （真实触发路径：assistant 消息里只有缺 signature 的 thinking 块时，
    ///      Anthropic 编码器会保守地不回传它，于是那条消息整体为空。）
    public static func merge(
        _ entries: [(role: String, payload: [JSONValue])]
    ) -> [(role: String, payload: [JSONValue])] {
        var out: [(role: String, payload: [JSONValue])] = []
        for entry in entries {
            guard !entry.payload.isEmpty else { continue }
            if let last = out.last, last.role == entry.role {
                out[out.count - 1].payload += entry.payload
            } else {
                out.append(entry)
            }
        }
        return out
    }

    /// 历史里每个工具调用 id → 工具名。
    ///
    /// 为什么需要它：`ToolResult` 只带 `callID`，**不带工具名**，
    /// 而 Gemini 的 `functionResponse` 要用名字与 `functionCall` 对上。
    /// 名字只能从配对的 assistant 消息里 `toolCall` 找回来 ——
    /// 这也正好是"每个 toolCall 必须有配对结果"（T18）那条不变式的另一面。
    public static func toolNames(in messages: [Message]) -> [String: String] {
        var names: [String: String] = [:]
        for message in messages {
            for block in message.blocks {
                if let call = block.toolCallValue { names[call.id] = call.name }
            }
        }
        return names
    }
}

// MARK: - 合并时的信任级

extension TrustLevel {
    /// 合并相邻消息时取哪个信任级：**取更保守的那个**。
    ///
    /// ⚠️ 这条规则的安全含义是「**合并永不提权**」。
    ///    实际会发生的两种合并：
    ///      `.toolResultTrusted + .toolResultTrusted` → 还是 toolResultTrusted
    ///      `.toolResultTrusted + .runtimeGuidance`   → runtimeGuidance
    ///    第二种是关键的：运行时的引导语（如"上次参数错了，注意 X"）如果因为合并
    ///    被提升成 `userInstruction`，那就等于**运行时可以借用户的口气下命令** ——
    ///    而那正是 `TrustLevel` 整个设计要挡住的事。
    public static func mostConservative(_ a: TrustLevel, _ b: TrustLevel) -> TrustLevel {
        rank(a) <= rank(b) ? a : b
    }

    /// 越小越不可信。顺序不是审美问题：它决定上面那条"永不提权"成不成立。
    private static func rank(_ level: TrustLevel) -> Int {
        switch level {
        case .untrustedContent:  return 0
        case .runtimeGuidance:   return 1
        case .toolResultTrusted: return 2
        case .modelOutput:       return 3
        case .projectInstruction: return 4
        case .userInstruction:   return 5
        }
    }
}
