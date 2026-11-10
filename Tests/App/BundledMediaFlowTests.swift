import AppKit
import FileToXCore
import XCTest
@testable import FileToX

final class BundledMediaFlowTests: XCTestCase {
    @MainActor
    func testBundledMediaSelectionOptionsConversionCancellationAndRetry() async throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FileToXEngine.app/Contents/MacOS/FileToXEngine")
        let probe = helper.deletingLastPathComponent().appendingPathComponent("engines/ffmpeg/bin/ffprobe")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: probe.path))
        if let expected = ProcessInfo.processInfo.environment["FILETOX_TEST_HOME"] {
            XCTAssertEqual(URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path,
                           URL(fileURLWithPath: expected).standardizedFileURL.path)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-media-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "FileToX.BundledMediaFlow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let host = EngineHost(executableURL: helper, dataDirectory: root.appendingPathComponent("host"))
        let model = AppModel(host: host, defaults: defaults)
        do {
            await model.connect()
            XCTAssertTrue(model.isConnected, model.statusMessage)
            XCTAssertEqual(model.catalog?.engines.first { $0.id == "ffmpeg" }?.available, true)
            let source = root.appendingPathComponent("한글 음성.wav")
            let original = Self.wav(seconds: 2)
            try original.write(to: source)
            model.selectFiles([source, source])
            XCTAssertEqual(model.selectedFiles, [source])
            await model.resolve(model.selectedFiles, showRadial: false)
            XCTAssertTrue(model.selection?.targets.contains { $0.formatId == "amr" && $0.available } == true)
            var preset = try XCTUnwrap(model.library?.presets.first { $0["id"]?.string == "to-mp3" })
            let presetID = try XCTUnwrap(preset["id"]?.string)
            preset["name"] = .string("Bundled AMR")
            preset["targetFormat"] = .string("amr")
            preset["media"]?["audioBitrateKbps"] = .number(8)
            preset["output"]?["fileNamePattern"] = .string("bundled-{name}")
            let saved = await model.savePreset(preset)
            XCTAssertTrue(saved, model.statusMessage)
            let library = try await host.library()
            XCTAssertEqual(library.presets.first { $0["id"]?.string == presetID }, preset)
            await model.resolve([source], showRadial: false)
            await model.start(presetID: presetID)
            let first = try await finished(model, id: XCTUnwrap(model.radialJobID))
            XCTAssertEqual(first.state, "completed", model.statusMessage)
            let output = URL(fileURLWithPath: try XCTUnwrap(first.outputs.first))
            XCTAssertEqual(output.lastPathComponent, "bundled-한글 음성.amr")
            XCTAssertEqual(try Data(contentsOf: output).prefix(6), Data("#!AMR\n".utf8))
            let stream = try Self.audio(probe, output)
            XCTAssertEqual(stream["codec_name"] as? String, "amr_nb")
            XCTAssertEqual(stream["sample_rate"] as? String, "8000")
            XCTAssertEqual(stream["channels"] as? Int, 1)
            XCTAssertEqual(try Data(contentsOf: source), original)

            let longSource = root.appendingPathComponent("cancel.wav")
            let longOriginal = Self.wav(seconds: 120)
            try longOriginal.write(to: longSource)
            await model.resolve([longSource], showRadial: false)
            await model.start(targetFormat: "ogg")
            let cancelledID = try XCTUnwrap(model.radialJobID)
            await model.cancel(jobID: cancelledID)
            let cancelled = try await finished(model, id: cancelledID)
            XCTAssertEqual(cancelled.state, "cancelled")
            XCTAssertTrue(cancelled.outputs.isEmpty)
            XCTAssertFalse(model.isConverting)
            XCTAssertTrue(model.cancellingJobIDs.isEmpty)
            await model.retry(cancelled)
            let retryID = try XCTUnwrap(model.radialJobID)
            XCTAssertNotEqual(retryID, cancelledID)
            let retried = try await finished(model, id: retryID)
            XCTAssertEqual(retried.state, "completed", model.statusMessage)
            let retriedOutput = URL(fileURLWithPath: try XCTUnwrap(retried.outputs.first))
            XCTAssertEqual(try Self.audio(probe, retriedOutput)["codec_name"] as? String, "vorbis")
            XCTAssertEqual(try Data(contentsOf: longSource), longOriginal)
            let history = try await host.history()
            XCTAssertEqual(history.count, 3)
            await model.shutDown()
        } catch {
            await model.shutDown()
            throw error
        }
    }

    @MainActor
    private func finished(_ model: AppModel, id: String) async throws -> HostHistory {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !model.historyEntries.contains(where: { $0.jobId == id }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(model.historyEntries.first { $0.jobId == id }, model.statusMessage)
    }

    private static func wav(seconds: Int) -> Data {
        let rate = 48_000, samples = rate * seconds
        var data = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        number(UInt32(36 + samples * 2)); data.append(Data("WAVEfmt ".utf8))
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(rate))
        number(UInt32(rate * 2)); number(UInt16(2)); number(UInt16(16)); data.append(Data("data".utf8)); number(UInt32(samples * 2))
        let second = (0..<rate).map { Int16(12_000 * sin(Double($0) * 440 * 2 * .pi / Double(rate))).littleEndian }
        second.withUnsafeBytes { bytes in for _ in 0..<seconds { data.append(contentsOf: bytes) } }
        return data
    }

    private static func audio(_ probe: URL, _ file: URL) throws -> [String: Any] {
        let process = Process(), output = Pipe()
        process.executableURL = probe
        process.arguments = ["-v", "error", "-select_streams", "a:0", "-show_streams", "-of", "json", file.path]
        process.environment = ["HOME": NSHomeDirectory(), "TMPDIR": FileManager.default.temporaryDirectory.path,
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        return try XCTUnwrap((json["streams"] as? [[String: Any]])?.first)
    }
}
