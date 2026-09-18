// swift-tools-version: 6.3
import PackageDescription

// RuneStore —— 事件日志（唯一真相源）、哈希链落盘、检查点、迁移、成本账本
//
// 📄 设计依据：docs/12-数据模型与持久化.md
// 🖥 平台：macOS / iOS（GRDB 7.x）——
//    ⚠️ 这个包**只在 macOS 上构建**（`.github/workflows/ios.yml` 的 packages job），
//       本机（Windows）不参与；RuneKernel 仍然保持零依赖。
// 📌 状态：🔨 第一片已落地（event 表 + 迁移 + 落盘/读回/验链）——
//       仍有：投影表（session/turn/goal）、检查点/VFS 快照表、FTS5
//       （**必须 CJK 分词器或 trigram，绝不用 unicode61**，见 T1–T3）。
//
// ⚠️ 零依赖约束只针对 `RuneKernel`（它要能在任意平台验证）。
//    Store 落盘用 GRDB 是设计文档定的选型，不违反那条约束。

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
        // ⚠️ 这里的用法刻意只用**最稳的裸 SQL 那层**（见 EventStore.swift 文件头），
        //    所以版本范围从 minor 起就够；大版本换 API 时受影响面很小。
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "RuneStore",
            dependencies: [
                "RuneKernel",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RuneStoreTests",
            dependencies: ["RuneStore", "RuneKernel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
