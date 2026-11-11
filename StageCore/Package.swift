// swift-tools-version: 5.9

import PackageDescription

// Platform-independent logic of the iOS app: no UIKit, ARKit or RealityKit in here, only Foundation.
// Everything in this package is covered by `swift test` on a Mac, without a simulator or a device.
let package = Package(
    name: "StageCore",
    platforms: [
        .iOS(.v16), .macOS(.v13),
    ],
    products: [
        .library(name: "StageCore", targets: ["StageCore"]),
    ],
    targets: [
        .target(name: "StageCore"),
        .testTarget(name: "StageCoreTests", dependencies: ["StageCore"]),
    ]
)
