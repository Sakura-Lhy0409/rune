// swift-tools-version: 6.3
import PackageDescription

// RuneTools —— 45 个工具的注册表与实现（原生优先，沙箱兜底）
//
// 📄 设计依据：docs/05-工具系统与执行沙箱.md §2
// 🖥 平台：需 macOS
// 📌 状态：⬜ 骨架（尚未实现；实现清单见 PROJECT_STATE.md §7）
//
// ⚠️ 本机（Windows）**不要**用 swift build（SwiftPM 在本环境的执行层不可用，
//    见 PROJECT_STATE.md §3）。纯逻辑部分请在 RuneKernel 内实现并用 Tools/rune.ps1 测试；
//    本文件供 macOS 上使用 Xcode / 标准 SwiftPM。
let package = Package(
    name: "RuneTools",
    platforms: [
        .iOS(.v18),      // WasmKit 实际最低要求 iOS 18（docs/附录B §11.1）
        .macOS(.v15),
    ],
    products: [
        .library(name: "RuneTools", targets: ["RuneTools"]),
    ],
    dependencies: [
        .package(path: "../RuneKernel"),
        .package(path: "../RuneBench"),
    ],
    targets: [
        .target(
            name: "RuneTools",
            dependencies: ["RuneKernel", "RuneBench"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
