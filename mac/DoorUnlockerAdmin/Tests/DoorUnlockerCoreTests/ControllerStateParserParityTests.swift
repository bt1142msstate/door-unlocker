import DoorUnlockerShared
import XCTest
@testable import DoorUnlockerCore

final class ControllerStateParserParityTests: XCTestCase {
    func testScalarParserAdaptersMatchSharedContract() {
        let states = [
            "lock_name:Brandon\u{2019}s Door",
            "firmware_version:0.1.6",
            "firmware_update:complete",
            "reject:v3:stale_nonce",
            "servo_angles:17,143"
        ]

        for state in states {
            XCTAssertEqual(
                ControllerStateParser.lockName(from: state, fallback: "My Lock"),
                DoorControllerStateParsing.lockName(from: state, fallback: "My Lock")
            )
            XCTAssertEqual(
                ControllerStateParser.firmwareVersion(from: state),
                DoorControllerStateParsing.firmwareVersion(from: state)
            )
            XCTAssertEqual(
                ControllerStateParser.firmwareUpdateState(from: state),
                DoorControllerStateParsing.firmwareUpdateState(from: state)
            )
            XCTAssertEqual(
                ControllerStateParser.fastCommandRejectReason(from: state),
                DoorControllerStateParsing.fastCommandRejectReason(from: state)
            )
            XCTAssertEqual(
                ControllerStateParser.servoAngles(from: state),
                DoorControllerStateParsing.servoAngles(from: state)
            )
        }
    }

    func testBinaryAndStructuredParserAdaptersMatchSharedContract() {
        let nonceState = "nonce:v3:00112233445566778899aabbccddeeff"
        XCTAssertEqual(
            ControllerStateParser.fastCommandNonce(from: nonceState),
            DoorControllerStateParsing.fastCommandNonce(from: nonceState)
        )

        let connectionState = "connections:2/4:iPhone Air|Brandon's Mac"
        let appConnections = ControllerStateParser.connectedDevices(from: connectionState)
        let sharedConnections = DoorControllerStateParsing.connectedDevices(from: connectionState)
        XCTAssertEqual(appConnections?.count, sharedConnections?.count)
        XCTAssertEqual(appConnections?.max, sharedConnections?.max)
        XCTAssertEqual(appConnections?.devices.map(\.slot), sharedConnections?.devices.map(\.slot))
        XCTAssertEqual(appConnections?.devices.map(\.name), sharedConnections?.devices.map(\.name))
    }

    func testSettingFormatterAdapterMatchesSharedContract() {
        let values: [(String, String?)] = [
            ("lock_name", "Front Door"),
            ("device_name", "Brandon's Mac"),
            ("servo_angles", "17,143"),
            ("timeout", "30"),
            ("unknown", nil)
        ]

        for (kind, value) in values {
            XCTAssertEqual(
                ControllerSettingFormatter.title(for: kind, value: value, defaultTitle: "Updating controller"),
                DoorControllerSettingFormatting.title(
                    for: kind,
                    value: value,
                    defaultTitle: "Updating controller"
                )
            )
            XCTAssertEqual(
                ControllerSettingFormatter.displayValue(for: kind, rawValue: value),
                DoorControllerSettingFormatting.displayValue(for: kind, rawValue: value)
            )
        }
    }
}
