// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "截图Free",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "截图Free", targets: ["截图Free"])
    ],
    targets: [
        .executableTarget(name: "截图Free", resources: [.process("Resources")]),
        .testTarget(name: "截图FreeTests", dependencies: ["截图Free"])
    ]
)
