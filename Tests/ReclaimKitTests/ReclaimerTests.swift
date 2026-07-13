import XCTest
@testable import ReclaimKit

final class ReclaimerTests: XCTestCase {
    private var tempDirectory: URL!
    private var server: FakeDockerServer?

    override func setUpWithError() throws {
        // /tmp (not FileManager's real temp dir) to stay under AF_UNIX's 104-byte path cap.
        tempDirectory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("reclaim-reclaimer-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    /// SPEC.md §2.4: dry-run must be the default and must issue zero mutating requests.
    func testDryRunIssuesZeroMutatingRequests() async throws {
        let json = """
        {
          "LayersSize": 1000000000,
          "Images": [{ "Id": "sha256:aaa1", "Containers": 0, "Size": 900000000, "SharedSize": 0, "RepoTags": ["web-app:latest"] }],
          "Containers": [],
          "Volumes": [],
          "BuildCache": [{ "ID": "bc1", "Type": "regular", "Description": "test", "InUse": false, "Shared": true, "Size": 700000000, "CreatedAt": "2026-01-01T00:00:00Z", "LastUsedAt": "2026-01-01T00:00:00Z", "UsageCount": 1 }]
        }
        """
        server = try FakeDockerServer(directoryURL: tempDirectory.appendingPathComponent("sock")) { method, path, _ in
            // The dry run must never hit anything but GET /system/df.
            XCTAssertEqual(method, "GET", "dry run issued a non-GET request to \(path)")
            return .json(json)
        }

        let client = DockerClient(socketPath: server!.socketPath)
        let reclaimer = Reclaimer(dockerClient: client, backend: .colima, diskProbePath: tempDirectory.path)

        var events: [CleanEvent] = []
        let report = try await reclaimer.clean(options: CleanOptions(dryRun: true)) { events.append($0) }

        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.hostDelta, 0, "dry run must not claim any real space was returned")
        XCTAssertEqual(report.trimmedBytes, 0)

        let mutatingRequests = server!.requests.filter { $0.method == "POST" || $0.method == "DELETE" }
        XCTAssertEqual(mutatingRequests, [], "dry run must issue zero POST/DELETE requests")

        // The Docker-estimate numbers should still be surfaced, clearly labeled.
        XCTAssertTrue(report.steps.contains { $0.name.contains("build cache") && $0.dockerReportedBytes == 700_000_000 })
        XCTAssertTrue(report.steps.contains { $0.name.contains("images") && $0.dockerReportedBytes == 900_000_000 })

        let logMessages = events.compactMap { event -> String? in
            if case .log(let text) = event { return text }
            return nil
        }
        XCTAssertTrue(logMessages.contains { $0.lowercased().contains("dry run") })
    }

    func testDryRunNeverCallsSystemDFTwice() async throws {
        // Sanity: exactly one GET /system/df, no repeated calls, no calls to prune endpoints.
        server = try FakeDockerServer(directoryURL: tempDirectory.appendingPathComponent("sock")) { _, _, _ in
            .json(#"{"LayersSize":0,"Images":null,"Containers":null,"Volumes":null,"BuildCache":null}"#)
        }
        let client = DockerClient(socketPath: server!.socketPath)
        let reclaimer = Reclaimer(dockerClient: client, backend: .colima, diskProbePath: tempDirectory.path)
        _ = try await reclaimer.clean(options: CleanOptions(dryRun: true))

        XCTAssertEqual(server!.requests.count, 1)
        XCTAssertEqual(server!.requests.first?.path, "/system/df")
    }

    /// Exercises the real (non-dry-run) path end to end without shelling out to a real
    /// backend CLI: OrbStack's trim strategy is `.notNeeded` and never spawns a process, so
    /// this covers prune orchestration + honest statfs delta without needing a live VM.
    func testRealRunPrunesAndSkipsTrimForOrbstack() async throws {
        var seenPaths: [String] = []
        server = try FakeDockerServer(directoryURL: tempDirectory.appendingPathComponent("sock")) { method, path, _ in
            seenPaths.append("\(method) \(path)")
            if path.hasPrefix("/images/prune") {
                return .json(#"{"ImagesDeleted": [], "SpaceReclaimed": 900000000}"#)
            } else if path == "/build/prune?all=true" {
                return .json(#"{"CachesDeleted": [], "SpaceReclaimed": 700000000}"#)
            }
            return .json("{}")
        }

        let client = DockerClient(socketPath: server!.socketPath)
        let reclaimer = Reclaimer(dockerClient: client, backend: .orbstack, diskProbePath: tempDirectory.path)

        var sawTrimNote = false
        let report = try await reclaimer.clean(options: CleanOptions(dryRun: false)) { event in
            if case .log(let text) = event, text.contains("OrbStack") { sawTrimNote = true }
        }

        XCTAssertFalse(report.dryRun)
        XCTAssertEqual(report.trimmedBytes, 0)
        XCTAssertEqual(report.trimNote, "OrbStack reclaims disk space natively — no trim needed.")
        XCTAssertTrue(sawTrimNote)
        XCTAssertTrue(seenPaths.contains { $0.hasPrefix("POST /images/prune") })
        XCTAssertTrue(seenPaths.contains("POST /build/prune?all=true"))
        XCTAssertTrue(seenPaths.contains { !$0.hasPrefix("POST") && $0.contains("volume") } == false)

        // No volume-touching call of any kind was ever issued.
        XCTAssertFalse(seenPaths.contains { $0.lowercased().contains("volume") })

        let imagesStep = try XCTUnwrap(report.steps.first { $0.name == "images" })
        XCTAssertEqual(imagesStep.dockerReportedBytes, 900_000_000)
        let buildStep = try XCTUnwrap(report.steps.first { $0.name == "build cache" })
        XCTAssertEqual(buildStep.dockerReportedBytes, 700_000_000)
    }

    func testCleanReportHostDeltaIsFreeAfterMinusFreeBefore() {
        let report = CleanReport(
            dryRun: false,
            backend: .colima,
            hostFreeBefore: 6_500_000_000,
            hostFreeAfter: 57_000_000_000,
            steps: [],
            trimmedBytes: 53_456_729_292,
            trimNote: nil
        )
        XCTAssertEqual(report.hostDelta, 50_500_000_000)
    }
}
