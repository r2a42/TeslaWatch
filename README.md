# TeslaWatch

A standalone Apple Watch app that locks, unlocks and opens the trunk/frunk of a Tesla over
Bluetooth LE, using Tesla's Vehicle Command Protocol. No iPhone, no Tesla account, no Tesla
servers, no developer registration.

Target: 2021 Model Y, Family Setup watch (watchOS 10+).

## Layout

| Path | What |
| --- | --- |
| `Sources/TeslaKit` | Protocol, crypto, BLE transport. Public API is `TeslaVehicle`. |
| `Tests/TeslaKitTests` | Unit tests against golden vectors from Tesla's spec and official protobuf bindings. |
| `App/TeslaWatch` | SwiftUI watch app (VIN entry → pairing → controls). |
| `project.yml` | XcodeGen spec for the watch-only app target. |
| `tools/reference_vectors.py` | Python reference that generates the golden vectors. |

## Build

```sh
swift test                      # on a Mac (CryptoKit) or Linux (swift-crypto): protocol tests
brew install xcodegen && xcodegen
open TeslaWatch.xcodeproj       # set your team and bundle ID, run on the watch
```

Regenerate vectors after changing the reference: `python3 tools/reference_vectors.py > tools/vectors.txt && python3 tools/gen_tests.py`
(needs `pip install cryptography protobuf grpcio-tools` and bindings generated into `tools/pygen`
from `vehicle-command/pkg/protocol/protobuf/*.proto`).

## Pairing flow

1. Enter the VIN once (it is bound into every message's authentication and derives the BLE name).
2. Sit in the car with an NFC key card. Tap **Pair** on the watch.
3. The watch generates a P-256 key in its Secure Enclave and sends an add-key request over BLE.
4. Tap the key card on the center console, then confirm on the car's screen.

## What is and isn't verified

Verified (runs in `swift test` on Linux): wire encoding, session-info HMAC, ECDH key derivation,
AES-GCM signing byte-for-byte against the official bindings, response decryption, replay
rejection, BLE framing.

**Not verified; never compiled or run against a real car:** `BLETransport` (CoreBluetooth),
`TeslaVehicle`/`VehicleLink` (handshake and reply handling over BLE), `SecureEnclaveClientKey`,
`KeyStore`, and the SwiftUI app. Expect compile fixes and BLE debugging on first run. Likely
trouble spots: scan behavior on watchOS, write chunk size, VCSEC reply sequencing.

## Known limitations

- Foreground only. watchOS won't run BLE sessions in the background, so this is a button, not
  passive entry.
- Pairing and every command require BLE range of the car.
- Key revocation: forgetting the key on the watch doesn't remove it from the car. Delete it
  under Controls › Locks.
- The vehicle's public key isn't pinned between sessions (trust on first use per connection).
