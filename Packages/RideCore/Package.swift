// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RideCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RideCore", targets: ["RideCore"]),
    ],
    targets: [
        .target(name: "RideCore"),
        .testTarget(
            name: "RideCoreTests",
            dependencies: ["RideCore"],
            resources: [.copy("Resources/golden-vectors.json"), .copy("Resources/olc")]
        ),
    ]
)
