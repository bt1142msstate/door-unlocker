# Security Policy

This repository is a desk-test prototype. Treat it as experimental hardware and software, not a production access-control system.

## Command Signing

The repository does not contain a command secret.

The iPhone app generates a P-256 signing key locally. It prefers Secure Enclave when available and falls back to a Keychain-stored software key when needed. The private key is never written into source code. During pairing, the app sends only the public key to the XIAO.

The XIAO stores the paired public key in internal flash and accepts only `v2` commands with valid ECDSA signatures and increasing counters.

## Pairing

Fresh firmware starts unpaired. Connect with the iPhone app and tap **Pair This iPhone**. After pairing, the XIAO rejects attempts to replace the public key over BLE.

If the phone is replaced, the app is deleted, or the signing key is lost, clear or reflash the XIAO firmware storage and pair again. A future hardware revision should add a physical pairing/reset gesture.

If the phone itself is compromised, reset the XIAO pairing and pair a freshly installed app.

## Responsible Use

Do not depend on this prototype for emergency egress, property security, or unattended access. Test on a desk first, then review the mechanical and safety implications before mounting anything to a real door.

Report security issues through a private GitHub security advisory if available on the repository, or open an issue with minimal sensitive detail.
