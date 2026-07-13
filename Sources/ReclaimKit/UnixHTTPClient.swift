import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A parsed HTTP response.
public struct HTTPResponse: Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public enum UnixHTTPError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(String)
    case socketCreationFailed(Int32)
    case connectFailed(String, Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .pathTooLong(let path):
            return "Unix socket path too long: \(path)"
        case .socketCreationFailed(let errnoValue):
            return "socket() failed (errno \(errnoValue))"
        case .connectFailed(let path, let errnoValue):
            return "connect(\(path)) failed (errno \(errnoValue))"
        case .writeFailed(let errnoValue):
            return "write() failed (errno \(errnoValue))"
        case .readFailed(let errnoValue):
            return "read() failed (errno \(errnoValue))"
        case .malformedResponse(let reason):
            return "Malformed HTTP response: \(reason)"
        }
    }
}

/// A minimal hand-rolled HTTP client that speaks HTTP/1.1 over a POSIX `AF_UNIX` stream
/// socket. There is no built-in Swift HTTP-over-UDS client and this app deliberately avoids
/// vendoring swift-nio (see docs/IMPLEMENTATION.md) — every request opens a fresh connection,
/// sends `Connection: close`, and reads to EOF, which makes response framing trivial as long
/// as both `Content-Length` and `Transfer-Encoding: chunked` bodies are handled.
///
/// The synchronous core (`requestSync`) runs entirely with blocking POSIX calls; the public
/// `request(method:path:body:)` wraps it in `async` by dispatching to a background queue.
public struct UnixHTTPClient: Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func request(method: String, path: String, body: Data? = nil) async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try self.requestSync(method: method, path: path, body: body)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous core. Exposed at module (internal) visibility so `BackendDetector` can
    /// issue a blocking `/_ping` without going through the async continuation machinery.
    func requestSync(method: String, path: String, body: Data? = nil) throws -> HTTPResponse {
        let fd = try Self.connectSocket(path: socketPath)
        defer { close(fd) }

        let requestData = Self.buildRequest(method: method, path: path, body: body)
        try Self.writeAll(fd: fd, data: requestData)

        let responseData = try Self.readToEOF(fd: fd)
        return try Self.parseHTTPResponse(responseData)
    }

    // MARK: - Socket plumbing

    private static func connectSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixHTTPError.socketCreationFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path) - 1 // leave room for NUL
        guard pathBytes.count <= maxPathLen else {
            close(fd)
            throw UnixHTTPError.pathTooLong(path)
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buf = rawPtr.bindMemory(to: UInt8.self)
            for i in 0..<pathBytes.count {
                buf[i] = pathBytes[i]
            }
            buf[pathBytes.count] = 0
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            let savedErrno = errno
            close(fd)
            throw UnixHTTPError.connectFailed(path, savedErrno)
        }

        return fd
    }

    private static func buildRequest(method: String, path: String, body: Data?) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: localhost\r\n"
        head += "Connection: close\r\n"
        head += "Accept: application/json\r\n"
        if let body {
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        if let body {
            data.append(body)
        }
        return data
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            guard let base = rawBuf.baseAddress else { return }
            var totalWritten = 0
            let count = rawBuf.count
            while totalWritten < count {
                let n = write(fd, base.advanced(by: totalWritten), count - totalWritten)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw UnixHTTPError.writeFailed(errno)
                }
                if n == 0 { break }
                totalWritten += n
            }
        }
    }

    private static func readToEOF(fd: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { rawBuf -> Int in
                read(fd, rawBuf.baseAddress, rawBuf.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw UnixHTTPError.readFailed(errno)
            }
            if n == 0 { break } // EOF — the server closed the connection (Connection: close)
            result.append(buffer, count: n)
        }
        return result
    }

    // MARK: - HTTP parsing

    static func parseHTTPResponse(_ data: Data) throws -> HTTPResponse {
        let bytes = [UInt8](data)
        guard let headerTerminator = firstRange(of: [13, 10, 13, 10], in: bytes) else {
            throw UnixHTTPError.malformedResponse("missing header terminator (\\r\\n\\r\\n)")
        }

        let headerBytes = Array(bytes[0..<headerTerminator.lowerBound])
        var bodyBytes = Array(bytes[headerTerminator.upperBound...])

        guard let headerString = String(bytes: headerBytes, encoding: .utf8) else {
            throw UnixHTTPError.malformedResponse("headers are not valid UTF-8")
        }

        let lines = headerString.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let statusLine = lines.first else {
            throw UnixHTTPError.malformedResponse("empty status line")
        }

        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw UnixHTTPError.malformedResponse("bad status line: '\(statusLine)'")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        if let transferEncoding = headers["transfer-encoding"], transferEncoding.lowercased().contains("chunked") {
            bodyBytes = try decodeChunked(bodyBytes)
        } else if let contentLengthString = headers["content-length"], let contentLength = Int(contentLengthString) {
            if bodyBytes.count > contentLength {
                bodyBytes = Array(bodyBytes.prefix(contentLength))
            }
            // If fewer bytes arrived than declared, tolerate it — read-to-EOF already gave us
            // everything the peer sent before closing the connection.
        }

        return HTTPResponse(statusCode: statusCode, headers: headers, body: Data(bodyBytes))
    }

    /// Decodes an HTTP/1.1 `Transfer-Encoding: chunked` body (RFC 7230 §4.1). Chunk
    /// extensions (after `;`) are ignored; trailers after the terminating `0` chunk are
    /// ignored.
    static func decodeChunked(_ bytes: [UInt8]) throws -> [UInt8] {
        var result: [UInt8] = []
        var idx = 0
        while idx < bytes.count {
            guard let sizeLineEnd = firstRange(of: [13, 10], in: bytes, from: idx) else {
                throw UnixHTTPError.malformedResponse("chunked body: missing chunk-size line terminator")
            }
            let sizeLineBytes = Array(bytes[idx..<sizeLineEnd.lowerBound])
            guard let sizeLineString = String(bytes: sizeLineBytes, encoding: .utf8) else {
                throw UnixHTTPError.malformedResponse("chunked body: chunk-size line not UTF-8")
            }
            let sizeHex = sizeLineString.split(separator: ";", maxSplits: 1).first.map(String.init) ?? sizeLineString
            let trimmedHex = sizeHex.trimmingCharacters(in: .whitespaces)
            guard let chunkSize = Int(trimmedHex, radix: 16) else {
                throw UnixHTTPError.malformedResponse("chunked body: bad chunk-size '\(trimmedHex)'")
            }

            idx = sizeLineEnd.upperBound
            if chunkSize == 0 {
                break // terminating chunk — ignore any trailers
            }

            let chunkEnd = min(idx + chunkSize, bytes.count)
            result.append(contentsOf: bytes[idx..<chunkEnd])
            idx = chunkEnd

            // Skip the CRLF that follows each chunk's data.
            if idx + 1 < bytes.count, bytes[idx] == 13, bytes[idx + 1] == 10 {
                idx += 2
            } else {
                idx += 2
            }
        }
        return result
    }

    static func firstRange(of pattern: [UInt8], in bytes: [UInt8], from start: Int = 0) -> Range<Int>? {
        guard !pattern.isEmpty, bytes.count >= pattern.count, start <= bytes.count - pattern.count else { return nil }
        var i = start
        let last = bytes.count - pattern.count
        while i <= last {
            var matched = true
            for j in 0..<pattern.count where bytes[i + j] != pattern[j] {
                matched = false
                break
            }
            if matched { return i..<(i + pattern.count) }
            i += 1
        }
        return nil
    }
}
