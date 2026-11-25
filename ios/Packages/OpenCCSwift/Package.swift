// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "OpenCCSwift",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "OpenCCSwift",
            targets: ["OpenCCSwift"]
        )
    ],
    targets: [
        .target(
            name: "OpenCCSwift"
        )
    ]
)
