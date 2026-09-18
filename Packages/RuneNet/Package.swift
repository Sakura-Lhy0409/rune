// swift-tools-version: 6.3
import PackageDescription

// RuneNet —— URLSession 传输、SSE 增量消费与出口校验
//
// 📄 设计依据：docs/06-模型网关与中转站.md §12
// 🖥 平台：macOS / iOS（URLSession delegate）
// 📌 状态：URLSession 传输、异步取消、出口校验、增量 SSE 与脱敏审计已实现。
//    核心保持零外部依赖；网络重试决策属于网关。
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
        .testTarget(
            name: "RuneNetTests",
            dependencies: ["RuneNet", "RuneKernel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
