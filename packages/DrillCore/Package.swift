// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DrillCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DrillCore", targets: ["DrillCore"]),
        .library(name: "FieldworkTour", targets: ["FieldworkTour"]),
    ],
    dependencies: [
        .package(path: "../DrillTiming"),
    ],
    targets: [
        .target(name: "DrillCore", dependencies: ["DrillTiming"]),
        .target(name: "FieldworkTour"),
        .testTarget(name: "DrillCoreTests", dependencies: ["DrillCore", "FieldworkTour"]),
    ]
)
