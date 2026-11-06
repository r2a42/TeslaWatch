# TeslaWatch

A standalone Apple Watch app that locks, unlocks and opens the trunk/frunk of a Tesla over
Bluetooth LE, using Tesla's Vehicle Command Protocol. No iPhone, no Tesla account, no Tesla
servers, no developer registration.

Target: 2021 Model Y, Family Setup watch (watchOS 10+).

## Purpose and scope

This app is for **retrieving things from the car**: locking, unlocking, and opening the trunk or frunk,
for example for a child with a watch and no phone. It is **not** meant for driving. It does not start the
car, does not use remote drive or keyless driving, and contains no code that could. The only commands are
lock, unlock, open/close trunk, open frunk, and reading lock and closure state (see `VehicleAction` in
`Sources/TeslaKit/TeslaVehicle.swift`). Please don't add driving-related commands.

## Layout

| Path | What |
| --- | --- |
| `Sources/TeslaKit` | Protocol, crypto, BLE transport. Public API is `TeslaVehicle`. |
| `Tests/TeslaKitTests` | Unit tests against golden vectors from Tesla's spec and official protobuf bindings. |
| `App/TeslaWatch` | SwiftUI watch app: named keys, pairing, controls, in-app log. |
| `App/TeslaHost` | Empty iOS container app. The App Store only accepts a watch app embedded in an iOS app. |
| `App/TeslaPhone` | iPhone test build (separate bundle ID, installed from Xcode) sharing the watch views and `TeslaKit`. |
| `docs/privacy.md` | Privacy policy (published with GitHub Pages). |
| `store/` | App Store listing text, review notes and screenshots. |
| `project.yml` | XcodeGen spec for all app targets. |
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

1. Add a key: give it a name and enter the VIN (it is bound into every message's authentication and
   derives the BLE name). Several keys can be added; each has its own Secure Enclave key.
2. Sit in the car with an NFC key card. Tap **Pair** on the watch.
3. The watch generates a P-256 key in its Secure Enclave and sends an add-key request over BLE.
4. Tap the key card on the center console, then confirm on the car's screen.

The name in the app is local. Tesla's protocol has no field for a key name (the add-key request carries
only a form factor), so the car lists these keys as "Phone Key".

To name a key on the car: open **Controls > Locks** on the car's screen and send a command from the app.
The car moves the key that was just used to the top of the list, and an edit button next to it lets you
rename it (for example "Joe's Apple Watch - WatchKeyT"). The key's page in the app shows when a command
was last sent through it, to help match it to the car's list.

## What is and isn't verified

Verified (runs in `swift test`): wire encoding, session-info HMAC, ECDH key derivation, AES-GCM
signing byte-for-byte against the official bindings, response decryption, replay rejection, BLE
framing.

Verified on a real 2021 Model Y from an iPhone (`TeslaPhone` build): BLE scan and connect, handshake,
pairing with a key card, lock, unlock, trunk and frunk.

**Not verified:** running on an Apple Watch, the watch's Secure Enclave key, watchOS Bluetooth
behavior, installing on a Family Setup watch, reading trunk and frunk state from the car (decoded
from Tesla's format but not yet checked against a real reply), and multi-key pairing.

## Known limitations

- Foreground only. watchOS won't run BLE sessions in the background, so this is a button, not
  passive entry.
- Pairing and every command require BLE range of the car.
- Key revocation: forgetting the key on the watch doesn't remove it from the car. Delete it
  under Controls › Locks.
- The vehicle's public key isn't pinned between sessions (trust on first use per connection).
