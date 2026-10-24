// swift-tools-version: 6.0
import PackageDescription
import Foundation

let pdfiumLibraryPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vendor/PDFium/lib").path

// The engine is a line-by-line port of C# (Filee); Swift 5 mode keeps its many shared mutable engine objects
// compiling while the queue and host do their own locking.
let engineSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

// LibRaw as the C# helper's ImageMagick built it (Vendor/LibRaw/README.FileToX.md). Thread-safe build (no
// LIBRAW_NOTHREADS: conversions run in parallel); LibRaw's own warnings are silenced. USE_JPEG: libjpeg-turbo below.
let libRawDefines = ["LIBRAW_NODLL", "USE_ZLIB", "USE_JPEG"]
let libRawHeaders: [String] = [".", "../libjpeg-turbo/src", "../libjpeg-turbo/FileToX/config"]

let package = Package(
    name: "FileToX",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FileToXCore", targets: ["FileToXCore"]),
        .library(name: "FileToXEngineKit", targets: ["FileToXEngineKit"]),
        // For the Xcode test bundle, which imports LibRaw's header directly (CameraRawTests).
        .library(name: "CLibRaw", targets: ["CLibRaw"]),
        .executable(name: "FileToXEngine", targets: ["FileToXEngine"]),
    ],
    dependencies: [
        // WebP and JPEG XL encoders (ImageIO only decodes them): Google's libwebp and libjxl, built from source.
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", exact: "1.6.0"),
        .package(url: "https://github.com/SDWebImage/libjxl-Xcode.git", exact: "0.10.4"),
        // JPEG writing like the C# helper's ImageMagick, and LibRaw's lossy DNG: libjpeg-turbo 3.2.0 from source.
        .package(path: "Vendor/libjpeg-turbo"),
    ],
    targets: [
        .target(name: "FileToXCore", path: "Sources/Core"),
        .target(
            name: "COpenJPEG", path: "Vendor/OpenJPEG",
            exclude: ["LICENSE", "README.FileToX.md", "NOTICES"],
            sources: ["src/thread.c", "src/bio.c", "src/cio.c", "src/dwt.c", "src/event.c", "src/ht_dec.c", "src/image.c", "src/invert.c", "src/j2k.c", "src/jp2.c", "src/mct.c", "src/mqc.c", "src/openjpeg.c", "src/opj_clock.c", "src/pi.c", "src/t1.c", "src/t2.c", "src/tcd.c", "src/tgt.c", "src/function_list.c", "src/opj_malloc.c", "src/sparse_array.c", "FileToX/encode.c"],
            publicHeadersPath: "FileToX/include",
            cSettings: [.headerSearchPath("src"), .define("OPJ_STATIC"), .define("MUTEX_pthread")]
        ),
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
            dependencies: [.product(name: "CJpegTurbo", package: "libjpeg-turbo")],
            path: "Vendor/LibRaw",
            exclude: ["COPYRIGHT", "LICENSE.CDDL", "LICENSE.LGPL", "README.md", "README.FileToX.md"],
            publicHeadersPath: "FileToX/include",
            cSettings: libRawDefines.map { .define($0) } + libRawHeaders.map { .headerSearchPath($0) } + [.unsafeFlags(["-w"])],
            cxxSettings: libRawDefines.map { .define($0) } + libRawHeaders.map { .headerSearchPath($0) } + [.unsafeFlags(["-w"])],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "FileToXEngineKit",
            dependencies: [
                "CLibRaw",
                "COpenJPEG",
                "CPDFium",
                .product(name: "CJpegTurbo", package: "libjpeg-turbo"),
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
