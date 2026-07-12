# Door Unlocker NordicDFU Patch

This directory vendors Nordic Semiconductor IOS-DFU-Library `4.16.0` at commit `4773d7eed944684dfdd177a4a91af8a89ebbaac8` under its BSD-3-Clause license.

Door Unlocker changes one transport assumption:

- Upstream `LegacyDFU/Characteristics/DFUPacket.swift` always sends 20-byte payloads.
- Adafruit nRF52 Bootloader `0.10+` accepts Legacy DFU writes up to `ATT_MTU - 3` and configures a maximum ATT MTU of 247.
- The patched client uses `CBPeripheral.maximumWriteValueLength(for: .withoutResponse)`, with a 20-byte floor for old bootloaders and a 244-byte cap for Adafruit.

The sizing policy is isolated in `LegacyDfuPacketSizing.swift` and covered by the package's independent tests. Do not remove the 20-byte fallback or 244-byte cap when rebasing onto a newer Nordic release.
