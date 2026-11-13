Reply to App Review, Guidelines 4.3 and 4.2.6 (WatchKeyT, com.r2a42.teslakey)

Hello,

I don't think this app is spam or a template app, so I'm replying instead of resubmitting like your message says. I attached a video of it working on my car since you can't test it without one.

1. What it does
It's an Apple Watch app that locks and unlocks my Tesla and opens the trunk and frunk. That's all it does. It talks straight to the car over Bluetooth using Tesla's published protocol. The watch makes its own key, and I pair it once by tapping my key card in the car. It doesn't use an iPhone, a Tesla account or any server. It can't start or drive the car. The code is public at https://github.com/r2a42/TeslaWatch

2. Who it's for
My son. He has a Family Setup watch and no iPhone. I want him to be able to get his stuff out of the car without being able to drive it. Other parents with a Tesla and a kid on a Family Setup watch would be in the same spot.

3. What gap it fills
I couldn't find anything that does this. As far as I know, Tesla's own watch support needs an iPhone with the Tesla app signed in to a Tesla account, and a Family Setup watch has neither. This app gives the watch its own key that shows up on the car's Locks screen, and I can delete it from there any time. It also only gets into the car. It sends lock, unlock, trunk and frunk and nothing else. I checked at the car and it can't be started with the app. It doesn't need internet either, so it works in a garage.

4. Beta testing
No outside beta. It's me and my family. Before I submitted I ran the unit tests and used the watch simulator. After I submitted I tested on my own 2021 Model Y with an iPhone build of the same code. Pairing, lock, unlock, trunk and frunk all work on the real car. That testing turned up things I fixed: a bug where the lock status got stuck, confusing trunk labels, status that didn't refresh on its own, and I added key names and a log screen. Those fixes are in build 3. I uploaded it but didn't select or submit it because your message says not to resubmit. I can submit it now or as an update, whichever you want. I haven't been able to test on my son's watch. Family Setup watches aren't eligible for Developer Mode, and I don't have another Apple Watch.

5. Standalone or part of a suite
Standalone. It's the only app on my account. The iOS app in the bundle is just the container a watch-only app needs.

6. Could it be part of another app of mine
No. I don't have any other apps.

7. Shared code with my other apps
No. I don't have any other apps.

8. Shared code with third-party apps
No. There are no third-party SDKs. I wrote the Bluetooth and protocol code from Tesla's public documentation (https://github.com/teslamotors/vehicle-command). It only uses Apple's CryptoKit and CoreBluetooth.

9. Made for a client or third party
No. It's my car and my project, and it's on my own account. It's not from a template or an app builder. I'm not affiliated with Tesla, and the description says so.

Thanks. Let me know if you want build 3 submitted or anything else.
