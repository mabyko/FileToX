import XCTest
import CryptoKit
@testable import FileToXEngineKit

final class ManagedEngineInstallerTests: XCTestCase {
    func testOnlyPinnedMacPackagesAreOfferedAndUnsupportedArchitectureCannotStart() throws {
        let d = CoreTempDir()
        let installer = ManagedEngineInstaller(root: d.path + "/engines")
        let packages = installer.snapshot()
        XCTAssertEqual(Set(packages.filter(\.canDownload).map(\.id)), ["pandoc", "calibre", "libreoffice"])
        XCTAssertEqual(packages.first { $0.id == "pandoc" }?.downloadSize, 42_267_373)
        XCTAssertEqual(packages.first { $0.id == "pandoc" }?.version, "3.12")
        for id in ["ffmpeg", "ghostscript", "../pandoc", "rhwp", "https://example.com/a.zip"] { XCTAssertThrowsError(try installer.start(id)) }
        let unsupported = ManagedEngineInstaller(root: d.path + "/unsupported", runtime: "osx-x64")
        XCTAssertFalse(unsupported.snapshot().contains(where: \.canDownload))
        XCTAssertThrowsError(try unsupported.start("pandoc"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.path + "/engines"))
    }

    func testSizeAndHashFailuresNeverExtractOrExecuteAndCleanStaging() async throws {
        for mutation in ["partial", "oversized", "hash", "corrupt"] {
            let d = CoreTempDir(), archive = try fixture(d, program: "#!/bin/sh\ntouch '\(d.path)/executed'\necho fixture\n")
            var data = try Data(contentsOf: URL(fileURLWithPath: archive))
            var component = try pin(archive)
            switch mutation {
            case "partial": data.removeLast()
            case "oversized": data.append(0)
            case "hash": data[0] ^= 1
            default: data = Data("not a zip".utf8); component = pin(data)
            }
            let bytes = data
            let installer = ManagedEngineInstaller(root: d.path + "/engines", components: ["pandoc": component], download: { _, path, progress in
                try bytes.write(to: URL(fileURLWithPath: path)); progress(Int64(bytes.count))
            })
            _ = try installer.start("pandoc")
            let status = try await finished(installer)
            XCTAssertEqual(status.state, "failed", mutation)
            XCTAssertEqual(status.errorKey, mutation == "hash" ? "engines.error.hash" : mutation == "corrupt" ? "engines.error.install" : "engines.error.size")
            XCTAssertFalse(FileManager.default.fileExists(atPath: d.path + "/executed"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: d.path + "/engines"), [])
        }
    }

    func testZipRejectsTraversalAliasesDuplicateNamesSpecialFilesAndExpansion() throws {
        for name in ["../escape", "/escape", "a/../../escape", "a\\escape", "C:escape", "./escape", "a//escape", "a/\0escape"] {
            let d = CoreTempDir(), archive = d.path + "/input.zip", out = d.path + "/out"
            let writer = try ZipWriter(path: archive); try writer.add(name, text: "bad"); try writer.close()
            try FileManager.default.createDirectoryIfNeeded(out)
            XCTAssertThrowsError(try ManagedEngineInstaller.extractZip(archive, into: out, limit: 1024), name)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out), [])
        }
        for pair in [["bin/tool", "BIN/TOOL"], ["é", "e\u{301}"], ["bin/", "bin"]] {
            let d = CoreTempDir(), archive = d.path + "/input.zip"
            let writer = try ZipWriter(path: archive)
            for name in pair { try writer.add(name, text: "x") }; try writer.close()
            XCTAssertThrowsError(try ManagedEngineInstaller.extractZip(archive, into: d.path, limit: 1024))
        }
        for mode: UInt16 in [0o010644, 0o020644] {
            let d = CoreTempDir(), archive = d.path + "/input.zip"
            let writer = try ZipWriter(path: archive); try writer.add("device", data: Data(), unixMode: mode); try writer.close()
            XCTAssertThrowsError(try ManagedEngineInstaller.extractZip(archive, into: d.path, limit: 1024))
        }
        let d = CoreTempDir(), archive = try fixture(d)
        XCTAssertThrowsError(try ManagedEngineInstaller.extractZip(archive, into: d.path, limit: 1))
    }

    func testZipInternalFileLinksWorkButEscapesAndLinkParentsFail() throws {
        for target in ["bin/pandoc", "../outside", "/tmp/outside", "missing", "bin"] {
            let d = CoreTempDir(), archive = d.path + "/input.zip", out = d.path + "/out"
            let writer = try ZipWriter(path: archive)
            try writer.add("bin/pandoc", data: Data("program".utf8), unixMode: 0o755)
            try writer.add("alias", data: Data(target.utf8), unixMode: 0o120777)
            try writer.close(); try FileManager.default.createDirectoryIfNeeded(out)
            if target == "bin/pandoc" {
                try ManagedEngineInstaller.extractZip(archive, into: out, limit: 1024)
                XCTAssertEqual(try String(contentsOfFile: out + "/alias", encoding: .utf8), "program")
            } else { XCTAssertThrowsError(try ManagedEngineInstaller.extractZip(archive, into: out, limit: 1024), target) }
        }
        let d = CoreTempDir(), archive = d.path + "/input.zip", out = d.path + "/out"
        let writer = try ZipWriter(path: archive)
        try writer.add("redirect", data: Data("../outside".utf8), unixMode: 0o120777)
        try writer.add("redirect/escape", text: "bad"); try writer.close()
        try FileManager.default.createDirectoryIfNeeded(out)
        XCTAssertThrowsError(try ManagedEngineInstaller.extractZip(archive, into: out, limit: 1024))
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.path + "/outside"))
    }

    func testCancellationIsPromptRetryWorksAndDuplicateStartIsIdempotent() async throws {
        let d = CoreTempDir(), archive = try fixture(d), started = expectation(description: "download started")
        let state = InstallTestState()
        let installer = ManagedEngineInstaller(root: d.path + "/engines", components: ["pandoc": try pin(archive)], download: { _, path, progress in
            let attempt = state.lock.withLock { state.attempts += 1; return state.attempts }
            if attempt == 1 {
                try Data("partial".utf8).write(to: URL(fileURLWithPath: path)); progress(7); started.fulfill()
                while true { try await Task.sleep(nanoseconds: 10_000_000) }
            }
            try FileManager.default.copyItem(atPath: archive, toPath: path)
        })
        XCTAssertEqual(try installer.start("pandoc").state, "queued")
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(try installer.start("pandoc").state, "downloading")
        XCTAssertEqual(installer.snapshot().first { $0.id == "pandoc" }?.bytesReceived, 7)
        XCTAssertEqual(try installer.cancel("pandoc").state, "cancelling")
        let cancelled = try await finished(installer)
        XCTAssertEqual(cancelled.state, "cancelled")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: d.path + "/engines"), [])
        _ = try installer.start("pandoc")
        let installed = try await finished(installer)
        XCTAssertEqual(installed.state, "installed", installed.errorDetail ?? "")
        XCTAssertEqual(state.lock.withLock { state.attempts }, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: d.path + "/engines"), ["pandoc"])
        XCTAssertThrowsError(try installer.start("pandoc"))
    }

    func testExistingDestinationAndRootSymlinksAreNeverOverwritten() async throws {
        for variant in ["existing", "race", "symlink", "root-link"] {
            let d = CoreTempDir(), archive = try fixture(d), root = d.path + "/engines"
            let keep = try d.file("original/keep", "original")
            let originalPermissions = try FileManager.default.attributesOfItem(atPath: d.path + "/original")[.posixPermissions] as? NSNumber
            if variant == "existing" { _ = try d.file("engines/pandoc/keep", "original") }
            if variant == "symlink" {
                try FileManager.default.createDirectoryIfNeeded(root)
                try FileManager.default.createSymbolicLink(atPath: root + "/pandoc", withDestinationPath: d.path + "/original")
            }
            if variant == "root-link" { try FileManager.default.createSymbolicLink(atPath: root, withDestinationPath: d.path + "/original") }
            let installer = ManagedEngineInstaller(root: root, components: ["pandoc": try pin(archive)], download: { _, path, _ in
                if variant == "race" {
                    try FileManager.default.createDirectoryIfNeeded(root + "/pandoc")
                    try Data("original".utf8).write(to: URL(fileURLWithPath: root + "/pandoc/keep"))
                }
                try FileManager.default.copyItem(atPath: archive, toPath: path)
            })
            if ["existing", "symlink"].contains(variant) { XCTAssertThrowsError(try installer.start("pandoc")) }
            else {
                _ = try installer.start("pandoc")
                let status = try await finished(installer)
                XCTAssertEqual(status.state, "failed", variant)
            }
            XCTAssertEqual(try String(contentsOfFile: keep, encoding: .utf8), "original")
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: d.path + "/original")[.posixPermissions] as? NSNumber, originalPermissions)
            if variant != "root-link" { XCTAssertEqual(try d.read("engines/pandoc/keep"), "original") }
            XCTAssertFalse((try FileManager.default.contentsOfDirectory(atPath: root)).contains { $0.hasPrefix(".install-") })
        }
    }

    func testFailedPartialDownloadCanRetryWithoutKeepingPartialFiles() async throws {
        let d = CoreTempDir(), archive = try fixture(d), state = InstallTestState()
        let installer = ManagedEngineInstaller(root: d.path + "/engines", components: ["pandoc": try pin(archive)], download: { _, path, _ in
            let attempt = state.lock.withLock { state.attempts += 1; return state.attempts }
            if attempt == 1 {
                try Data("partial".utf8).write(to: URL(fileURLWithPath: path))
                throw EngineInstallFailure("engines.error.download", "Connection lost")
            }
            try FileManager.default.copyItem(atPath: archive, toPath: path)
        })
        _ = try installer.start("pandoc")
        let failed = try await finished(installer)
        XCTAssertEqual(failed.state, "failed"); XCTAssertEqual(failed.errorKey, "engines.error.download")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: d.path + "/engines"), [])
        _ = try installer.start("pandoc")
        let retry = try await finished(installer)
        XCTAssertEqual(retry.state, "installed", retry.errorDetail ?? "")
        XCTAssertNil(retry.errorKey); XCTAssertNil(retry.errorDetail)
    }

    func testMissingOrNonExecutableOrFailingProgramIsNotPublished() async throws {
        for variant in ["missing", "nonExecutable", "failed"] {
            let d = CoreTempDir()
            let archive = try fixture(d, name: variant == "missing" ? "wrong" : "bin/pandoc",
                program: variant == "failed" ? "#!/bin/sh\nexit 42\n" : "#!/bin/sh\necho fixture\n", mode: variant == "nonExecutable" ? 0o644 : 0o755)
            let installer = localInstaller(d, archive)
            _ = try installer.start("pandoc")
            let status = try await finished(installer)
            XCTAssertEqual(status.state, "failed"); XCTAssertEqual(status.errorKey, "engines.error.program", variant)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: d.path + "/engines"), [])
        }
    }

    func testApplicationTreeAllowsInternalFrameworkLinksAndRejectsEscapes() throws {
        let d = CoreTempDir(), app = d.path + "/Test.app"
        _ = try d.file("Test.app/Contents/Frameworks/F.framework/Versions/A/F", "signed resource")
        let versions = app + "/Contents/Frameworks/F.framework/Versions"
        try FileManager.default.createSymbolicLink(atPath: versions + "/Current", withDestinationPath: "A")
        try ManagedEngineInstaller.validateTree(app)
        try FileManager.default.createSymbolicLink(atPath: app + "/escape", withDestinationPath: "../outside")
        _ = try d.file("outside", "original")
        XCTAssertThrowsError(try ManagedEngineInstaller.validateTree(app))
        XCTAssertEqual(try d.read("outside"), "original")
    }

    func testDMGDetachRunsAfterCopyFailureAndCancellationDuringAttach() async throws {
        for cancel in [false, true] {
            let d = CoreTempDir(), attached = expectation(description: "attach")
            let state = InstallTestState()
            let bytes = Data("mock disk image".utf8), component = pin(bytes, id: "calibre", kind: "dmg")
            let installer = ManagedEngineInstaller(root: d.path + "/engines", components: ["calibre": component], download: { _, path, _ in
                try bytes.write(to: URL(fileURLWithPath: path))
            }, run: { executable, args, _ in
                state.lock.withLock { state.calls.append([executable] + args) }
                if args.first == "attach" {
                    state.lock.withLock { state.archive = args.last; state.mounted = true }
                    let mount = args[try XCTUnwrap(args.firstIndex(of: "-mountpoint")) + 1]
                    try FileManager.default.createDirectoryIfNeeded(mount + "/calibre.app")
                    attached.fulfill()
                    if cancel { while !state.lock.withLock({ state.released }) { try await Task.sleep(nanoseconds: 10_000_000) } }
                    return ProcessResult(exitCode: 0, standardOutput: "mounted", standardError: "")
                }
                if executable == "/usr/bin/ditto" { return ProcessResult(exitCode: 1, standardOutput: "", standardError: "copy failed") }
                if args.first == "info" {
                    let images: [[String: Any]] = state.lock.withLock {
                        state.mounted ? [["image-path": state.archive!, "system-entities": [["dev-entry": "/dev/disk12345"]]]] : []
                    }
                    let data = try PropertyListSerialization.data(fromPropertyList: ["images": images], format: .xml, options: 0)
                    return ProcessResult(exitCode: 0, standardOutput: String(decoding: data, as: UTF8.self), standardError: "")
                }
                if args.first == "detach" {
                    XCTAssertFalse(Task.isCancelled, "Cleanup must run outside the cancelled task")
                    XCTAssertEqual(args.last, "/dev/disk12345")
                    state.lock.withLock { state.mounted = false }
                }
                return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
            })
            _ = try installer.start("calibre")
            await fulfillment(of: [attached], timeout: 2)
            if cancel { _ = try installer.cancel("calibre"); state.lock.withLock { state.released = true } }
            let status = try await finished(installer, id: "calibre")
            XCTAssertEqual(status.state, cancel ? "cancelled" : "failed")
            let observed = state.lock.withLock { state.calls }
            XCTAssertEqual(observed.filter { $0.dropFirst().first == "detach" }.count, 1)
            XCTAssertEqual(observed.filter { $0.first == "/usr/bin/ditto" }.count, cancel ? 0 : 1)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: d.path + "/engines"), [])
        }
    }

    func testCancellationDuringCopyDetachesRealPrivateDiskImage() async throws {
        let d = CoreTempDir(), image = d.path + "/fixture.dmg", copying = expectation(description: "copy started")
        _ = try d.file("volume/calibre.app/Contents/MacOS/ebook-convert", "fixture")
        let created = try await ProcessRunner.run("/usr/bin/hdiutil", ["create", "-srcfolder", d.path + "/volume", "-format", "UDZO", "-volname", "FileToX private fixture", image], timeout: 30)
        XCTAssertEqual(created.exitCode, 0, created.standardError)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: image))
        let state = InstallTestState()
        defer {
            if let path = state.lock.withLock({ state.mount }),
               let info = try? ProcessRunner.runBlocking("/usr/bin/hdiutil", ["info", "-plist"], timeout: 10), info.standardOutput.contains(path) {
                _ = try? ProcessRunner.runBlocking("/usr/bin/hdiutil", ["detach", "-force", path], timeout: 10)
            }
        }
        let installer = ManagedEngineInstaller(root: d.path + "/engines", components: ["calibre": pin(bytes, id: "calibre", kind: "dmg")], download: { _, path, _ in
            try FileManager.default.copyItem(atPath: image, toPath: path)
        }, run: { executable, args, timeout in
            if args.first == "attach" { state.lock.withLock { state.mount = args[args.firstIndex(of: "-mountpoint")! + 1] } }
            if executable == "/usr/bin/ditto" {
                copying.fulfill()
                return try await ProcessRunner.run("/bin/sleep", ["30"], timeout: 35)
            }
            if args.first == "detach" { XCTAssertFalse(Task.isCancelled) }
            return try await ProcessRunner.run(executable, args, timeout: timeout)
        })
        _ = try installer.start("calibre")
        await fulfillment(of: [copying], timeout: 30)
        _ = try installer.cancel("calibre")
        let status = try await finished(installer, id: "calibre", timeout: 30)
        XCTAssertEqual(status.state, "cancelled", status.errorDetail ?? "")
        let info = try await ProcessRunner.run("/usr/bin/hdiutil", ["info", "-plist"], timeout: 10)
        XCTAssertFalse(info.standardOutput.contains(d.path + "/engines/.install-"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: d.path + "/engines"), [])
    }

    func testDMGCleanupTargetsOnlyItsImageRetriesDetachAndRetainsUnreleasedMount() async throws {
        for variant in ["attachFailedMounted", "attachFailedUnmounted", "forceDetach", "detachFailed"] {
            let d = CoreTempDir(), state = InstallTestState(), bytes = Data("fixture image".utf8)
            let installer = ManagedEngineInstaller(root: d.path + "/engines", components: ["calibre": pin(bytes, id: "calibre", kind: "dmg")], download: { _, path, _ in
                try bytes.write(to: URL(fileURLWithPath: path))
            }, run: { executable, args, _ in
                if args.first == "attach" {
                    state.lock.withLock { state.archive = args.last; state.mounted = variant != "attachFailedUnmounted" }
                    let mount = args[args.firstIndex(of: "-mountpoint")! + 1]
                    try FileManager.default.createDirectoryIfNeeded(mount + "/calibre.app")
                    return ProcessResult(exitCode: variant.hasPrefix("attachFailed") ? 1 : 0, standardOutput: "", standardError: "fixture attach")
                }
                if args.first == "info" {
                    var images: [[String: Any]] = [["image-path": "/tmp/unrelated-user-image.dmg", "system-entities": [["dev-entry": "/dev/disk99999"]]]]
                    if state.lock.withLock({ state.mounted }) { images.append(["image-path": state.lock.withLock { state.archive! }, "system-entities": [["dev-entry": "/dev/disk12345s1"]]]) }
                    let data = try PropertyListSerialization.data(fromPropertyList: ["images": images], format: .xml, options: 0)
                    return ProcessResult(exitCode: 0, standardOutput: String(decoding: data, as: UTF8.self), standardError: "")
                }
                if args.first == "detach" {
                    XCTAssertFalse(Task.isCancelled); XCTAssertEqual(args.last, "/dev/disk12345")
                    state.lock.withLock { state.calls.append(args) }
                    let success = variant != "detachFailed" && (variant != "forceDetach" || args.contains("-force"))
                    if success { state.lock.withLock { state.mounted = false } }
                    return ProcessResult(exitCode: success ? 0 : 1, standardOutput: "", standardError: "fixture detach")
                }
                XCTAssertEqual(executable, "/usr/bin/ditto")
                return ProcessResult(exitCode: 1, standardOutput: "", standardError: "fixture copy failure")
            })
            _ = try installer.start("calibre")
            let result = try await finished(installer, id: "calibre")
            XCTAssertEqual(result.state, "failed", variant)
            let children = try FileManager.default.contentsOfDirectory(atPath: d.path + "/engines")
            if variant == "detachFailed" {
                XCTAssertEqual(result.errorKey, "engines.error.detach")
                XCTAssertEqual(children.count, 1); XCTAssertTrue(children[0].hasPrefix(".install-"))
            } else { XCTAssertEqual(children, [], variant) }
            XCTAssertEqual(state.lock.withLock { state.calls.count }, variant == "attachFailedUnmounted" ? 0 : variant == "attachFailedMounted" ? 1 : 2)
        }
    }

    func testHostDownloadsDoNotHoldGateOrBlockSettingsWatchStatusOrJobCancellation() async throws {
        let d = CoreTempDir(), archive = try fixture(d), started = expectation(description: "started")
        let installer = ManagedEngineInstaller(root: d.path + "/engines", components: ["pandoc": try pin(archive)], download: { _, _, _ in
            started.fulfill(); while true { try await Task.sleep(nanoseconds: 10_000_000) }
        })
        let store = UserDataStore(d.path + "/core"); try store.load()
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: try d.file("wire", "")))
        defer { try? output.close() }
        let wire = WireWriter(output.fileDescriptor)
        let host = Host(wire, store, [], Localizer("en"), languageFixed: true, engineInstaller: installer, onStaging: { _ in })
        XCTAssertThrowsError(try host.handle("bad", "engine.install", ["packageId": "pandoc", "url": "https://example.com/payload"]))
        _ = try host.handle("start", "engine.install", ["packageId": "pandoc"])
        await fulfillment(of: [started], timeout: 2)
        let start = Date()
        for method in ["engine.packages", "watch.status", "library.get", "watch.stop"] { _ = try host.handle("status", method, [:]) }
        _ = try host.handle("settings", "settings.save", ["baseRevision": 1, "settings": try WireJson.toNode(store.settings)])
        _ = try host.handle("cancel", "job.cancel", ["jobId": "absent"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        await host.cancelAll(1); wire.complete(1)
        let status = try await finished(installer)
        XCTAssertEqual(status.state, "cancelled")
        XCTAssertThrowsError(try installer.start("pandoc"))
    }

    func testPinnedPackagesInstallAndConvertPrivately() async throws {
        guard let cache = ProcessInfo.processInfo.environment["FILETOX_MANAGED_ARCHIVES"] else { throw XCTSkip("Opt in with a hash-checked archive cache; never writes the user's engine root.") }
        let requested = (ProcessInfo.processInfo.environment["FILETOX_MANAGED_PACKAGES"] ?? "pandoc,calibre,libreoffice").split(separator: ",").map(String.init)
        let d = CoreTempDir(), root = d.path + "/engines"
        let previous = (EngineEnvironment.downloadRoot, EngineEnvironment.baseDirectory, EngineEnvironment.ownCopies, EngineEnvironment.searchSystem)
        defer {
            EngineEnvironment.downloadRoot = previous.0; EngineEnvironment.baseDirectory = previous.1
            EngineEnvironment.ownCopies = previous.2; EngineEnvironment.searchSystem = previous.3
        }
        EngineEnvironment.downloadRoot = root; EngineEnvironment.baseDirectory = d.path + "/unbundled"
        EngineEnvironment.ownCopies = [:]; EngineEnvironment.searchSystem = false
        let installer = ManagedEngineInstaller(root: root, download: { component, path, progress in
            let cached = cache + "/" + component.sha256.lowercased() + "." + component.kind
            try ManagedEngineInstaller.verify(cached, component)
            try FileManager.default.copyItem(atPath: cached, toPath: path); progress(component.size)
        })
        for id in requested {
            _ = try installer.start(id)
            let status = try await finished(installer, id: id, timeout: 180)
            XCTAssertEqual(status.state, "installed", status.errorDetail ?? "")
            guard status.state == "installed" else { continue }
            let program = try XCTUnwrap(EngineEnvironment.bundledProgram(id, EngineEnvironment.ownCopyPrograms[id]![0]))
            let binaryHash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: program))).map { String(format: "%02x", $0) }.joined()
            print("MANAGED-INSTALL \(id) \(status.version ?? "") archive=\(EngineDownloads.components[id]!.sha256) binary=\(binaryHash)")
            let converter: Converter, source: String, target: String
            if id == "pandoc" {
                converter = PandocConverter(); source = try d.file("pandoc.rst", "Managed engine\n==============\n\nPrivate pinned package conversion.\n"); target = "docx"
            } else if id == "libreoffice" {
                converter = LibreOfficeConverter(EngineEnvironment(dataDirectory: d.path + "/state"))
                source = try d.file("office.rtf", "{\\rtf1\\ansi Private pinned package conversion.}"); target = "docx"
            } else {
                converter = CalibreConverter(); target = "epub"
                source = d.path + "/book.tcr"; try TcrWriter.encode(Data("Private pinned package conversion.\n".utf8)).write(to: URL(fileURLWithPath: source))
            }
            XCTAssertTrue(converter.status().isAvailable)
            let catalog = ConverterCatalog([converter]), queue = JobQueue(catalog)
            let job = await coreRun(queue, [source], corePreset(target))
            XCTAssertEqual(job.state, .completed, job.files.first?.errorDetail ?? "")
            XCTAssertFalse(job.outputs.isEmpty)
            for output in job.outputs {
                let zip = try ZipReader(path: output)
                let text: String
                if target == "docx" { text = try XCTUnwrap(zip.string(named: "word/document.xml")) }
                else {
                    text = try zip.entries.filter { $0.name.hasSuffix(".xhtml") || $0.name.hasSuffix(".html") }
                        .map { String(decoding: try zip.data(for: $0), as: UTF8.self) }.joined()
                }
                XCTAssertTrue(text.contains("Private pinned package conversion."), "Converted content is missing for \(id)")
                let hash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: output))).map { String(format: "%02x", $0) }.joined()
                print("MANAGED-CONVERSION \(id) \(target) sha256=\(hash)")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: source))
            if id == "pandoc" {
                let manual = try d.file("manual/pandoc", "manual original")
                EngineEnvironment.ownCopies = ["pandoc": manual]
                XCTAssertEqual(PandocConverter.locate(), manual)
                EngineEnvironment.ownCopies = [:]
            }
        }
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(atPath: root)).contains { $0.hasPrefix(".install-") })
    }

    private func fixture(_ d: CoreTempDir, name: String = "bin/pandoc", program: String = "#!/bin/sh\necho 'pandoc fixture'\n", mode: UInt16 = 0o755) throws -> String {
        let path = d.path + "/fixture.zip", writer = try ZipWriter(path: path)
        try writer.add(name, data: Data(program.utf8), unixMode: mode); try writer.close(); return path
    }
    private func pin(_ archive: String) throws -> EngineComponent { pin(try Data(contentsOf: URL(fileURLWithPath: archive))) }
    private func pin(_ data: Data, id: String = "pandoc", kind: String = "zip") -> EngineComponent {
        EngineComponent(id: id, version: "fixture", url: "https://example.invalid/pinned.zip",
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), size: Int64(data.count), kind: kind)
    }
    private func localInstaller(_ d: CoreTempDir, _ archive: String) -> ManagedEngineInstaller {
        ManagedEngineInstaller(root: d.path + "/engines", components: ["pandoc": try! pin(archive)], download: { _, path, _ in
            try FileManager.default.copyItem(atPath: archive, toPath: path)
        })
    }
    private func finished(_ installer: ManagedEngineInstaller, id: String = "pandoc", timeout: TimeInterval = 5) async throws -> EngineInstallStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while installer.isActive, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(installer.isActive, "Installer did not finish")
        return try XCTUnwrap(installer.snapshot().first { $0.id == id })
    }
}

private final class InstallTestState: @unchecked Sendable {
    let lock = NSLock()
    var attempts = 0
    var calls: [[String]] = []
    var mount: String?
    var archive: String?
    var mounted = false
    var released = false
}
