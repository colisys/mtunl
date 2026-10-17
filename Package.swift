// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "mtunl",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MTunl", targets: ["MTunl"]),
        .executable(name: "mtunlctl", targets: ["mtunlctl"]),
                .executable(name: "mtunl-helper", targets: ["mtunl-helper"]),

        .library(name: "TunnelCore", targets: ["TunnelCore"]),
    ],
    targets: [
        .target(name: "MihomoWatchdog"),
                .target(name: "TunnelCore", dependencies: ["MihomoWatchdog"]),
                .executableTarget(name: "mtunl-helper", dependencies: ["TunnelCore"]),
        .executableTarget(
            name: "MTunl",
            dependencies: ["TunnelCore"]
        ),
        .executableTarget(
            name: "mtunlctl",
            dependencies: ["TunnelCore"]
        ),

        .testTarget(
            name: "TunnelCoreTests",
            dependencies: ["TunnelCore"]
        ),
    ]
)
