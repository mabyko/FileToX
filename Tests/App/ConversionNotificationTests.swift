import XCTest
@testable import FileToX

final class ConversionNotificationTests: XCTestCase {
    func testNotificationClickKeepsExistingFilesAndFoldersAndFallsBackAfterDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("filetox-notification-click-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("결과 file.txt")
        try Data("converted".utf8).write(to: file)
        let paths = [root.appendingPathComponent("missing.zip").path, file.path, root.path]
        XCTAssertEqual(ConversionNotification.existingOutputs(paths), [file.path, root.path])
        try FileManager.default.removeItem(at: root)
        XCTAssertTrue(ConversionNotification.existingOutputs(paths).isEmpty)
        XCTAssertTrue(ConversionNotification.existingOutputs([]).isEmpty)
    }

    @MainActor
    func testNotificationOptionsPartialFailuresCancellationAndOutputPaths() throws {
        let suite = "filetox-notification-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ApplicationPreferences(defaults: defaults)
        XCTAssertNil(ConversionNotification(job: try job(state: "completed"), preferences: preferences))
        preferences.notifyOnSuccess = true
        let completed = try XCTUnwrap(ConversionNotification(job: try job(state: "completed"), preferences: preferences))
        XCTAssertEqual(completed.outputs, ["/tmp/result.zip", "/tmp/other.zip"])
        XCTAssertNil(ConversionNotification(job: try job(state: "completedWithErrors"), preferences: preferences))
        XCTAssertNil(ConversionNotification(job: try job(state: "failed"), preferences: preferences))
        preferences.notifyOnSuccess = false
        preferences.notifyOnFailure = true
        XCTAssertNotNil(ConversionNotification(job: try job(state: "completedWithErrors"), preferences: preferences))
        XCTAssertNotNil(ConversionNotification(job: try job(state: "failed"), preferences: preferences))
        XCTAssertNil(ConversionNotification(job: try job(state: "completed"), preferences: preferences))
        XCTAssertNil(ConversionNotification(job: try job(state: "cancelled"), preferences: preferences))
        XCTAssertNil(ConversionNotification(job: try job(state: "running"), preferences: preferences))
    }

    @MainActor
    func testFinishedEventNotifiesOnceEvenWhenItArrivesBeforeStartResponse() throws {
        let model = AppModel()
        var deliveries: [String] = []
        model.onJobFinished = { deliveries.append($0.jobId) }
        model.consume(.updated(try job(state: "running")))
        XCTAssertTrue(deliveries.isEmpty)
        model.consume(.finished(try job(state: "completed")))
        model.consume(.finished(try job(state: "completed")))
        XCTAssertEqual(deliveries, ["one"])
        XCTAssertEqual(model.jobs.first?.state, "completed")
    }

    private func job(state: String) throws -> HostJob {
        let data = Data("""
        {"jobId":"one","state":"\(state)","progress":1,"presetName":"ZIP",
         "files":[{"source":"/tmp/input.txt","state":"completed","progress":1,"outputs":[{"path":"/tmp/result.zip","isDirectory":false}]}],
         "historyEntry":{"jobId":"one","finishedAt":"2026-10-22T10:00:00Z","presetId":"zip","presetName":"ZIP","state":"\(state)",
                         "sources":["/tmp/input.txt"],"outputs":["/tmp/result.zip","/tmp/other.zip"],"failures":[]}}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HostJob.self, from: data)
    }
}
