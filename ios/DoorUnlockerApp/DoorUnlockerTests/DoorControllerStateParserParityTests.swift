import DoorUnlockerShared
import XCTest
@testable import DoorUnlocker

final class DoorControllerStateParserParityTests: XCTestCase {
    func testScalarParserAdaptersMatchSharedContract() {
        let states = [
            "lock_name:Brandon\u{2019}s Door",
            "firmware_version:0.1.6",
            "firmware_update:complete",
            "reject:v3:stale_nonce",
            "servo_angles:17,143",
            "session:0011223344556677",
            "health:storage_fault"
        ]

        for state in states {
            XCTAssertEqual(
                DoorControllerStateParser.lockName(from: state),
                DoorControllerStateParsing.lockName(from: state, fallback: DoorStatusStore.defaultLockName)
            )
            XCTAssertEqual(
                DoorControllerStateParser.firmwareVersion(from: state),
                DoorControllerStateParsing.firmwareVersion(from: state)
            )
            XCTAssertEqual(
                DoorControllerStateParser.firmwareUpdateState(from: state),
                DoorControllerStateParsing.firmwareUpdateState(from: state)
            )
            XCTAssertEqual(
                DoorControllerStateParser.fastCommandRejectReason(from: state),
                DoorControllerStateParsing.fastCommandRejectReason(from: state)
            )
            XCTAssertEqual(
                DoorControllerStateParser.servoAngles(from: state),
                DoorControllerStateParsing.servoAngles(from: state)
            )
            XCTAssertEqual(
                DoorControllerStateParsing.sessionIdentifier(from: state),
                state.hasPrefix("session:") ? "0011223344556677" : nil
            )
            XCTAssertEqual(
                DoorControllerStateParsing.healthState(from: state),
                state.hasPrefix("health:") ? "storage_fault" : nil
            )
        }
    }

    func testBinaryAndStructuredParserAdaptersMatchSharedContract() {
        let nonceState = "nonce:v3:00112233445566778899aabbccddeeff"
        XCTAssertEqual(
            DoorControllerStateParser.fastCommandNonce(from: nonceState),
            DoorControllerStateParsing.fastCommandNonce(from: nonceState)
        )

        let settingState = "setting_applying:timeout:30"
        let appSetting = DoorControllerStateParser.settingApplying(from: settingState)
        let sharedSetting = DoorControllerStateParsing.settingApplying(from: settingState)
        XCTAssertEqual(appSetting?.kind, sharedSetting?.kind)
        XCTAssertEqual(appSetting?.value, sharedSetting?.value)

        let connectionState = "connections:2/4:iPhone Air|Brandon's Mac"
        let appConnections = DoorControllerStateParser.connectedDevices(from: connectionState)
        let sharedConnections = DoorControllerStateParsing.connectedDevices(from: connectionState)
        XCTAssertEqual(appConnections?.count, sharedConnections?.count)
        XCTAssertEqual(appConnections?.max, sharedConnections?.max)
        XCTAssertEqual(appConnections?.devices.map(\.slot), sharedConnections?.devices.map(\.slot))
        XCTAssertEqual(appConnections?.devices.map(\.name), sharedConnections?.devices.map(\.name))
    }

    func testSettingFormatterAdapterMatchesSharedContract() {
        let values: [(String, String?)] = [
            ("lock_name", "Front Door"),
            ("device_name", "iPhone Air"),
            ("servo_angles", "17,143"),
            ("timeout", "30"),
            ("unknown", nil)
        ]

        for (kind, value) in values {
            XCTAssertEqual(
                DoorControllerSettingFormatter.title(for: kind, value: value),
                DoorControllerSettingFormatting.title(
                    for: kind,
                    value: value,
                    defaultTitle: "Applying setting"
                )
            )
            XCTAssertEqual(
                DoorControllerSettingFormatter.displayValue(for: kind, rawValue: value),
                DoorControllerSettingFormatting.displayValue(for: kind, rawValue: value)
            )
        }
    }
}
