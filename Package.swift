// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Whisp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Whisp", targets: ["Whisp"]),
        .executable(name: "whisp-bench", targets: ["whisp-bench"]),
        .executable(name: "whisp-learnprobe", targets: ["whisp-learnprobe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
    ],
    targets: [
        // Hand-tuned matrix kernels for the native RNNT decode loop.
        .target(name: "WhispKernels"),
        .target(
            name: "WhispCore",
            dependencies: ["WhispKernels", .product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Whisp",
            dependencies: ["WhispCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "whisp-bench",
            dependencies: ["WhispCore", .product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "whisp-tests",
            dependencies: ["WhispCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "whisp-learnprobe",
            dependencies: ["WhispCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
