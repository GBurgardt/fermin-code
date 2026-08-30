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
            path: "Sources/FerminCore",
            sources: [
                "FerminCodeRelay",
                "Persistence/TokenVault.swift",
                "Protocol/JSONValue.swift",
            ]
        ),
        .executableTarget(
            name: "FerminMac",
            dependencies: ["FerminCore"],
            path: "Sources/FerminMac",
            sources: [
                "FerminMacApp.swift",
                "FerminCodeDesktop",
            ]
        ),
        .testTarget(
            name: "FerminCoreTests",
            dependencies: ["FerminCore"],
            path: "Tests/FerminCoreTests",
            sources: [
                "FerminCodeRelayCommandTrackerTests.swift",
                "FerminCodeRelayDecodingTests.swift",
                "FerminCodeRelayHTTPTests.swift",
                "FerminCodeRelayModelPolicyTests.swift",
                "FerminCodeRelayRoutingTests.swift",
                "FerminCodeRelaySSETests.swift",
            ]
        ),
        .testTarget(
            name: "FerminMacTests",
            dependencies: ["FerminMac"],
            path: "Tests/FerminMacTests",
            sources: [
                "FerminCodeDesktopPolicyTests.swift",
                "FerminCodeDesktopStoreTests.swift",
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
