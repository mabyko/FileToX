// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileToX",
    platforms: [.macOS(.v15)],
    products: [.library(name: "FileToXCore", targets: ["FileToXCore"])],
    targets: [
        .target(name: "FileToXCore", path: "Sources/Core"),
        .testTarget(name: "FileToXCoreTests", dependencies: ["FileToXCore"], path: "Tests/Core")
    ]
)
