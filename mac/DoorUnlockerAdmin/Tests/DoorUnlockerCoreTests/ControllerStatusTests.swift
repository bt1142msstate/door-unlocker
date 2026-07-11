import XCTest
@testable import DoorUnlockerCore

final class ControllerStatusTests: XCTestCase {
    func testUSBStatusValidationFailsClosedOnIncompleteOrForeignDevices() {
        let valid = [
            "APP_STATUS_BEGIN",
            "model=DoorUnlocker-XIAO-v4",
            "protocol=1",
            "boot_session=0011223344556677",
            "storage_health=ok",
            "APP_STATUS_END"
        ]
        XCTAssertTrue(DoorSerialParser.isValidControllerStatusResponse(valid))

        for omittedIndex in valid.indices {
            var incomplete = valid
            incomplete.remove(at: omittedIndex)
            XCTAssertFalse(
                DoorSerialParser.isValidControllerStatusResponse(incomplete),
                "Response unexpectedly survived omission at index \(omittedIndex)"
            )
        }

        XCTAssertFalse(DoorSerialParser.isValidControllerStatusResponse([
            "APP_STATUS_BEGIN",
            "model=OtherSerialDevice",
            "protocol=1",
            "boot_session=0011223344556677",
            "storage_health=ok",
            "APP_STATUS_END"
        ]))
    }

    private let localUSBDevice = ConnectedControllerDevice(
        slot: 0,
        handle: "usb-c-this-mac",
        name: "Brandon's Mac (USB-C)",
        isTrustedName: true
    )

    func testIncludingLocalConnectionCountsUSBAndBluetoothDevices() {
        let phone = ConnectedControllerDevice(
            slot: 1,
            handle: "ble-1",
            name: "iPhone Air",
            isTrustedName: true
        )
        let status = ControllerStatus(
            connectedCount: 1,
            maxConnections: 4,
            connectedDevices: [phone]
        )

        let mergedStatus = status.includingLocalConnection(localUSBDevice)

        XCTAssertEqual(mergedStatus.connectedCount, 2)
        XCTAssertEqual(mergedStatus.maxConnections, 4)
        XCTAssertEqual(mergedStatus.connectedDevices.map(\.handle), ["usb-c-this-mac", "ble-1"])
    }

    func testIncludingLocalConnectionPreservesUnidentifiedBluetoothCount() {
        let status = ControllerStatus(
            connectedCount: 2,
            maxConnections: 4,
            connectedDevices: []
        )

        let mergedStatus = status.includingLocalConnection(localUSBDevice)

        XCTAssertEqual(mergedStatus.connectedCount, 3)
        XCTAssertEqual(mergedStatus.maxConnections, 4)
        XCTAssertEqual(mergedStatus.connectedDevices.map(\.handle), ["usb-c-this-mac"])
        XCTAssertEqual(mergedStatus.unidentifiedConnectedDeviceCount, 2)
    }

    func testIncludingLocalConnectionDoesNotDoubleCountExistingUSBDevice() {
        let phone = ConnectedControllerDevice(
            slot: 1,
            handle: "ble-1",
            name: "iPhone Air",
            isTrustedName: true
        )
        let status = ControllerStatus(
            connectedCount: 2,
            maxConnections: 4,
            connectedDevices: [localUSBDevice, phone]
        )

        let mergedStatus = status.includingLocalConnection(localUSBDevice)

        XCTAssertEqual(mergedStatus.connectedCount, 2)
        XCTAssertEqual(mergedStatus.connectedDevices.map(\.handle), ["usb-c-this-mac", "ble-1"])
    }

    func testRemovingLocalConnectionRestoresBluetoothOnlyStatus() {
        let phone = ConnectedControllerDevice(
            slot: 1,
            handle: "ble-1",
            name: "iPhone Air",
            isTrustedName: true
        )
        let status = ControllerStatus(
            connectedCount: 2,
            maxConnections: 4,
            connectedDevices: [localUSBDevice, phone]
        )

        let bluetoothOnlyStatus = status.removingConnection(handle: localUSBDevice.handle)

        XCTAssertEqual(bluetoothOnlyStatus.connectedCount, 1)
        XCTAssertEqual(bluetoothOnlyStatus.connectedDevices.map(\.handle), ["ble-1"])
    }

    func testParseStatusReadsConnectedDevicesFromFirmwareOutput() {
        let status = DoorSerialParser.parseStatus(from: [
            "APP_STATUS_BEGIN",
            "protocol=1",
            "ble_connected_count=2",
            "ble_max_connections=4",
            "connected_device=index=1 handle=64 trusted=yes name=iPhone Air",
            "connected_device=index=2 handle=65 trusted=no name=Brandon's Mac",
            "APP_STATUS_END"
        ])

        XCTAssertEqual(status.connectedCount, 2)
        XCTAssertEqual(status.maxConnections, 4)
        XCTAssertEqual(status.connectedDevices.map(\.slot), [1, 2])
        XCTAssertEqual(status.connectedDevices.map(\.handle), ["64", "65"])
        XCTAssertEqual(status.connectedDevices.map(\.displayName), ["iPhone Air", "Brandon's Mac"])
        XCTAssertEqual(status.connectedDevices.map(\.isTrustedName), [true, false])
    }

    func testParseStatusCombinesFirmwareDevicesWithLocalUSBConnection() {
        let status = DoorSerialParser.parseStatus(from: [
            "APP_STATUS_BEGIN",
            "ble_connected_count=1",
            "ble_max_connections=4",
            "connected_device=index=1 handle=64 trusted=yes name=iPhone Air",
            "APP_STATUS_END"
        ])

        let mergedStatus = status.includingLocalConnection(localUSBDevice)

        XCTAssertEqual(mergedStatus.connectedCount, 2)
        XCTAssertEqual(mergedStatus.maxConnections, 4)
        XCTAssertEqual(mergedStatus.connectedDevices.map(\.handle), ["usb-c-this-mac", "64"])
        XCTAssertEqual(mergedStatus.connectedDevices.map(\.displayName), ["Brandon's Mac (USB-C)", "iPhone Air"])
        XCTAssertEqual(mergedStatus.unidentifiedConnectedDeviceCount, 0)
    }

    func testTrustedDeviceRosterPreservesWirelessReportedCount() {
        let summary = TrustedDeviceRosterSummary(
            reportedTrustedCount: 2,
            reportedMaximumCount: 4,
            loadedDeviceCount: 0,
            hasTrustedLocalDevice: true
        )

        XCTAssertEqual(summary.trustedCount, 2)
        XCTAssertEqual(summary.maximumCount, 4)
        XCTAssertEqual(summary.countText, "2/4")
        XCTAssertTrue(summary.isRosterIncomplete)
    }

    func testTrustedDeviceRosterUsesLoadedRosterWhenStatusIsStale() {
        let summary = TrustedDeviceRosterSummary(
            reportedTrustedCount: 1,
            reportedMaximumCount: 0,
            loadedDeviceCount: 3,
            hasTrustedLocalDevice: false
        )

        XCTAssertEqual(summary.trustedCount, 3)
        XCTAssertEqual(summary.maximumCount, 4)
        XCTAssertEqual(summary.loadedDeviceCount, 3)
        XCTAssertFalse(summary.isRosterIncomplete)
    }
}
