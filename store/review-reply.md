Reply to App Review, Guidelines 4.3 and 4.2.6 (WatchKeyT, com.r2a42.teslakey)

Hello,

I believe WatchKeyT meets guidelines 4.3(a), 4.3(b) and 4.2.6, so I am replying instead of resubmitting. Answers below, in order.

1. What the app does
WatchKeyT is a standalone Apple Watch app that lets the owner's family member lock and unlock a Tesla Model Y and open its trunk and frunk. It talks directly to the car over Bluetooth Low Energy using Tesla's published Vehicle Command Protocol. The watch holds its own private key in the Secure Enclave. The owner pairs that key once by tapping their key card on the car's center console, after which the watch can send signed commands to the car. There is no iPhone companion in normal use, no Tesla account sign-in, no cloud service and no server of mine. The app does not start or drive the car. It is only for getting things out of the car (bags in the trunk, a stroller in the frunk) and locking up. The project is open source: https://github.com/r2a42/TeslaWatch

2. Intended user
The immediate user is my child, who wears a Family Setup Apple Watch and has no iPhone of their own. More broadly: anyone who owns a Tesla and wants a watch that works as a simple car key for a person who cannot or does not want to run the Tesla phone app, such as children on managed watches or people who leave their phone behind.

3. Gap in the market
What makes WatchKeyT unique is its deliberately limited scope: it gives access to the things in the car without letting anyone drive it. It can lock, unlock and open the trunk and frunk, and it has no start, remote-drive or keyless-driving command. That makes it safe to hand to a child, a house guest or a valet-style helper who needs to fetch or stow something but must never be able to take the car. A full phone key cannot be limited this way. To my knowledge, the Tesla app's watch support depends on a paired iPhone running the Tesla app signed in to a Tesla account, and it is not designed for Family Setup. A child's Family Setup watch cannot sign in to a Tesla account or share the owner's login safely. WatchKeyT gives that watch its own revocable key, listed on the car's own Locks screen, so the owner can remove it at any time from the car. It also needs no internet connection, which matters in underground garages and on trails where the car has no cell service.

4. Beta testing
I have not run an external beta. I tested as the owner, on my own 2021 Model Y, using an iPhone build that shares the same SwiftUI and protocol code as the watch app. I tested pairing, connect and handshake, lock, unlock, trunk and frunk. Feedback from that testing that went into the build: a lock-state parsing bug that left the status stuck on "Checking" after unlocking (fixed); inconsistent trunk button labels (fixed); lid animations starting before the car acknowledged the command (now they wait for the car's reply); the dimming and spinner during commands (removed); and trunk and frunk state now polling every few seconds while open. Testing on the child's physical Family Setup watch is still outstanding because the app is not yet installable there. I can attach a screen recording of the iPhone build against the car and a watch simulator recording.

5. Standalone or suite
Standalone. The only other app target in this project is the required iOS container for a watch-only app, and it has no functionality of its own. [CONFIRM: if your developer account has any other published apps, say they are unrelated to this one.]

6. Could this be an IAP or feature in another app of mine
No. [CONFIRM: no other app of mine does anything related to vehicles.]

7. Shared code or assets with other apps of mine
No. The iOS container shares the app icon with the watch app, and that is all. [CONFIRM against your other apps, if any.]

8. Shared code with third-party apps
No third-party SDKs. The Bluetooth and protocol layer (TeslaKit) is my own implementation, written against Tesla's public documentation at https://github.com/teslamotors/vehicle-command, using only Apple's CryptoKit and CoreBluetooth.

9. Client or third party
No. I own the car, wrote the app, and am submitting it under my own account. It was not built from a template or app generation service. I am not affiliated with Tesla and the app says so.

Thank you for the review. If it would help, I can supply a demo video or a test build.
