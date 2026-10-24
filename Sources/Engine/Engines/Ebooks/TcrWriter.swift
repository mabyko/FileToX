import Foundation

/// TCR's dictionary stores literal byte strings; payload bytes index those strings once, without recursion.
enum TcrWriter {
    static func encode(_ text: Data) throws -> Data {
        try Task.checkCancellation()
        var payload = Array(text)
        var dictionary = [[UInt8]](repeating: [], count: 256)
        for (index, byte) in payload.enumerated() {
            if index & 0xffff == 0 { try Task.checkCancellation() }
            dictionary[Int(byte)] = [byte]
        }

        // Only assign unused codes. Redefining a code still present in the stream caused Calibre's corruption.
        for free in 0..<256 where dictionary[free].isEmpty {
            try Task.checkCancellation()
            guard payload.count > 1 else { break }
            var counts = [Int](repeating: 0, count: 65536)
            var run = 1
            for index in 1..<payload.count {
                if index & 0xffff == 0 { try Task.checkCancellation() }
                let first = payload[index - 1], second = payload[index]
                run = first == second ? run + 1 : 1
                if first != second || run % 2 == 0 {
                    counts[Int(first) * 256 + Int(second)] += 1
                }
            }
            var best: Int?, saving = 0
            for pair in 0..<counts.count where counts[pair] > 0 {
                let length = dictionary[pair >> 8].count + dictionary[pair & 255].count
                let gain = counts[pair] - length
                if length <= 255 && gain > saving { best = pair; saving = gain }
            }
            guard let pair = best else { break }
            let first = UInt8(pair >> 8), second = UInt8(pair & 255)
            dictionary[free] = dictionary[Int(first)] + dictionary[Int(second)]
            var next = [UInt8](); next.reserveCapacity(payload.count - counts[pair])
            var index = 0
            while index < payload.count {
                if next.count & 0xffff == 0 { try Task.checkCancellation() }
                if index + 1 < payload.count && payload[index] == first && payload[index + 1] == second {
                    next.append(UInt8(free)); index += 2
                } else {
                    next.append(payload[index]); index += 1
                }
            }
            payload = next
        }
        try Task.checkCancellation()
        var result = Data("!!8-Bit!!".utf8)
        for entry in dictionary { result.append(UInt8(entry.count)); result.append(contentsOf: entry) }
        result.append(contentsOf: payload)
        return result
    }
}
