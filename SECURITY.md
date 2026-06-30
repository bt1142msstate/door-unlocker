# Security Policy

This repository is a desk-test prototype. Treat it as experimental hardware and software, not a production access-control system.

## Command Signing

The repository does not contain a command secret.

The iPhone app generates a P-256 signing key locally. It prefers Secure Enclave when available and falls back to a Keychain-stored software key when needed. The private key is never written into source code. During pairing, the app sends only the public key to the XIAO.

The XIAO stores trusted phone public keys in internal flash and accepts only `v2` commands with valid ECDSA signatures and increasing per-phone counters.

The iPhone app also has an optional setting to require Face ID or the device passcode before it signs an unlock command. This setting is off by default for convenience, and locking does not require extra authentication.

## Pairing

BLE pairing is locked by default. To add a phone, connect the XIAO over USB-C, open the serial monitor or Mac admin app, and enable pairing mode. Then connect with the iPhone app and tap **Pair This iPhone** while pairing mode is enabled. The app shows a short approval code, and the XIAO prints the matching pending phone fingerprint over USB serial. Type `pair approve CODE` or approve the code in the Mac admin app only when the app and USB-side output match. Pairing mode turns itself off after approval.

The firmware can store multiple trusted phone public keys. Use USB-C serial command `pair status` to see the trusted phone count and pending request, `pairs list` to list trusted phone fingerprints, `pairs remove N` to remove one trusted phone, `pair reject` to reject a pending phone, `pair off` to lock pairing mode, or `pairs clear` to remove all trusted phones. The Mac admin app wraps the same USB-C management path.

If the phone is replaced, the app is deleted, or the signing key is lost, enable USB-C pairing mode and pair the replacement phone. If a phone should no longer be trusted, clear the pairing table over USB-C and re-pair the phones you still trust.

If the phone itself is compromised, remove that phone from the XIAO pairing table or reset the XIAO pairing and pair a freshly installed app.

USB-C admin commands are treated as physically trusted controller-management actions. The Mac admin app can remove trusted phones and send lock/unlock over USB without using the phone command-signing key, so do not leave the controller USB port connected to an untrusted computer.

## Responsible Use

Do not depend on this prototype for emergency egress, property security, or unattended access. Test on a desk first, then review the mechanical and safety implications before mounting anything to a real door.

Report security issues through a private GitHub security advisory if available on the repository, or open an issue with minimal sensitive detail.
