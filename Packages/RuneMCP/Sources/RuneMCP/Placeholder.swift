// RuneMCP —— MCP 客户端（HTTP）与 MCP 服务端（把手机当桌面 Agent 的工具箱）
//
// 📄 设计依据：docs/04-Agent运行时核心.md §11
// 🖥 平台：部分可测
// 📌 状态：⬜ 骨架（尚未实现）
//
// ⚠️ 实现前请先读 PROJECT_STATE.md（续接文档）与上面那份设计文档，
//    不要凭直觉重造已经定好的接口。
//
// 实现清单：
//   [ ] MCP 客户端：连接管理、工具命名空间隔离、信任分级
//   [ ] 工具爆炸防护（单 server 只暴露 Top-N + 按需检索）
//   [ ] MCP 服务端：暴露相机 / 相册 / 位置 / 通知 / 剪贴板 / rune.run
//   [ ] 配对（局域网 mDNS + 配对码）

// 本文件的作用只是让模块结构就位。实现第一个类型时请删掉它。
enum RuneMCPPlaceholder {
    /// 模块自述（供 UI 的"关于"页与开发者面板使用）
    static let moduleSummary = "MCP 客户端（HTTP）与 MCP 服务端（把手机当桌面 Agent 的工具箱）"
}
