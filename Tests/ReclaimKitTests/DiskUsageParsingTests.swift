import XCTest
@testable import ReclaimKit

/// All fixtures below are synthetic — invented image/volume/container names modeled on the
/// real Docker Engine API shapes, per docs/IMPLEMENTATION.md's public-repo hygiene rule. None
/// of this data came from a real machine.
final class DiskUsageParsingTests: XCTestCase {
    func testDecodesFullSystemDFResponse() throws {
        let json = """
        {
          "LayersSize": 1500000000,
          "Images": [
            { "Id": "sha256:aaa1", "Containers": 0, "Size": 900000000, "SharedSize": 0, "RepoTags": ["web-app:latest"] },
            { "Id": "sha256:aaa2", "Containers": 1, "Size": 600000000, "SharedSize": 0, "RepoTags": ["cache-store:7-alpine"] }
          ],
          "Containers": [
            { "Id": "c1", "State": "running", "SizeRw": null, "SizeRootFs": 900000000 },
            { "Id": "c2", "State": "exited", "SizeRw": 4096, "SizeRootFs": 600000000 }
          ],
          "Volumes": [
            { "CreatedAt": "2026-01-01T00:00:00Z", "Driver": "local", "Labels": {"app": "shop"}, "Mountpoint": "/var/lib/docker/volumes/shop_db_data/_data", "Name": "shop_db_data", "Options": null, "Scope": "local", "UsageData": {"RefCount": 1, "Size": 123456} },
            { "CreatedAt": "2026-01-02T00:00:00Z", "Driver": "local", "Labels": null, "Mountpoint": "/var/lib/docker/volumes/anon1/_data", "Name": "anon1", "Options": null, "Scope": "local", "UsageData": {"RefCount": 0, "Size": 0} }
          ],
          "BuildCache": [
            { "ID": "bc1", "Type": "regular", "Description": "pulled from docker.io/library/node:22-slim", "InUse": false, "Shared": true, "Size": 300000000, "CreatedAt": "2026-01-01T00:00:00Z", "LastUsedAt": "2026-01-01T00:00:00Z", "UsageCount": 1 },
            { "ID": "bc2", "Type": "regular", "Description": "[1/1] RUN npm install", "InUse": true, "Shared": true, "Size": 50000000, "CreatedAt": "2026-01-01T00:00:00Z", "LastUsedAt": "2026-01-01T00:00:00Z", "UsageCount": 1 }
          ]
        }
        """

        let usage = try JSONDecoder().decode(DiskUsage.self, from: Data(json.utf8))

        XCTAssertEqual(usage.layersSize, 1_500_000_000)
        XCTAssertEqual(usage.images.count, 2)
        XCTAssertEqual(usage.imagesTotalSize, 1_500_000_000)
        XCTAssertEqual(usage.imagesReclaimableSize, 900_000_000) // only the Containers == 0 image
        XCTAssertEqual(usage.imagesReclaimableCount, 1)

        XCTAssertEqual(usage.stoppedContainersCount, 1)
        XCTAssertEqual(usage.stoppedContainersSize, 4096) // null SizeRw tolerated as 0, excluded since running

        XCTAssertEqual(usage.buildCacheTotalSize, 350_000_000)
        XCTAssertEqual(usage.buildCacheReclaimableSize, 300_000_000) // only InUse == false
        XCTAssertEqual(usage.buildCacheReclaimableCount, 1)

        XCTAssertEqual(usage.volumesCount, 2)
        XCTAssertEqual(usage.volumesTotalSize, 123_456)
    }

    func testTreatsNullArraysAsEmpty() throws {
        // Real Docker daemons return null (not []) for these arrays when there's nothing to
        // report — every array must tolerate that (docs/IMPLEMENTATION.md).
        let json = """
        {
          "LayersSize": 0,
          "Images": null,
          "Containers": null,
          "Volumes": null,
          "BuildCache": null
        }
        """

        let usage = try JSONDecoder().decode(DiskUsage.self, from: Data(json.utf8))

        XCTAssertEqual(usage.images, [])
        XCTAssertEqual(usage.containers, [])
        XCTAssertEqual(usage.volumes, [])
        XCTAssertEqual(usage.buildCache, [])
        XCTAssertEqual(usage.imagesTotalSize, 0)
        XCTAssertEqual(usage.buildCacheReclaimableSize, 0)
        XCTAssertEqual(usage.stoppedContainersCount, 0)
        XCTAssertEqual(usage.volumesTotalSize, 0)
    }

    func testTreatsMissingKeysAsEmpty() throws {
        // Also tolerate keys that are entirely absent, not just explicitly null.
        let json = "{}"
        let usage = try JSONDecoder().decode(DiskUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.layersSize, 0)
        XCTAssertEqual(usage.images, [])
        XCTAssertEqual(usage.buildCache, [])
    }

    func testVolumeUsageDataMissingOrNullYieldsNilUsageSize() throws {
        let json = """
        {
          "Volumes": [
            { "Name": "no-usage-data", "Driver": "local", "Mountpoint": "/m", "CreatedAt": "2026-01-01T00:00:00Z", "Labels": null, "Options": null, "Scope": "local" },
            { "Name": "null-usage-data", "Driver": "local", "Mountpoint": "/m2", "CreatedAt": "2026-01-01T00:00:00Z", "Labels": null, "Options": null, "Scope": "local", "UsageData": null },
            { "Name": "unknown-size", "Driver": "local", "Mountpoint": "/m3", "CreatedAt": "2026-01-01T00:00:00Z", "Labels": null, "Options": null, "Scope": "local", "UsageData": {"RefCount": 0, "Size": -1} }
          ]
        }
        """
        let usage = try JSONDecoder().decode(DiskUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.volumes.count, 3)
        XCTAssertNil(usage.volumes[0].usageSize)
        XCTAssertNil(usage.volumes[1].usageSize)
        XCTAssertEqual(usage.volumes[2].usageSize, -1)
        // -1 ("not computed") must not be counted as reclaimable/real bytes.
        XCTAssertEqual(usage.volumesTotalSize, 0)
    }

    func testDecodesVolumeListResponseWrapper() throws {
        let json = """
        {
          "Volumes": [
            { "CreatedAt": "2026-02-01T00:00:00Z", "Driver": "local", "Labels": {"com.docker.compose.project": "shop"}, "Mountpoint": "/var/lib/docker/volumes/shop_db_data/_data", "Name": "shop_db_data", "Options": null, "Scope": "local", "UsageData": {"RefCount": 1, "Size": 42} }
          ],
          "Warnings": null
        }
        """
        let response = try JSONDecoder().decode(VolumeListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.volumes.count, 1)
        XCTAssertEqual(response.volumes[0].name, "shop_db_data")
        XCTAssertEqual(response.volumes[0].usageSize, 42)
    }

    func testDecodesEmptyVolumesArrayWrapper() throws {
        let json = #"{"Volumes": [], "Warnings": null}"#
        let response = try JSONDecoder().decode(VolumeListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.volumes, [])
    }
}
