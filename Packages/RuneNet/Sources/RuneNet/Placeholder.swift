// RuneNet —— SSE 增量解析、断流重连、重试退避、出口代理（唯一出站点）
//
// 📄 设计依据：docs/06-模型网关与中转站.md §12
// 🖥 平台：需 macOS（URLSession / AsyncBytes）
// 📌 状态：⬜ 骨架（尚未实现）
//
// ⚠️ 实现前请先读 PROJECT_STATE.md（续接文档）与上面那份设计文档，
//    不要凭直觉重造已经定好的接口。
//
// 实现清单：
//   [ ] SSE 增量解析器（容忍注释行 / 心跳 / 跨 chunk 断裂的 UTF-8）
//   [ ] 统一出口代理（含出口白名单校验与审计落库）
//   [ ] 重试退避与 Retry-After 处理
//   [ ] 按渠道的 URLSession 复用与弱网降级

// 本文件的作用只是让模块结构就位。实现第一个类型时请删掉它。
enum RuneNetPlaceholder {
    /// 模块自述（供 UI 的"关于"页与开发者面板使用）
    static let moduleSummary = "SSE 增量解析、断流重连、重试退避、出口代理（唯一出站点）"
}
