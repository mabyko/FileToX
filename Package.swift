// swift-tools-version: 6.0
import PackageDescription

// The engine is a line-by-line port of C# (Filee); Swift 5 mode keeps its many shared mutable engine objects
// compiling while the queue and host do their own locking.
let engineSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "FileToX",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FileToXCore", targets: ["FileToXCore"]),
        .library(name: "FileToXEngineKit", targets: ["FileToXEngineKit"]),
        .executable(name: "FileToXEngine", targets: ["FileToXEngine"]),
    ],
    targets: [
        .target(name: "FileToXCore", path: "Sources/Core"),
        .target(
            name: "FileToXEngineKit",
            path: "Sources/Engine",
            resources: [.copy("Resources")],
            swiftSettings: engineSettings,
            linkerSettings: [.linkedLibrary("xml2"), .linkedLibrary("z")]
        ),
        .executableTarget(name: "FileToXEngine", dependencies: ["FileToXEngineKit"], path: "Sources/EngineMain", swiftSettings: engineSettings),
        .testTarget(name: "FileToXCoreTests", dependencies: ["FileToXCore"], path: "Tests/Core"),
        .testTarget(
            name: "FileToXEngineTests",
            dependencies: ["FileToXEngineKit"],
            path: "Tests/Engine",
            swiftSettings: engineSettings
        ),
    ]
)
