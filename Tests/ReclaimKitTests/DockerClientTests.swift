import XCTest
@testable import ReclaimKit

final class DockerClientTests: XCTestCase {
    private var tempDirectory: URL!
    private var server: FakeDockerServer?

    override func setUpWithError() throws {
        // /tmp (not FileManager's real temp dir) to stay under AF_UNIX's 104-byte path cap.
        tempDirectory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("reclaim-docker-client-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testPingReturnsTrueOnOK() async throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { _, path, _ in
            XCTAssertEqual(path, "/_ping")
            return .plainText("OK")
        }
        let client = DockerClient(socketPath: server!.socketPath)
        let ok = try await client.ping()
        XCTAssertTrue(ok)
    }

    func testSystemDFParsesOverRealSocketIncludingChunkedTransfer() async throws {
        // Synthetic fixture — invented names, modeled on the real /system/df shape.
        let json = """
        {
          "LayersSize": 400000000,
          "Images": [
            { "Id": "sha256:aaa1", "Containers": 0, "Size": 400000000, "SharedSize": 0, "RepoTags": ["web-app:latest"] }
          ],
          "Containers": [
            { "Id": "c1", "State": "exited", "SizeRw": 1000, "SizeRootFs": 400000000 }
          ],
          "Volumes": [
            { "CreatedAt": "2026-01-01T00:00:00Z", "Driver": "local", "Labels": null, "Mountpoint": "/m", "Name": "shop_db_data", "Options": null, "Scope": "local", "UsageData": {"RefCount": 1, "Size": 555} }
          ],
          "BuildCache": [
            { "ID": "bc1", "Type": "regular", "Description": "test layer", "InUse": false, "Shared": true, "Size": 700000000, "CreatedAt": "2026-01-01T00:00:00Z", "LastUsedAt": "2026-01-01T00:00:00Z", "UsageCount": 1 }
          ]
        }
        """
        server = try FakeDockerServer(directoryURL: tempDirectory) { method, path, _ in
            XCTAssertEqual(method, "GET")
            XCTAssertEqual(path, "/system/df")
            return .chunkedJSON(json, chunkSize: 29) // force chunked framing through the real client
        }

        let client = DockerClient(socketPath: server!.socketPath)
        let usage = try await client.systemDF()

        XCTAssertEqual(usage.imagesTotalSize, 400_000_000)
        XCTAssertEqual(usage.buildCacheReclaimableSize, 700_000_000)
        XCTAssertEqual(usage.stoppedContainersCount, 1)
        XCTAssertEqual(usage.volumesCount, 1)
    }

    func testPruneImagesSendsCorrectMethodPathAndParsesResult() async throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { method, path, _ in
            XCTAssertEqual(method, "POST")
            XCTAssertTrue(path.hasPrefix("/images/prune"))
            XCTAssertTrue(path.contains("filters="))
            return .json(#"{"ImagesDeleted": [{"Untagged": "web-app:old"}], "SpaceReclaimed": 2680000000}"#)
        }
        let client = DockerClient(socketPath: server!.socketPath)
        let result = try await client.pruneImages()
        XCTAssertEqual(result.spaceReclaimed, 2_680_000_000)
        XCTAssertEqual(result.deleted, ["web-app:old"])
    }

    func testPruneBuildCacheSendsCorrectMethodAndPath() async throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { method, path, _ in
            XCTAssertEqual(method, "POST")
            XCTAssertEqual(path, "/build/prune?all=true")
            return .json(#"{"CachesDeleted": ["id1"], "SpaceReclaimed": 34350000000}"#)
        }
        let client = DockerClient(socketPath: server!.socketPath)
        let result = try await client.pruneBuildCache()
        XCTAssertEqual(result.spaceReclaimed, 34_350_000_000)
    }

    func testPruneContainersSendsCorrectMethodAndPath() async throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { method, path, _ in
            XCTAssertEqual(method, "POST")
            XCTAssertEqual(path, "/containers/prune")
            return .json(#"{"ContainersDeleted": [], "SpaceReclaimed": 0}"#)
        }
        let client = DockerClient(socketPath: server!.socketPath)
        let result = try await client.pruneContainers()
        XCTAssertEqual(result.spaceReclaimed, 0)
    }

    func testListVolumesIsGetAndReadOnly() async throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { method, path, _ in
            XCTAssertEqual(method, "GET")
            XCTAssertEqual(path, "/volumes")
            return .json(#"{"Volumes": [{"Name": "shop_db_data", "Driver": "local", "Mountpoint": "/m", "CreatedAt": "2026-01-01T00:00:00Z", "Labels": null, "Options": null, "Scope": "local", "UsageData": {"RefCount": 1, "Size": 42}}], "Warnings": null}"#)
        }
        let client = DockerClient(socketPath: server!.socketPath)
        let volumes = try await client.listVolumes()
        XCTAssertEqual(volumes.count, 1)
        XCTAssertEqual(volumes.first?.name, "shop_db_data")
    }

    func testListContainersPassesAllFlag() async throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { method, path, _ in
            XCTAssertEqual(method, "GET")
            XCTAssertEqual(path, "/containers/json?all=true")
            return .json("[]")
        }
        let client = DockerClient(socketPath: server!.socketPath)
        let containers = try await client.listContainers(all: true)
        XCTAssertEqual(containers, [])
    }

    func testUnexpectedStatusThrows() async throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { _, _, _ in
            .json("{}", statusCode: 500)
        }
        let client = DockerClient(socketPath: server!.socketPath)
        do {
            _ = try await client.systemDF()
            XCTFail("expected an error")
        } catch {
            // expected
        }
    }
}
