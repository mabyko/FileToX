// swift-tools-version: 6.0
import PackageDescription

// libjpeg-turbo 3.2.0's libjpeg API library, built like upstream's CMake target jpeg-static without SIMD
// (README.FileToX.md), plus FileToX's JPEG writer (FileToX/encode.c, the module CJpegTurbo).

/// Upstream's JPEG_SOURCES compiled directly; the rest are the 8/12/16-bit wrappers in src/wrapper, which include the
/// shared sources (jcapistd.c, jccolor.c …) once per data precision.
let direct = [
    "jcapimin", "jchuff", "jcicc", "jcinit", "jclhuff", "jcmarker", "jcmaster", "jcomapi", "jcparam", "jcphuff", "jctrans",
    "jdapimin", "jdatadst", "jdatasrc", "jdhuff", "jdicc", "jdinput", "jdlhuff", "jdmarker", "jdmaster", "jdphuff", "jdtrans",
    "jerror", "jfdctflt", "jmemmgr", "jmemnobs", "jpeg_nbits",
    // WITH_ARITH_ENC / WITH_ARITH_DEC
    "jaricom", "jcarith", "jdarith",
]

let package = Package(
    name: "libjpeg-turbo",
    platforms: [.macOS(.v15)],
    products: [.library(name: "CJpegTurbo", targets: ["CJpegTurbo"])],
    targets: [
        .target(
            name: "CJpegTurbo",
            path: ".",
            sources: direct.map { "src/\($0).c" } + ["src/wrapper", "FileToX/encode.c"],
            publicHeadersPath: "FileToX/include",
            // Upstream code, upstream warnings (64-to-32-bit conversions that are intended).
            cSettings: [.headerSearchPath("src"), .headerSearchPath("FileToX/config"), .unsafeFlags(["-w"])]
        ),
    ]
)
