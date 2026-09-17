// swift-tools-version: 6.3
import PackageDescription

// RuneGateway —— 协议适配（11 族）、ToolCallAssembler、路由降级、缓存记账、密钥注入
//
// 📄 设计依据：docs/06-模型网关与中转站.md
// 🖥 平台：纯逻辑部分 Windows 可测
// 📌 状态：⬜ 骨架（尚未实现；实现清单见 PROJECT_STATE.md §7）
//
// ⚠️ 本机（Windows）**不要**用 swift build（SwiftPM 在本环境的执行层不可用，
//    见 PROJECT_STATE.md §3）。纯逻辑部分请在 RuneKernel 内实现并用 Tools/rune.ps1 测试；
//    本文件供 macOS 上使用 Xcode / 标准 SwiftPM。
let package = Package(
    name: "RuneGateway",
    platforms: [
        .iOS(.v18),      // WasmKit 实际最低要求 iOS 18（docs/附录B §11.1）
        .macOS(.v15),
    ],
    products: [
        .library(name: "RuneGateway", targets: ["RuneGateway"]),
    ],
    dependencies: [
        .package(path: "../RuneKernel"),
        .package(path: "../RuneNet"),
    ],
    targets: [
        .target(
            name: "RuneGateway",
            dependencies: ["RuneKernel", "RuneNet"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
