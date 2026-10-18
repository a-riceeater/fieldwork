// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DrillTiming",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DrillTiming", targets: ["DrillTiming"]),
    ],
    targets: [
        .target(name: "DrillTiming"),
        .testTarget(name: "DrillTimingTests", dependencies: ["DrillTiming"]),
    ]
)
