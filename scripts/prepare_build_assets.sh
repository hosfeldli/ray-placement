#!/bin/zsh
# Resolve large deterministic package inputs without teaching package_app.sh
# about any cloud provider. Local verified files always win; GCS is an optional
# release-runner source, and Whisper retains its existing installed/upstream
# fallback when cloud assets are unavailable.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
MANIFEST="${LIMA_BUILD_ASSETS_MANIFEST:-$PROJECT_DIRECTORY/Packaging/build-assets.json}"
ASSET_BUCKET="${LIMA_BUILD_ASSET_BUCKET:-}"
GCS_PREFIX="${LIMA_BUILD_ASSET_GCS_PREFIX:-}"
[[ -n "$GCS_PREFIX" || -z "$ASSET_BUCKET" ]] || GCS_PREFIX="gs://$ASSET_BUCKET"

[[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || {
    print -u2 "Build-asset manifest is missing or symbolic: $MANIFEST"
    exit 1
}

asset_records() {
    /usr/bin/python3 - "$MANIFEST" <<'PY'
import json
import os
import re
import sys

manifest_path = sys.argv[1]
with open(manifest_path, encoding="utf-8") as source:
    manifest = json.load(source)
if manifest.get("schemaVersion") != 1 or not isinstance(manifest.get("assets"), dict):
    raise SystemExit("Unsupported build-asset manifest")
for name, asset in manifest["assets"].items():
    if not isinstance(asset, dict):
        raise SystemExit(f"Invalid asset declaration: {name}")
    object_name = asset.get("object", "")
    destination = asset.get("destination", "")
    digest = asset.get("sha256", "")
    mode = asset.get("mode", "")
    if (
        not isinstance(name, str)
        or not isinstance(object_name, str)
        or not isinstance(destination, str)
        or not isinstance(digest, str)
        or not isinstance(mode, str)
        or object_name.startswith("/")
        or ".." in object_name.split("/")
        or os.path.isabs(destination)
        or ".." in destination.split("/")
        or not re.fullmatch(r"[0-9a-f]{64}", digest)
        or not re.fullmatch(r"0[0-7]{3}", mode)
    ):
        raise SystemExit(f"Unsafe build-asset declaration: {name}")
    print("\t".join((name, object_name, destination, digest, mode)))
PY
}

sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

is_valid() {
    [[ -f "$1" && ! -L "$1" && "$(sha256 "$1")" == "$2" ]]
}

fetch_from_gcs() {
    local object_name="$1"
    local destination="$2"
    local expected_sha256="$3"
    local mode="$4"
    local temporary="${destination}.downloading.$$"

    [[ -n "$GCS_PREFIX" ]] || return 1
    command -v gcloud >/dev/null 2>&1 || {
        print -u2 "gcloud is required to fetch $object_name from the configured build-asset bucket."
        return 1
    }

    mkdir -p "${destination:h}"
    rm -f "$temporary"
    if ! gcloud storage cp "${GCS_PREFIX%/}/$object_name" "$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    if ! is_valid "$temporary" "$expected_sha256"; then
        print -u2 "GCS build asset $object_name did not match its pinned SHA-256."
        rm -f "$temporary"
        return 1
    fi
    chmod "$mode" "$temporary"
    mv -f "$temporary" "$destination"
    print "Fetched and verified build asset: $object_name"
}

while IFS=$'\t' read -r name object_name relative_destination expected_sha256 mode; do
    destination="$PROJECT_DIRECTORY/$relative_destination"
    if is_valid "$destination" "$expected_sha256"; then
        chmod "$mode" "$destination"
        print "Using verified local build asset: $name"
        continue
    fi

    if fetch_from_gcs "$object_name" "$destination" "$expected_sha256" "$mode"; then
        continue
    fi

    if [[ "$name" == "whisperModel" ]]; then
        print "GCS Whisper asset unavailable; using Lima's verified local/upstream fallback."
        "$SCRIPT_DIRECTORY/assemble_whisper_model.sh"
        is_valid "$destination" "$expected_sha256" || {
            print -u2 "Whisper fallback did not produce the pinned model."
            exit 1
        }
        chmod "$mode" "$destination"
        continue
    fi

    print -u2 "Build asset $name is missing or invalid and could not be restored from GCS."
    exit 1
done < <(asset_records)
