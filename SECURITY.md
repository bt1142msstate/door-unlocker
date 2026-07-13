# Security Policy

This repository is a desk-test prototype. Treat it as experimental hardware and software, not a production access-control system.

## Command Signing

The repository does not contain a command secret.

The iPhone and Mac apps generate P-256 signing keys locally. They prefer Secure Enclave when available and fall back to Keychain-stored software keys when needed. Private keys are never written into source code. During pairing, the app sends only its public key and a short display name to the XIAO.

The XIAO stores trusted device public keys in internal flash and accepts only `v3` commands with valid ECDSA signatures, increasing per-device counters, and a fresh connection-private controller nonce. Captured commands cannot be replayed in a later session.

The iPhone app also has an optional setting to require Face ID or the device passcode before it signs an unlock command. This setting is off by default for convenience, and locking does not require extra authentication.

## Pairing

BLE pairing is locked by default. An already trusted iPhone or Mac can open pairing mode wirelessly; USB-C remains the recovery path when no trusted key is available. The new device shows a 4-digit approval code, which must be entered on an already trusted device or with `pair approve CODE` over USB-C. The approving Mac intentionally does not reveal the code. Pairing mode turns itself off after approval.

The first Mac can be trusted automatically through the physically trusted USB-C admin channel. Additional Macs can use the same wireless approval flow as iPhone.

The firmware can store multiple trusted public keys. Use USB-C serial command `pair status` to see the trusted device count and pending request, `pairs list` to list trusted fingerprints and names when known, `app rename N NAME` to rename a trusted device, `pairs remove N` to remove one trusted device, `pair reject` to reject a pending device, `pair off` to lock pairing mode, or `pairs clear` to remove all trusted devices. The Mac admin app and CLI wrap the same USB-C management path and can also use the Mac's paired key for wireless lock/unlock commands. When the Mac app is running, local CLI lock/unlock/toggle/timeout commands are handed to the app so only one process owns the USB-C serial stream; that means processes running as the same Mac user should be treated as trusted for this prototype.

If a phone or Mac is replaced, the app is deleted, or its signing key is lost, approve the replacement from another trusted device. Use USB-C only when no trusted device remains. Remove a lost device from a trusted client or over USB-C.

If a trusted phone or Mac is compromised, remove that device from the XIAO pairing table or reset the XIAO pairing table and pair freshly installed apps.

USB-C admin commands are treated as physically trusted controller-management actions. The Mac admin app can trust the Mac's wireless key, remove trusted phones, and send lock/unlock over USB without using a previously paired wireless key, so do not leave the controller USB port connected to an untrusted computer.

## Responsible Use

Do not depend on this prototype for emergency egress, property security, or unattended access. Test on a desk first, then review the mechanical and safety implications before mounting anything to a real door.

Report security issues through a private GitHub security advisory if available on the repository, or open an issue with minimal sensitive detail.
