import Foundation
import XCTest
@testable import DoorUnlockerShared

final class ControllerStateParsingTests: XCTestCase {
    func testParsesSecureNonce() {
        let nonce = DoorControllerStateParsing.fastCommandNonce(
            from: "nonce:v3:00112233445566778899aabbccddeeff"
        )

        XCTAssertEqual(nonce?.count, 16)
        XCTAssertEqual(nonce?.map { String(format: "%02x", $0) }.joined(), "00112233445566778899aabbccddeeff")
    }

    func testParsesServoAngles() {
        let angles = DoorControllerStateParsing.servoAngles(from: "servo_angles:12,98")

        XCTAssertEqual(angles, DoorServoAngles(lockAngle: 12, unlockAngle: 98))
    }

    func testParsesConnections() {
        let connections = DoorControllerStateParsing.connectedDevices(from: "connections:2/4:Brandon iPhone|MacBook")

        XCTAssertEqual(connections?.count, 2)
        XCTAssertEqual(connections?.max, 4)
        XCTAssertEqual(connections?.devices.map(\.name), ["Brandon iPhone", "MacBook"])
    }

    func testNormalizesSmartPunctuationInNames() {
        let name = DoorNameNormalizer.normalized("Brandon\u{2019}s Lock", fallback: "My Lock")

        XCTAssertEqual(name, "Brandon's Lock")
    }

    func testFormatsRemoteSettingValues() {
        XCTAssertEqual(
            DoorControllerSettingFormatting.displayValue(for: "servo_angles", rawValue: "10,95"),
            "10° / 95°"
        )
        XCTAssertEqual(
            DoorControllerSettingFormatting.title(for: "timeout", value: "30s", defaultTitle: "Applying setting"),
            "Auto-lock to 30s"
        )
    }
}
