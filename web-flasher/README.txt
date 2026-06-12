KV4P HT BLE web flasher

This folder is a portable Chromium flasher package for the KV4P HT BLE bridge firmware. Keep kv4p-ble-flasher.html together with the assets/, esp-web-tools/, and firmware/ folders.

License and notices:
- The project-specific flasher page and KV4P glyph asset are GPL-3.0-or-later.
- ESP Web Tools 10.0.1 is bundled under Apache-2.0.
- Bundled Google Lit/Material Web code inside ESP Web Tools includes BSD-3-Clause and Apache-2.0 code.
- Keep THIRD_PARTY_NOTICES.txt and LICENSES/ with any public copy of this folder.
- The former photo asset is not included in this public flasher package; the page uses the GPL-traceable KV4P SVG glyph.

How to run locally:
1. From the project root, start a local server:
   python3 -m http.server 8766 --directory web-flasher

2. Open this URL in Chrome, Edge, Brave, or another Chromium browser:
   http://127.0.0.1:8766/kv4p-ble-flasher.html

3. Connect the KV4P HT ESP32 by USB and choose "BLE firmware for KV4P/ATL".

4. After flashing and rebooting, use "Scan for KV4P BLE" to confirm the ESP32 advertises the Nordic UART-compatible service.

To rebuild the firmware from current upstream KV4P source:
   firmware/ble_bridge/build_ble_release.sh --update

The static browser page does not compile C++ firmware in the browser. The rebuild script is the repeatable path that pulls or uses upstream source, applies only the BLE overlay, and regenerates the manifest/bin consumed by this page.
