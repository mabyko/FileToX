import Foundation
import XCTest
@testable import FileToXCore

final class ManagedEngineClientTests: XCTestCase {
    func testPackageProgressAndActiveStatesDecodeWithoutChangingSettingsSchema() throws {
        for (state, active) in [("queued", true), ("downloading", true), ("verifying", true), ("installing", true), ("cancelling", true), ("installed", false), ("failed", false), ("cancelled", false)] {
            let json: [String: Any] = ["id": "pandoc", "version": "3.12", "downloadSize": 100, "installedSize": 200,
                "canDownload": true, "state": state, "bytesReceived": 120]
            let package = try JSONDecoder.hostDecoder().decode(HostEnginePackage.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(package.isActive, active, state); XCTAssertEqual(package.progress, 1)
        }
    }

    func testInstallAcknowledgesImmediatelyAndStatusCancelAndShutdownStayResponsive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("filetox-install-client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("host.py")
        let script = #"""
        #!/usr/bin/env python3
        import json,sys,os
        os.setpgid(0,0)
        state="idle"
        stopping_polls=0
        def package():return {"id":"pandoc","version":"3.12","downloadSize":100,"installedSize":200,"canDownload":True,"state":state,"bytesReceived":10}
        def send(v):print(json.dumps(v),flush=True)
        send({"v":1,"event":"hello","data":{"protocol":1,"hostVersion":"test","fileeCommit":"21fdd05ef7181b032ed83ec895cc9bbc4b198985","rid":"osx-arm64","dataDir":"private"}})
        for line in sys.stdin:
            r=json.loads(line);m=r["method"];result={}
            if m=="engine.install":
                assert r["params"]=={"packageId":"pandoc"}
                state="downloading";result=package()
            elif m=="engine.install.cancel":state="cancelled";result=package()
            elif m=="engine.install.stop":
                if state=="downloading":state="cancelling";stopping_polls=55
            elif m=="engine.packages":
                if state=="cancelling":
                    stopping_polls-=1
                    if stopping_polls<=0:state="cancelled"
                result={"packages":[package()]}
            elif m=="watch.status":result={"rules":[]}
            send({"v":1,"id":r["id"],"result":result})
        assert state=="cancelled", "stdin closed before cleanup finished"
        with open(os.path.join(os.path.dirname(__file__),"clean-shutdown"),"w") as f:f.write("ok")
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let host = EngineHost(executableURL: executable, dataDirectory: root.appendingPathComponent("data"))
        _ = try await host.start()
        let start = Date()
        let accepted = try await host.installEngine(packageId: "pandoc")
        XCTAssertEqual(accepted.state, "downloading")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let status = try await host.enginePackages(), watch = try await host.watchStatus()
        XCTAssertEqual(status.first?.state, "downloading"); XCTAssertTrue(watch.isEmpty)
        let cancelled = try await host.cancelEngineInstall(packageId: "pandoc")
        XCTAssertEqual(cancelled.state, "cancelled")
        _ = try await host.installEngine(packageId: "pandoc")
        let shutdownStarted = Date()
        await host.shutdown()
        XCTAssertGreaterThan(Date().timeIntervalSince(shutdownStarted), 5)
        XCTAssertLessThan(Date().timeIntervalSince(shutdownStarted), 10)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("clean-shutdown"), encoding: .utf8), "ok")
    }
}
