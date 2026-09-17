// RuneGateway —— 协议适配（11 族）、ToolCallAssembler、路由降级、缓存记账、密钥注入
//
// 📄 设计依据：docs/06-模型网关与中转站.md
// 🖥 平台：纯逻辑部分 Windows 可测
// 📌 状态：⬜ 骨架（尚未实现）
//
// ⚠️ 实现前请先读 PROJECT_STATE.md（续接文档）与上面那份设计文档，
//    不要凭直觉重造已经定好的接口。
//
// 实现清单：
//   [ ] ⭐ ToolCallAssembler：三种协议形态的参数拼装 + 7 种脏情况
//   [ ] ProviderQuirks 声明式配置（新渠道不改代码）
//   [ ] 缓存经济学记账（写入 1.25× / 读取 0.1× / 省下多少）
//   [ ] 路由策略与降级链（⚠️ 降级必须对用户可见）
//   [ ] Prompt Cache 断点规划（层 1+2 字节稳定）

// 本文件的作用只是让模块结构就位。实现第一个类型时请删掉它。
enum RuneGatewayPlaceholder {
    /// 模块自述（供 UI 的"关于"页与开发者面板使用）
    static let moduleSummary = "协议适配（11 族）、ToolCallAssembler、路由降级、缓存记账、密钥注入"
}
