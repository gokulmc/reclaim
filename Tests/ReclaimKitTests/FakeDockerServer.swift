import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A minimal HTTP-over-`AF_UNIX` test server. Binds a real Unix domain socket in a temp
/// directory and answers requests via a caller-supplied handler, so `UnixHTTPClient` and
/// `DockerClient` can be exercised against a real socket instead of a mock. Supports
/// responding with either a `Content-Length`-framed body or a `Transfer-Encoding: chunked`
/// body, so both codepaths in the hand-rolled HTTP client get real coverage.
final class FakeDockerServer {
    struct RecordedRequest: Equatable {
        let method: String
        let path: String
        let body: Data
    }

    struct FakeResponse {
        var statusCode: Int = 200
        var statusText: String = "OK"
        var headers: [String: String] = [:]
        /// If set, body is sent chunk-by-chunk with `Transfer-Encoding: chunked` framing.
        var chunks: [Data]?
        /// If `chunks` is nil, this is sent with an explicit `Content-Length` header.
        var body: Data = Data()

        static func json(_ string: String, statusCode: Int = 200) -> FakeResponse {
            FakeResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: Data(string.utf8))
        }

        static func chunkedJSON(_ string: String, chunkSize: Int, statusCode: Int = 200) -> FakeResponse {
            let bytes = Array(string.utf8)
            var chunks: [Data] = []
            var idx = 0
            while idx < bytes.count {
                let end = min(idx + chunkSize, bytes.count)
                chunks.append(Data(bytes[idx..<end]))
                idx = end
            }
            if chunks.isEmpty { chunks = [Data()] }
            return FakeResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], chunks: chunks)
        }

        static func plainText(_ string: String, statusCode: Int = 200) -> FakeResponse {
            FakeResponse(statusCode: statusCode, headers: ["Content-Type": "text/plain"], body: Data(string.utf8))
        }
    }

    let socketPath: String
    private let listenSocket: Int32
    private let queue = DispatchQueue(label: "FakeDockerServer.accept")
    private let handler: (String, String, Data) -> FakeResponse

    private let recordedLock = NSLock()
    private var recorded: [RecordedRequest] = []

    private var isRunning = true

    init(directoryURL: URL, handler: @escaping (String, String, Data) -> FakeResponse) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        self.socketPath = directoryURL.appendingPathComponent("docker.sock").path
        self.handler = handler

        unlink(socketPath) // remove any stale socket file

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FakeServerError.socketCreationFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLen else {
            close(fd)
            throw FakeServerError.pathTooLong(socketPath)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buf = rawPtr.bindMemory(to: UInt8.self)
            for i in 0..<pathBytes.count { buf[i] = pathBytes[i] }
            buf[pathBytes.count] = 0
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, addrLen) }
        }
        guard bindResult == 0 else {
            let savedErrno = errno
            close(fd)
            throw FakeServerError.bindFailed(savedErrno)
        }
        guard listen(fd, 16) == 0 else {
            let savedErrno = errno
            close(fd)
            throw FakeServerError.listenFailed(savedErrno)
        }

        self.listenSocket = fd
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        isRunning = false
        shutdown(listenSocket, SHUT_RDWR)
        close(listenSocket)
        unlink(socketPath)
    }

    var requests: [RecordedRequest] {
        recordedLock.lock()
        defer { recordedLock.unlock() }
        return recorded
    }

    private func acceptLoop() {
        while isRunning {
            let clientFD = accept(listenSocket, nil, nil)
            if clientFD < 0 {
                if isRunning { continue }
                break
            }
            handleConnection(clientFD)
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }
        guard let (method, path, body) = Self.readRequest(fd: fd) else { return }

        recordedLock.lock()
        recorded.append(RecordedRequest(method: method, path: path, body: body))
        recordedLock.unlock()

        let response = handler(method, path, body)
        let responseData = Self.encode(response)
        _ = responseData.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return write(fd, base, raw.count)
        }
    }

    // MARK: - Request reading

    private static func readRequest(fd: Int32) -> (method: String, path: String, body: Data)? {
        var buffer = Data()
        var headerRange: Range<Int>?
        var chunk = [UInt8](repeating: 0, count: 8192)

        while headerRange == nil {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(chunk, count: n)
            headerRange = firstRange(of: [13, 10, 13, 10], in: [UInt8](buffer))
        }

        let bytes = [UInt8](buffer)
        let headerBytes = Array(bytes[0..<headerRange!.lowerBound])
        guard let headerString = String(bytes: headerBytes, encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            if key == "content-length" { contentLength = Int(value) ?? 0 }
        }

        var bodyBytes = Array(bytes[headerRange!.upperBound...])
        while bodyBytes.count < contentLength {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            bodyBytes.append(contentsOf: chunk[0..<n])
        }

        return (method, path, Data(bodyBytes.prefix(contentLength)))
    }

    private static func firstRange(of pattern: [UInt8], in bytes: [UInt8]) -> Range<Int>? {
        guard bytes.count >= pattern.count else { return nil }
        var i = 0
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

    // MARK: - Response encoding

    private static func encode(_ response: FakeResponse) -> Data {
        var head = "HTTP/1.1 \(response.statusCode) \(response.statusText)\r\n"
        for (key, value) in response.headers {
            head += "\(key): \(value)\r\n"
        }

        var data = Data()
        if let chunks = response.chunks {
            head += "Transfer-Encoding: chunked\r\n"
            head += "\r\n"
            data.append(Data(head.utf8))
            for chunk in chunks {
                data.append(Data(String(chunk.count, radix: 16).utf8))
                data.append(Data("\r\n".utf8))
                data.append(chunk)
                data.append(Data("\r\n".utf8))
            }
            data.append(Data("0\r\n\r\n".utf8))
        } else {
            head += "Content-Length: \(response.body.count)\r\n"
            head += "\r\n"
            data.append(Data(head.utf8))
            data.append(response.body)
        }
        return data
    }
}

enum FakeServerError: Error {
    case socketCreationFailed(Int32)
    case pathTooLong(String)
    case bindFailed(Int32)
    case listenFailed(Int32)
}
