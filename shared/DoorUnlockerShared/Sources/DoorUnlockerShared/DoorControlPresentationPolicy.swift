public enum DoorControlActivationVerb: String, Sendable {
    case tap = "Tap"
    case click = "Click"
}

public struct DoorControlPresentationInput: Equatable, Sendable {
    public var servoState: String
    public var isUnlocked: Bool
    public var canAcceptDoorCommand: Bool
    public var isBusy: Bool
    public var isAuthenticatingUnlock: Bool
    public var isApplyingControllerSetting: Bool
    public var isFirmwareUpdateBlockingDoorControl: Bool
    public var isDoorCommandQueuedForSecureLink: Bool
    public var isPreparingKnownController: Bool
    public var preservesDoorControlDuringTransientConnection: Bool
    public var isDoorCommandReady: Bool
    public var requiresHoldToUnlock: Bool
    public var isUnlockHoldActive: Bool
    public var activationVerb: DoorControlActivationVerb
    public var controllerSettingApplyTitle: String
    public var firmwareUpdateActionTitle: String
    public var disconnectedActionTitle: String

    public init(
        servoState: String,
        isUnlocked: Bool,
        canAcceptDoorCommand: Bool,
        isBusy: Bool,
        isAuthenticatingUnlock: Bool = false,
        isApplyingControllerSetting: Bool,
        isFirmwareUpdateBlockingDoorControl: Bool = false,
        isDoorCommandQueuedForSecureLink: Bool,
        isPreparingKnownController: Bool = false,
        preservesDoorControlDuringTransientConnection: Bool = false,
        isDoorCommandReady: Bool = true,
        requiresHoldToUnlock: Bool = false,
        isUnlockHoldActive: Bool = false,
        activationVerb: DoorControlActivationVerb,
        controllerSettingApplyTitle: String,
        firmwareUpdateActionTitle: String = "Updating firmware...",
        disconnectedActionTitle: String = "Connect first"
    ) {
        self.servoState = servoState
        self.isUnlocked = isUnlocked
        self.canAcceptDoorCommand = canAcceptDoorCommand
        self.isBusy = isBusy
        self.isAuthenticatingUnlock = isAuthenticatingUnlock
        self.isApplyingControllerSetting = isApplyingControllerSetting
        self.isFirmwareUpdateBlockingDoorControl = isFirmwareUpdateBlockingDoorControl
        self.isDoorCommandQueuedForSecureLink = isDoorCommandQueuedForSecureLink
        self.isPreparingKnownController = isPreparingKnownController
        self.preservesDoorControlDuringTransientConnection = preservesDoorControlDuringTransientConnection
        self.isDoorCommandReady = isDoorCommandReady
        self.requiresHoldToUnlock = requiresHoldToUnlock
        self.isUnlockHoldActive = isUnlockHoldActive
        self.activationVerb = activationVerb
        self.controllerSettingApplyTitle = controllerSettingApplyTitle
        self.firmwareUpdateActionTitle = firmwareUpdateActionTitle
        self.disconnectedActionTitle = disconnectedActionTitle
    }
}

public struct DoorControlPresentation: Equatable, Sendable {
    public var isApplyingSettingsOnly: Bool
    public var isFirmwareUpdateOnly: Bool
    public var shouldShowLockControl: Bool
    public var isPrimaryActionEnabled: Bool
    public var actionTitle: String

    public init(
        isApplyingSettingsOnly: Bool,
        isFirmwareUpdateOnly: Bool = false,
        shouldShowLockControl: Bool,
        isPrimaryActionEnabled: Bool,
        actionTitle: String
    ) {
        self.isApplyingSettingsOnly = isApplyingSettingsOnly
        self.isFirmwareUpdateOnly = isFirmwareUpdateOnly
        self.shouldShowLockControl = shouldShowLockControl
        self.isPrimaryActionEnabled = isPrimaryActionEnabled
        self.actionTitle = actionTitle
    }
}

public enum DoorControlPresentationPolicy {
    public static func isChangingState(_ state: String) -> Bool {
        state == "locking" || state == "unlocking"
    }

    public static func isDoorState(_ state: String) -> Bool {
        state == "locked" || state == "unlocked" || isChangingState(state)
    }

    public static func isUnlockedState(_ state: String, fallback: Bool) -> Bool {
        switch state {
        case "unlocked", "unlocking":
            return true
        case "locked", "locking":
            return false
        default:
            return fallback
        }
    }

    public static func state(_ state: String, satisfiesUnlockedTarget targetIsUnlocked: Bool) -> Bool {
        targetIsUnlocked
            ? state == "unlocking" || state == "unlocked"
            : state == "locking" || state == "locked"
    }

    public static func presentation(for input: DoorControlPresentationInput) -> DoorControlPresentation {
        let isChangingState = isChangingState(input.servoState)
        let isApplyingSettingsOnly = input.isApplyingControllerSetting && !isChangingState
        if input.isFirmwareUpdateBlockingDoorControl {
            return DoorControlPresentation(
                isApplyingSettingsOnly: false,
                isFirmwareUpdateOnly: true,
                shouldShowLockControl: true,
                isPrimaryActionEnabled: false,
                actionTitle: input.firmwareUpdateActionTitle
            )
        }

        let shouldShowLockControl = input.canAcceptDoorCommand ||
            input.isDoorCommandQueuedForSecureLink ||
            input.preservesDoorControlDuringTransientConnection ||
            isChangingState ||
            input.isAuthenticatingUnlock ||
            isApplyingSettingsOnly
        let isPrimaryActionEnabled = input.canAcceptDoorCommand &&
            !input.isBusy &&
            !input.isApplyingControllerSetting &&
            !input.isDoorCommandQueuedForSecureLink &&
            !isChangingState

        return DoorControlPresentation(
            isApplyingSettingsOnly: isApplyingSettingsOnly,
            shouldShowLockControl: shouldShowLockControl,
            isPrimaryActionEnabled: isPrimaryActionEnabled,
            actionTitle: actionTitle(for: input, isChangingState: isChangingState, isApplyingSettingsOnly: isApplyingSettingsOnly)
        )
    }

    private static func actionTitle(
        for input: DoorControlPresentationInput,
        isChangingState: Bool,
        isApplyingSettingsOnly: Bool
    ) -> String {
        if input.isAuthenticatingUnlock { return "Authenticating..." }
        if isChangingState {
            return stableActionTitle(for: input)
        }
        if isApplyingSettingsOnly { return input.controllerSettingApplyTitle }
        if input.isDoorCommandQueuedForSecureLink {
            return stableActionTitle(for: input)
        }
        if input.preservesDoorControlDuringTransientConnection {
            return stableActionTitle(for: input)
        }
        if input.isPreparingKnownController && !input.canAcceptDoorCommand {
            return "Preparing controller..."
        }
        if !input.canAcceptDoorCommand {
            return input.disconnectedActionTitle
        }
        if input.requiresHoldToUnlock && !input.isUnlocked {
            return input.isUnlockHoldActive ? "Keep holding" : "Hold to unlock"
        }
        return stableActionTitle(for: input)
    }

    private static func stableActionTitle(for input: DoorControlPresentationInput) -> String {
        input.isUnlocked
            ? "\(input.activationVerb.rawValue) to lock"
            : "\(input.activationVerb.rawValue) to unlock"
    }
}
