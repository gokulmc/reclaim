import XCTest
@testable import ReclaimKit

/// Covers the named selective Docker cleanup path (M4a): `DockerClient.deleteImage` +
/// `decodeImageDeleteResult`, and `Reclaimer.cleanSelected`'s dry-run/real-run behavior.
final class DockerImageDeleteTests: XCTestCase {
    private var tempDirectory: URL!
    private var server: FakeDockerServer?

    override func setUpWithError() throws {
        // /tmp (not FileManager's real temp dir) to stay under AF_UNIX's 104-byte path cap.
        tempDirectory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("reclaim-imgdel-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    // MARK: - DockerClient.deleteImage

    func testDeleteImageParsesArrayResponseAndSetsForceQueryParam() async throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { method, path, _ in
            XCTAssertEqual(method, "DELETE")
            XCTAssertTrue(path.hasPrefix("/images/"))
            return .json(#"[{"Untagged":"repo:tag"},{"Deleted":"sha256:abc"}]"#)
        }
        let client = DockerClient(socketPath: server!.socketPath)
        let result = try await client.deleteImage(id: "sha256:abc", force: true)

        XCTAssertEqual(result.untagged, ["repo:tag"])
        XCTAssertEqual(result.deleted, ["sha256:abc"])
        XCTAssertEqual(server!.requests.count, 1)
        XCTAssertTrue(server!.requests[0].path.contains("?force=true"), "expected force=true in \(server!.requests[0].path)")
    }

    func testDeleteImageDefaultsForceFalseInQueryParam() async throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { _, _, _ in
            .json("[]")
        }
        let client = DockerClient(socketPath: server!.socketPath)
        _ = try await client.deleteImage(id: "sha256:abc")

        XCTAssertEqual(server!.requests.count, 1)
        XCTAssertTrue(server!.requests[0].path.contains("?force=false"), "expected force=false in \(server!.requests[0].path)")
    }

    func testDeleteImageEmptyArrayBodyDecodesToEmptyResult() async throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { _, _, _ in
            .json("[]")
        }
        let client = DockerClient(socketPath: server!.socketPath)
        let result = try await client.deleteImage(id: "sha256:abc")
        XCTAssertEqual(result, ImageDeleteResult(untagged: [], deleted: []))
    }

    func testDeleteImageTrulyEmptyBodyDecodesToEmptyResult() async throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { _, _, _ in
            FakeDockerServer.FakeResponse() // defaults: 200, empty body
        }
        let client = DockerClient(socketPath: server!.socketPath)
        let result = try await client.deleteImage(id: "sha256:abc")
        XCTAssertEqual(result, ImageDeleteResult(untagged: [], deleted: []))
    }

    func testDeleteImageNullBodyDecodesToEmptyResult() async throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { _, _, _ in
            .json("null")
        }
        let client = DockerClient(socketPath: server!.socketPath)
        let result = try await client.deleteImage(id: "sha256:abc")
        XCTAssertEqual(result, ImageDeleteResult(untagged: [], deleted: []))
    }

    func testDeleteImage409Throws() async throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { _, _, _ in
            .json(#"{"message":"conflict: unable to delete, image is referenced in multiple repositories"}"#, statusCode: 409)
        }
        let client = DockerClient(socketPath: server!.socketPath)
        do {
            _ = try await client.deleteImage(id: "sha256:abc")
            XCTFail("expected an error")
        } catch DockerClientError.unexpectedStatus(let code, _) {
            XCTAssertEqual(code, 409)
        }
    }

    func testDeleteImageRejectsIDWithSlashWithoutHittingServer() async throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { _, _, _ in
            .json("[]")
        }
        let client = DockerClient(socketPath: server!.socketPath)
        do {
            _ = try await client.deleteImage(id: "a/b")
            XCTFail("expected an error")
        } catch {
            // expected
        }
        XCTAssertEqual(server!.requests, [], "an invalid id must never reach the server")
    }

    func testDeleteImageRejectsEmptyIDWithoutHittingServer() async throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { _, _, _ in
            .json("[]")
        }
        let client = DockerClient(socketPath: server!.socketPath)
        do {
            _ = try await client.deleteImage(id: "")
            XCTFail("expected an error")
        } catch {
            // expected
        }
        XCTAssertEqual(server!.requests, [], "an invalid id must never reach the server")
    }

    // MARK: - Reclaimer.cleanSelected

    func testCleanSelectedDryRunIssuesZeroMutatingRequests() async throws {
        let json = """
        {
          "LayersSize": 500000000,
          "Images": [{ "Id": "sha256:aaa1", "Containers": 0, "Size": 123000000, "SharedSize": 0, "RepoTags": ["web-app:latest"] }],
          "Containers": [],
          "Volumes": [],
          "BuildCache": [{ "ID": "bc1", "Type": "regular", "Description": "test", "InUse": false, "Shared": true, "Size": 300000000, "CreatedAt": "2026-01-01T00:00:00Z", "LastUsedAt": "2026-01-01T00:00:00Z", "UsageCount": 1 }]
        }
        """
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        server = try FakeDockerServer(directoryURL: tempDirectory.appendingPathComponent("sock")) { method, _, _ in
            XCTAssertEqual(method, "GET", "dry run must only ever GET")
            return .json(json)
        }
        let client = DockerClient(socketPath: server!.socketPath)
        let reclaimer = Reclaimer(dockerClient: client, backend: .orbstack, diskProbePath: tempDirectory.path)

        let selection = DockerSelection(imageIDs: ["sha256:aaa1"], includeBuildCache: true)
        var logs: [String] = []
        let report = try await reclaimer.cleanSelected(selection, options: CleanOptions(dryRun: true)) { event in
            if case .log(let text) = event { logs.append(text) }
        }

        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.hostDelta, 0, "dry run must not claim any real space was returned")

        let mutatingRequests = server!.requests.filter { $0.method == "POST" || $0.method == "DELETE" }
        XCTAssertEqual(mutatingRequests, [], "dry run must issue zero POST/DELETE requests")

        XCTAssertTrue(logs.contains { $0.contains("would remove sha256:aaa1") })
        XCTAssertTrue(report.steps.contains { $0.name.contains("sha256:aaa1") && $0.dockerReportedBytes == 123_000_000 })
        XCTAssertTrue(report.steps.contains { $0.name.contains("build cache") && $0.dockerReportedBytes == 300_000_000 })
    }

    /// Real (non-dry-run) selective delete, mirroring
    /// `ReclaimerTests.testRealRunPrunesAndSkipsTrimForOrbstack`: OrbStack's trim strategy is
    /// `.notNeeded` and never spawns a process, so this exercises the delete + report shape
    /// without needing a live VM.
    func testCleanSelectedRealRunIssuesExpectedDeleteAndSkipsTrimForOrbstack() async throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        var seenPaths: [String] = []
        server = try FakeDockerServer(directoryURL: tempDirectory.appendingPathComponent("sock")) { method, path, _ in
            seenPaths.append("\(method) \(path)")
            if path.hasPrefix("/images/sha256:aaa1") {
                return .json(#"[{"Deleted":"sha256:aaa1"}]"#)
            }
            if path == "/system/df" {
                return .json(#"{"LayersSize":0,"Images":[{"Id":"sha256:aaa1","Containers":0,"Size":123000000,"SharedSize":0,"RepoTags":["web-app:latest"]}],"Containers":[],"Volumes":[],"BuildCache":[]}"#)
            }
            return .json("{}")
        }
        let client = DockerClient(socketPath: server!.socketPath)
        let reclaimer = Reclaimer(dockerClient: client, backend: .orbstack, diskProbePath: tempDirectory.path)

        let selection = DockerSelection(imageIDs: ["sha256:aaa1"], includeBuildCache: false)
        let report = try await reclaimer.cleanSelected(selection, options: CleanOptions(dryRun: false))

        XCTAssertFalse(report.dryRun)
        XCTAssertTrue(seenPaths.contains { $0.hasPrefix("DELETE /images/sha256:aaa1") }, "expected a DELETE /images/sha256:aaa1 request, saw \(seenPaths)")
        XCTAssertTrue(seenPaths.contains { $0.contains("force=false") })
        XCTAssertFalse(seenPaths.contains { $0.lowercased().contains("volume") })
        XCTAssertEqual(report.trimNote, "OrbStack reclaims disk space natively — no trim needed.")

        let imageStep = try XCTUnwrap(report.steps.first { $0.name == "image sha256:aaa1" })
        XCTAssertEqual(imageStep.dockerReportedBytes, 123_000_000)
    }

    /// Docker's 409 (in use / multi-tagged) on one image must not abort the rest of the
    /// selection — this is the "skip and continue" contract `cleanSelected` promises.
    func testCleanSelectedRealRunSkipsImageOn409AndContinues() async throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        server = try FakeDockerServer(directoryURL: tempDirectory.appendingPathComponent("sock")) { _, path, _ in
            if path == "/system/df" {
                return .json(#"{"LayersSize":0,"Images":[{"Id":"sha256:inuse","Containers":1,"Size":50000000,"SharedSize":0,"RepoTags":["x:latest"]}],"Containers":[],"Volumes":[],"BuildCache":[]}"#)
            }
            if path.hasPrefix("/images/sha256:inuse") {
                return .json(#"{"message":"conflict"}"#, statusCode: 409)
            }
            return .json("{}")
        }
        let client = DockerClient(socketPath: server!.socketPath)
        let reclaimer = Reclaimer(dockerClient: client, backend: .orbstack, diskProbePath: tempDirectory.path)

        var logs: [String] = []
        let selection = DockerSelection(imageIDs: ["sha256:inuse"], includeBuildCache: false)
        let report = try await reclaimer.cleanSelected(selection, options: CleanOptions(dryRun: false)) { event in
            if case .log(let text) = event { logs.append(text) }
        }

        // The run completed (didn't throw/abort) despite the 409, and recorded no step for
        // the skipped image.
        XCTAssertFalse(report.dryRun)
        XCTAssertFalse(report.steps.contains { $0.name.contains("sha256:inuse") })
        XCTAssertTrue(logs.contains { $0.contains("Skipped sha256:inuse") })
    }
}
