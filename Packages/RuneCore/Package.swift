// swift-tools-version: 6.3
import PackageDescription

// RuneCore —— AgentRuntime：Turn 状态机、规划、工具调度、审批、Goal / Job / Workflow / Subagent / Skill / Hook
//
// 📄 设计依据：docs/04-Agent运行时核心.md
// 🖥 平台：需 macOS（含 iOS 生命周期）
// 📌 状态：真实运行时、逐步持久化、审批、取消与恢复；测试已覆盖接口组合。
let package = Package(
    name: "RuneCore",
    platforms: [
        .iOS(.v18),      // WasmKit 实际最低要求 iOS 18（docs/附录B §11.1）
        .macOS(.v15),
    ],
    products: [
        .library(name: "RuneCore", targets: ["RuneCore"]),
        .executable(name: "RuneValidation", targets: ["RuneValidation"]),
    ],
    dependencies: [
        .package(path: "../RuneKernel"),
        .package(path: "../RuneNet"),
        .package(path: "../RuneTools"),
        .package(path: "../RuneGateway"),
        .package(path: "../RuneContext"),
        .package(path: "../RuneBench"),
        .package(path: "../RuneStore"),
    ],
    targets: [
        .target(
            name: "RuneCore",
            dependencies: ["RuneKernel", "RuneGateway", "RuneContext", "RuneBench", "RuneStore", "RuneNet", "RuneTools"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(name: "RuneValidation", dependencies: ["RuneCore", "RuneKernel", "RuneStore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "RuneCoreTests", dependencies: ["RuneCore", "RuneKernel", "RuneStore"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
