// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "FerminCodeDesktop",
    defaultLocalization: "es",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(name: "FerminCore", targets: ["FerminCore"]),
        .executable(name: "FerminCode", targets: ["FerminMac"]),
    ],
    targets: [
        .target(
            name: "FerminCore",
            path: "Sources/FerminCore"
        ),
        .executableTarget(
            name: "FerminMac",
            dependencies: ["FerminCore"],
            path: "Sources/FerminMac"
        ),
        .testTarget(
            name: "FerminCoreTests",
            dependencies: ["FerminCore"],
            path: "Tests/FerminCoreTests"
        ),
        .testTarget(
            name: "FerminMacTests",
            dependencies: ["FerminMac"],
            path: "Tests/FerminMacTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
