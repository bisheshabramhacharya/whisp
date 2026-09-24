// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Whisp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Whisp", targets: ["Whisp"]),
        .executable(name: "whisp-bench", targets: ["whisp-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7"),
    ],
    targets: [
        .target(
            name: "WhispCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
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
    ]
)
