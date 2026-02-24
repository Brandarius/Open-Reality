// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MetalBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "MetalBridge",
            type: .dynamic,
            targets: ["MetalBridge"]
        ),
    ],
    targets: [
        .target(
            name: "MetalBridge",
            path: "Sources/MetalBridge",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "MetalBridgeTests",
            dependencies: ["MetalBridge"],
            path: "Tests/MetalBridgeTests"
        ),
    ]
)
