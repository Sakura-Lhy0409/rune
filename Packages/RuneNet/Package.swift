// swift-tools-version: 6.3
import PackageDescription

// RuneNet —— SSE 增量解析、断流重连、重试退避、出口代理（唯一出站点）
//
// 📄 设计依据：docs/06-模型网关与中转站.md §12
// 🖥 平台：需 macOS（URLSession / AsyncBytes）
// 📌 状态：⬜ 骨架（尚未实现；实现清单见 PROJECT_STATE.md §7）
//
// ⚠️ 本机（Windows）**不要**用 swift build（SwiftPM 在本环境的执行层不可用，
//    见 PROJECT_STATE.md §3）。纯逻辑部分请在 RuneKernel 内实现并用 Tools/rune.ps1 测试；
//    本文件供 macOS 上使用 Xcode / 标准 SwiftPM。
let package = Package(
    name: "RuneNet",
    platforms: [
        .iOS(.v18),      // WasmKit 实际最低要求 iOS 18（docs/附录B §11.1）
        .macOS(.v15),
    ],
    products: [
        .library(name: "RuneNet", targets: ["RuneNet"]),
    ],
    dependencies: [
        .package(path: "../RuneKernel"),
    ],
    targets: [
        .target(
            name: "RuneNet",
            dependencies: ["RuneKernel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
