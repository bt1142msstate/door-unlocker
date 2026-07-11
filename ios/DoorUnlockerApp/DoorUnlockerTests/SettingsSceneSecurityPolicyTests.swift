import SwiftUI
import XCTest
@testable import DoorUnlocker

final class SettingsSceneSecurityPolicyTests: XCTestCase {
    func testFaceIDInactivePhaseDoesNotCancelSettingsAuthentication() {
        XCTAssertFalse(SettingsSceneSecurityPolicy.shouldLockSettings(for: .inactive))
    }

    func testBackgroundPhaseLocksSettings() {
        XCTAssertTrue(SettingsSceneSecurityPolicy.shouldLockSettings(for: .background))
    }

    func testActivePhaseLeavesSettingsStateUnchanged() {
        XCTAssertFalse(SettingsSceneSecurityPolicy.shouldLockSettings(for: .active))
    }
}
