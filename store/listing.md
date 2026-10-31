# App Store listing: Watch Key Test

**Name:** Watch Key Test  (30 chars max; no brand names)
**Subtitle:** Vehicle key for Apple Watch  (30 chars max)
**Category:** Utilities  (secondary: Lifestyle)
**Price:** Free
**Age rating:** 4+  (no objectionable content)
**Support URL / Privacy Policy URL:** see docs/privacy.md (host it, then paste the URL)

**Promotional text (170 chars max):**
A key for your vehicle on your Apple Watch. Made for family-managed watches with no iPhone.

**Keywords (100 chars max):**
watch,key,car,vehicle,lock,unlock,trunk,bluetooth,family,kids,remote

**Description:**
Watch Key Test turns an Apple Watch into a Bluetooth key for a compatible vehicle.

Built for family watches with no iPhone. If your child wears an Apple Watch set up through Family Setup and
doesn't have a phone, this app works entirely from the watch. There's no iPhone app to install, no account to
create and no phone needed for setup.

What it does
- Lock and unlock your vehicle
- Open the front and rear trunks
- Show whether the vehicle is locked

How setup works
1. Open the app on the watch and enter your vehicle's VIN.
2. Sit in the vehicle and tap Pair.
3. Hold your key card to the centre console and confirm on the vehicle's screen.

Privacy
The watch creates its own key inside the Secure Enclave. Nothing is sent to us. No accounts, no tracking, no
servers. Your key can be removed from the vehicle at any time on its own screen.

Good to know
- The app must be open on the watch to send a command. It is not a hands-free key and doesn't unlock
  automatically as you walk up.
- Requires Bluetooth and a compatible vehicle within range.
- Independent app. Not made by, or affiliated with, any vehicle manufacturer.

**What's New (1.0):** First release.

**Copyright:** 2026 Sean McNally

## Review notes (App Review Information)
This is a watchOS app for Apple Watches managed through Family Setup (no paired iPhone). The iOS target is
only a required container and has no functionality.

The app talks to the user's own vehicle over Bluetooth LE using the manufacturer's published vehicle command
protocol. It cannot be exercised without that vehicle, so reviewers cannot complete pairing or send commands.
A demo video of pairing, locking and unlocking on a real vehicle is attached. The first screen (VIN entry) and
the pairing screen can be reviewed without a vehicle.

The app contains no account system, no network calls and collects no data. Encryption is limited to standard
algorithms from Apple's CryptoKit (AES-GCM, P-256 keys held in the Secure Enclave), so it declares
ITSAppUsesNonExemptEncryption = NO.

**Contact:** Sean McNally, sfmcnally@gmail.com
**Demo account:** not applicable (no sign-in).

## Unlisted distribution request notes
App is for use by owners of compatible vehicles whose children wear Family Setup watches. It's shared by direct
link with those users and is not intended for search discovery.
