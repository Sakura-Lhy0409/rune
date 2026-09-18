// swift-tools-version: 6.3
import PackageDescription

// RuneTools —— 45 个工具的注册表与实现（原生优先，沙箱兜底）
//
// 📄 设计依据：docs/05-工具系统与执行沙箱.md §2
// 🖥 平台：需 macOS
// 📌 状态：端侧 PDF、OCR、CSV/TSV 工具；文件工具复用 RuneKernel。
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
        .testTarget(name: "RuneToolsTests", dependencies: ["RuneTools", "RuneKernel"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
