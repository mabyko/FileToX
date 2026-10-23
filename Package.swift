// swift-tools-version: 6.0
import PackageDescription
import Foundation

let pdfiumLibraryPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vendor/PDFium/lib").path

// The engine is a line-by-line port of C# (Filee); Swift 5 mode keeps its many shared mutable engine objects
// compiling while the queue and host do their own locking.
let engineSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

// LibRaw as the C# helper's ImageMagick built it, minus libjpeg (Vendor/LibRaw/README.FileToX.md). Thread-safe build
// (no LIBRAW_NOTHREADS: conversions run in parallel); LibRaw's own warnings are silenced.
let libRawDefines = ["LIBRAW_NODLL", "USE_ZLIB"]

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
            name: "CPDFium",
            path: "Vendor/PDFium",
            sources: ["CPDFium.c"],
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("pdfium"), .unsafeFlags(["-L", pdfiumLibraryPath, "-Xlinker", "-rpath", "-Xlinker", pdfiumLibraryPath])]
        ),
        // Camera RAW decoding: LibRaw 0.22.2 (CDDL-1.0) and FileToX's shim in Vendor/LibRaw/FileToX.
        .target(
            name: "CLibRaw",
            path: "Vendor/LibRaw",
            exclude: ["COPYRIGHT", "LICENSE.CDDL", "LICENSE.LGPL", "README.md", "README.FileToX.md"],
            publicHeadersPath: "FileToX/include",
            cSettings: libRawDefines.map { .define($0) } + [.headerSearchPath("."), .unsafeFlags(["-w"])],
            cxxSettings: libRawDefines.map { .define($0) } + [.headerSearchPath("."), .unsafeFlags(["-w"])],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "FileToXEngineKit",
            dependencies: [
                "CLibRaw",
                "CPDFium",
                .product(name: "libwebp", package: "libwebp-Xcode"),
                .product(name: "libjxl", package: "libjxl-Xcode"),
                // Google's Brotli (part of the libjxl package) for WOFF2 at Filee's quality 11.
                .product(name: "brotli", package: "libjxl-Xcode"),
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
            dependencies: ["FileToXEngineKit", "CLibRaw"],
            path: "Tests/Engine",
            exclude: ["Pdf/Fixtures"],
            swiftSettings: engineSettings
        ),
    ]
)
