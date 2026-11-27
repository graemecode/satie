// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Satie",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "AcousticCore", targets: ["AcousticCore"]),
        .executable(name: "Satie", targets: ["Satie"])
    ],
    targets: [
        .target(
            name: "AcousticCore",
            path: "Sources/AcousticCore",
            resources: [
                .copy("Resources/Samples"),
                .process("Resources/Localization")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
                .linkedFramework("IOKit"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "Satie",
            dependencies: ["AcousticCore"],
            path: "Sources/AcousticCircuit",
            exclude: [
                "Renderer/Shaders.metal"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AppIntents"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        // Developer-only sound design studio (never shipped). Run: scripts/lab.sh
        .executableTarget(
            name: "SatieLab",
            dependencies: ["AcousticCore"],
            path: "Sources/SatieLab"
        ),
        .testTarget(
            name: "AcousticCoreTests",
            dependencies: ["AcousticCore"],
            path: "Tests/AcousticCoreTests"
        )
    ]
)
