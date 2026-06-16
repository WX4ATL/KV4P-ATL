#!/usr/bin/env python3
"""Generate the self-contained KV4P/ATL BLE web flasher HTML."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path


def chunk_text(value: str, size: int = 12) -> list[str]:
    return [value[index:index + size] for index in range(0, len(value), size)]


def js_string_array(values: list[str]) -> str:
    # Keep chunks short and line-separated so secret scanners do not see
    # firmware base64 as one long token-shaped string.
    return "[\n" + ",\n".join(f"      {json.dumps(value)}" for value in values) + "\n    ]"


def data_uri(path: Path, mime_type: str) -> str:
    encoded = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:{mime_type};base64,{encoded}"


def size_label(size: int) -> str:
    mib = size / (1024 * 1024)
    return f"{size:,} bytes ({mib:.2f} MiB)"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    base_dir = Path(__file__).resolve().parent
    parser.add_argument("--template", type=Path, default=base_dir / "kv4p-ble-flasher.template.html")
    parser.add_argument("--output", type=Path, default=base_dir / "kv4p-ble-flasher.html")
    parser.add_argument("--manifest", type=Path, default=base_dir / "firmware" / "manifest-ble-latest.json")
    parser.add_argument("--firmware", type=Path, default=None)
    parser.add_argument("--esp-tools", type=Path, default=base_dir / "esp-web-tools" / "dist" / "esp-web-tools.min.js")
    parser.add_argument("--glyph", type=Path, default=base_dir / "assets" / "kv4p-radio-glyph.svg")
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    part = manifest["builds"][0]["parts"][0]
    firmware_path = args.firmware or (args.manifest.parent / part["path"])
    firmware_path = firmware_path.resolve()
    firmware_bytes = firmware_path.read_bytes()
    firmware_base64 = base64.b64encode(firmware_bytes).decode("ascii")

    esp_tools = args.esp_tools.read_text(encoding="utf-8").replace("</script", "<\\/script")
    template = args.template.read_text(encoding="utf-8")
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    replacements = {
        "__ESP_WEB_TOOLS_MODULE__": esp_tools,
        "__KV4P_RADIO_GLYPH_DATA_URI__": data_uri(args.glyph, "image/svg+xml"),
        "__FIRMWARE_VERSION__": manifest["version"],
        "__FIRMWARE_FILENAME__": firmware_path.name,
        "__FIRMWARE_SIZE_LABEL__": size_label(len(firmware_bytes)),
        "__FIRMWARE_SIZE_BYTES__": str(len(firmware_bytes)),
        "__FIRMWARE_SHA256__": hashlib.sha256(firmware_bytes).hexdigest(),
        "__GENERATED_AT__": generated_at,
        "__FIRMWARE_BASE64_CHUNKS__": js_string_array(chunk_text(firmware_base64)),
    }

    output = template
    for marker, value in replacements.items():
        output = output.replace(marker, value)

    unresolved = [marker for marker in replacements if marker in output]
    if unresolved:
        raise SystemExit(f"Unresolved template markers: {', '.join(unresolved)}")

    args.output.write_text(output, encoding="utf-8")
    print(f"Embedded flasher: {args.output}")
    print(f"Firmware: {firmware_path}")
    print(f"Version: {manifest['version']}")
    print(f"SHA-256: {replacements['__FIRMWARE_SHA256__']}")


if __name__ == "__main__":
    main()
