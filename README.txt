KV4P/ATL

KV4P/ATL is a native SwiftUI iPhone and Mac companion app, ESP32 BLE firmware overlay,
APRS/KISS TNC implementation, and Chromium web flasher for KV4P HT ham radios.
It keeps the KV4P 2.0 KISS protocol semantics while adding an Apple-platform
Bluetooth Low Energy transport for voice, APRS, memories, radio control, and
firmware status.

Current shared development version: 0.3.2.

This workspace contains the app source in kv4patl/, protocol tests in
kv4patl_tests/, firmware bridge code in firmware/ble_bridge/, and the portable
web flasher in web-flasher/. Local research/device logs are retained privately
in corpus/ and are excluded from public source packages.

License and public release:
- This project is intended to be distributed under GPL-3.0-or-later. See LICENSE.txt and NOTICE.txt.
- The KV4P/ATL app, BLE firmware overlay, web flasher glue, and icon adaptation are KV4P HT derivative work because they adapt KV4P firmware/app behavior, protocol behavior, and artwork.
- Public App Store and firmware binary releases include complete corresponding source and follow APP_STORE_GPL_RELEASE_PLAN.txt.
- Use CUSTOM_EULA_GPL.txt as the App Store End User License Agreement text so GPL rights are preserved.
- Public source repository: https://github.com/WX4ATL/KV4P-ATL. Do not submit public app or firmware binaries unless that repository contains the complete corresponding source for the exact build.
- Use GITHUB_RELEASE_GUIDE.txt for the step-by-step GitHub publishing flow.
- Use PUBLIC_RELEASE_MANIFEST.txt and tools/make_public_release.sh to create the public source package. The package excludes local corpus logs, quarantined materials, downloaded research PDFs, signing files, and device logs.

How to run:
1. Generate or refresh the Xcode project:
   xcodegen generate

2. Build for simulator without signing:
   xcodebuild build -project kv4patl.xcodeproj -target kv4patl -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO

3. Build and run the native Mac app:
   xcodebuild build -project kv4patl.xcodeproj -scheme kv4patl-macOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
   open ~/Library/Developer/Xcode/DerivedData/kv4patl-*/Build/Products/Debug/kv4patl-macOS.app

4. Install and launch in an available simulator:
   xcrun simctl boot <simulator-udid>
   xcrun simctl install <simulator-udid> build/Debug-iphonesimulator/kv4patl.app
   xcrun simctl launch <simulator-udid> com.blakeross.kv4patl

5. Build for iPhone device hardware without signing:
   xcodebuild build -project kv4patl.xcodeproj -target kv4patl -sdk iphoneos CODE_SIGNING_ALLOWED=NO

6. Run the protocol unit tests on an available simulator:
   xcodebuild test -project kv4patl.xcodeproj -scheme kv4patl -destination 'platform=iOS Simulator,id=<simulator-udid>' CODE_SIGNING_ALLOWED=NO

7. Run the shared protocol tests natively on macOS:
   xcodebuild test -project kv4patl.xcodeproj -scheme kv4patl-macOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

8. Build the BLE firmware/flasher package:
   firmware/ble_bridge/build_ble_release.sh --update

9. Run the local web flasher:
   Open web-flasher/kv4p-ble-flasher.html in Chrome, Edge, Brave, or another Chromium browser.
   The generated HTML is self-contained and embeds the latest KV4P/ATL BLE firmware binary.

10. Run the experimental browser auto-reset diagnostic:
   Open web-flasher/kv4p-auto-reset-diagnostic.html in Chrome, Edge, Brave, or another Chromium browser.
   Select the KV4P HT CP2102 serial port, run the sequence matrix, and review the downloaded JSON log.

11. Create a public source release package:
   tools/make_public_release.sh

12. Build and install on a physical iPhone after provisioning is available:
   Open kv4patl.xcodeproj in Xcode, select your Apple Development team, select your connected iPhone as the run destination, and use Product > Run.
   For command-line installs, get your own device identifier with xcrun devicectl list devices and keep personal device names and identifiers out of committed files.

Provisioning notes:
- Do not commit personal device names, device identifiers, Apple team identifiers, or local signing state.
- Direct target builds with -sdk iphoneos and -sdk iphonesimulator work; a signed device install requires a local Xcode signing setup.

Notes:
- Version 0.3.2 adds reliable APRS messaging on iPhone and Mac. Direct messages use compact two-character message identifiers, APRS 1.1 Reply-ACK capability signaling, explicit ACK/reject handling, automatic inbound ACK responses, and decaying retries at 15, 30, 60, 120, and 240 seconds followed by a final acknowledgement grace period. Message rows show pending retry counts, delivered, failed, and acknowledgement-sent states; the composer enforces and displays the APRS 67-character message-text limit. Reliable outgoing messages are enabled by default and can be disabled in Settings.
- Version 0.3.1 fixes macOS scrolling throughout the app. Shared screen containers, Settings, and Memories now expose visible scroll indicators; APRS uses an independently scrollable packet feed beside the interactive map; and full bundled legal texts open in a dedicated scrolling sheet instead of a nested scroll view that could trap the About page.
- Version 0.3.0 adds a native macOS app target that shares the radio, BLE, APRS, persistence, settings, audio codec, and UI source with iPhone. The Mac app uses a resizable/full-screen sidebar workspace, desktop Voice and APRS layouts, Mac-native Core Audio microphone/playback behavior, App Sandbox Bluetooth/audio/location/network entitlements, shared protocol tests, and an in-app browser for every bundled legal text. The iOS and macOS targets use the same bundle identifier so they can be attached to one App Store Connect record for universal purchase.
- The BLE transport uses Nordic UART-compatible UUIDs and carries the KV4P 2.0 KISS stream.
- Direct arbitrary USB serial access from a public iPhone app is not available; USB-C is treated as power-only for this implementation path.
- The web flasher is generated as one self-contained HTML file with ESP Web Tools, the KV4P glyph, manifest data, and the v17 BLE firmware image embedded. The build script reapplies the BLE overlay to a fresh copy of upstream KV4P source and regenerates the HTML so future releases include the latest binary. The Chromium flasher intentionally uses the manual BOOT flow documented in `web-flasher/README.txt`.
- Version 0.2.15 latches the web flasher's green BOOT-release banner. Once Erasing or visible Installing progress has appeared, the banner stays green through later ESP Web Tools text changes instead of briefly falling back to amber.
- Version 0.2.14 refines the manual BOOT timing in the web flasher. The user still holds BOOT through the serial picker, install confirmation, and ESP Web Tools initialization, but the green release banner appears when the ESP Web Tools install box shows Erasing or visible Installing progress, instead of asking the user to hold BOOT for the whole flash.
- Version 0.2.13 makes the web flasher's manual BOOT sequence the primary path. The top of the page is now step-by-step flashing instructions, the flash button is labeled for manual BOOT flashing, a pre-flash dialog explains how to enter the serial picker, and an always-on-top banner changes to "You may now release the BOOT button" during the install flow.
- Version 0.2.12 replaces the removed toggle-driven APRS weak-signal path with an automatic firmware Bell 202 packet-candidate detector. The AFSK tap now measures 1200/2200 Hz tone-band energy against a rolling static floor, holds a candidate window when the step exceeds 12 dB, and uses that to arm adaptive AFSK gain/clipping protection while continuing to feed standard AX.25 KISS DATA frames. The iOS app parses and displays Bell 202 step/floor/tone/candidate telemetry in Settings > Debug.
- Version 0.2.11 removes the experimental RX noise-reduction controls from the app and removes the related playback spectral-DSP path, reset action, Settings.bundle references, and sources text. Firmware was checked and has no matching RX noise-reduction host setting to remove.
- Version 0.2.10 adds iPhone-side speaker control for APRS use: APRS-frequency RX mute keeps the speaker quiet when monitoring the configured packet channel while APRS decode and packet logging continue. It also cleans up APRS weather packet chips so wind is labeled as wind speed and appended weather comments are shown instead of a generic fallback.
- Version 0.2.9 fixes choppy RX playback on AirPods, Bluetooth headphones, and CarPlay-style buffered audio routes by switching those routes to a source-node ring buffer with a deeper wireless jitter cushion. PTT capture now allows A2DP output while still preferring the built-in iPhone microphone, reducing route churn around TX/RX changes.
- Version 0.2.8 adds an opt-in APRS weak-signal RX mode. The app sends a dedicated host-state bit, and the firmware uses it to keep the AFSK receive path armed, open the SA818 module squelch, disable module audio filters, run conservative AFSK-only AGC/clipping protection, and emit binary AFSK telemetry frames.
- Voice now exposes RX/TX split frequency and CTCSS tone index controls. Current upstream KV4P firmware exposes CTCSS tone indexes; true DCS/CDCSS is a separate future protocol/firmware feature.
- APRS now has Map, Messages, Beacons, and Packets views with AX.25/APRS parsing feeding those sections.
- Memories are managed manually in-app; the previous CSV repeater importer has been removed.
- Current source-build status: iPhone device-SDK build passed, native macOS build and APRS messaging UI QA passed, shared macOS protocol tests passed 31/31, and the BLE firmware/flasher package was regenerated for shared version 0.3.2. The self-contained web flasher embeds firmware manifest version `0.3.2-fw17-ble`.
- BLE RF voice uses 8 kHz mono IMA ADPCM at 20 ms frames. KV4P/ATL keeps a warm 48 kHz AVAudioEngine graph and down/up-samples internally so PTT does not rebuild the app audio path.
- RX power save is optional and receive-safe. The app sends firmware host-state flags, but it keeps RX audio requested; the firmware keeps the RX path armed and slows nonessential reporting without suppressing ADPCM frames based on squelch state.
