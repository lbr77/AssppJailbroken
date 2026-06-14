// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "unfaird",
    platforms: [
        .macOS(.v14),
        .iOS(.v15),
    ],
    products: [
        .executable(name: "UnfairDaemon", targets: ["UnfairDaemon"]),
    ],
    dependencies: [
        .package(name: "unfair-swift", path: "../../unfair"),
        .package(url: "https://github.com/Lakr233/ApplePackage.git", exact: "1.2.7"),
        .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.33.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", "1.3.0"..<"2.0.0"),
        .package(url: "https://github.com/vapor/vapor.git", exact: "4.60.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19"),
    ],
    targets: [
        .target(name: "UnfairDaemonSupport"),
        .target(
            name: "UnfairDaemonCore",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "ApplePackage", package: "ApplePackage"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .executableTarget(
            name: "UnfairDaemon",
            dependencies: [
                "UnfairDaemonCore",
                "UnfairDaemonSupport",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "UnfairKit", package: "unfair-swift"),
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
        .testTarget(
            name: "UnfairDaemonCoreTests",
            dependencies: [
                "UnfairDaemonCore",
                .product(name: "XCTVapor", package: "vapor"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
