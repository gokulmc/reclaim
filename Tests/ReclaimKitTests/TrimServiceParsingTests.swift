import XCTest
@testable import ReclaimKit

final class TrimServiceParsingTests: XCTestCase {
    func testParsesSingleMountWithByteCount() {
        let lines = ["/mnt/lima-colima: 49.8 GiB (53456729292 bytes) trimmed on /dev/vdb1"]
        XCTAssertEqual(TrimService.parseFstrimBytes(from: lines), 53_456_729_292)
    }

    func testSumsMultipleMountsWithByteCounts() {
        let lines = [
            "/mnt/lima-colima: 49.8 GiB (53456729292 bytes) trimmed on /dev/vdb1",
            "/mnt/data: 1.0 GiB (1073741824 bytes) trimmed on /dev/vdb2"
        ]
        XCTAssertEqual(TrimService.parseFstrimBytes(from: lines), 53_456_729_292 + 1_073_741_824)
    }

    func testFallsBackToHumanSizeWhenNoByteCountParenthetical() {
        // "no-bytes variant" — some fstrim builds omit the parenthesized exact byte count.
        let lines = ["/mnt/lima-colima: 2 GiB trimmed on /dev/vdb1"]
        let bytes = TrimService.parseFstrimBytes(from: lines)
        XCTAssertEqual(bytes, 2 * 1024 * 1024 * 1024)
    }

    func testFallsBackToHumanSizeForMiB() {
        let lines = ["/mnt/data: 512 MiB trimmed on /dev/sdb1"]
        let bytes = TrimService.parseFstrimBytes(from: lines)
        XCTAssertEqual(bytes, 512 * 1024 * 1024)
    }

    func testHumanSizeToleratesFractionalValues() {
        let lines = ["/mnt/data: 1.5 GiB trimmed on /dev/sdb1"]
        let bytes = TrimService.parseFstrimBytes(from: lines)
        XCTAssertEqual(bytes, Int64((1.5 * 1024 * 1024 * 1024).rounded()))
    }

    func testIgnoresUnrelatedLines() {
        let lines = [
            "fstrim: starting",
            "/mnt/lima-colima: 49.8 GiB (53456729292 bytes) trimmed on /dev/vdb1",
            "fstrim: done"
        ]
        XCTAssertEqual(TrimService.parseFstrimBytes(from: lines), 53_456_729_292)
    }

    func testEmptyLinesYieldZero() {
        XCTAssertEqual(TrimService.parseFstrimBytes(from: []), 0)
    }

    func testMixedByteCountAndHumanSizeLinesAreBothSummed() {
        let lines = [
            "/mnt/a: 1.0 GiB (1073741824 bytes) trimmed on /dev/vdb1",
            "/mnt/b: 100 MiB trimmed on /dev/vdb2"
        ]
        XCTAssertEqual(TrimService.parseFstrimBytes(from: lines), 1_073_741_824 + 100 * 1024 * 1024)
    }
}
