// RuneVM —— WasmKit 沙箱：加载 .wasm、资源限额、强杀、WASI 导入注入
//
// 📄 设计依据：docs/05-工具系统与执行沙箱.md §3.2
// 🖥 平台：需 macOS（WasmKit，要求 iOS 18+）
// 📌 状态：⬜ 骨架（尚未实现）
//
// ⚠️ 实现前请先读 PROJECT_STATE.md（续接文档）与上面那份设计文档，
//    不要凭直觉重造已经定好的接口。
//
// 实现清单：
//   [ ] 模块缓存与实例池化
//   [ ] WASI 导入注入（文件走 VFS，默认不注入 socket）
//   [ ] 资源限额（指令数 / 内存 / 写入 / 时长）与强杀
//   [ ] 确定性执行（同输入同结果，供回放测试）

// 本文件的作用只是让模块结构就位。实现第一个类型时请删掉它。
enum RuneVMPlaceholder {
    /// 模块自述（供 UI 的"关于"页与开发者面板使用）
    static let moduleSummary = "WasmKit 沙箱：加载 .wasm、资源限额、强杀、WASI 导入注入"
}
