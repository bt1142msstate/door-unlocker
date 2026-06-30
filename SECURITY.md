# Security Policy

This repository is a desk-test prototype. Treat it as experimental hardware and software, not a production access-control system.

## Command Signing

The repository does not contain a command secret.

The iPhone app generates a P-256 signing key locally. It prefers Secure Enclave when available and falls back to a Keychain-stored software key when needed. The private key is never written into source code. During pairing, the app sends only the public key to the XIAO.

The XIAO stores trusted phone public keys in internal flash and accepts only `v2` commands with valid ECDSA signatures and increasing per-phone counters.

## Pairing

BLE pairing is locked by default. To add a phone, connect the XIAO over USB-C, open the serial monitor, and send `pair on`. Then connect with the iPhone app and tap **Pair This iPhone** while pairing mode is enabled. Pairing mode turns itself off after accepting one phone.

The firmware can store multiple trusted phone public keys. Use USB-C serial command `pair status` to see the trusted phone count, `pair off` to lock pairing mode, or `pairs clear` to remove all trusted phones.

If the phone is replaced, the app is deleted, or the signing key is lost, enable USB-C pairing mode and pair the replacement phone. If a phone should no longer be trusted, clear the pairing table over USB-C and re-pair the phones you still trust.

If the phone itself is compromised, reset the XIAO pairing and pair a freshly installed app.

## Responsible Use

Do not depend on this prototype for emergency egress, property security, or unattended access. Test on a desk first, then review the mechanical and safety implications before mounting anything to a real door.

Report security issues through a private GitHub security advisory if available on the repository, or open an issue with minimal sensitive detail.
