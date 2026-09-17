// swift-tools-version: 6.3
import PackageDescription

// RuneKernel —— 零依赖核心。
//
// 设计约束（见 docs/03-总体架构.md §3）：
//   * 只依赖 Foundation 与标准库，**不得 import 任何 Apple 专属框架**
//   * 因此它可以在 Linux / Windows 上完整 build + test（本机 Swift 6.3.3 for Windows 即可验证）
//   * 一切跨 Actor 传递的类型必须 Sendable；一切需要持久化的类型必须 Codable
//
// ⚠️ 新增类型时先问三个问题：
//   1. 它是"事实"（值类型、不可变）还是"行为"（属于上层包）？本包只放事实。
//   2. 它会不会被写进事件日志？会 → 必须 Codable 且**新增字段只能追加、不能改语义**。
//   3. 它会不会跨越污点边界？会 → 必须携带 TrustLevel（见 Trust.swift）。
let package = Package(
    name: "RuneKernel",
    platforms: [
        .iOS(.v18),      // WasmKit 实际最低要求 iOS 18（见 docs/附录B §11.1）
        .macOS(.v15),
    ],
    products: [
        .library(name: "RuneKernel", targets: ["RuneKernel"]),
    ],
    targets: [
        .target(
            name: "RuneKernel",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RuneKernelTests",
            dependencies: ["RuneKernel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
