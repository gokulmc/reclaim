import XCTest
@testable import ReclaimKit

final class PruneResultParsingTests: XCTestCase {
    func testParsesImagesDeletedAndSpaceReclaimed() throws {
        let json = """
        {
          "ImagesDeleted": [
            { "Untagged": "web-app:old" },
            { "Deleted": "sha256:bbb1" }
          ],
          "SpaceReclaimed": 2680000000
        }
        """
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        let result = try DockerClient.decodePruneResult(response, deletedKeys: ["ImagesDeleted"])
        XCTAssertEqual(result.spaceReclaimed, 2_680_000_000)
        XCTAssertEqual(result.deleted, ["web-app:old", "sha256:bbb1"])
    }

    func testParsesCachesDeletedForBuildPrune() throws {
        let json = """
        {
          "CachesDeleted": ["cache-id-1", "cache-id-2"],
          "SpaceReclaimed": 34350000000
        }
        """
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        let result = try DockerClient.decodePruneResult(response, deletedKeys: ["CachesDeleted"])
        XCTAssertEqual(result.spaceReclaimed, 34_350_000_000)
        XCTAssertEqual(result.deleted, ["cache-id-1", "cache-id-2"])
    }

    func testParsesContainersDeletedForContainerPrune() throws {
        let json = """
        {
          "ContainersDeleted": ["container-id-1"],
          "SpaceReclaimed": 1024
        }
        """
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        let result = try DockerClient.decodePruneResult(response, deletedKeys: ["ContainersDeleted"])
        XCTAssertEqual(result.spaceReclaimed, 1024)
        XCTAssertEqual(result.deleted, ["container-id-1"])
    }

    func testTreatsMissingDeletedArrayAsEmpty() throws {
        // Docker returns null (not []) for *Deleted when there was nothing to delete.
        let json = #"{"ImagesDeleted": null, "SpaceReclaimed": 0}"#
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        let result = try DockerClient.decodePruneResult(response, deletedKeys: ["ImagesDeleted"])
        XCTAssertEqual(result.deleted, [])
        XCTAssertEqual(result.spaceReclaimed, 0)
    }

    func testTreatsEmptyBodyAsZeroResult() throws {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data())
        let result = try DockerClient.decodePruneResult(response, deletedKeys: ["ImagesDeleted"])
        XCTAssertEqual(result.deleted, [])
        XCTAssertEqual(result.spaceReclaimed, 0)
    }

    func testThrowsOnNonOKStatus() {
        let response = HTTPResponse(statusCode: 500, headers: [:], body: Data("boom".utf8))
        XCTAssertThrowsError(try DockerClient.decodePruneResult(response, deletedKeys: ["ImagesDeleted"]))
    }
}
