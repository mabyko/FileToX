// ImageMagick 7.1.2-32 Q8 ResizeImage ported to Swift. The SHA-256 values are of the samples that ImageMagick (the C#
// helper's Magick.Native) produced from the same 41 × 29 pixels (read and written as PAM, so nothing else touched them).

import CoreGraphics
import CryptoKit
import XCTest
@testable import FileToXEngineKit

final class MagickResizeTests: XCTestCase {
    private static func samples(alpha: Bool) -> [UInt8] {
        var samples: [UInt8] = []
        for y in 0..<29 {
            for x in 0..<41 {
                for c in 0..<3 { samples.append(UInt8((x * 37 + y * 91 + c * 53 + (x * y) % 17 * 7) & 255)) }
                if alpha { samples.append(UInt8((x * 13 + y * 29) & 255)) }
            }
        }
        return samples
    }

    private static func sha256(_ samples: [UInt8]) -> String {
        SHA256.hash(data: Data(samples)).map { String(format: "%02x", $0) }.joined()
    }

    func testKernelsAreImageMagicksSincFastLanczosAndMitchell() {
        XCTAssertEqual(MagickResize.sincFast(0), 1, accuracy: 1e-5)
        for zero in [1.0, 2, 3, 4] { XCTAssertEqual(MagickResize.sincFast(zero), 0, accuracy: 1e-15) }
        XCTAssertEqual(MagickResize.sincFast(0.5), 2 / Double.pi, accuracy: 6.3e-6 * 2 / Double.pi)
        XCTAssertEqual(MagickResize.Filter.lanczos.weight(1.5), MagickResize.sincFast(0.5) * MagickResize.sincFast(1.5))
        // Mitchell–Netravali (B = C = 1/3): 8/9 at 0, 1/18 at 1, 0 from 2.
        XCTAssertEqual(MagickResize.cubicBC(0), 8.0 / 9.0, accuracy: 1e-15)
        XCTAssertEqual(MagickResize.cubicBC(1), 1.0 / 18.0, accuracy: 1e-15)
        XCTAssertEqual(MagickResize.cubicBC(2), 0)
        XCTAssertEqual(MagickResize.Filter.mitchell.weight(-0.5), MagickResize.cubicBC(0.5))
    }

    func testFilterIsChosenLikeImageMagick() {
        let source = (width: 40, height: 30)
        XCTAssertEqual(MagickResize.defaultFilter(from: source, to: (20, 15), alpha: false, palette: false), .lanczos)
        XCTAssertEqual(MagickResize.defaultFilter(from: source, to: (20, 15), alpha: true, palette: false), .mitchell)
        XCTAssertEqual(MagickResize.defaultFilter(from: source, to: (20, 15), alpha: false, palette: true), .mitchell)
        // Enlarging: the area grows even when one side shrinks.
        XCTAssertEqual(MagickResize.defaultFilter(from: source, to: (80, 20), alpha: false, palette: false), .mitchell)
        XCTAssertEqual(MagickResize.defaultFilter(from: source, to: (40, 20), alpha: false, palette: false), .lanczos)
    }

    func testSamplesAreIdenticalToImageMagick() {
        let expected: [(alpha: Bool, size: (Int, Int), sha256: String)] = [
            (false, (16, 16), "fa571c803dba43008a59e8dac5509fee6fb89d269753081c4511de037a24ad3a"), // Lanczos
            (false, (60, 40), "e7e7ac99c7baa4d1080fe1c7ba971a58b09b0970c1f3b64495251ba5c78b53cf"), // Mitchell, enlarged
            (false, (21, 15), "370342b40da4c87b84894dcc6cf4797234442a7f07acdf96f678f33cabae04a4"), // 50%
            (false, (7, 30), "69d90a42d44d3490da7429916c61128a62dc5022d970b4813e51fafabe90ccc5"), // vertical pass first
            (true, (16, 16), "cc3973a7a3a2b12a18d0816db0b35e6c816fb8900199a8ef93957e43122067d6"), // alpha-weighted Mitchell
            (true, (60, 40), "36a2d614497c351a5e02a7403d9ef1a6df10cba099ebd34db55964968bf04a2b"),
            (true, (21, 15), "f4b5a9fb25dcfbe415302264c6316a20c6c6fb8bb6fee68fca562e71051c302b"),
            (true, (7, 30), "e79af7eb9b05303287ac81457d9aed796c956e0fd0b8dc65c9679969017e6d64"),
        ]
        for case let (alpha, size, sha256) in expected {
            let filter = MagickResize.defaultFilter(from: (41, 29), to: size, alpha: alpha, palette: false)
            let result = MagickResize.resize(Self.samples(alpha: alpha), width: 41, height: 29, channels: alpha ? 4 : 3, alpha: alpha, to: size,
                                             filter: filter)
            XCTAssertEqual(Self.sha256(result), sha256, "alpha \(alpha), \(size)")
        }
    }

    func testResizedImagesKeepStraightAlphaAndGray() {
        let rgba = ImagePixels.make(Self.samples(alpha: true), 41, 29, components: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: true,
                                    premultiplied: false)
        let resized = ImagePixels.resized(rgba, width: 16, height: 16)
        XCTAssertEqual(resized.alphaInfo, .last)
        XCTAssertEqual(Self.sha256(ImagePixels.straight(resized).samples), "cc3973a7a3a2b12a18d0816db0b35e6c816fb8900199a8ef93957e43122067d6")
        let gray = ImagePixels.make([UInt8](repeating: 128, count: 40 * 30), 40, 30, components: 1, space: CGColorSpaceCreateDeviceGray(), alpha: false)
        XCTAssertEqual(ImagePixels.resized(gray, width: 20, height: 15).colorSpace?.model, .monochrome)
        XCTAssertTrue(ImagePixels.resized(gray, width: 40, height: 30) === gray, "the same size is left alone")
    }

    func testAlphaRemovalIsImageMagicksFlatten() {
        // Alpha(AlphaOption.Remove) over Filee's default white and another colour, from the same straight samples.
        let rgba = ImagePixels.make(Self.samples(alpha: true), 41, 29, components: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: true,
                                    premultiplied: false)
        for (background, sha256) in [((UInt8(255), UInt8(255), UInt8(255)), "98268e6079748d348f34ba99b1fed7cc38aa5014ef17b3d31985748b88c53dc7"),
                                     ((0x33, 0x66, 0x99), "c79877f5c6ef9460c1cd52643fba0cc2832be7083dbecd54391213c7a180125d")] {
            let flat = ImagePixels.flattened(rgba, background: background)
            XCTAssertFalse(ImagePixels.hasAlpha(flat))
            XCTAssertEqual(Self.sha256(ImagePixels.straight(flat).samples), sha256, "\(background)")
        }
    }
}
