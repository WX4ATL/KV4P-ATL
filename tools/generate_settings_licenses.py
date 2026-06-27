#!/usr/bin/env python3
"""Generate the iOS Settings.bundle legal panes from kv4patl/Legal text files."""

from __future__ import annotations

import plistlib
import shutil
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LEGAL = ROOT / "kv4patl" / "Legal"
SETTINGS = ROOT / "kv4patl" / "Settings.bundle"
def spec_group(title: str, footer: str | None = None) -> dict:
    spec = {"Type": "PSGroupSpecifier", "Title": title}
    if footer:
        spec["FooterText"] = footer
    return spec


def spec_child(title: str, file_name: str) -> dict:
    return {"Type": "PSChildPaneSpecifier", "Title": title, "File": file_name}


def spec_value(title: str, key: str, value: str) -> dict:
    return {
        "Type": "PSTitleValueSpecifier",
        "Title": title,
        "Key": key,
        "DefaultValue": value,
    }


def write_plist(name: str, title: str, specs: list[dict]) -> None:
    payload = {"Title": title, "PreferenceSpecifiers": specs}
    with (SETTINGS / f"{name}.plist").open("wb") as handle:
        plistlib.dump(payload, handle, sort_keys=False)


def make_text_pane(prefix: str, title: str, text: str) -> str:
    write_plist(prefix, title, [spec_group(title, text.strip())])
    return prefix


def main() -> None:
    SETTINGS.mkdir(exist_ok=True)
    with (ROOT / "kv4patl" / "Info.plist").open("rb") as handle:
        app_version = plistlib.load(handle)["CFBundleShortVersionString"]
    for plist_path in SETTINGS.glob("*.plist"):
        plist_path.unlink()

    legal_entries = [
        ("Distribution Terms and Disclaimers", "AppDistributionTerms.txt", "Legal_AppDistributionTerms"),
        ("Component Legal Index", "ComponentLegalIndex.txt", "Legal_ComponentLegalIndex"),
        ("Third-Party Notices", "ThirdPartyNotices.txt", "Legal_ThirdPartyNotices"),
        ("End User License Agreement", "CustomAppStoreEULA.txt", "Legal_EndUserLicenseAgreement"),
        ("GPLv3 Source Notice", "GPLv3SourceNotice.txt", "Legal_GPLv3SourceNotice"),
        ("GNU GPL 3.0 or Later", "GPL-3.0-or-later.txt", "Legal_GPL_3_0_or_later"),
        ("ESP Web Tools Apache 2.0", "Apache-2.0-ESP-Web-Tools.txt", "Legal_Apache_2_0_ESP_Web_Tools"),
        ("Google Web Components BSD 3-Clause", "BSD-3-Clause-Google-Web-Components.txt", "Legal_BSD_3_Clause_Google_Web_Components"),
        ("alta/swift-opus BSD 3-Clause", "BSD-3-Clause-alta-swift-opus.txt", "Legal_BSD_3_Clause_alta_swift_opus"),
        ("raff/kv4p-go MIT", "MIT-raff-kv4p-go.txt", "Legal_MIT_raff_kv4p_go"),
        ("Web Flasher Third-Party Notices", "WebFlasherThirdPartyNotices.txt", "Legal_WebFlasherThirdPartyNotices"),
    ]

    generated = [
        (
            title,
            make_text_pane(prefix, title, (LEGAL / file_name).read_text(encoding="utf-8")),
        )
        for title, file_name, prefix in legal_entries[:4]
    ]
    generated.append(
        (
            "KV4P upstream other-licenses.txt",
            make_text_pane(
                "Legal_KV4P_Upstream_OtherLicenses",
                "KV4P upstream other-licenses.txt",
                (LEGAL / "KV4PUpstreamOtherLicenses.txt").read_text(encoding="utf-8"),
            ),
        ),
    )

    for title, file_name, prefix in legal_entries[4:]:
        generated.append((title, make_text_pane(prefix, title, (LEGAL / file_name).read_text(encoding="utf-8"))))

    write_plist(
        "Legal_Index",
        "Licenses",
        [
            spec_group(
                "Licenses, Credits & Attributions",
                "Each legal notice below is shown as one complete text block. The same source files are bundled with the app and retained in the project source.",
            ),
            *[spec_child(title, file_name) for title, file_name in generated],
        ],
    )

    write_plist(
        "Root",
        "KV4P/ATL",
        [
            spec_group("KV4P/ATL", "Settings and legal information for the KV4P/ATL radio app."),
            spec_child("Licenses, Credits & Attributions", "Legal_Index"),
            spec_value("App Name", "app_name", "KV4P/ATL"),
            spec_value("Version", "version", app_version),
            spec_value("Project License", "project_license", "GPL-3.0-or-later"),
        ],
    )

    # Settings.bundle resources must be present as ordinary files for Xcode to copy.
    shutil.copystat(LEGAL, SETTINGS, follow_symlinks=True)
    print(f"Generated {len(list(SETTINGS.glob('*.plist')))} Settings.bundle plist files.")


if __name__ == "__main__":
    main()
