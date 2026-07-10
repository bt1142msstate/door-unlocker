import Foundation

struct DoorAdminRuntimeTelemetryEntry: Identifiable, Equatable {
    let id = UUID()
    let elapsedMilliseconds: Int
    let event: String
    let details: String?

    var timeText: String {
        "\(elapsedMilliseconds)ms"
    }

    var title: String {
        switch event {
        case "store_init":
            return "Admin app started"
        case "central_created":
            return "Bluetooth manager created"
        case "bluetooth_powered_on":
            return "Bluetooth powered on"
        case "scan_requested":
            return "Scan requested"
        case "known_peripheral_retrieved":
            return "Saved controller found"
        case "connected_peripheral_retrieved":
            return "Connected controller reused"
        case "connect_start":
            return "Bluetooth connection started"
        case "peripheral_connected":
            return "Bluetooth connected"
        case "services_discovered":
            return "Services discovered"
        case "gatt_ready":
            return "Controller link ready"
        case "state_notify_enabled":
            return "State updates enabled"
        case "control_notify_enabled":
            return "Secure control updates enabled"
        case "secure_nonce_requested":
            return "Secure nonce requested"
        case "secure_nonce_received":
            return "Secure nonce received"
        case "wireless_auth_probe_sent":
            return "Wireless trust checked"
        case "wireless_disconnect":
            return "Wireless disconnected"
        case "wireless_stop":
            return "Wireless stopped"
        case "door_command_usable":
            return "Door command usable"
        case "first_fast_payload_ready":
            return "Fast command prepared"
        case "wireless_command_sent":
            return "Wireless command sent"
        case "usb_auto_connect_start":
            return "USB-C auto-connect started"
        case "usb_ready":
            return "USB-C ready"
        case "usb_startup_sync_start":
            return "USB-C startup sync started"
        case "usb_startup_sync_done":
            return "USB-C startup sync finished"
        case "usb_command_start":
            return "USB-C command started"
        case "usb_command_done":
            return "USB-C command finished"
        case "bluetooth_state":
            return "Bluetooth state"
        case "wireless_state":
            return "Wireless state"
        case "pairing_state":
            return "Pairing state"
        case "status_state":
            return "Door state"
        default:
            return event
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }
}
