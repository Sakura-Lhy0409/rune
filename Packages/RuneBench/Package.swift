// swift-tools-version: 6.3
import PackageDescription

// RuneBench —— VFS（唯一文件入口）、写时复制快照、原生 CPython 垫片、自研 shell 命令表
//
// 📄 设计依据：docs/05-工具系统与执行沙箱.md §3–§4
// 🖥 平台：需 macOS（VFS + iOS 文件系统）
// 📌 状态：⬜ 骨架（尚未实现；实现清单见 PROJECT_STATE.md §7）
//
// ⚠️ 本机（Windows）**不要**用 swift build（SwiftPM 在本环境的执行层不可用，
//    见 PROJECT_STATE.md §3）。纯逻辑部分请在 RuneKernel 内实现并用 Tools/rune.ps1 测试；
//    本文件供 macOS 上使用 Xcode / 标准 SwiftPM。
let package = Package(
    name: "RuneBench",
    platforms: [
        .iOS(.v18),      // WasmKit 实际最低要求 iOS 18（docs/附录B §11.1）
        .macOS(.v15),
    ],
    products: [
        .library(name: "RuneBench", targets: ["RuneBench"]),
    ],
    dependencies: [
        .package(path: "../RuneKernel"),
        .package(path: "../RuneVM"),
    ],
    targets: [
        .target(
            name: "RuneBench",
            dependencies: ["RuneKernel", "RuneVM"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
