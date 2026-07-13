import XCTest
@testable import ReclaimKit

final class UnixHTTPClientTests: XCTestCase {
    private var tempDirectory: URL!
    private var server: FakeDockerServer?

    override func setUpWithError() throws {
        // /tmp (not FileManager's real temp dir) to stay under AF_UNIX's 104-byte path cap.
        tempDirectory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("reclaim-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testContentLengthResponseIsReadInFull() throws {
        let payload = String(repeating: "x", count: 5000)
        let jsonBody = #"{"padding":"\#(payload)","ok":true}"#
        server = try FakeDockerServer(directoryURL: tempDirectory) { _, _, _ in
            .json(jsonBody)
        }

        let client = UnixHTTPClient(socketPath: server!.socketPath)
        let expectation = expectation(description: "response")
        var received: HTTPResponse?
        Task {
            received = try await client.request(method: "GET", path: "/system/df")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        let response = try XCTUnwrap(received)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data(jsonBody.utf8))
    }

    func testChunkedResponseIsReassembledCorrectly() throws {
        // A body deliberately larger than any single chunk, so reassembly across multiple
        // `Transfer-Encoding: chunked` chunks is actually exercised.
        let items = (0..<200).map { "\"item-\($0)\"" }.joined(separator: ",")
        let jsonBody = "{\"items\":[\(items)]}"

        server = try FakeDockerServer(directoryURL: tempDirectory) { _, _, _ in
            .chunkedJSON(jsonBody, chunkSize: 37) // odd chunk size to force many boundaries
        }

        let client = UnixHTTPClient(socketPath: server!.socketPath)
        let expectation = expectation(description: "chunked response")
        var received: HTTPResponse?
        Task {
            received = try await client.request(method: "GET", path: "/system/df")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        let response = try XCTUnwrap(received)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data(jsonBody.utf8))

        // And confirm it actually round-trips through JSONDecoder, not just byte-for-byte.
        struct Payload: Decodable { let items: [String] }
        let decoded = try JSONDecoder().decode(Payload.self, from: response.body)
        XCTAssertEqual(decoded.items.count, 200)
        XCTAssertEqual(decoded.items.first, "item-0")
        XCTAssertEqual(decoded.items.last, "item-199")
    }

    func testPingRespondsOK() throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { method, path, _ in
            XCTAssertEqual(method, "GET")
            XCTAssertEqual(path, "/_ping")
            return .plainText("OK")
        }

        let client = UnixHTTPClient(socketPath: server!.socketPath)
        let expectation = expectation(description: "ping")
        var received: HTTPResponse?
        Task {
            received = try await client.request(method: "GET", path: "/_ping")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        let response = try XCTUnwrap(received)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "OK")
    }

    func testRequestSyncMatchesAsyncRequest() throws {
        server = try FakeDockerServer(directoryURL: tempDirectory) { _, _, _ in
            .plainText("OK")
        }
        let client = UnixHTTPClient(socketPath: server!.socketPath)
        let response = try client.requestSync(method: "GET", path: "/_ping")
        XCTAssertEqual(response.statusCode, 200)
    }

    // MARK: - Pure parsing unit tests (no socket needed)

    func testDecodeChunkedHandlesMultipleChunksAndTerminator() throws {
        var raw: [UInt8] = []
        raw.append(contentsOf: Array("5\r\nhello\r\n".utf8))
        raw.append(contentsOf: Array("6\r\n world\r\n".utf8))
        raw.append(contentsOf: Array("0\r\n\r\n".utf8))

        let decoded = try UnixHTTPClient.decodeChunked(raw)
        XCTAssertEqual(String(bytes: decoded, encoding: .utf8), "hello world")
    }

    func testDecodeChunkedIgnoresChunkExtensions() throws {
        var raw: [UInt8] = []
        raw.append(contentsOf: Array("5;ignored-extension\r\nhello\r\n".utf8))
        raw.append(contentsOf: Array("0\r\n\r\n".utf8))

        let decoded = try UnixHTTPClient.decodeChunked(raw)
        XCTAssertEqual(String(bytes: decoded, encoding: .utf8), "hello")
    }

    func testParseHTTPResponseParsesStatusAndHeaders() throws {
        let raw = Data("HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let response = try UnixHTTPClient.parseHTTPResponse(raw)
        XCTAssertEqual(response.statusCode, 404)
        XCTAssertEqual(response.headers["content-type"], "application/json")
        XCTAssertEqual(response.body, Data("{}".utf8))
    }
}
