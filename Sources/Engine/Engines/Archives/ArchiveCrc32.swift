// Port of Filee.Engines/Archives/Crc32.cs: CRC-32 (IEEE 802.3, as in ZIP, gzip, ALZ, EGG and lzip) for checking what
// Filee's own archive readers unpack. zlib's crc32 is the same reflected polynomial (0xEDB88320).

import Foundation
import zlib

/// Incremental CRC-32 (Filee's `Crc32`).
struct ArchiveCrc32 {
    private var crc: uLong = zlib.crc32(0, nil, 0)

    /// The checksum of everything passed to `append` so far.
    var value: UInt32 { UInt32(truncatingIfNeeded: crc) }

    mutating func append(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = min(raw.count - offset, 1 << 30)
                crc = zlib.crc32(crc, base + offset, uInt(count))
                offset += count
            }
        }
    }

    /// CRC-32 of `data`.
    static func compute(_ data: Data) -> UInt32 {
        var crc = ArchiveCrc32()
        crc.append(data)
        return crc.value
    }
}
