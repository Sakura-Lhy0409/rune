// swift-tools-version: 6.3
import PackageDescription

// RuneUI —— 可复用视图组件：卡片、时间轴、Diff 审阅、信任刻度盘、语音
//
// 📄 设计依据：docs/08-交互与体验设计.md
// 🖥 平台：需 macOS（SwiftUI）
// 📌 状态：⬜ 骨架（尚未实现；实现清单见 PROJECT_STATE.md §7）
//
// ⚠️ 本机（Windows）**不要**用 swift build（SwiftPM 在本环境的执行层不可用，
//    见 PROJECT_STATE.md §3）。纯逻辑部分请在 RuneKernel 内实现并用 Tools/rune.ps1 测试；
//    本文件供 macOS 上使用 Xcode / 标准 SwiftPM。
let package = Package(
    name: "RuneUI",
    platforms: [
        .iOS(.v18),      // WasmKit 实际最低要求 iOS 18（docs/附录B §11.1）
        .macOS(.v15),
    ],
    products: [
        .library(name: "RuneUI", targets: ["RuneUI"]),
    ],
    dependencies: [
        .package(path: "../RuneKernel"),
        .package(path: "../RuneCore"),
    ],
    targets: [
        .target(
            name: "RuneUI",
            dependencies: ["RuneKernel", "RuneCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
