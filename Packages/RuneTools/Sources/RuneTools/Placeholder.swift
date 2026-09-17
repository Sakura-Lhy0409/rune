// RuneTools —— 45 个工具的注册表与实现（原生优先，沙箱兜底）
//
// 📄 设计依据：docs/05-工具系统与执行沙箱.md §2
// 🖥 平台：需 macOS
// 📌 状态：⬜ 骨架（尚未实现）
//
// ⚠️ 实现前请先读 PROJECT_STATE.md（续接文档）与上面那份设计文档，
//    不要凭直觉重造已经定好的接口。
//
// 实现清单：
//   [ ] 工具注册表 + ToolSpec 描述规范（含"何时不要用"）
//   [ ] 文件类（read/write/edit/apply_patch/list）
//   [ ] 检索类（glob/grep/semantic/find_symbol）
//   [ ] 执行类（run_python/run_tests/run_build/job_*）
//   [ ] Git 类（libgit2）与网络类（fetch/search/http）
//   [ ] iOS 原生能力类（Photos/Calendar/Camera/Speech/OCR）

// 本文件的作用只是让模块结构就位。实现第一个类型时请删掉它。
enum RuneToolsPlaceholder {
    /// 模块自述（供 UI 的"关于"页与开发者面板使用）
    static let moduleSummary = "45 个工具的注册表与实现（原生优先，沙箱兜底）"
}
