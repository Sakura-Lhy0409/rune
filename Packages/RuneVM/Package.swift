// swift-tools-version: 6.3
import PackageDescription

// RuneVM —— WasmKit 沙箱：加载 .wasm、资源限额、强杀、WASI 导入注入
//
// 📄 设计依据：docs/05-工具系统与执行沙箱.md §3.2
// 🖥 平台：需 macOS（WasmKit，要求 iOS 18+）
// 📌 状态：⬜ 骨架（尚未实现；实现清单见 PROJECT_STATE.md §7）
//
// ⚠️ 本机（Windows）**不要**用 swift build（SwiftPM 在本环境的执行层不可用，
//    见 PROJECT_STATE.md §3）。纯逻辑部分请在 RuneKernel 内实现并用 Tools/rune.ps1 测试；
//    本文件供 macOS 上使用 Xcode / 标准 SwiftPM。
let package = Package(
    name: "RuneVM",
    platforms: [
        .iOS(.v18),      // WasmKit 实际最低要求 iOS 18（docs/附录B §11.1）
        .macOS(.v15),
    ],
    products: [
        .library(name: "RuneVM", targets: ["RuneVM"]),
    ],
    dependencies: [
        .package(path: "../RuneKernel"),
    ],
    targets: [
        .target(
            name: "RuneVM",
            dependencies: ["RuneKernel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
