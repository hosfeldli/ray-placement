#!/usr/bin/env python3
"""Validate companion contents; Firefox, not this script, verifies Mozilla signatures."""
import argparse
import json
import pathlib
import zipfile

FILES = ("manifest.json", "policy.js", "background.js", "snapshot.js", "interaction.js", "popup.html", "popup.css", "popup.js")

def verify(package, require_signature=False):
    source = pathlib.Path(__file__).resolve().parents[1] / "BrowserBridge"
    with zipfile.ZipFile(package) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or len(names) > 32:
            raise ValueError("Duplicate or excessive archive entries")
        if any(name not in FILES and not name.startswith("META-INF/") for name in names):
            raise ValueError("Unexpected companion entry")
        if any(".." in pathlib.PurePosixPath(name).parts or name.startswith("/") for name in names):
            raise ValueError("Invalid archive path")
        if sum(item.file_size for item in archive.infolist()) > 4 * 1024 * 1024:
            raise ValueError("Companion exceeds size limit")
        for name in FILES:
            actual = archive.read(name)
            expected = (source / name).read_bytes()
            equal = json.loads(actual) == json.loads(expected) if name == "manifest.json" else actual == expected
            if not equal:
                raise ValueError(f"Companion differs from reviewed source: {name}")
        if require_signature:
            lowered = {name.lower() for name in names}
            jar = {"meta-inf/mozilla.rsa", "meta-inf/mozilla.sf", "meta-inf/manifest.mf"}
            cose = {"meta-inf/cose.sig", "meta-inf/cose.manifest"}
            if not (jar <= lowered or cose <= lowered):
                raise ValueError("Missing Mozilla signature metadata")
    print("Companion contents verified. Mozilla signature trust is verified by the browser at installation.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("package")
    parser.add_argument("--require-signature", action="store_true")
    args = parser.parse_args()
    verify(args.package, args.require_signature)
