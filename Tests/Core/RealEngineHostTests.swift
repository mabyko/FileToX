import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FileToXCore

final class RealEngineHostTests: XCTestCase {
    func testLanguageChangesReachHostWithoutRestartAndSettingsPersist() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let executable = ProcessInfo.processInfo.environment["FILETOX_TEST_HOST"].map(URL.init(fileURLWithPath:))
            ?? root.appendingPathComponent("build/engine-host/osx-arm64/Debug/FileToXEngine.app/Contents/MacOS/FileToXEngine")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Build the engine host first with Tools/build-engine-host.sh.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = folder.appendingPathComponent("host")
        let host = EngineHost(executableURL: executable, dataDirectory: data)
        do {
            var library = try await host.library()
            XCTAssertEqual(library.settings["language"]?.string, "en")
            XCTAssertEqual(library.settings["theme"]?["accent"]?.string, "#3478F6")
            let source = try imageFixture(folder.appendingPathComponent("image.png"))
            let english = try await host.resolve(paths: [source.path])
            var presets = library.presets
            presets[0]["name"] = .string("My custom preset 이름")
            library = try await host.saveLibrary(baseRevision: library.revision, presets: presets, profiles: library.profiles)
            let savedPresets = library.presets
            let savedProfiles = library.profiles
            for language in ["ja", "ko", "en", "ja"] {
                var settings = library.settings
                settings["language"] = .string(language)
                var theme = settings["theme"] ?? .object([:])
                theme["accent"] = .string("#C4603A")
                settings["theme"] = theme
                library = try await host.saveSettings(baseRevision: library.revision, settings: settings)
                XCTAssertEqual(library.settings["language"]?.string, language)
                XCTAssertEqual(library.presets, savedPresets)
                XCTAssertEqual(library.profiles, savedProfiles)
                if language == "ja" {
                    let japanese = try await host.resolve(paths: [source.path])
                    XCTAssertTrue(japanese.slices.contains { slice in
                        english.slices.contains { $0.presetId == slice.presetId && $0.displayName != slice.displayName }
                    }, "Changing settings must change the running host's localized names.")
                    XCTAssertTrue(japanese.slices.contains { slice in
                        slice.displayName.unicodeScalars.contains { (0x3040...0x30FF).contains(Int($0.value)) }
                    })
                }
            }
            await host.shutdown()
            let restarted = EngineHost(executableURL: executable, dataDirectory: data)
            do {
                let persisted = try await restarted.library()
                XCTAssertEqual(persisted.settings["language"]?.string, "ja")
                XCTAssertEqual(persisted.settings["theme"]?["accent"]?.string, "#C4603A")
                XCTAssertEqual(persisted.presets, savedPresets)
                await restarted.shutdown()
            } catch {
                await restarted.shutdown()
                throw error
            }
        } catch {
            await host.shutdown()
            throw error
        }
    }

    @MainActor
    func testBundledHostConvertsImagesPDFAndArchivesThroughSwiftClient() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let executable = ProcessInfo.processInfo.environment["FILETOX_TEST_HOST"].map(URL.init(fileURLWithPath:))
            ?? root.appendingPathComponent("build/engine-host/osx-arm64/Debug/FileToXEngine.app/Contents/MacOS/FileToXEngine")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Build the engine host first with Tools/build-engine-host.sh.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let host = EngineHost(executableURL: executable, dataDirectory: folder.appendingPathComponent("host"))
        var completed: [String: HostJob] = [:]
        let events = await host.events()
        let consumer = Task { @MainActor in
            for await event in events {
                if case .finished(let job) = event { completed[job.id] = job }
            }
        }
        do {
            let hello = try await host.start()
            XCTAssertEqual(hello.rid, "osx-arm64")
            let catalog = try await host.catalog()
            XCTAssertEqual(catalog.formats.count, 172)
            XCTAssertEqual(catalog.engines.count, 23)
            let library = try await host.library()
            let source = try imageFixture(folder.appendingPathComponent("한글 사진.png"))
            let original = try Data(contentsOf: source)
            let selection = try await host.resolve(paths: [source.path])
            XCTAssertTrue(selection.targets.contains { $0.formatId == "jpg" && $0.available })

            func finish(_ id: String) async throws -> HostJob {
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                while completed[id] == nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let job = try XCTUnwrap(completed[id], "No terminal event for \(id)")
                XCTAssertEqual(job.state, "completed", job.files.compactMap(\.errorDetail).joined(separator: "\n"))
                return job
            }
            let jpeg = try await finish(host.startJob(paths: [source.path], targetFormat: "jpg"))
            let output = try XCTUnwrap(jpeg.outputs.first)
            let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(output.url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(decoded) as String?, UTType.jpeg.identifier)
            XCTAssertEqual(try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil)).width, 12)
            XCTAssertEqual(try Data(contentsOf: source), original)

            let second = try imageFixture(folder.appendingPathComponent("second.png"))
            let merge = try XCTUnwrap(library.presets.first { $0["pdf"]?["mergeIntoSingle"]?.bool == true })
            let pdf = try await finish(host.startJob(paths: [source.path, second.path], preset: merge))
            XCTAssertEqual(pdf.outputs.count, 1)
            let pages = try await finish(host.startJob(paths: [try XCTUnwrap(pdf.outputs.first).path], targetFormat: "png"))
            XCTAssertEqual(pages.outputs.count, 2)
            for page in pages.outputs {
                XCTAssertNotNil(CGImageSourceCreateWithURL(page.url as CFURL, nil))
            }

            let unknown = folder.appendingPathComponent("note.unknown")
            try Data("unknown format still archives".utf8).write(to: unknown)
            let inputFolder = folder.appendingPathComponent("files", isDirectory: true)
            try FileManager.default.createDirectory(at: inputFolder, withIntermediateDirectories: false)
            try Data("inside".utf8).write(to: inputFolder.appendingPathComponent("inside.txt"))
            let zipPreset = try XCTUnwrap(library.presets.first { $0["archive"]?["combineIntoOne"]?.bool == true })
            let archive = try await finish(host.startJob(paths: [source.path, unknown.path, inputFolder.path], preset: zipPreset))
            XCTAssertEqual(archive.outputs.count, 1)
            let extracted = try await finish(host.startJob(paths: [try XCTUnwrap(archive.outputs.first).path], targetFormat: "folder"))
            let directory = try XCTUnwrap(extracted.outputs.first)
            XCTAssertTrue(directory.isDirectory)
            XCTAssertEqual(try Data(contentsOf: directory.url.appendingPathComponent("note.unknown")), Data("unknown format still archives".utf8))
            XCTAssertEqual(try Data(contentsOf: source), original)
            let history = try await host.history()
            XCTAssertEqual(history.count, 5)
            XCTAssertTrue(history.contains { $0.outputs.count == 2 })
            await host.shutdown()
            consumer.cancel()
            try FileManager.default.removeItem(at: folder)
        } catch {
            await host.shutdown()
            consumer.cancel()
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func imageFixture(_ url: URL) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
