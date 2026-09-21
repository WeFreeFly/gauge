// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Gauge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Gauge", targets: ["Gauge"]),
        .executable(name: "GaugeTests", targets: ["GaugeTests"]),
        .library(name: "GaugeKit", targets: ["GaugeKit"]),
    ],
    targets: [
        .target(name: "CGaugeSMC"),
        .target(name: "GaugeKit", dependencies: ["CGaugeSMC"]),
        .executableTarget(name: "Gauge", dependencies: ["GaugeKit"]),
        // XCTest ships with Xcode, not with the Command Line Tools, so the
        // suite is an ordinary executable with its own small harness. Run it
        // with `swift run GaugeTests`.
        .executableTarget(name: "GaugeTests", dependencies: ["GaugeKit"]),
    ]
)
