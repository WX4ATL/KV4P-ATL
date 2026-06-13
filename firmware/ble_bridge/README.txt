KV4P/ATL BLE bridge integration notes

Current shared development version: 0.2.0.

License
This BLE bridge overlay is intended to be distributed under GPL-3.0-or-later as
part of a KV4P HT derivative firmware. Preserve upstream KV4P HT notices,
include LICENSE.txt/NOTICE.txt with public releases, and publish complete
corresponding source plus build instructions for any flashed firmware binary.

Purpose
This bridge adds a Nordic UART-compatible BLE transport while keeping the KV4P
2.0 KISS protocol unchanged. iOS writes KISS bytes to characteristic
6E400002-B5A3-F393-E0A9-E50E24DCCA9E and receives KISS bytes from notify
characteristic 6E400003-B5A3-F393-E0A9-E50E24DCCA9E.

Secondary APRS KISS TNC service
The bridge also exposes the standard BLE KISS service used by Mobilinkd-style
iOS APRS clients such as PocketPacket, aprs.fi, and RadioMail:
  Service: 00000001-BA2A-46C9-AE49-01B0961F68BB
  App/client-to-radio write: 00000002-BA2A-46C9-AE49-01B0961F68BB
  Radio-to-app/client notify: 00000003-BA2A-46C9-AE49-01B0961F68BB
Inbound DATA frames from this service are passed to handleAx25Data(). KV4P
vendor frames are ignored on this service so public APRS clients cannot change
PTT, audio, or radio settings. Outbound received/transmitted AX.25 packets are
mirrored to this service as standard KISS DATA frames.

External APRS apps connect directly to this BLE KISS endpoint. If the KV4P iOS
app is already connected to the radio's main BLE service, the radio may not be
advertising for another central; disconnect or force quit the KV4P app before
opening PocketPacket's Bluetooth TNC selector.

Integration sketch for the upstream Arduino firmware
1. Copy kv4p_ble_bridge.h and kv4p_ble_bridge.cpp into
   microcontroller-src/kv4p_ht_esp32_wroom_32/.
2. Include kv4p_ble_bridge.h after protocol.h in kv4p_ht_esp32_wroom_32.ino.
3. Add globals after the existing Serial parser is declared:
   KV4PBleBridgeStream bleKissStream;
   KV4PBleBridge bleBridge(bleKissStream);
   KissParser bleParser(bleKissStream, &handleCommands, &handleAx25Data);
4. In setup(), after Serial is initialized, call:
   bleBridge.begin("KV4P HT BLE");
5. In loop(), call:
   protocolLoop();
   bleParser.loop();
   bleBridge.loop();
6. For outgoing radio-to-host frames, continue to call the existing USB send
   helpers and mirror each frame to BLE when bleBridge.isConnected() is true:
   sendKv4pVendorFrame(bleKissStream, command, payload, len);
   sendKissDataFrame(bleKissStream, ax25, len);

The safest production integration is to centralize the mirror in protocol.h
near the no-Stream overloads of sendKissDataFrame(), sendKv4pVendorFrame(),
sendHello(), sendDeviceState(), sendAudio(), sendAx25Packet(), and
sendWindowAck(). That keeps USB serial unchanged for Android, desktop KISS TNC
use, and flashing, while BLE receives the same encoded KISS frames.

BLE audio pacing note
RX audio frames are 8 kHz mono IMA ADPCM with 20 ms frames. Each voice payload
is 84 bytes: 2 bytes predictor, 1 byte step index, 1 byte sequence, and 80
packed ADPCM data bytes. For stable iPhone playback, the BLE notification queue
must be drained immediately after audio production, not only once before
rxAudioLoop() runs. The overlay therefore pumps when bytes are queued and calls
the BLE loop again after rxAudioLoop(). A separate FreeRTOS notification task
was tested and rejected because it caused BLE subscription timeouts on the ESP32
Arduino BLE stack.

BLE timing and packet size note
The bridge requests a 247-byte ATT MTU, stores the server-side MTU callback
payload size, and uses that value for notifications. Do not replace this with
BLEDevice::getPeerDevices(false); that global peer list stayed at the default
20-byte payload in Mac/iPhone testing and caused audio frames to be split across
multiple notifications. On connect, the bridge requests a 15 ms BLE connection
interval with zero slave latency and calls esp_ble_gap_set_pkt_data_len(...,
251) so accepted links can carry the larger ATT payloads with less link-layer
fragmentation.

BLE reconnect and advertising note
The bridge restarts advertising immediately on disconnect and schedules a
second restart about 500 ms later from loop(). This follows the Arduino-ESP32
BLE UART example's delayed advertising restart pattern and makes the radio more
findable after a central disconnect or a brief post-TX link drop.

Test order
1. Build firmware with BLE only on an ESP32 dev board and run a loopback test
   before connecting RF hardware.
2. Confirm iOS can connect, subscribe, and exchange KISS data frames.
3. Then flash a KV4P HT, verify hello/version/device-state frames, and only
   then test RF receive/transmit.

Build and flasher package
1. Run from the project root:
   firmware/ble_bridge/build_ble_release.sh --update
2. The script runs the required speed check before network work, pulls upstream
   if requested, applies the BLE overlay, builds PlatformIO release firmware,
   merges bootloader/partition/app images, and writes:
   web-flasher/firmware/kv4p-ht-firmware-ble-v<version>.bin
   web-flasher/firmware/manifest-ble-latest.json
3. The BLE build uses partitions_ble.csv because the stock OTA-sized app slot
   is too small once ESP32 BLE support is linked. NVS stays at 0x9000 so KV4P
   board configuration storage remains compatible.
4. Flash with the local web flasher:
   python3 -m http.server 8766 --directory web-flasher
   Open http://127.0.0.1:8766/kv4p-ble-flasher.html in Chromium.

Power and CPU profiling
See POWER_PROFILING_NOTES.txt for the 0.2.0 USB diagnostic findings, including
the observed loopTask watchdog reset, idle binary output rate, macOS live-power
measurement limitation, and recommended future FreeRTOS runtime-stat telemetry.
