import XCTest
@testable import ReclaimKit

final class BackendDetectorTests: XCTestCase {
    private var tempHome: URL!
    private var servers: [FakeDockerServer] = []

    override func setUpWithError() throws {
        // AF_UNIX socket paths are capped at 104 bytes on Darwin — FileManager's real temp
        // directory (/var/folders/...) is too long once a socket file is appended, so use
        // /tmp directly, same as real Colima/OrbStack sockets do.
        tempHome = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("reclaim-home-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for server in servers { server.stop() }
        servers = []
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
    }

    func testDetectsColimaWhenSocketRespondsToPing() throws {
        let colimaDir = tempHome.appendingPathComponent(".colima/default", isDirectory: true)
        let server = try FakeDockerServer(directoryURL: colimaDir) { _, path, _ in
            XCTAssertEqual(path, "/_ping")
            return .plainText("OK")
        }
        servers.append(server)

        let detected = BackendDetector.detect(baseDirectory: tempHome.path)
        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(detected.first?.backend, .colima)
        XCTAssertEqual(detected.first?.socketPath, server.socketPath)
    }

    func testDetectsOrbstackAtItsOwnPath() throws {
        let orbstackDir = tempHome.appendingPathComponent(".orbstack/run", isDirectory: true)
        let server = try FakeDockerServer(directoryURL: orbstackDir) { _, _, _ in .plainText("OK") }
        servers.append(server)

        let detected = BackendDetector.detect(baseDirectory: tempHome.path)
        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(detected.first?.backend, .orbstack)
    }

    func testReturnsEmptyWhenNoSocketsExist() {
        let detected = BackendDetector.detect(baseDirectory: tempHome.path)
        XCTAssertEqual(detected, [])
    }

    func testIgnoresStaleSocketFileThatDoesNotAcceptConnections() throws {
        // A leftover socket file on disk with nothing listening must not be reported as a
        // live backend — detection requires a real /_ping response, not just file existence.
        let colimaDir = tempHome.appendingPathComponent(".colima/default", isDirectory: true)
        try FileManager.default.createDirectory(at: colimaDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: colimaDir.appendingPathComponent("docker.sock").path, contents: Data())

        let detected = BackendDetector.detect(baseDirectory: tempHome.path)
        XCTAssertEqual(detected, [])
    }

    func testDetectsMultipleLiveBackendsInDocumentedOrder() throws {
        // Detection order per docs/IMPLEMENTATION.md: colima, orbstack, rancherDesktop, dockerDesktop.
        let colimaDir = tempHome.appendingPathComponent(".colima/default", isDirectory: true)
        let rdDir = tempHome.appendingPathComponent(".rd", isDirectory: true)
        servers.append(try FakeDockerServer(directoryURL: colimaDir) { _, _, _ in .plainText("OK") })
        servers.append(try FakeDockerServer(directoryURL: rdDir) { _, _, _ in .plainText("OK") })

        let detected = BackendDetector.detect(baseDirectory: tempHome.path)
        XCTAssertEqual(detected.map(\.backend), [.colima, .rancherDesktop])
    }

    func testRejectsBackendWhosePingDoesNotReturnOK() throws {
        let colimaDir = tempHome.appendingPathComponent(".colima/default", isDirectory: true)
        let server = try FakeDockerServer(directoryURL: colimaDir) { _, _, _ in .plainText("NOT-OK") }
        servers.append(server)

        let detected = BackendDetector.detect(baseDirectory: tempHome.path)
        XCTAssertEqual(detected, [])
    }
}
