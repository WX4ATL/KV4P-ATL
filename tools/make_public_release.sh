#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="KV4P-ATL-public-source-${STAMP}"
OUT_DIR="${ROOT}/build/releases/${NAME}"
ZIP_PATH="${OUT_DIR}.zip"

INCLUDE_PATHS=(
  ".gitignore"
  "LICENSE.txt"
  "NOTICE.txt"
  "README.txt"
  "APP_STORE_GPL_RELEASE_PLAN.txt"
  "CUSTOM_EULA_GPL.txt"
  "GITHUB_RELEASE_GUIDE.txt"
  "PUBLIC_RELEASE_MANIFEST.txt"
  "project.yml"
  "LICENSES"
  "kv4patl"
  "kv4patl_tests"
  "firmware/ble_bridge"
  "tools"
  "web-flasher"
)

EXCLUDES=(
  ".DS_Store"
  "build/"
  "DerivedData/"
  "*.xcresult"
  "*.xcarchive"
  "*.ipa"
  "*.dSYM"
  "*.mobileprovision"
  "*.provisionprofile"
  "corpus/"
  "kv4patl.xcodeproj/"
)

if [[ "${1:-}" == "--check" ]]; then
  printf 'Public release include set:\n'
  printf '  %s\n' "${INCLUDE_PATHS[@]}"
  printf '\nPublic release excludes:\n'
  printf '  %s\n' "${EXCLUDES[@]}"
  exit 0
fi

rm -rf "${OUT_DIR}" "${ZIP_PATH}"
mkdir -p "${OUT_DIR}"

for path in "${INCLUDE_PATHS[@]}"; do
  if [[ ! -e "${ROOT}/${path}" ]]; then
    printf 'Missing required release path: %s\n' "${path}" >&2
    exit 1
  fi
done

for path in "${INCLUDE_PATHS[@]}"; do
  rsync_args=(-a)
  for pattern in "${EXCLUDES[@]}"; do
    rsync_args+=(--exclude "${pattern}")
  done
  rsync "${rsync_args[@]}" "${ROOT}/${path}" "${OUT_DIR}/"
done

(
  cd "${ROOT}/build/releases"
  /usr/bin/zip -qry "${NAME}.zip" "${NAME}"
)

printf 'Created public source package:\n%s\n' "${ZIP_PATH}"
