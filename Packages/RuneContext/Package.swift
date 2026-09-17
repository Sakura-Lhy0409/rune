// swift-tools-version: 6.3
import PackageDescription

// RuneContext —— 上下文装配（预算制）、三级压缩、混合检索、三层记忆
//
// 📄 设计依据：docs/07-上下文与记忆引擎.md
// 🖥 平台：纯逻辑部分 Windows 可测
// 📌 状态：⬜ 骨架（尚未实现；实现清单见 PROJECT_STATE.md §7）
//
// ⚠️ 本机（Windows）**不要**用 swift build（SwiftPM 在本环境的执行层不可用，
//    见 PROJECT_STATE.md §3）。纯逻辑部分请在 RuneKernel 内实现并用 Tools/rune.ps1 测试；
//    本文件供 macOS 上使用 Xcode / 标准 SwiftPM。
let package = Package(
    name: "RuneContext",
    platforms: [
        .iOS(.v18),      // WasmKit 实际最低要求 iOS 18（docs/附录B §11.1）
        .macOS(.v15),
    ],
    products: [
        .library(name: "RuneContext", targets: ["RuneContext"]),
    ],
    dependencies: [
        .package(path: "../RuneKernel"),
        .package(path: "../RuneStore"),
    ],
    targets: [
        .target(
            name: "RuneContext",
            dependencies: ["RuneKernel", "RuneStore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
