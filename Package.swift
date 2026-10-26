// swift-tools-version: 6.4

import PackageDescription

// 远程 SPM 只读取仓库根上的这份清单。源码仍留在 packages/pag-swift，
// product 名 pag-swift、模块名 pag_swift 与子目录包保持一致。
// swiftSettings 必须和 packages/pag-swift/Package.swift 一起改。
// 测试仍走子目录清单：swift test --package-path packages/pag-swift
let package = Package(
    name: "pag-swift",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "pag-swift",
            targets: ["pag_swift"]
        ),
    ],
    targets: [
        .target(
            name: "pag_swift",
            path: "packages/pag-swift/Sources/pag_swift",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ],
    // 保持库默认 nonisolated；界面宿主另行隔离到 MainActor。
    swiftLanguageModes: [.v6]
)
