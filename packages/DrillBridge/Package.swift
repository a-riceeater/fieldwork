// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DrillBridge",
    platforms: [.macOS(.v14)],
    products: [
        // Native Windows frontends load this DLL through the C ABI in include/fieldwork_core.h.
        .library(name: "FieldworkCore", type: .dynamic, targets: ["FieldworkCore"]),
        .executable(name: "fwtool", targets: ["fwtool"]),
    ],
    dependencies: [
        .package(path: "../DrillTiming"),
        .package(path: "../DrillCore"),
        .package(path: "../DrillDocument"),
    ],
    targets: [
        .target(name: "FieldworkCore", dependencies: [
            .product(name: "DrillTiming", package: "DrillTiming"),
            .product(name: "DrillCore", package: "DrillCore"),
            .product(name: "DrillDocument", package: "DrillDocument"),
        ]),
        .executableTarget(name: "fwtool", dependencies: [
            .product(name: "DrillTiming", package: "DrillTiming"),
            .product(name: "DrillCore", package: "DrillCore"),
            .product(name: "DrillDocument", package: "DrillDocument"),
            .product(name: "DrillMedia", package: "DrillDocument"),
            .product(name: "DrillExport", package: "DrillDocument"),
        ]),
        .testTarget(name: "DrillBridgeTests", dependencies: ["FieldworkCore"]),
    ]
)
