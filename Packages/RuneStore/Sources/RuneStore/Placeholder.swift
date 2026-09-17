// RuneStore —— 事件日志（唯一真相源）、哈希链落盘、检查点、迁移、成本账本
//
// 📄 设计依据：docs/12-数据模型与持久化.md
// 🖥 平台：需 macOS（GRDB 7.x）
// 📌 状态：⬜ 骨架（尚未实现）
//
// ⚠️ 实现前请先读 PROJECT_STATE.md（续接文档）与上面那份设计文档，
//    不要凭直觉重造已经定好的接口。
//
// 实现清单：
//   [ ] GRDB 建表与迁移（docs/12 §2 的全部 DDL）
//   [ ] EventLog actor（唯一写入入口 + 批量提交）
//   [ ] 哈希链锚点与校验
//   [ ] 检查点 / VFS 快照表
//   [ ] ⚠️ FTS5 必须用 CJK 分词器或 trigram，绝不用 unicode61

// 本文件的作用只是让模块结构就位。实现第一个类型时请删掉它。
enum RuneStorePlaceholder {
    /// 模块自述（供 UI 的"关于"页与开发者面板使用）
    static let moduleSummary = "事件日志（唯一真相源）、哈希链落盘、检查点、迁移、成本账本"
}
