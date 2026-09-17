// RuneBench —— VFS（唯一文件入口）、写时复制快照、原生 CPython 垫片、自研 shell 命令表
//
// 📄 设计依据：docs/05-工具系统与执行沙箱.md §3–§4
// 🖥 平台：需 macOS（VFS + iOS 文件系统）
// 📌 状态：⬜ 骨架（尚未实现）
//
// ⚠️ 实现前请先读 PROJECT_STATE.md（续接文档）与上面那份设计文档，
//    不要凭直觉重造已经定好的接口。
//
// 实现清单：
//   [ ] VFS：挂载、路径规范化、原子写、忽略清单
//   [ ] 快照与回滚（APFS clonefile，回退写前日志）
//   [ ] security-scoped bookmark 的 RAII 包装（⚠️ stop 必须配对）
//   [ ] 原生 CPython 集成 + no-fork 垫片（subprocess/os.system/os.fork 全拦截）
//   [ ] 自研命令解释器（命令表 → 原生实现 / WASM 模块，无 fork/exec）

// 本文件的作用只是让模块结构就位。实现第一个类型时请删掉它。
enum RuneBenchPlaceholder {
    /// 模块自述（供 UI 的"关于"页与开发者面板使用）
    static let moduleSummary = "VFS（唯一文件入口）、写时复制快照、原生 CPython 垫片、自研 shell 命令表"
}
