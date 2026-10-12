# Generated keys never leave the device

An SSH key that Shello generates is never synced, backed up or exported; each device has its own generated keys. Losing a device then means revoking only that device's keys, and the rule matches what the Secure Enclave enforces anyway for hardware-bound keys. Imported keys and passwords already exist elsewhere, so they may sync through iCloud Keychain if the user chooses.

## Consequences

- A new device cannot reach a server until its own key is installed there. To keep that cheap, public keys sync between the user's devices, and a device that already has access can install a sibling device's public key on chosen hosts in one action.
- The encrypted backup never contains generated keys; after a restore, hosts that used one show "key not on this device".
