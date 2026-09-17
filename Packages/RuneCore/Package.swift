// swift-tools-version: 6.3
import PackageDescription

// RuneCore —— AgentRuntime：Turn 状态机、规划、工具调度、审批、Goal / Job / Workflow / Subagent / Skill / Hook
//
// 📄 设计依据：docs/04-Agent运行时核心.md
// 🖥 平台：需 macOS（含 iOS 生命周期）
// 📌 状态：⬜ 骨架（尚未实现；实现清单见 PROJECT_STATE.md §7）
//
// ⚠️ 本机（Windows）**不要**用 swift build（SwiftPM 在本环境的执行层不可用，
//    见 PROJECT_STATE.md §3）。纯逻辑部分请在 RuneKernel 内实现并用 Tools/rune.ps1 测试；
//    本文件供 macOS 上使用 Xcode / 标准 SwiftPM。
let package = Package(
    name: "RuneCore",
    platforms: [
        .iOS(.v18),      // WasmKit 实际最低要求 iOS 18（docs/附录B §11.1）
        .macOS(.v15),
    ],
    products: [
        .library(name: "RuneCore", targets: ["RuneCore"]),
    ],
    dependencies: [
        .package(path: "../RuneKernel"),
        .package(path: "../RuneGateway"),
        .package(path: "../RuneContext"),
        .package(path: "../RuneBench"),
        .package(path: "../RuneStore"),
    ],
    targets: [
        .target(
            name: "RuneCore",
            dependencies: ["RuneKernel", "RuneGateway", "RuneContext", "RuneBench", "RuneStore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
