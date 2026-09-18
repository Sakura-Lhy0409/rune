// swift-tools-version: 6.3
import PackageDescription

// RuneUI：跨页面视觉组件与可持久化的界面状态模型。
let package = Package(
    name: "RuneUI",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "RuneUI", targets: ["RuneUI"])],
    targets: [
        .target(name: "RuneUI", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "RuneUITests", dependencies: ["RuneUI"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
