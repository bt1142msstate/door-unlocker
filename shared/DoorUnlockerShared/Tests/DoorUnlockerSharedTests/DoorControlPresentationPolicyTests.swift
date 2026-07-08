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

    func testQueuedDoorCommandTitleWinsUntilChangingStarts() {
        let queued = DoorControlPresentationPolicy.presentation(
            for: input(isDoorCommandQueuedForSecureLink: true, queuedDoorCommandActionTitle: "Preparing lock...")
        )
        let changing = DoorControlPresentationPolicy.presentation(
            for: input(
                servoState: "locking",
                isUnlocked: false,
                isDoorCommandQueuedForSecureLink: true,
                queuedDoorCommandActionTitle: "Preparing lock..."
            )
        )

        XCTAssertEqual(queued.actionTitle, "Preparing lock...")
        XCTAssertEqual(changing.actionTitle, "Locking...")
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
            for: input(isUnlocked: false, isDoorCommandReady: false, secureLinkActionTitle: "Preparing control...")
        )

        XCTAssertEqual(presentation.actionTitle, "Tap to unlock")
    }

    func testDoorStateHelpersCoverFinalAndTransientStates() {
        XCTAssertTrue(DoorControlPresentationPolicy.isDoorState("locked"))
        XCTAssertTrue(DoorControlPresentationPolicy.isDoorState("unlocking"))
        XCTAssertFalse(DoorControlPresentationPolicy.isDoorState("paired"))
        XCTAssertTrue(DoorControlPresentationPolicy.isUnlockedState("unlocking", fallback: false))
        XCTAssertFalse(DoorControlPresentationPolicy.isUnlockedState("locking", fallback: true))
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
        isDoorCommandReady: Bool = true,
        requiresHoldToUnlock: Bool = false,
        isUnlockHoldActive: Bool = false,
        activationVerb: DoorControlActivationVerb = .tap,
        controllerSettingApplyTitle: String = "Applying setting",
        firmwareUpdateActionTitle: String = "Updating firmware...",
        queuedDoorCommandActionTitle: String? = nil,
        secureLinkActionTitle: String = "Preparing control...",
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
            isDoorCommandReady: isDoorCommandReady,
            requiresHoldToUnlock: requiresHoldToUnlock,
            isUnlockHoldActive: isUnlockHoldActive,
            activationVerb: activationVerb,
            controllerSettingApplyTitle: controllerSettingApplyTitle,
            firmwareUpdateActionTitle: firmwareUpdateActionTitle,
            queuedDoorCommandActionTitle: queuedDoorCommandActionTitle,
            secureLinkActionTitle: secureLinkActionTitle,
            disconnectedActionTitle: disconnectedActionTitle
        )
    }
}
