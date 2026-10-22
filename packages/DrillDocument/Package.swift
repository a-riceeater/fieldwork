// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DrillDocument",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DrillDocument", targets: ["DrillDocument"]),
        .library(name: "DrillMedia", targets: ["DrillMedia"]),
        .library(name: "DrillExport", targets: ["DrillExport"]),
        .library(name: "DrillConvert", targets: ["DrillConvert"]),
    ],
    dependencies: [
        .package(path: "../DrillTiming"),
        .package(path: "../DrillCore"),
    ],
    targets: [
        .target(
            name: "CSQLite",
            exclude: ["VENDORED.txt"],
            cSettings: [
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_DEFAULT_FOREIGN_KEYS", to: "1"),
                .define("SQLITE_OMIT_LOAD_EXTENSION", to: "1"),
                .define("SQLITE_DQS", to: "0"),
                .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
            ]
        ),
        .target(name: "DrillDocument", dependencies: [
            "CSQLite",
            .product(name: "DrillTiming", package: "DrillTiming"),
            .product(name: "DrillCore", package: "DrillCore"),
        ]),
        .target(name: "DrillMedia"),
        .target(name: "DrillExport", dependencies: [
            .product(name: "DrillTiming", package: "DrillTiming"),
            .product(name: "DrillCore", package: "DrillCore"),
        ]),
        // Runs the bundled 3du-converter executable; no dependency on the document model.
        .target(name: "DrillConvert"),
        .testTarget(name: "DrillDocumentTests", dependencies: ["DrillDocument", "DrillMedia", "DrillExport"]),
        .testTarget(name: "DrillConvertTests", dependencies: [
            "DrillConvert", "DrillDocument",
            .product(name: "DrillCore", package: "DrillCore"),
        ]),
    ]
)
