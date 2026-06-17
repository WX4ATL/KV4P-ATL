#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

# Builds a fresh KV4P BLE firmware release from upstream source plus the small
# additive BLE overlay. The generated manifest is what the browser flasher uses.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
UPSTREAM_REPO="${PROJECT_ROOT}/corpus/sources/repos/VanceVagell-kv4p-ht"
BUILD_ROOT="${PROJECT_ROOT}/build/kv4p-ble-firmware-src"
WEB_FIRMWARE_DIR="${PROJECT_ROOT}/web-flasher/firmware"
UPDATE_UPSTREAM=0
PROJECT_VERSION="${KV4P_ATL_PROJECT_VERSION:-0.2.12}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream)
      UPSTREAM_REPO="$2"
      shift 2
      ;;
    --output)
      WEB_FIRMWARE_DIR="$2"
      shift 2
      ;;
    --update)
      UPDATE_UPSTREAM=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 64
      ;;
  esac
done

check_speed_before_network() {
  if [[ "${KV4P_SKIP_SPEED_CHECK:-}" == "1" ]]; then
    return
  fi

  if ! command -v networkQuality >/dev/null 2>&1; then
    echo "networkQuality is not available; continuing without an automatic speed check." >&2
    return
  fi

  local output
  output="$(networkQuality -s)"
  echo "${output}"

  local downlink
  downlink="$(awk -F': ' '/Downlink capacity/{print $2}' <<< "${output}" | awk '{print $1}')"
  if [[ -n "${downlink}" ]] && awk "BEGIN { exit !(${downlink} < 75) }"; then
    echo "Download speed is ${downlink} Mbps, below the 75 Mbps threshold." >&2
    echo "Use this URL manually instead, then rerun without --update: https://github.com/VanceVagell/kv4p-ht" >&2
    exit 75
  fi
}

check_speed_before_network

if [[ "${UPDATE_UPSTREAM}" == "1" ]]; then
  git -C "${UPSTREAM_REPO}" pull --ff-only
fi

FIRMWARE_DIR="$(bash "${SCRIPT_DIR}/apply_ble_overlay.sh" "${UPSTREAM_REPO}" "${BUILD_ROOT}")"
SKETCH="${FIRMWARE_DIR}/kv4p_ht_esp32_wroom_32/kv4p_ht_esp32_wroom_32.ino"
VERSION="$(sed -nE 's/^const uint16_t FIRMWARE_VER = ([0-9]+);/\1/p' "${SKETCH}" | head -n 1)"

if [[ -z "${VERSION}" ]]; then
  echo "Could not read FIRMWARE_VER from ${SKETCH}" >&2
  exit 1
fi

(
  cd "${FIRMWARE_DIR}"
  pio run -e esp32dev-release
)

mkdir -p "${WEB_FIRMWARE_DIR}"

PIO_PYTHON="${HOME}/.platformio/penv/bin/python"
ESPTOOL="${HOME}/.platformio/packages/tool-esptoolpy/esptool.py"
BOOT_APP0="${HOME}/.platformio/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin"
BUILD_DIR="${FIRMWARE_DIR}/.pio/build/esp32dev-release"
OUT_BIN="${WEB_FIRMWARE_DIR}/kv4p-ht-firmware-ble-v${VERSION}.bin"

"${PIO_PYTHON}" "${ESPTOOL}" --chip esp32 merge_bin \
  -o "${OUT_BIN}" \
  0x1000 "${BUILD_DIR}/bootloader.bin" \
  0x8000 "${BUILD_DIR}/partitions.bin" \
  0xe000 "${BOOT_APP0}" \
  0x10000 "${BUILD_DIR}/firmware.bin"

cat > "${WEB_FIRMWARE_DIR}/manifest-ble-v${VERSION}.json" <<JSON
{
  "name": "KV4P/ATL BLE bridge firmware",
  "version": "${PROJECT_VERSION}-fw${VERSION}-ble",
  "new_install_prompt_erase": false,
  "builds": [
    {
      "chipFamily": "ESP32",
      "improv": false,
      "parts": [
        { "path": "kv4p-ht-firmware-ble-v${VERSION}.bin", "offset": 0 }
      ]
    }
  ]
}
JSON

cp "${WEB_FIRMWARE_DIR}/manifest-ble-v${VERSION}.json" "${WEB_FIRMWARE_DIR}/manifest-ble-latest.json"
"${PIO_PYTHON}" "${PROJECT_ROOT}/web-flasher/build_embedded_flasher.py" \
  --manifest "${WEB_FIRMWARE_DIR}/manifest-ble-latest.json" \
  --firmware "${OUT_BIN}" \
  --output "${PROJECT_ROOT}/web-flasher/kv4p-ble-flasher.html"
shasum -a 256 "${OUT_BIN}"
echo "Built ${OUT_BIN}"
echo "Manifest: ${WEB_FIRMWARE_DIR}/manifest-ble-latest.json"
echo "Self-contained flasher: ${PROJECT_ROOT}/web-flasher/kv4p-ble-flasher.html"
