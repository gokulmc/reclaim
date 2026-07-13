import XCTest

/// The one regression that must never happen: a code path that emits `volume prune`
/// (SPEC.md §2, §8). This test greps every `.swift` file under `Sources/` for the literal
/// path fragment Docker's volume-prune endpoint uses.
///
/// The forbidden string is built via string concatenation rather than written as a literal,
/// so that adding this test doesn't itself trip the grep this test (and CI) run over
/// `Sources/` — see docs/IMPLEMENTATION.md.
final class SourceGrepRegressionTests: XCTestCase {
    func testNoSourceFileContainsTheVolumesPruneLiteral() throws {
        let forbidden = "volumes/" + "prune"

        let sourcesURL = try sourcesDirectoryURL()
        var offendingFiles: [String] = []

        let enumerator = FileManager.default.enumerator(
            at: sourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let element = enumerator?.nextObject() {
            guard let fileURL = element as? URL, fileURL.pathExtension == "swift" else { continue }
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            if contents.contains(forbidden) {
                offendingFiles.append(fileURL.path)
            }
        }

        XCTAssertTrue(
            offendingFiles.isEmpty,
            "Forbidden literal '\(forbidden)' found in: \(offendingFiles.joined(separator: ", "))"
        )
    }

    /// Locates the repo's `Sources/` directory relative to this test file, so the test works
    /// regardless of the machine's checkout path (no absolute paths — see
    /// docs/IMPLEMENTATION.md's public-repo hygiene rule).
    private func sourcesDirectoryURL() throws -> URL {
        // This file lives at Tests/ReclaimKitTests/SourceGrepRegressionTests.swift — walk up
        // three levels to the repo root, then into Sources/.
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // ReclaimKitTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
        let sourcesURL = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourcesURL.path) else {
            throw XCTSkip("Could not locate Sources/ directory relative to test file at \(thisFile.path)")
        }
        return sourcesURL
    }
}
