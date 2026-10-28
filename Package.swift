// swift-tools-version: 6.4

import PackageDescription

// 仓库只有这一份清单。源码在 Sources/，测试在 Tests/。
// 不要再把库放进名为 packages 或 Packages 的目录，也不要另加子目录 Package.swift：
// Xcode 展示远程依赖时会藏起保留目录，嵌套清单会让导航器看不到源码。
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
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "pag_swiftTests",
            dependencies: ["pag_swift"],
            resources: [
                // Resources 是指向仓库根 resources/ 的符号链接。往该目录加 .pag 后，下次 swift test 会一并拷进测试包。
                .copy("Resources"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ],
    // 保持库默认 nonisolated；界面宿主另行隔离到 MainActor。
    swiftLanguageModes: [.v6]
)
