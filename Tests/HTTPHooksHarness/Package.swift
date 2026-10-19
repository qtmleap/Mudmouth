// swift-tools-version: 6.1
// Host-only harness. It compiles the pure MudmouthHTTPHooks sources (symlinked, so UIKit/SwiftData
// targets of the root package are never resolved or built) and runs the EmbeddedChannel behavior tests.

import PackageDescription

let package = Package(
    name: "HTTPHooksHarness",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "MudmouthHTTPHooks",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
        ),
        .testTarget(
            name: "MudmouthHTTPHooksTests",
            dependencies: [
                "MudmouthHTTPHooks",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
        ),
    ],
)
