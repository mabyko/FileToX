import Foundation
import XCTest
@testable import FileToXEngineKit

final class TcrWriterTests: XCTestCase {
    // Decode the file format independently: each of 256 length-prefixed strings replaces one payload byte.
    static func decode(_ data: Data) throws -> Data {
        let bytes = Array(data)
        guard bytes.starts(with: Array("!!8-Bit!!".utf8)) else { throw CocoaError(.fileReadCorruptFile) }
        var position = 9, entries = [Data]()
        for _ in 0..<256 {
            guard position < bytes.count else { throw CocoaError(.fileReadCorruptFile) }
            let count = Int(bytes[position]); position += 1
            guard count <= bytes.count - position else { throw CocoaError(.fileReadCorruptFile) }
            entries.append(Data(bytes[position..<(position + count)])); position += count
        }
        var result = Data()
        for code in bytes[position...] {
            guard !entries[Int(code)].isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            result.append(entries[Int(code)])
        }
        return result
    }

    func testPreservesTerminalCodesUnicodeAndAllByteValues() throws {
        let witnesses = [Data(), Data([0]), Data((0..<256).map(UInt8.init)),
                         Data("안녕하세요\n\n\nFileToX sample bold text.\n\n\n\n\n\n".utf8),
                         Data(String(repeating: "책 내용 🙂 한글 e\u{301}\n", count: 500).utf8),
                         Data(String(repeating: "a", count: 4097).utf8)]
        for source in witnesses {
            let encoded = try TcrWriter.encode(source)
            XCTAssertEqual(try Self.decode(encoded), source)
            XCTAssertEqual(try TcrWriter.encode(source), encoded)
        }
        let repeated = witnesses[4]
        XCTAssertLessThan(try TcrWriter.encode(repeated).count, repeated.count / 2)
    }

    func testDeterministicBinaryRoundTrips() throws {
        var state: UInt64 = 12345
        for length in [1, 2, 3, 255, 256, 1025, 8192] {
            for alphabet in [2, 17, 128, 256] {
                let source = Data((0..<length).map { _ -> UInt8 in
                    state = state &* 6364136223846793005 &+ 1
                    return UInt8((state >> 32) % UInt64(alphabet))
                })
                XCTAssertEqual(try Self.decode(TcrWriter.encode(source)), source)
            }
        }
    }

    func testCancelledCompressionDoesNotProduceOutput() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try TcrWriter.encode(Data("book".utf8))
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
