# iPhone Wireless Debugging

Door Unlocker uses Apple CoreDevice for iPhone installs, launches, notifications,
and debug console capture. The normal recovery/setup path is USB-C once, then
wireless whenever CoreDevice can keep the device reachable over the local
network.

## Requirements

- The iPhone must be paired with this Mac.
- Developer Mode must be enabled on the iPhone.
- The iPhone and Mac must be on the same network, and the network must allow
  local device discovery and IPv6.
- The iPhone must be unlocked when establishing the wireless developer tunnel.

Apple's Device Hub documentation says apps can run over Wi-Fi after disconnecting
the physical cable when the device is on the same network with IPv6 enabled.
Apple's OS logging documentation also recommends Console, the `log` command, or
Xcode's debug console for reviewing app log messages. For this project, the most
repeatable command-line path is CoreDevice's app launch console.

## Check Device Availability

```sh
script/ios_device_status.sh
script/ios_device_status.sh --require-wireless
```

Key fields:

- `transport=network` or another non-`wired` value means the iPhone is reachable
  without USB-C.
- `tunnel=connected`, `pairing=paired`, and `ddi_services=true` mean Xcode can
  install, launch, and debug through CoreDevice.
- `transport=wired` means the cable is currently being used. That is fine for
  setup, but it does not prove the wireless path.

## Install And Launch

```sh
DEVELOPMENT_TEAM=<team-id> script/install_ios_app.sh
```

When the phone is wireless-ready, the same script works without USB-C because it
installs through `devicectl`.

## Monitor The iPhone App

```sh
script/monitor_ios_app.sh --seconds 20
script/monitor_ios_app.sh --wireless-only --seconds 20
script/monitor_ios_app.sh --install --wireless-only --seconds 20
```

The monitor launches the app through CoreDevice with console capture and saves:

- Raw output: `docs/ios-telemetry/*-iphone-console.log`
- Filtered Door Unlocker diagnostics: `docs/ios-telemetry/*-iphone-summary.log`

The filtered output includes `DUStartup` timing, BLE readiness, secure nonce
flow, command readiness, and firmware update events.

## Debugger Attach

For breakpoint-level debugging, launch the app from Xcode using the physical
iPhone destination once CoreDevice reports wireless readiness. Apple's
`devicectl device process launch --help` also documents the LLDB attach flow:
launch the app, then use LLDB's device selection and process attach commands.

USB-C remains the recovery fallback. A normal app install, app launch, OTA
firmware proof, notification observation, and console capture should not require
USB-C once the wireless CoreDevice tunnel is connected.
