// RuneCore —— AgentRuntime：Turn 状态机、规划、工具调度、审批、Goal / Job / Workflow / Subagent / Skill / Hook
//
// 📄 设计依据：docs/04-Agent运行时核心.md
// 🖥 平台：需 macOS（含 iOS 生命周期）
// 📌 状态：⬜ 骨架（尚未实现）
//
// ⚠️ 实现前请先读 PROJECT_STATE.md（续接文档）与上面那份设计文档，
//    不要凭直觉重造已经定好的接口。
//
// 实现清单：
//   [ ] Turn 状态机 + 幂等重放（三步落盘协议）
//   [ ] PolicyEngine（能力令牌 + 人类专属区 + 污点规则）
//   [ ] ToolScheduler（并行分桶 + 冲突检测 + 预算）
//   [ ] GoalEngine（跨轮推进 + 阻塞纪律）
//   [ ] JobEngine 与 ContinuationScheduler（BGContinuedProcessingTask）
//   [ ] WorkflowEngine（JavaScriptCore）与 SubagentPool

// 本文件的作用只是让模块结构就位。实现第一个类型时请删掉它。
enum RuneCorePlaceholder {
    /// 模块自述（供 UI 的"关于"页与开发者面板使用）
    static let moduleSummary = "AgentRuntime：Turn 状态机、规划、工具调度、审批、Goal / Job / Workflow / Subagent / Skill / Hook"
}
