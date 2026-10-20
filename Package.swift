// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "szt",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "szt", targets: ["szt"]),
    ],
    targets: [
        .executableTarget(name: "szt"),
        .testTarget(name: "sztTests", dependencies: ["szt"]),
    ]
)
