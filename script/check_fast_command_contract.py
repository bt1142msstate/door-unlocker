#!/usr/bin/env python3
"""Verify the cross-platform fast lock/unlock contract stays intact."""

from __future__ import annotations

import hashlib
import plistlib
import re
import sys
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def source_text(path: Path) -> str:
    if path.is_dir():
        return "\n".join(
            candidate.read_text(encoding="utf-8")
            for candidate in sorted(path.rglob("*.swift"))
        )
    return path.read_text(encoding="utf-8")


def require(path: Path, snippets: list[str], failures: list[str]) -> None:
    text = source_text(path)
    for snippet in snippets:
        if snippet not in text:
            failures.append(f"{display_path(path)} is missing: {snippet}")


def forbid(path: Path, snippets: list[str], failures: list[str]) -> None:
    text = source_text(path)
    for snippet in snippets:
        if snippet in text:
            failures.append(f"{display_path(path)} must not contain: {snippet}")


def nonce_channel_is_dedicated(firmware_text: str) -> bool:
    nonce_function = re.search(
        r"bool issueV3NonceTo\(uint16_t connHandle\) \{(?P<body>.*?)\n\s*void retryMissingV3Nonces",
        firmware_text,
        re.S,
    )
    return nonce_function is not None and "buildConnectionsStatePayload" not in nonce_function.group("body")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def zip_payload_digests(path: Path) -> dict[str, str]:
    with zipfile.ZipFile(path) as archive:
        return {
            info.filename: hashlib.sha256(archive.read(info.filename)).hexdigest()
            for info in archive.infolist()
            if not info.is_dir()
        }


def dfu_packages_match(first: Path, second: Path) -> bool:
    if not first.exists() or not second.exists():
        return False
    try:
        return zip_payload_digests(first) == zip_payload_digests(second)
    except (OSError, zipfile.BadZipFile):
        return False


def dfu_package_contract_failures(dist_package: Path, bundled_package: Path) -> list[str]:
    if not bundled_package.exists():
        return ["bundled iOS DFU package is missing"]
    try:
        zip_payload_digests(bundled_package)
    except (OSError, zipfile.BadZipFile):
        return ["bundled iOS DFU package is not a readable archive"]

    if dist_package.exists() and not dfu_packages_match(dist_package, bundled_package):
        return ["bundled iOS DFU payload does not match dist/DoorUnlockerXiao-dfu.zip"]
    return []


def main() -> int:
    failures: list[str] = []
    ios = ROOT / "ios/DoorUnlockerApp/DoorUnlocker"
    ios_recovery = ROOT / "ios/DoorUnlockerApp/DoorUnlocker/DoorUnlockerController+FastDoorRecovery.swift"
    ios_firmware = ROOT / "ios/DoorUnlockerApp/DoorUnlocker/Controller/System/DoorUnlockerController+FirmwareUpdate.swift"
    ios_bluetooth = ROOT / "ios/DoorUnlockerApp/DoorUnlocker/Controller/Bluetooth"
    mac = ROOT / "mac/DoorUnlockerAdmin/Sources/DoorUnlockerAdmin/Stores"
    mac_format = ROOT / "mac/DoorUnlockerAdmin/Sources/DoorUnlockerAdmin/Stores/DoorAdminStore+WirelessCommandFormatting.swift"
    mac_recovery = ROOT / "mac/DoorUnlockerAdmin/Sources/DoorUnlockerAdmin/Stores/DoorAdminStore+FastDoorRecovery.swift"
    ios_snapshot = ROOT / "ios/DoorUnlockerApp/DoorUnlocker/DoorUnlockerController+FirmwareStatus.swift"
    mac_snapshot = ROOT / "mac/DoorUnlockerAdmin/Sources/DoorUnlockerAdmin/Stores/DoorAdminStore+FirmwareSnapshot.swift"
    mac_connection = ROOT / "mac/DoorUnlockerAdmin/Sources/DoorUnlockerAdmin/Stores/Modules/Bluetooth/DoorAdminStore+BluetoothConnection.swift"
    mac_bluetooth_recovery = ROOT / "mac/DoorUnlockerAdmin/Sources/DoorUnlockerAdmin/Stores/Modules/Bluetooth/DoorAdminStore+BluetoothRecovery.swift"
    mac_firmware_transport = ROOT / "mac/DoorUnlockerAdmin/Sources/DoorUnlockerAdmin/Stores/Modules/Firmware/DoorAdminStore+FirmwareTransport.swift"
    mac_firmware_request = ROOT / "mac/DoorUnlockerAdmin/Sources/DoorUnlockerAdmin/Stores/Modules/Firmware/DoorAdminStore+FirmwareRequest.swift"
    presentation = ROOT / "shared/DoorUnlockerShared/Sources/DoorUnlockerShared/DoorControlPresentationPolicy.swift"
    firmware_snapshot_policy = ROOT / "shared/DoorUnlockerShared/Sources/DoorUnlockerShared/DoorFirmwareSnapshotPolicy.swift"
    firmware = ROOT / "firmware/DoorUnlockerXiao/DoorUnlockerXiao.ino"

    require(ios, [
        "DoorFastWritePolicy.action(",
        "peripheral.canSendWriteWithoutResponse",
        "peripheralIsReady(toSendWriteWithoutResponse",
        "clearQueuedDoorCommandIfSatisfied(by:",
        "if case .linkAuthentication = intent",
        "optimisticDoorCommand == nil",
    ], failures)
    require(ios_recovery, [
        "scheduleDoorCommandTransportRecovery()",
        "recoverStalledQueuedDoorCommandLink()",
        "DoorControlPresentationPolicy.state(",
    ], failures)
    require(ios_firmware, [
        "var isFirmwareDfuTransportActive: Bool",
        "firmwareUpdateEntryCommandSent || pendingFirmwareUpdatePackageURL == nil",
    ], failures)
    require(ios_bluetooth, [
        "guard !isFirmwareDfuTransportActive",
        "if isFirmwareDfuTransportActive",
    ], failures)
    require(mac, [
        "fastDoorCommandWriteAction(",
        "applyPredictedDoorCommand(predictedDoorCommand)",
        "peripheralIsReady(toSendWriteWithoutResponse",
        "reconcileWirelessDoorCommands(with:",
        "scheduleWirelessDoorCommandConfirmation(",
        "enum WirelessCommandDispatchResult",
        "case sent",
        "case queued",
        "case failed",
        "fastDoorCommandInFlight == nil",
        "hasAuthenticatedCurrentWirelessLink = true",
        "clearPendingWirelessDoorCommandAfterDispatch()",
    ], failures)
    require(mac_format, ["DoorFastWritePolicy.action("], failures)
    require(mac_recovery, [
        "scheduleWirelessDoorCommandTransportRecovery()",
        "DoorControlPresentationPolicy.state(",
        "DoorCommandPreparationRecoveryPolicy.action(",
        "recoverStalledQueuedSecureCommandLink()",
    ], failures)
    require(firmware, [
        "taskENTER_CRITICAL();",
        "taskEXIT_CRITICAL();",
        "popBleCommandQueueOverflow",
        "commandCharacteristic.setWriteCallback(commandWrittenCallback)",
        "controlCharacteristic.setProperties(CHR_PROPS_NOTIFY | CHR_PROPS_INDICATE)",
        "controlCharacteristic.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS)",
        "Bluefruit.configPrphConn(128, MULTI_LINK_EVENT_LENGTH, 2, 1)",
        "Bluefruit.Periph.setConnSupervisionTimeoutMS(MULTI_LINK_SUPERVISION_TIMEOUT_MS)",
        "BLE_COMMAND_QUEUE_PER_CONNECTION_LIMIT = 2",
        "queuedBleCommandCountForHandleLocked(connHandle)",
        "markBleCommandQueueOverflowLocked(connHandle)",
        "bleCommandQueueOverflowHandles[MAX_BLE_CONNECTIONS]",
        "discardBleCommandsForHandle(connHandle);",
        "bleCommandQueueServeOverflowNext",
        'publishControlRejectTo(connHandle, "controller_busy")',
        'handleServo.write(targetAngle);\n  // Begin physical movement before BLE notification backpressure.',
        'publishState(transitionState);',
    ], failures)
    require(presentation, [
        "!input.isDoorCommandQueuedForSecureLink",
        "!isChangingState",
    ], failures)
    require(firmware_snapshot_policy, [
        "case deferUntilCommandCompletes",
        "hasQueuedDoorCommand",
        "hasInFlightDoorCommand",
        "hasControllerSettingOperation",
    ], failures)
    require(ios_snapshot, ["DoorFirmwareSnapshotPolicy.action("], failures)
    require(mac_snapshot, ["DoorFirmwareSnapshotPolicy.action("], failures)
    require(firmware, [
        "stateCccdWrittenCallback",
        "publishStateTo(connHandle, currentStateText());",
    ], failures)
    forbid(firmware, [
        "void stateCccdWrittenCallback(uint16_t connHandle, BLECharacteristic* chr, uint16_t value) {\n"
        "  (void) chr;\n\n"
        "  if (value == 0 || connHandle == BLE_CONN_HANDLE_INVALID || !Bluefruit.connected(connHandle)) {\n"
        "    return;\n"
        "  }\n\n"
        "  publishStartupSnapshotTo(connHandle);",
    ], failures)
    forbid(ios, [
        "fastCommandMaterialMaxAge",
        "readControlIfPermitted",
        "if characteristic.uuid == controlUUID {\n                controlUpdateGeneration += 1",
    ], failures)
    forbid(ios_bluetooth, [
        "guard !isFirmwareUpdateRunning",
    ], failures)
    forbid(mac, [
        "fastCommandMaterialMaxAge",
        "readAckIfPossible",
        "queuedWirelessCommandDuringCurrentSend",
        "CBConnectPeripheralOptionEnableAutoReconnect",
        "scheduleWirelessReconnect(after: 6)",
        "if characteristic.uuid == controlUUID {\n                wirelessControlUpdateGeneration += 1",
    ], failures)
    forbid(ios_snapshot, ["setNotifyValue(false"], failures)
    forbid(mac_snapshot, ["setNotifyValue(false"], failures)
    for cancellable_transport_file in (
        mac_connection,
        mac_bluetooth_recovery,
        mac_snapshot,
        mac_firmware_transport,
        mac_firmware_request,
    ):
        forbid(cancellable_transport_file, ["try? await Task.sleep"], failures)
    forbid(firmware, [
        "controlCharacteristic.write(",
        "controlCharacteristic.setProperties(CHR_PROPS_READ",
        "controlCharacteristic.setPermission(SECMODE_NO_ACCESS",
        "requestConnectionParameter(",
        "setConnectedDeviceName(connHandle, trustedDeviceName, true);\n    publishConnectionsState();",
        "bleCommandQueueOverflowConnHandle",
        "bleCommandQueueOverflowPending",
    ], failures)

    firmware_text = firmware.read_text(encoding="utf-8")
    if not nonce_channel_is_dedicated(firmware_text):
        failures.append("issueV3NonceTo must keep the control characteristic dedicated to nonce traffic")

    match = re.search(r'CONTROLLER_FIRMWARE_VERSION\[\] = "([^"]+)"', firmware_text)
    firmware_version = match.group(1) if match else None
    with (ROOT / "ios/DoorUnlockerApp/DoorUnlocker/Info.plist").open("rb") as handle:
        bundled_version = plistlib.load(handle).get("DoorControllerFirmwareVersion")
    if not firmware_version or firmware_version != bundled_version:
        failures.append(f"firmware/app version mismatch: {firmware_version!r} != {bundled_version!r}")

    dist_package = ROOT / "dist/DoorUnlockerXiao-dfu.zip"
    bundled_package = ROOT / "ios/DoorUnlockerApp/DoorUnlocker/Firmware/DoorUnlockerXiao-dfu.zip"
    failures.extend(dfu_package_contract_failures(dist_package, bundled_package))

    if failures:
        print("Fast command contract: FAIL")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print(f"Fast command contract: PASS (firmware {firmware_version})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
