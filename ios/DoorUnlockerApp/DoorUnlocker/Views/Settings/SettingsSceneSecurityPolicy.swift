import SwiftUI

enum SettingsSceneSecurityPolicy {
    static func shouldLockSettings(for phase: ScenePhase) -> Bool {
        phase == .background
    }
}
