KV4P HT BLE web flasher

This folder contains the Chromium flasher package for the KV4P HT BLE bridge
firmware. The public release artifact is `kv4p-ble-flasher.html`; that single
HTML file embeds ESP Web Tools, the KV4P glyph, the generated manifest, and the
latest KV4P/ATL BLE firmware binary. A user can download only that HTML file
and still flash the bundled KV4P/ATL firmware.

License and notices:
- The project-specific flasher page and KV4P glyph asset are GPL-3.0-or-later.
- ESP Web Tools 10.0.1 is bundled under Apache-2.0.
- Bundled Google Lit/Material Web code inside ESP Web Tools includes BSD-3-Clause and Apache-2.0 code.
- Keep THIRD_PARTY_NOTICES.txt and LICENSES/ with any public copy of this folder.
- The former photo asset is not included in this public flasher package; the page uses the GPL-traceable KV4P SVG glyph.

How to run locally:
1. Open `kv4p-ble-flasher.html` directly in Chrome, Edge, Brave, or another
   Chromium browser. A local web server is optional, not required.

2. Connect the KV4P HT ESP32 by USB and press "Connect and flash". The
   generated page skips the optional Improv Serial probe and lets esptool-js
   enter the ESP32 bootloader with Web Serial DTR/RTS control lines. The
   embedded esptool-js reset sequence is patched to try a macOS esptool-style
   combined DTR/RTS reset before the classic fallback timing, so the BOOT/RST
   buttons should not be pressed on a normal KV4P HT USB bridge.
   If initialization fails, close other serial tools, unplug/replug USB, and
   try again.

3. After flashing and rebooting, use "Scan for KV4P BLE" to confirm the ESP32
   advertises the Nordic UART-compatible service.

To rebuild the firmware from current upstream KV4P source:
   firmware/ble_bridge/build_ble_release.sh --update

The static browser page does not compile C++ firmware in the browser. The
rebuild script is the repeatable path that pulls or uses upstream source,
applies only the BLE overlay, regenerates the manifest/bin files, and rebuilds
the self-contained `kv4p-ble-flasher.html` with the newest firmware embedded.
Every generated manifest sets `new_install_improv_wait_time` to `0`, keeping
the browser install path focused on the same DTR/RTS bootloader entry used by
command-line esptool/PlatformIO flashes. The generator also patches the bundled
ESP Web Tools/esptool-js reset command parser so it can issue combined DTR/RTS
line-state changes through Web Serial, matching the native esptool reset path
that succeeded on `/dev/cu.usbserial-0001` without pressing BOOT/RST.
