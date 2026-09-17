// swift-tools-version: 6.3
import PackageDescription

// RuneStore —— 事件日志（唯一真相源）、哈希链落盘、检查点、迁移、成本账本
//
// 📄 设计依据：docs/12-数据模型与持久化.md
// 🖥 平台：需 macOS（GRDB 7.x）
// 📌 状态：⬜ 骨架（尚未实现；实现清单见 PROJECT_STATE.md §7）
//
// ⚠️ 本机（Windows）**不要**用 swift build（SwiftPM 在本环境的执行层不可用，
//    见 PROJECT_STATE.md §3）。纯逻辑部分请在 RuneKernel 内实现并用 Tools/rune.ps1 测试；
//    本文件供 macOS 上使用 Xcode / 标准 SwiftPM。
let package = Package(
    name: "RuneStore",
    platforms: [
        .iOS(.v18),      // WasmKit 实际最低要求 iOS 18（docs/附录B §11.1）
        .macOS(.v15),
    ],
    products: [
        .library(name: "RuneStore", targets: ["RuneStore"]),
    ],
    dependencies: [
        .package(path: "../RuneKernel"),
    ],
    targets: [
        .target(
            name: "RuneStore",
            dependencies: ["RuneKernel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
