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

2. Close the KV4P/ATL app, serial monitors, and anything else using the radio
   USB serial port.

3. Connect the KV4P HT ESP32 by USB.

4. Press and keep holding the ESP32/radio board's BOOT button.

5. Click "Start manual BOOT flash". The page shows a final reminder dialog.
   Keep holding BOOT, click "I am holding BOOT - start flash", then choose the
   CP2102/USB serial port in the browser picker.

6. Keep holding BOOT while the flasher says connecting, preparing, or
   initializing. The large ESP Web Tools install box is normal. Release BOOT
   only when the page's top banner says "You may now release the BOOT button."

7. If initialization fails, release BOOT, tap RST once or reconnect USB, then
   retry from step 4.

8. After flashing and rebooting, use "Scan for KV4P BLE" to confirm the ESP32
   advertises the Nordic UART-compatible service.

To rebuild the firmware from current upstream KV4P source:
   firmware/ble_bridge/build_ble_release.sh --update

The static browser page does not compile C++ firmware in the browser. The
rebuild script is the repeatable path that pulls or uses upstream source,
applies only the BLE overlay, regenerates the manifest/bin files, and rebuilds
the self-contained `kv4p-ble-flasher.html` with the newest firmware embedded.
The browser flasher keeps ESP Web Tools' stock Web Serial behavior. On the
tested KV4P HT, native command-line esptool can auto-reset the board, but
Chromium/Web Serial did not consistently enter ESP32 download mode. For that
reason the public HTML requires and explains the manual BOOT path instead of
promising automatic reset.

Experimental auto-reset diagnostic:
1. Open `kv4p-auto-reset-diagnostic.html` directly in Chrome, Edge, Brave, or
   another Chromium browser. A local web server is optional, not required.

2. Select the KV4P HT CP2102 serial port and run the sequence matrix. The page
   does not flash or write firmware. It only toggles DTR/RTS, reads the ESP32
   boot banner at 115200 baud, and classifies whether each reset sequence
   reached UART download mode. Version 0.2.5 and later automatically close the
   serial port after each run/reset so native flashing tools can reopen it.

3. After the run, save the downloaded JSON log. A successful browser auto-boot
   candidate should show `boot:0x3`, `DOWNLOAD_BOOT`, or similar download-mode
   evidence. If every tested sequence reports `boot:0x13 (SPI_FAST_FLASH_BOOT)`
   or no boot banner, keep using the manual BOOT flow for the public flasher.
