import XCTest
@testable import ReclaimKit

/// SafetyGuard is the one piece of this app that must never regress (SPEC.md §2): a volume
/// prune can silently delete a running production database. These tests cover exactly the
/// calls docs/IMPLEMENTATION.md calls out as mandatory rejections.
final class SafetyGuardTests: XCTestCase {
    func testRejectsPostVolumesPrune() {
        XCTAssertThrowsError(try SafetyGuard.validate(method: "POST", path: "/volumes/prune")) { error in
            XCTAssertTrue(error is SafetyGuard.Violation)
        }
    }

    func testRejectsDeleteVolumesByName() {
        XCTAssertThrowsError(try SafetyGuard.validate(method: "DELETE", path: "/volumes/x"))
    }

    func testRejectsPostVersionedVolumesPrune() {
        XCTAssertThrowsError(try SafetyGuard.validate(method: "POST", path: "/v1.41/volumes/prune"))
    }

    func testRejectsPostSystemPrune() {
        XCTAssertThrowsError(try SafetyGuard.validate(method: "POST", path: "/system/prune"))
    }

    func testRejectionIsCaseInsensitive() {
        XCTAssertThrowsError(try SafetyGuard.validate(method: "post", path: "/VOLUMES/PRUNE"))
    }

    // MARK: - Calls that must remain allowed

    func testAllowsGetVolumesReadOnlyList() {
        XCTAssertNoThrow(try SafetyGuard.validate(method: "GET", path: "/volumes"))
    }

    func testAllowsGetPing() {
        XCTAssertNoThrow(try SafetyGuard.validate(method: "GET", path: "/_ping"))
    }

    func testAllowsGetSystemDF() {
        XCTAssertNoThrow(try SafetyGuard.validate(method: "GET", path: "/system/df"))
    }

    func testAllowsPostImagesPrune() {
        XCTAssertNoThrow(try SafetyGuard.validate(method: "POST", path: "/images/prune?filters=%7B%22dangling%22%3A%7B%22false%22%3Atrue%7D%7D"))
    }

    func testAllowsPostBuildPrune() {
        XCTAssertNoThrow(try SafetyGuard.validate(method: "POST", path: "/build/prune?all=true"))
    }

    func testAllowsPostContainersPrune() {
        XCTAssertNoThrow(try SafetyGuard.validate(method: "POST", path: "/containers/prune"))
    }

    // MARK: - Named selective Docker cleanup (M4a): per-image DELETE allowed, volumes still blocked

    func testAllowsDeleteImageByID() {
        XCTAssertNoThrow(try SafetyGuard.validate(method: "DELETE", path: "/images/sha256:abc"))
    }

    func testAllowsDeleteImageByIDWithForceQueryParam() {
        XCTAssertNoThrow(try SafetyGuard.validate(method: "DELETE", path: "/images/foo?force=true"))
    }

    func testStillRejectsDeleteVolumesByNameAfterImageDeleteAdded() {
        XCTAssertThrowsError(try SafetyGuard.validate(method: "DELETE", path: "/volumes/abc")) { error in
            XCTAssertTrue(error is SafetyGuard.Violation)
        }
    }

    func testStillRejectsDeleteVersionedVolumesByNameAfterImageDeleteAdded() {
        XCTAssertThrowsError(try SafetyGuard.validate(method: "DELETE", path: "/v1.41/volumes/abc")) { error in
            XCTAssertTrue(error is SafetyGuard.Violation)
        }
    }
}
