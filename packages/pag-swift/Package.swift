// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "pag-swift",
    platforms: [.iOS(.v26), .macOS(.v26)],
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
            ],
        ),
        .testTarget(
            name: "pag_swiftTests",
            dependencies: ["pag_swift"],
            resources: [
                // 指向仓库根目录 resources/。往该目录加 .pag 后，下次 swift test 会一并拷进测试包。
                .copy("Resources"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ],
    // 保持库默认 nonisolated；只有后续界面宿主显式隔离到 MainActor。
    swiftLanguageModes: [.v6]
)
