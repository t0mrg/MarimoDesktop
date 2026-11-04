// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MarimoDesktop",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MarimoDesktop", targets: ["MarimoDesktop"]),
        .library(name: "MarimoCore", targets: ["MarimoCore"]),
    ],
    targets: [
        .target(name: "MarimoCore"),
        .executableTarget(name: "MarimoDesktop", dependencies: ["MarimoCore"]),
        .testTarget(name: "MarimoCoreTests", dependencies: ["MarimoCore"]),
    ]
)
