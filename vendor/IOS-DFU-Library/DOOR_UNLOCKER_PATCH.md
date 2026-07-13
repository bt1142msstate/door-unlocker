# Door Unlocker NordicDFU Patch

This directory vendors Nordic Semiconductor IOS-DFU-Library `4.16.0` at commit `4773d7eed944684dfdd177a4a91af8a89ebbaac8` under its BSD-3-Clause license.

Door Unlocker changes one transport assumption:

- Upstream `LegacyDFU/Characteristics/DFUPacket.swift` always sends 20-byte payloads.
- Adafruit nRF52 Bootloader `0.10+` accepts Legacy DFU writes up to `ATT_MTU - 3` and configures a maximum ATT MTU of 247.
- The patched client uses `CBPeripheral.maximumWriteValueLength(for: .withoutResponse)` for the known factory `AdaDFU` bootloader and project-owned `DoorDFU*` bootloaders, with a 244-byte cap. Unknown Legacy DFU bootloaders keep 20-byte packets.
- Three physical `AdaDFU` transfers delivered the full 134 KB payload in 9.54-13.89 seconds with 244-byte writes. Their final CRC rejection was traced to the incompatible signed init packet: the exact same binary validates when wrapped in AdaDFU's legacy CRC16 package.
- Package selection is bootloader-specific: `AdaDFU` receives the factory CRC16 package and `DoorDFU` receives the ECDSA-signed package.

The sizing policy is isolated in `LegacyDfuPacketSizing.swift` and covered by the package's independent tests. Do not remove the known-name gate, unknown-device 20-byte fallback, or 244-byte cap when rebasing onto a newer Nordic release.
