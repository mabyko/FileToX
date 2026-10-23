// Versions of the WebP / JPEG XL encoder libraries (SwiftPM packages libwebp-Xcode and libjxl-Xcode), for the image
// engine's status text and notices.

import libjxl
import libwebp

public enum CodecLibraries {
    /// "1.6.0": libwebp's encoder version.
    public static var webpVersion: String {
        let version = WebPGetEncoderVersion()
        return "\(version >> 16).\((version >> 8) & 0xFF).\(version & 0xFF)"
    }

    /// "0.10.4": libjxl's encoder version.
    public static var jxlVersion: String {
        let version = JxlEncoderVersion()
        return "\(version / 1_000_000).\(version / 1000 % 1000).\(version % 1000)"
    }
}
