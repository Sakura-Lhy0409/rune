// swift-tools-version: 6.3
import PackageDescription

// RuneMCP —— MCP 客户端（HTTP）与 MCP 服务端（把手机当桌面 Agent 的工具箱）
//
// 📄 设计依据：docs/04-Agent运行时核心.md §11
// 🖥 平台：部分可测
// 📌 状态：⬜ 骨架（尚未实现；实现清单见 PROJECT_STATE.md §7）
//
// ⚠️ 本机（Windows）**不要**用 swift build（SwiftPM 在本环境的执行层不可用，
//    见 PROJECT_STATE.md §3）。纯逻辑部分请在 RuneKernel 内实现并用 Tools/rune.ps1 测试；
//    本文件供 macOS 上使用 Xcode / 标准 SwiftPM。
let package = Package(
    name: "RuneMCP",
    platforms: [
        .iOS(.v18),      // WasmKit 实际最低要求 iOS 18（docs/附录B §11.1）
        .macOS(.v15),
    ],
    products: [
        .library(name: "RuneMCP", targets: ["RuneMCP"]),
    ],
    dependencies: [
        .package(path: "../RuneKernel"),
        .package(path: "../RuneNet"),
    ],
    targets: [
        .target(
            name: "RuneMCP",
            dependencies: ["RuneKernel", "RuneNet"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
