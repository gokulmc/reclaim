import Foundation

public enum DockerClientError: Error, CustomStringConvertible, Equatable {
    case unexpectedStatus(Int, String)
    case decodingFailed(String)
    case invalidRequest(String)

    public var description: String {
        switch self {
        case .unexpectedStatus(let code, let body):
            return "Docker API returned HTTP \(code): \(body)"
        case .decodingFailed(let reason):
            return "Failed to decode Docker API response: \(reason)"
        case .invalidRequest(let reason):
            return "Invalid Docker API request: \(reason)"
        }
    }
}

/// A client for the subset of the Docker Engine API this app needs, talking directly to the
/// Unix socket (no CLI shelling, no output-parsing — see SPEC.md §5).
///
/// **This type is the whole safety boundary.** Its request path (`send`) is `private`; the
/// only way to reach it from outside is through the fixed methods below, and there is no
/// method here that deletes a volume — that call is unrepresentable. Every request, even
/// from these trusted call sites, is additionally checked by `SafetyGuard.validate` before
/// it goes out, so a coding mistake in one of these methods still can't produce a
/// volume-destructive or `system/prune` call.
public struct DockerClient {
    private let http: UnixHTTPClient

    public init(socketPath: String) {
        self.http = UnixHTTPClient(socketPath: socketPath)
    }

    public func ping() async throws -> Bool {
        let response = try await send(method: "GET", path: "/_ping")
        guard response.statusCode == 200 else { return false }
        let text = String(data: response.body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "OK"
    }

    public func systemDF() async throws -> DiskUsage {
        let response = try await send(method: "GET", path: "/system/df")
        guard response.statusCode == 200 else {
            throw DockerClientError.unexpectedStatus(response.statusCode, Self.bodyText(response))
        }
        do {
            return try JSONDecoder().decode(DiskUsage.self, from: response.body)
        } catch {
            throw DockerClientError.decodingFailed("system/df: \(error)")
        }
    }

    /// `POST /images/prune?filters={"dangling":{"false":true}}` — prunes *all* unused
    /// images (not just dangling ones), matching SPEC.md §5. Never touches images belonging
    /// to a running container; that's Docker's own behavior, not hand-rolled here.
    public func pruneImages() async throws -> PruneResult {
        let response = try await send(method: "POST", path: "/images/prune?filters=%7B%22dangling%22%3A%7B%22false%22%3Atrue%7D%7D")
        return try Self.decodePruneResult(response, deletedKeys: ["ImagesDeleted"])
    }

    /// `POST /build/prune?all=true` — the big one (SPEC.md §1, §7): build cache is usually
    /// the largest reclaimable chunk of disk, far more than images.
    public func pruneBuildCache() async throws -> PruneResult {
        let response = try await send(method: "POST", path: "/build/prune?all=true")
        return try Self.decodePruneResult(response, deletedKeys: ["CachesDeleted"])
    }

    public func pruneContainers() async throws -> PruneResult {
        let response = try await send(method: "POST", path: "/containers/prune")
        return try Self.decodePruneResult(response, deletedKeys: ["ContainersDeleted"])
    }

    /// `DELETE /images/{id}?force=…` — removes a single named image (named selective cleanup,
    /// as opposed to `pruneImages()`'s all-unused sweep). Routes through the same validated
    /// `send` egress as every other method here, so `SafetyGuard` still checks it — it already
    /// allows image `DELETE` and still blocks anything volume-shaped.
    ///
    /// `id` is checked *before* any request is built: it must be non-empty and contain no
    /// `"/"`, so a caller can never smuggle an extra path segment into the URL this method
    /// constructs. The check throws synchronously, so an invalid id never reaches the socket.
    ///
    /// Docker returns **409** when the image can't be removed (still referenced by a running
    /// container, or by more than one tag, since `force` always defaults to `false` here per
    /// the app's "never force-delete" policy) — that's surfaced as a thrown
    /// `DockerClientError.unexpectedStatus`, which a caller removing several images (see
    /// `Reclaimer.cleanSelected`) can catch per-image and continue rather than aborting the
    /// whole run.
    public func deleteImage(id: String, force: Bool = false) async throws -> ImageDeleteResult {
        guard !id.isEmpty, !id.contains("/") else {
            throw DockerClientError.invalidRequest("deleteImage: id must be non-empty and contain no \"/\" (got \"\(id)\")")
        }
        let response = try await send(method: "DELETE", path: "/images/\(id)?force=\(force ? "true" : "false")")
        return try Self.decodeImageDeleteResult(response)
    }

    /// `GET /volumes` — **read-only**. There is no corresponding delete/prune method on this
    /// type, by design (SPEC.md §2).
    public func listVolumes() async throws -> [Volume] {
        let response = try await send(method: "GET", path: "/volumes")
        guard response.statusCode == 200 else {
            throw DockerClientError.unexpectedStatus(response.statusCode, Self.bodyText(response))
        }
        do {
            return try JSONDecoder().decode(VolumeListResponse.self, from: response.body).volumes
        } catch {
            throw DockerClientError.decodingFailed("volumes: \(error)")
        }
    }

    public func listContainers(all: Bool) async throws -> [ContainerSummary] {
        let response = try await send(method: "GET", path: "/containers/json?all=\(all ? "true" : "false")")
        guard response.statusCode == 200 else {
            throw DockerClientError.unexpectedStatus(response.statusCode, Self.bodyText(response))
        }
        do {
            return try JSONDecoder().decode([ContainerSummary].self, from: response.body)
        } catch {
            throw DockerClientError.decodingFailed("containers/json: \(error)")
        }
    }

    // MARK: - Private request path

    /// The single funnel every request goes through. Every call is validated by
    /// `SafetyGuard` before it is sent — this is intentionally not skippable from within this
    /// type.
    private func send(method: String, path: String, body: Data? = nil) async throws -> HTTPResponse {
        try SafetyGuard.validate(method: method, path: path)
        return try await http.request(method: method, path: path, body: body)
    }

    // MARK: - Response decoding helpers

    private static func bodyText(_ response: HTTPResponse) -> String {
        String(data: response.body, encoding: .utf8) ?? "<\(response.body.count) bytes>"
    }

    static func decodePruneResult(_ response: HTTPResponse, deletedKeys: [String]) throws -> PruneResult {
        guard response.statusCode == 200 else {
            throw DockerClientError.unexpectedStatus(response.statusCode, bodyText(response))
        }
        guard !response.body.isEmpty else {
            return PruneResult(deleted: [], spaceReclaimed: 0)
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: response.body)
        } catch {
            throw DockerClientError.decodingFailed("prune result: \(error)")
        }
        guard let dict = json as? [String: Any] else {
            throw DockerClientError.decodingFailed("prune result: not a JSON object")
        }

        let spaceReclaimed = (dict["SpaceReclaimed"] as? NSNumber)?.int64Value ?? 0

        var deleted: [String] = []
        for key in deletedKeys {
            guard let items = dict[key] as? [Any] else { continue }
            deleted = items.compactMap { item -> String? in
                if let s = item as? String { return s }
                if let d = item as? [String: Any] {
                    return (d["Deleted"] as? String) ?? (d["Untagged"] as? String) ?? (d["ID"] as? String)
                }
                return nil
            }
        }
        return PruneResult(deleted: deleted, spaceReclaimed: spaceReclaimed)
    }

    /// Decodes `DELETE /images/{id}`'s response, which — unlike the prune endpoints — is a
    /// JSON **array** of `{"Untagged": "..."}` / `{"Deleted": "sha256:..."}` objects, so
    /// `decodePruneResult`'s single-object shape doesn't fit. Tolerates an empty body or a
    /// literal `null` body (both become an empty result) — Docker has been observed to send
    /// either for a no-op removal.
    static func decodeImageDeleteResult(_ response: HTTPResponse) throws -> ImageDeleteResult {
        guard response.statusCode == 200 else {
            throw DockerClientError.unexpectedStatus(response.statusCode, bodyText(response))
        }

        let trimmedText = bodyText(response).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, trimmedText.lowercased() != "null" else {
            return ImageDeleteResult(untagged: [], deleted: [])
        }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: response.body, options: [.fragmentsAllowed])
        } catch {
            throw DockerClientError.decodingFailed("image delete result: \(error)")
        }
        guard let items = json as? [[String: Any]] else {
            throw DockerClientError.decodingFailed("image delete result: not a JSON array")
        }

        let untagged = items.compactMap { $0["Untagged"] as? String }
        let deleted = items.compactMap { $0["Deleted"] as? String }
        return ImageDeleteResult(untagged: untagged, deleted: deleted)
    }
}

/// Wire shape of `GET /volumes`: `{"Volumes": [...], "Warnings": null}`.
struct VolumeListResponse: Decodable {
    let volumes: [Volume]

    enum CodingKeys: String, CodingKey {
        case volumes = "Volumes"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumes = try c.decodeIfPresent([Volume].self, forKey: .volumes) ?? []
    }
}
