#!/usr/bin/env python3
"""Build an unsigned XPI for development or Mozilla signing submission."""
import json
import pathlib
import sys
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
source = root / "BrowserBridge"
destination = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / "build/lima-browser-bridge-unsigned.xpi"
manifest = json.loads((source / "manifest.json").read_text())
assert manifest["browser_specific_settings"]["gecko"]["id"] == "lima-browser-bridge@liamhosfeld.com"
assert "<all_urls>" not in manifest.get("permissions", [])
assert manifest["optional_permissions"] == ["https://*/*"]
files = ["manifest.json", "policy.js", "background.js", "snapshot.js", "page_state.js", "scan_step.js", "scan_restore.js", "interaction.js", "popup.html", "popup.css", "popup.js"]
destination.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for name in files:
        info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        archive.writestr(info, (source / name).read_bytes())
print(f"Unsigned companion package: {destination}")
print("Development/signing submission only; permanent Firefox installation requires Mozilla signing.")
