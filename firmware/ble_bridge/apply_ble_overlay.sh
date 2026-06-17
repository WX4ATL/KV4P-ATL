#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

# Applies the additive iOS BLE transport overlay to a fresh copy of upstream
# KV4P HT firmware source. This keeps the patch rerunnable for future upstream
# releases instead of maintaining a hand-forked firmware tree.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
UPSTREAM_REPO="${1:-"${PROJECT_ROOT}/corpus/sources/repos/VanceVagell-kv4p-ht"}"
OUTPUT_DIR="${2:-"${PROJECT_ROOT}/build/kv4p-ble-firmware-src"}"
FIRMWARE_DIR="${OUTPUT_DIR}/microcontroller-src"
SKETCH_DIR="${FIRMWARE_DIR}/kv4p_ht_esp32_wroom_32"

if [[ ! -d "${UPSTREAM_REPO}/microcontroller-src/kv4p_ht_esp32_wroom_32" ]]; then
  echo "Upstream KV4P firmware source was not found at ${UPSTREAM_REPO}" >&2
  exit 1
fi

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"
rsync -a --exclude '.pio' --exclude '.git' "${UPSTREAM_REPO}/microcontroller-src/" "${FIRMWARE_DIR}/"
cp "${SCRIPT_DIR}/kv4p_ble_bridge.h" "${SKETCH_DIR}/kv4p_ble_bridge.h"
cp "${SCRIPT_DIR}/kv4p_ble_bridge.cpp" "${SKETCH_DIR}/kv4p_ble_bridge.cpp"
cp "${SCRIPT_DIR}/kv4p_adpcm_audio.h" "${SKETCH_DIR}/kv4p_adpcm_audio.h"
cp "${SCRIPT_DIR}/rxAudio_adpcm.h" "${SKETCH_DIR}/rxAudio.h"
cp "${SCRIPT_DIR}/txAudio_adpcm.h" "${SKETCH_DIR}/txAudio.h"
cp "${SCRIPT_DIR}/partitions_ble.csv" "${FIRMWARE_DIR}/partitions_ble.csv"

PROTOCOL="${SKETCH_DIR}/protocol.h"
SKETCH="${SKETCH_DIR}/kv4p_ht_esp32_wroom_32.ino"
PLATFORMIO="${FIRMWARE_DIR}/platformio.ini"
GLOBALS="${SKETCH_DIR}/globals.h"

if ! grep -q "libdeps_dir = ../../platformio-libdeps" "${PLATFORMIO}"; then
  perl -0pi -e 's|(\[platformio\]\n)|${1}libdeps_dir = ../../platformio-libdeps\n|s' "${PLATFORMIO}"
fi

if ! grep -q "board_build.partitions = partitions_ble.csv" "${PLATFORMIO}"; then
  perl -0pi -e 's|(framework = arduino\n)|${1}board_build.partitions = partitions_ble.csv\n|s' "${PLATFORMIO}"
fi

if ! grep -q -- "-DVAR_ARRAYS=1" "${PLATFORMIO}"; then
  perl -0pi -e 's|(-DARDUINO_EVENT_RUNNING_CORE=0\n)|${1}  -DVAR_ARRAYS=1\n|g' "${PLATFORMIO}"
fi

perl -0pi -e 's|^[ \t]*arduino-libopus=.*\n||mg' "${PLATFORMIO}"
perl -0pi -e 's|boolean audioOpen = false; // true when host wants RX Opus audio frames|boolean audioOpen = false; // true when host wants RX ADPCM audio frames|' "${SKETCH}"

perl -0pi -e 's|void inline sendKissDataFrame\(const uint8_t \*ax25, size_t len\) \{\n  sendKissDataFrame\(Serial, ax25, len\);\n\}|Stream *kv4pBleKissOutput = nullptr;\nStream *kv4pAprsTncOutput = nullptr;\nbool kv4pBleRxAudioOnly = false;\n\nvoid inline sendKissDataFrame(const uint8_t *ax25, size_t len) {\n  sendKissDataFrame(Serial, ax25, len);\n  if (kv4pBleKissOutput != nullptr) {\n    sendKissDataFrame(*kv4pBleKissOutput, ax25, len);\n  }\n  if (kv4pAprsTncOutput != nullptr) {\n    sendKissDataFrame(*kv4pAprsTncOutput, ax25, len);\n  }\n}|s' "${PROTOCOL}"

perl -0pi -e 's|void inline sendKv4pVendorFrame\(uint8_t kv4pCommand, const uint8_t \*payload, size_t len\) \{\n  sendKv4pVendorFrame\(Serial, kv4pCommand, payload, len\);\n\}|void inline sendKv4pVendorFrame(uint8_t kv4pCommand, const uint8_t *payload, size_t len) {\n  sendKv4pVendorFrame(Serial, kv4pCommand, payload, len);\n  if (kv4pBleKissOutput != nullptr) {\n    sendKv4pVendorFrame(*kv4pBleKissOutput, kv4pCommand, payload, len);\n  }\n}|s' "${PROTOCOL}"

perl -0pi -e 's|  static constexpr size_t BUF_SIZE = 64;|  // BLE RX audio packets should leave the KISS writer as one buffer so the bridge can notify one whole ADPCM frame.\n  static constexpr size_t BUF_SIZE = 256;|' "${PROTOCOL}"
perl -0pi -e 's|  COMMAND_DEVICE_STATE   = 0x0B, // \[COMMAND_DEVICE_STATE\(DeviceState\)\]|  COMMAND_DEVICE_STATE   = 0x0B, // [COMMAND_DEVICE_STATE(DeviceState)]\n  COMMAND_AFSK_STATS     = 0x0E, // [COMMAND_AFSK_STATS(AfskDecodeStatsPayload)]|' "${PROTOCOL}"
perl -0pi -e 's|#define HOST_STATE_ENABLE_STATUS_REPORTS \(1 << 12\)|#define HOST_STATE_ENABLE_STATUS_REPORTS (1 << 12)\n#define HOST_STATE_RX_POWER_SAVE      (1 << 13)\n#define HOST_STATE_RX_POWER_SAVE_MAX  (1 << 14)|' "${PROTOCOL}"
perl -0pi -e 's|#define DEVICE_STATE_ENABLE_STATUS_REPORTS HOST_STATE_ENABLE_STATUS_REPORTS|#define DEVICE_STATE_ENABLE_STATUS_REPORTS HOST_STATE_ENABLE_STATUS_REPORTS\n#define DEVICE_STATE_RX_POWER_SAVE      HOST_STATE_RX_POWER_SAVE\n#define DEVICE_STATE_RX_POWER_SAVE_MAX  HOST_STATE_RX_POWER_SAVE_MAX|' "${PROTOCOL}"

perl -0pi -e 's|#include "protocol.h"|#include "protocol.h"\n#include "kv4p_ble_bridge.h"|' "${SKETCH}"

perl -0pi -e 's|#include <Arduino.h>|#include <Arduino.h>\n\n// BLE audio and KISS mirroring benefit from loop stack headroom on ESP32 Arduino.\nSET_LOOP_TASK_STACK_SIZE(32 * 1024);|' "${SKETCH}"

perl -0pi -e 's|DRA818 &sa818 = sa818_vhf;|DRA818 \&sa818 = sa818_vhf;\n\nvoid handleTncKissCommand(RcvCommand command, uint8_t *params, size_t param_len);\nKV4PBleBridgeStream kv4pBleStream;\nKV4PBleBridgeStream kv4pBleTncStream;\nKV4PBleBridge kv4pBleBridge(kv4pBleStream, \&kv4pBleTncStream);\nKissParser kv4pBleParser(kv4pBleStream, &handleCommands, &handleAx25Data);\nKissParser kv4pBleTncParser(kv4pBleTncStream, &handleTncKissCommand, &handleAx25Data);\nbool kv4pBleWasConnected = false;\nvolatile bool kv4pBleUrgentPttOffPending = false;|' "${SKETCH}"

perl -0pi -e 's|const uint32_t DEVICE_STATE_REPORT_INTERVAL_MS = 500;|const uint32_t DEVICE_STATE_REPORT_INTERVAL_MS = 500;\nconst uint32_t BLE_AUDIO_DEVICE_STATE_REPORT_INTERVAL_MS = 2000;\nconst uint32_t BLE_POWER_SAVE_DEVICE_STATE_REPORT_INTERVAL_MS = 5000;|' "${SKETCH}"

perl -0pi -e 's|const uint32_t RSSI_REPORT_INTERVAL_MS = 100;|// RSSI? uses the SA818 serial control port. Keep BLE polling slow so it does not interrupt live ADPCM audio.\nconst uint32_t RSSI_REPORT_INTERVAL_MS = 1250;|' "${SKETCH}"

perl -0pi -e 's|  sendHello\(FIRMWARE_VER, radioModuleStatus, USB_BUFFER_SIZE, hw.rfModuleType, moduleMinRadioFreq\(\), moduleMaxRadioFreq\(\), getFirmwareFeatures\(\), currentDeviceState\(\)\);\n  _LOGI\("Setup is finished"\);|  sendHello(FIRMWARE_VER, radioModuleStatus, USB_BUFFER_SIZE, hw.rfModuleType, moduleMinRadioFreq(), moduleMaxRadioFreq(), getFirmwareFeatures(), currentDeviceState());\n  kv4pBleKissOutput = \&kv4pBleStream;\n  kv4pAprsTncOutput = \&kv4pBleTncStream;\n  kv4pBleBridge.begin("KV4P HT BLE");\n  _LOGI("Setup is finished");|' "${SKETCH}"

perl -0pi -e 's|  boardSetup\(\);\n  loadPersistedRadioState\(\);|  boardSetup();\n  loadPersistedRadioState();\n  // SA818 programming manual volume range is 1..8. Force max for this BLE/iPhone build so saved older board profiles do not stay quiet.\n  hw.volume = 8;|' "${SKETCH}"

perl -0pi -e 's|      endI2STx\(\);\n      initI2SRx\(\);|      endI2STx();\n      endI2SRx();|' "${SKETCH}"

perl -0pi -e 's|  setMode\(MODE_STOPPED\);\n  initI2SRx\(\);|  setMode(MODE_STOPPED);|' "${SKETCH}"

perl -0pi -e 's|        reconcileDesiredState\(\);|        reconcileDesiredState();\n        kv4pBleUrgentPttOffPending = false;|' "${SKETCH}"

perl -0pi -e 's|void handleCommands\(RcvCommand command, uint8_t \*params, size_t param_len\) \{|void handleTncKissCommand(RcvCommand command, uint8_t *params, size_t param_len) {\n  // The secondary BLE TNC service is intentionally APRS-only. Ignore KV4P\n  // vendor commands so external APRS clients cannot control PTT, audio, or\n  // radio settings through this public KISS endpoint.\n  (void)command;\n  (void)params;\n  (void)param_len;\n}\n\nvoid handleCommands(RcvCommand command, uint8_t *params, size_t param_len) {|' "${SKETCH}"

perl -0pi -e 's|static constexpr float TX_AFSK_GAIN = 0\.8f;|static constexpr float TX_AFSK_GAIN = 0.95f; // Raise APRS transmit tone level while keeping clamp headroom.|' "${GLOBALS}"

perl -0pi -e 's|    sendAudio\(\(uint8_t\*\)data, len\);|    esp_task_wdt_reset();\n        sendAudio((uint8_t*)data, len);\n        esp_task_wdt_reset();|' "${SKETCH_DIR}/rxAudio.h"

perl -0pi -e 's|void inline sendAudio\(const uint8_t \*data, size_t len\) \{\n  sendKv4pVendorFrame\(COMMAND_RX_AUDIO, data, len\);\n\}|void inline sendAudio(const uint8_t *data, size_t len) {\n  if (kv4pBleRxAudioOnly && kv4pBleKissOutput != nullptr) {\n    sendKv4pVendorFrame(*kv4pBleKissOutput, COMMAND_RX_AUDIO, data, len);\n  } else {\n    sendKv4pVendorFrame(COMMAND_RX_AUDIO, data, len);\n  }\n}|' "${PROTOCOL}"

perl -0pi -e 's@void reconcileDesiredState\(bool sendReport = true\) \{@bool kv4pRxPowerSaveRequested() {\n  return (desiredState.flags & HOST_STATE_RX_POWER_SAVE) &&\n    ((desiredState.flags & HOST_STATE_PTT_REQUESTED) == 0);\n}\n\nvoid kv4pRxPowerSaveLoop() {\n  if (!kv4pRxPowerSaveRequested() || mode == MODE_TX) {\n    return;\n  }\n\n  // 0.2.1 is intentionally fail-open for receive audio. Physical testing showed\n  // that using the firmware squelch flag to suppress ADPCM frames could miss\n  // open-squelch audio, so power save may slow reporting but must not mute RX.\n  if (!audioOpen || mode == MODE_STOPPED) {\n    audioOpen = true;\n    setMode(MODE_RX);\n    markDeviceStateDirty();\n  }\n}\n\nvoid reconcileDesiredState(bool sendReport = true) {@' "${SKETCH}"
perl -0pi -e 's@  audioOpen = desiredState.flags & HOST_STATE_RX_AUDIO_OPEN;@  audioOpen = desiredState.flags & HOST_STATE_RX_AUDIO_OPEN;\n  if (kv4pRxPowerSaveRequested()) {\n    audioOpen = true;\n  }@' "${SKETCH}"
perl -0pi -e 's|void loop\(\) \{|void kv4pBleLoop() {\n  kv4pBleParser.loop();\n  kv4pBleTncParser.loop();\n  const bool ready = kv4pBleBridge.isReady();\n  kv4pBleRxAudioOnly = ready;\n  if (!ready && kv4pBleWasConnected) {\n    // BLE sessions own only transient live-audio/PTT flags. Clear them on\n    // disconnect so a stale iPhone session cannot keep ADC, ADPCM encoding,\n    // USB KISS audio output, power-save RX, or TX state running after the\n    // central is gone.\n    desiredState.flags &= ~(HOST_STATE_PTT_REQUESTED \| HOST_STATE_RX_AUDIO_OPEN \| HOST_STATE_RX_POWER_SAVE \| HOST_STATE_RX_POWER_SAVE_MAX);\n    kv4pBleUrgentPttOffPending = true;\n    reconcileDesiredState(false);\n    markDeviceStateDirty();\n  }\n  if (ready && !kv4pBleWasConnected) {\n    sendHello(FIRMWARE_VER, radioModuleStatus, USB_BUFFER_SIZE, hw.rfModuleType, moduleMinRadioFreq(), moduleMaxRadioFreq(), getFirmwareFeatures(), currentDeviceState());\n  }\n  kv4pBleWasConnected = ready;\n}\n\nvoid loop() {|' "${SKETCH}"

perl -0pi -e 's|void kv4pBleLoop\(\) \{\n  kv4pBleParser.loop\(\);|void kv4pBleLoop() {\n  kv4pBleParser.loop();\n  kv4pBleBridge.loop();|' "${SKETCH}"

perl -0pi -e 's|void deviceStateLoop\(\) \{|uint32_t deviceStateReportIntervalMs() {\n  return (kv4pBleBridge.isReady() && audioOpen) ? BLE_AUDIO_DEVICE_STATE_REPORT_INTERVAL_MS : DEVICE_STATE_REPORT_INTERVAL_MS;\n}\n\nvoid deviceStateLoop() {|' "${SKETCH}"
perl -0pi -e 's|return \(kv4pBleBridge.isReady\(\) && audioOpen\) \? BLE_AUDIO_DEVICE_STATE_REPORT_INTERVAL_MS : DEVICE_STATE_REPORT_INTERVAL_MS;|if (kv4pBleBridge.isReady() && kv4pRxPowerSaveRequested()) {\n    return BLE_POWER_SAVE_DEVICE_STATE_REPORT_INTERVAL_MS;\n  }\n  return (kv4pBleBridge.isReady() && audioOpen) ? BLE_AUDIO_DEVICE_STATE_REPORT_INTERVAL_MS : DEVICE_STATE_REPORT_INTERVAL_MS;|' "${SKETCH}"

perl -0pi -e 's|EVERY_N_MILLISECONDS\(DEVICE_STATE_REPORT_INTERVAL_MS\)|EVERY_N_MILLISECONDS(deviceStateReportIntervalMs())|' "${SKETCH}"

perl -0pi -e 's|  protocolLoop\(\);\n|  protocolLoop();\n  kv4pBleLoop();\n|' "${SKETCH}"
perl -0pi -e 's|  squelchLoop\(\);\n|  squelchLoop();\n  kv4pRxPowerSaveLoop();\n|' "${SKETCH}"

perl -0pi -e 's|  rxAudioLoop\(\);\n|  rxAudioLoop();\n  kv4pBleLoop();\n|' "${SKETCH}"

perl -0pi -e 's|  txAudioLoop\(\);\n|  txAudioLoop();\n  kv4pBleLoop();\n|' "${SKETCH}"

perl -0pi -e 's|  deviceStateLoop\(\);\n|  deviceStateLoop();\n  kv4pBleLoop();\n|' "${SKETCH}"

if ! grep -q "KV4PBleBridgeStream kv4pBleStream" "${SKETCH}"; then
  echo "BLE overlay did not apply cleanly to ${SKETCH}" >&2
  exit 1
fi

if ! grep -q "kv4pBleKissOutput" "${PROTOCOL}" || ! grep -q "kv4pAprsTncOutput" "${PROTOCOL}"; then
  echo "Protocol mirroring patch did not apply cleanly to ${PROTOCOL}" >&2
  exit 1
fi

echo "${FIRMWARE_DIR}"
