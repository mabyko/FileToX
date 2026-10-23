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
    dependencies: [
        // WebP and JPEG XL encoders (ImageIO only decodes them): Google's libwebp and libjxl, built from source.
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", exact: "1.6.0"),
        .package(url: "https://github.com/SDWebImage/libjxl-Xcode.git", exact: "0.10.4"),
    ],
    targets: [
        .target(name: "FileToXCore", path: "Sources/Core"),
        .target(
            name: "FileToXEngineKit",
            dependencies: [
                .product(name: "libwebp", package: "libwebp-Xcode"),
                .product(name: "libjxl", package: "libjxl-Xcode"),
            ],
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
