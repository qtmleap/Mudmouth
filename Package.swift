// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Mudmouth",
    defaultLocalization: "ja",
    platforms: [.iOS(.v17)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Mudmouth",
            targets: ["Mudmouth"],
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.0.0"),
        .package(url: "https://github.com/qtmleap/swifty-logger.git", exact: "2.1.1"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
        .package(url: "https://github.com/stleamist/BetterSafariView.git", from: "2.4.2"),
        .package(url: "https://github.com/1024jp/GzipSwift.git", from: "6.1.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Mudmouth",
            dependencies: [
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "SwiftyLogger", package: "swifty-logger"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "KeychainAccess", package: "KeychainAccess"),
                .product(name: "BetterSafariView", package: "BetterSafariView"),
                .product(name: "Gzip", package: "GzipSwift"),
            ],
        ),
    ],
)
