Reply to App Review, Guidelines 4.3 and 4.2.6 (WatchKeyT, com.r2a42.teslakey)

Hello,

I believe WatchKeyT meets guidelines 4.3(a), 4.3(b) and 4.2.6, so I am replying and not resubmitting, as your message asks. My answers are below, in order. A demo video is attached, because the app cannot be exercised without a car.

1. What the app does
WatchKeyT is a standalone Apple Watch app that lets a family member lock and unlock a Tesla and open its trunk and frunk. It talks directly to the car over Bluetooth Low Energy using Tesla's published Vehicle Command Protocol. The watch creates its own private key in the Secure Enclave. The owner pairs that key once by tapping their key card on the car's center console, and after that the watch can send signed commands to the car. There is no iPhone companion app, no Tesla account sign-in, no cloud service and no server of mine. The app has no command to start or drive the car. It is for getting things out of the car, such as bags from the trunk, and locking up afterwards. The source code is public: https://github.com/r2a42/TeslaWatch

2. Intended user
The first user is my child, who wears a Family Setup Apple Watch and has no iPhone. More broadly, it is for Tesla owners who want to give a watch wearer access to the car's contents when that person cannot or should not use the Tesla phone app: children on managed watches, and family members who should be able to fetch something from the car but not drive it.

3. Gap in the market
What makes WatchKeyT different is its deliberately limited scope: it gives access to the things in the car without being a way to drive it. It sends only four commands (lock, unlock, open trunk, open frunk) and contains no start, remote-drive or keyless-driving command. I have confirmed this at the car: after unlocking with the app, the car cannot be started with it. To my knowledge, Tesla's own Apple Watch support depends on an iPhone running the Tesla app signed in to a Tesla account, and a Family Setup watch has neither. I have not found another App Store app that works on a Family Setup watch with no phone and no account. WatchKeyT gives that watch its own key, which appears on the car's Locks screen and can be removed there by the owner at any time. It also needs no internet connection, so it works in garages and other places with no signal.

4. Beta testing
I have not run an external beta, and I want to be accurate about what was tested when. Before submitting, I tested the protocol code with unit tests and the app in the watchOS simulator. After submitting, I tested on my own 2021 Model Y using an iPhone build of the same code: pairing, connecting, lock, unlock, trunk and frunk all work against the real car. That testing was by me and my family, and it led to changes that are not in the build you have (build 2): a fix for a lock-status display bug, clearer trunk and frunk labels, automatic status refresh, named keys, and a diagnostic log. Those are in a newer build (build 3), which I have uploaded to App Store Connect but have not selected or submitted, because your message asks me not to resubmit. I can submit it now or as an update after approval, whichever you prefer. I have not been able to test on the Family Setup watch itself. It is a Family Setup watch on my child's Apple Account, and it is not eligible for Developer Mode, so I cannot install a pre-release build on it. I have no other Apple Watch.

5. Standalone or suite
Standalone. This is the only app on my developer account. The iOS app in the bundle is only the container that a watch-only app requires, and it has no functionality of its own.

6. Could this be an in-app purchase or feature of another app of mine
No. I have no other apps, so there is nothing to consolidate it into.

7. Shared code or assets with other apps of mine
No. I have no other apps.

8. Shared code with third-party apps
No. The app uses no third-party SDKs or libraries. The Bluetooth and protocol layer is my own implementation, written against Tesla's public protocol documentation (https://github.com/teslamotors/vehicle-command) using only Apple's CryptoKit and CoreBluetooth frameworks.

9. Client or third party
No. I own the car, the app is my own project, and I am submitting it under my own account. It was not built from a template or an app generation service. I am not affiliated with Tesla, and the App Store description says so.

Thank you for your time. I am happy to provide anything else that would help, including a longer video. Build 3 is already uploaded if you would like me to submit it.
