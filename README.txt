KV4P/ATL

KV4P/ATL is a native SwiftUI iPhone companion app, ESP32 BLE firmware overlay,
APRS/KISS TNC implementation, and Chromium web flasher for KV4P HT ham radios.
It keeps the KV4P 2.0 KISS protocol semantics while adding an iPhone-friendly
Bluetooth Low Energy transport for voice, APRS, memories, radio control, and
firmware status.

Current shared development version: 0.2.4.

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

3. Install and launch in an available simulator:
   xcrun simctl boot <simulator-udid>
   xcrun simctl install <simulator-udid> build/Debug-iphonesimulator/kv4patl.app
   xcrun simctl launch <simulator-udid> com.blakeross.kv4patl

4. Build for iPhone device hardware without signing:
   xcodebuild build -project kv4patl.xcodeproj -target kv4patl -sdk iphoneos CODE_SIGNING_ALLOWED=NO

5. Run the protocol unit tests on an available simulator:
   xcodebuild test -project kv4patl.xcodeproj -scheme kv4patl -destination 'platform=iOS Simulator,id=<simulator-udid>' CODE_SIGNING_ALLOWED=NO

6. Build the BLE firmware/flasher package:
   firmware/ble_bridge/build_ble_release.sh --update

7. Run the local web flasher:
   Open web-flasher/kv4p-ble-flasher.html in Chrome, Edge, Brave, or another Chromium browser.
   The generated HTML is self-contained and embeds the latest KV4P/ATL BLE firmware binary.

8. Run the experimental browser auto-reset diagnostic:
   Open web-flasher/kv4p-auto-reset-diagnostic.html in Chrome, Edge, Brave, or another Chromium browser.
   Select the KV4P HT CP2102 serial port, run the sequence matrix, and review the downloaded JSON log.

9. Create a public source release package:
   tools/make_public_release.sh

10. Build and install on a physical iPhone after provisioning is available:
   Open kv4patl.xcodeproj in Xcode, select your Apple Development team, select your connected iPhone as the run destination, and use Product > Run.
   For command-line installs, get your own device identifier with xcrun devicectl list devices and keep personal device names and identifiers out of committed files.

Provisioning notes:
- Do not commit personal device names, device identifiers, Apple team identifiers, or local signing state.
- Direct target builds with -sdk iphoneos and -sdk iphonesimulator work; a signed device install requires a local Xcode signing setup.

Notes:
- The BLE transport uses Nordic UART-compatible UUIDs and carries the KV4P 2.0 KISS stream.
- Direct arbitrary USB serial access from a public iPhone app is not available; USB-C is treated as power-only for this implementation path.
- The web flasher is generated as one self-contained HTML file with ESP Web Tools, the KV4P glyph, manifest data, and the v17 BLE firmware image embedded. The build script reapplies the BLE overlay to a fresh copy of upstream KV4P source and regenerates the HTML so future releases include the latest binary. If Chromium cannot initialize the ESP32, use the manual BOOT flow documented in `web-flasher/README.txt`.
- Version 0.2.4 adds a separate experimental auto-reset diagnostic page that tests Web Serial DTR/RTS sequences without flashing firmware and downloads a JSON log for comparing boot-mode evidence.
- Voice now exposes RX/TX split frequency and CTCSS tone index controls. Current upstream KV4P firmware exposes CTCSS tone indexes; true DCS/CDCSS is a separate future protocol/firmware feature.
- APRS now has Map, Messages, Beacons, and Packets views with AX.25/APRS parsing feeding those sections.
- Memories are managed manually in-app; the previous CSV repeater importer has been removed.
- Current source-build status: simulator build/test passed, BLE firmware esp32dev-release build passed, and the physical KV4P HT was flashed/verified on 2026-06-15 for shared version 0.2.3. The 0.2.4 source change adds the browser auto-reset diagnostic without changing the flashed firmware image.
- BLE RF voice uses 8 kHz mono IMA ADPCM at 20 ms frames. KV4P/ATL keeps a warm 48 kHz AVAudioEngine graph and down/up-samples internally so PTT does not rebuild the app audio path.
- RX power save is optional and receive-safe. The app sends firmware host-state flags, but it keeps RX audio requested; the firmware keeps the RX path armed and slows nonessential reporting without suppressing ADPCM frames based on squelch state.
