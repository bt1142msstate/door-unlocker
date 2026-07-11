import XCTest
@testable import DoorUnlockerShared

final class DoorControlPresentationPolicyTests: XCTestCase {
    func testPrimaryTitleUsesRequestedActivationVerb() {
        let tap = DoorControlPresentationPolicy.presentation(
            for: input(isUnlocked: false, activationVerb: .tap)
        )
        let click = DoorControlPresentationPolicy.presentation(
            for: input(isUnlocked: true, activationVerb: .click)
        )

        XCTAssertEqual(tap.actionTitle, "Tap to unlock")
        XCTAssertEqual(click.actionTitle, "Click to lock")
    }

    func testQueuedDoorCommandKeepsStableActionTitleUntilChangingStarts() {
        let queued = DoorControlPresentationPolicy.presentation(
            for: input(
                canAcceptDoorCommand: false,
                isDoorCommandQueuedForSecureLink: true,
                isPreparingKnownController: true
            )
        )
        let changing = DoorControlPresentationPolicy.presentation(
            for: input(
                servoState: "unlocking",
                isUnlocked: true,
                isDoorCommandQueuedForSecureLink: true
            )
        )

        XCTAssertEqual(queued.actionTitle, "Tap to unlock")
        XCTAssertEqual(changing.actionTitle, "Tap to lock")
    }

    func testQueuedDoorCommandsNeverExposeTransportPreparationOnPrimaryAction() {
        for isUnlocked in [false, true] {
            let presentation = DoorControlPresentationPolicy.presentation(
                for: input(
                    isUnlocked: isUnlocked,
                    canAcceptDoorCommand: false,
                    isDoorCommandQueuedForSecureLink: true,
                    isPreparingKnownController: true
                )
            )

            XCTAssertEqual(
                presentation.actionTitle,
                isUnlocked ? "Tap to lock" : "Tap to unlock"
            )
            XCTAssertFalse(presentation.actionTitle.localizedCaseInsensitiveContains("prepar"))
        }
    }

    func testTransientConnectionContinuityKeepsStableDoorAction() {
        let presentation = DoorControlPresentationPolicy.presentation(
            for: input(
                isUnlocked: true,
                canAcceptDoorCommand: false,
                isPreparingKnownController: true,
                preservesDoorControlDuringTransientConnection: true
            )
        )

        XCTAssertTrue(presentation.shouldShowLockControl)
        XCTAssertFalse(presentation.isPrimaryActionEnabled)
        XCTAssertEqual(presentation.actionTitle, "Tap to lock")
    }

    func testSettingsOnlyPresentation() {
        let presentation = DoorControlPresentationPolicy.presentation(
            for: input(
                isApplyingControllerSetting: true,
                controllerSettingApplyTitle: "Setting lock after 30s"
            )
        )

        XCTAssertTrue(presentation.isApplyingSettingsOnly)
        XCTAssertTrue(presentation.shouldShowLockControl)
        XCTAssertFalse(presentation.isPrimaryActionEnabled)
        XCTAssertEqual(presentation.actionTitle, "Setting lock after 30s")
    }

    func testFirmwareUpdatePresentationBlocksDoorAction() {
        let presentation = DoorControlPresentationPolicy.presentation(
            for: input(
                isFirmwareUpdateBlockingDoorControl: true,
                firmwareUpdateActionTitle: "Firmware updated"
            )
        )

        XCTAssertFalse(presentation.isApplyingSettingsOnly)
        XCTAssertTrue(presentation.isFirmwareUpdateOnly)
        XCTAssertTrue(presentation.shouldShowLockControl)
        XCTAssertFalse(presentation.isPrimaryActionEnabled)
        XCTAssertEqual(presentation.actionTitle, "Firmware updated")
    }

    func testUnavailableSecureNonceDoesNotReplacePrimaryActionTitle() {
        let presentation = DoorControlPresentationPolicy.presentation(
            for: input(isUnlocked: false, isDoorCommandReady: false)
        )

        XCTAssertEqual(presentation.actionTitle, "Tap to unlock")
    }

    func testQueuedCommandDisablesRepeatedAction() {
        let presentation = DoorControlPresentationPolicy.presentation(
            for: input(isDoorCommandQueuedForSecureLink: true)
        )

        XCTAssertFalse(presentation.isPrimaryActionEnabled)
    }

    func testDisconnectedSessionHidesTheLockControl() {
        let presentation = DoorControlPresentationPolicy.presentation(
            for: input(canAcceptDoorCommand: false)
        )

        XCTAssertFalse(presentation.shouldShowLockControl)
        XCTAssertFalse(presentation.isPrimaryActionEnabled)
    }

    func testChangingStateDisablesRepeatedActionUntilControllerConfirmation() {
        let presentation = DoorControlPresentationPolicy.presentation(
            for: input(servoState: "unlocking", isUnlocked: true)
        )

        XCTAssertFalse(presentation.isPrimaryActionEnabled)
        XCTAssertEqual(presentation.actionTitle, "Tap to lock")
    }

    func testDoorTransitionsNeverAddAThirdPrimaryActionLabel() {
        let locking = DoorControlPresentationPolicy.presentation(
            for: input(servoState: "locking", isUnlocked: false)
        )
        let unlocking = DoorControlPresentationPolicy.presentation(
            for: input(servoState: "unlocking", isUnlocked: true)
        )

        XCTAssertEqual(locking.actionTitle, "Tap to unlock")
        XCTAssertEqual(unlocking.actionTitle, "Tap to lock")
    }

    func testDoorStateHelpersCoverFinalAndTransientStates() {
        XCTAssertTrue(DoorControlPresentationPolicy.isDoorState("locked"))
        XCTAssertTrue(DoorControlPresentationPolicy.isDoorState("unlocking"))
        XCTAssertFalse(DoorControlPresentationPolicy.isDoorState("paired"))
        XCTAssertTrue(DoorControlPresentationPolicy.isUnlockedState("unlocking", fallback: false))
        XCTAssertFalse(DoorControlPresentationPolicy.isUnlockedState("locking", fallback: true))
    }

    func testDoorStateOnlySatisfiesMatchingCommandTarget() {
        XCTAssertTrue(DoorControlPresentationPolicy.state("unlocking", satisfiesUnlockedTarget: true))
        XCTAssertTrue(DoorControlPresentationPolicy.state("locked", satisfiesUnlockedTarget: false))
        XCTAssertFalse(DoorControlPresentationPolicy.state("locking", satisfiesUnlockedTarget: true))
        XCTAssertFalse(DoorControlPresentationPolicy.state("paired", satisfiesUnlockedTarget: false))
    }

    func testSupersededUnlockNotificationCannotConfirmNewerLock() {
        XCTAssertFalse(DoorControlPresentationPolicy.state("unlocking", satisfiesUnlockedTarget: false))
        XCTAssertFalse(DoorControlPresentationPolicy.state("unlocked", satisfiesUnlockedTarget: false))
        XCTAssertTrue(DoorControlPresentationPolicy.state("locking", satisfiesUnlockedTarget: false))
        XCTAssertTrue(DoorControlPresentationPolicy.state("locked", satisfiesUnlockedTarget: false))
    }

    func testSupersededLockNotificationCannotConfirmNewerUnlock() {
        XCTAssertFalse(DoorControlPresentationPolicy.state("locking", satisfiesUnlockedTarget: true))
        XCTAssertFalse(DoorControlPresentationPolicy.state("locked", satisfiesUnlockedTarget: true))
        XCTAssertTrue(DoorControlPresentationPolicy.state("unlocking", satisfiesUnlockedTarget: true))
        XCTAssertTrue(DoorControlPresentationPolicy.state("unlocked", satisfiesUnlockedTarget: true))
    }

    private func input(
        servoState: String = "locked",
        isUnlocked: Bool = false,
        canAcceptDoorCommand: Bool = true,
        isBusy: Bool = false,
        isAuthenticatingUnlock: Bool = false,
        isApplyingControllerSetting: Bool = false,
        isFirmwareUpdateBlockingDoorControl: Bool = false,
        isDoorCommandQueuedForSecureLink: Bool = false,
        isPreparingKnownController: Bool = false,
        preservesDoorControlDuringTransientConnection: Bool = false,
        isDoorCommandReady: Bool = true,
        requiresHoldToUnlock: Bool = false,
        isUnlockHoldActive: Bool = false,
        activationVerb: DoorControlActivationVerb = .tap,
        controllerSettingApplyTitle: String = "Applying setting",
        firmwareUpdateActionTitle: String = "Updating firmware...",
        disconnectedActionTitle: String = "Connect first"
    ) -> DoorControlPresentationInput {
        DoorControlPresentationInput(
            servoState: servoState,
            isUnlocked: isUnlocked,
            canAcceptDoorCommand: canAcceptDoorCommand,
            isBusy: isBusy,
            isAuthenticatingUnlock: isAuthenticatingUnlock,
            isApplyingControllerSetting: isApplyingControllerSetting,
            isFirmwareUpdateBlockingDoorControl: isFirmwareUpdateBlockingDoorControl,
            isDoorCommandQueuedForSecureLink: isDoorCommandQueuedForSecureLink,
            isPreparingKnownController: isPreparingKnownController,
            preservesDoorControlDuringTransientConnection: preservesDoorControlDuringTransientConnection,
            isDoorCommandReady: isDoorCommandReady,
            requiresHoldToUnlock: requiresHoldToUnlock,
            isUnlockHoldActive: isUnlockHoldActive,
            activationVerb: activationVerb,
            controllerSettingApplyTitle: controllerSettingApplyTitle,
            firmwareUpdateActionTitle: firmwareUpdateActionTitle,
            disconnectedActionTitle: disconnectedActionTitle
        )
    }
}
