// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AcousticCircuit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "AcousticCore", targets: ["AcousticCore"]),
        .executable(name: "AcousticCircuit", targets: ["AcousticCircuit"])
    ],
    targets: [
        .target(
            name: "AcousticCore",
            path: "Sources/AcousticCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "AcousticCircuit",
            dependencies: ["AcousticCore"],
            path: "Sources/AcousticCircuit",
            exclude: [
                "Renderer/Shaders.metal"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "AcousticCoreTests",
            dependencies: ["AcousticCore"],
            path: "Tests/AcousticCoreTests"
        )
    ]
)
