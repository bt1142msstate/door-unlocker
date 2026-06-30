# Security Policy

This repository is a desk-test prototype. Treat it as experimental hardware and software, not a production access-control system.

## Command Signing

The repository does not contain a command secret.

The iPhone and Mac apps generate P-256 signing keys locally. They prefer Secure Enclave when available and fall back to Keychain-stored software keys when needed. Private keys are never written into source code. During pairing, the app sends only its public key and a short display name to the XIAO.

The XIAO stores trusted device public keys in internal flash and accepts only `v2` commands with valid ECDSA signatures and increasing per-device counters.

The iPhone app also has an optional setting to require Face ID or the device passcode before it signs an unlock command. This setting is off by default for convenience, and locking does not require extra authentication.

## Pairing

BLE pairing is locked by default. To add an iPhone, connect the XIAO over USB-C, open the serial monitor or Mac admin app, and enable pairing mode. Then connect with the iPhone app and tap **Pair This iPhone** while pairing mode is enabled. The phone shows a 4-digit approval code. Type that code with `pair approve CODE`, or type it into the Mac admin app. The Mac admin app intentionally does not display pending approval codes or pending public-key fingerprints. Pairing mode turns itself off after approval.

To trust the Mac itself, connect the XIAO over USB-C and open the Mac admin app. The app automatically sends its public signing key over the physically trusted USB-C admin channel and stores it directly, without a BLE approval code.

The firmware can store multiple trusted public keys. Use USB-C serial command `pair status` to see the trusted device count and pending request, `pairs list` to list trusted fingerprints and names when known, `pairs remove N` to remove one trusted device, `pair reject` to reject a pending device, `pair off` to lock pairing mode, or `pairs clear` to remove all trusted devices. The Mac admin app wraps the same USB-C management path and can also use its own paired key for wireless lock/unlock commands.

If a phone or Mac is replaced, the app is deleted, or the signing key is lost, enable USB-C pairing mode and pair the replacement device. If a device should no longer be trusted, remove it over USB-C or clear the pairing table and re-pair the devices you still trust.

If a trusted phone or Mac is compromised, remove that device from the XIAO pairing table or reset the XIAO pairing table and pair freshly installed apps.

USB-C admin commands are treated as physically trusted controller-management actions. The Mac admin app can trust the Mac's wireless key, remove trusted phones, and send lock/unlock over USB without using a previously paired wireless key, so do not leave the controller USB port connected to an untrusted computer.

## Responsible Use

Do not depend on this prototype for emergency egress, property security, or unattended access. Test on a desk first, then review the mechanical and safety implications before mounting anything to a real door.

Report security issues through a private GitHub security advisory if available on the repository, or open an issue with minimal sensitive detail.
