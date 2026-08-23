#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
QWEN_DIRECTORY="$PROJECT_DIRECTORY/Packaging/Vendor/Qwen"
PARTS_DIRECTORY="$QWEN_DIRECTORY/ModelParts"
MODEL="$QWEN_DIRECTORY/Qwen3-1.7B-Q8_0.gguf"
RUNTIME_DIRECTORY="$QWEN_DIRECTORY/runtime"

EXPECTED_MODEL_SHA256="061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a"
EXPECTED_LLAMA_ARCHIVE_SHA256="f3e87f1664c09183a861f16758c55a5adc925672705cd3a47e3dc4444504c914"
EXPECTED_LLAMA_CLI_SHA256="1895313a209f70c745ccd8d1946c2c81c84e87ac50564ddb3dd4adb376dd7a52"
QWEN_REVISION="90862c4b9d2787eaed51d12237eafdfe7c5f6077"
LLAMA_VERSION="b10218"
DEFAULT_MODEL_URL="https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/$QWEN_REVISION/Qwen3-1.7B-Q8_0.gguf?download=true"
DEFAULT_LLAMA_ARCHIVE_URL="https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_VERSION/llama-$LLAMA_VERSION-bin-macos-arm64.tar.gz"
MODEL_URL="${RAYPLACEMENT_QWEN_MODEL_URL:-$DEFAULT_MODEL_URL}"
LLAMA_ARCHIVE_URL="${RAYPLACEMENT_LLAMA_ARCHIVE_URL:-$DEFAULT_LLAMA_ARCHIVE_URL}"

PREBUILT_QWEN="$PROJECT_DIRECTORY/build/RayPlacement.app/Contents/Resources/Qwen"
INSTALLED_QWEN="${HOME:?The current user home folder is unavailable}/Applications/RayPlacement.app/Contents/Resources/Qwen"
LOCAL_LLAMA_ARCHIVE="$PROJECT_DIRECTORY/Downloads/llama-$LLAMA_VERSION-bin-macos-arm64.tar.gz"
TEMP_MODEL="$QWEN_DIRECTORY/.Qwen3-1.7B-Q8_0.gguf.assembling.$$"
TEMP_RUNTIME="$QWEN_DIRECTORY/.runtime.assembling.$$"
TEMP_EXTRACT="$QWEN_DIRECTORY/.runtime.extracting.$$"
TEMP_LLAMA_ARCHIVE="$QWEN_DIRECTORY/.llama-$LLAMA_VERSION.downloading.$$"

cleanup_temporary_assets() {
    rm -f "$TEMP_MODEL" "$TEMP_LLAMA_ARCHIVE"
    rm -rf "$TEMP_RUNTIME" "$TEMP_EXTRACT"
}
trap cleanup_temporary_assets EXIT INT TERM

sha256_matches() {
    local candidate="$1"
    local expected="$2"
    [[ -f "$candidate" ]] || return 1
    [[ "$(shasum -a 256 "$candidate" | awk '{print $1}')" == "$expected" ]]
}

model_is_valid() {
    sha256_matches "$1" "$EXPECTED_MODEL_SHA256"
}

runtime_is_valid() {
    local candidate="$1"
    local executable="$candidate/llama-cli"
    sha256_matches "$executable" "$EXPECTED_LLAMA_CLI_SHA256" || return 1
    file "$executable" | grep -q "Mach-O 64-bit executable arm64" || return 1
    DYLD_LIBRARY_PATH="$candidate" "$executable" --version >/dev/null 2>&1
}

install_verified_model() {
    local candidate="$1"
    cp "$candidate" "$TEMP_MODEL"
    model_is_valid "$TEMP_MODEL" || return 1
    mv -f "$TEMP_MODEL" "$MODEL"
}

install_verified_runtime() {
    local candidate="$1"
    rm -rf "$TEMP_RUNTIME"
    ditto "$candidate" "$TEMP_RUNTIME"
    runtime_is_valid "$TEMP_RUNTIME" || return 1
    rm -rf "$RUNTIME_DIRECTORY"
    mv "$TEMP_RUNTIME" "$RUNTIME_DIRECTORY"
}

parts_are_valid() {
    local parts=("$PARTS_DIRECTORY"/Qwen3-1.7B-Q8_0.gguf.part-*(N))
    (( ${#parts[@]} == 6 )) || return 1
    [[ -f "$PARTS_DIRECTORY/SHA256SUMS" ]] || return 1
    (cd "$PARTS_DIRECTORY" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1)
}

try_git_lfs_recovery() {
    command -v git >/dev/null 2>&1 || return 1
    git -C "$PROJECT_DIRECTORY" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    git -C "$PROJECT_DIRECTORY" lfs version >/dev/null 2>&1 || return 1
    echo "Qwen assets are incomplete. Retrying the repository's Git LFS objects…"
    git -C "$PROJECT_DIRECTORY" lfs pull \
        --include="Packaging/Vendor/Qwen/ModelParts/*,Packaging/Vendor/Qwen/Qwen3-1.7B-Q8_0.gguf,Packaging/Vendor/Qwen/runtime/*" \
        >/dev/null 2>&1 || return 1
}

prepare_model() {
    model_is_valid "$MODEL" && return 0

    local candidate
    for candidate in "$PREBUILT_QWEN/Qwen3-1.7B-Q8_0.gguf" "$INSTALLED_QWEN/Qwen3-1.7B-Q8_0.gguf"; do
        if model_is_valid "$candidate"; then
            echo "Restoring Qwen from a verified local RayPlacement copy…"
            install_verified_model "$candidate"
            return 0
        fi
    done

    if ! parts_are_valid; then
        try_git_lfs_recovery || true
    fi

    if parts_are_valid; then
        local parts=("$PARTS_DIRECTORY"/Qwen3-1.7B-Q8_0.gguf.part-*(N))
        : > "$TEMP_MODEL"
        local part
        for part in "${parts[@]}"; do
            /bin/cat "$part" >> "$TEMP_MODEL"
        done
        if model_is_valid "$TEMP_MODEL"; then
            mv -f "$TEMP_MODEL" "$MODEL"
            echo "Reconstructed and verified the bundled Qwen model."
            return 0
        fi
        rm -f "$TEMP_MODEL"
        echo "The Qwen chunks were valid individually but did not reconstruct the pinned model."
    fi

    echo "Downloading the pinned Qwen3 1.7B model from the official Qwen repository (about 1.8 GB)…"
    if ! curl --fail --location --retry 3 --retry-all-errors --progress-bar "$MODEL_URL" --output "$TEMP_MODEL"; then
        echo "Qwen could not be downloaded. Check the network connection and run the installer again."
        return 1
    fi
    if ! model_is_valid "$TEMP_MODEL"; then
        local actual_sha256
        actual_sha256="$(shasum -a 256 "$TEMP_MODEL" | awk '{print $1}')"
        echo "The downloaded Qwen model did not match the pinned SHA-256."
        echo "Expected: $EXPECTED_MODEL_SHA256"
        echo "Received: $actual_sha256"
        return 1
    fi
    mv -f "$TEMP_MODEL" "$MODEL"
    echo "Downloaded and verified the pinned Qwen model."
}

prepare_runtime() {
    runtime_is_valid "$RUNTIME_DIRECTORY" && return 0

    local candidate
    for candidate in "$PREBUILT_QWEN/runtime" "$INSTALLED_QWEN/runtime"; do
        if runtime_is_valid "$candidate"; then
            echo "Restoring the Qwen runtime from a verified local RayPlacement copy…"
            install_verified_runtime "$candidate"
            return 0
        fi
    done

    try_git_lfs_recovery || true
    runtime_is_valid "$RUNTIME_DIRECTORY" && return 0

    local archive="$LOCAL_LLAMA_ARCHIVE"
    if ! sha256_matches "$archive" "$EXPECTED_LLAMA_ARCHIVE_SHA256"; then
        echo "Downloading the pinned Qwen runtime from the official llama.cpp release…"
        if ! curl --fail --location --retry 3 --retry-all-errors --progress-bar "$LLAMA_ARCHIVE_URL" --output "$TEMP_LLAMA_ARCHIVE"; then
            echo "The Qwen runtime could not be downloaded. Check the network connection and run the installer again."
            return 1
        fi
        if ! sha256_matches "$TEMP_LLAMA_ARCHIVE" "$EXPECTED_LLAMA_ARCHIVE_SHA256"; then
            local actual_sha256
            actual_sha256="$(shasum -a 256 "$TEMP_LLAMA_ARCHIVE" | awk '{print $1}')"
            echo "The downloaded Qwen runtime did not match the pinned SHA-256."
            echo "Expected: $EXPECTED_LLAMA_ARCHIVE_SHA256"
            echo "Received: $actual_sha256"
            return 1
        fi
        archive="$TEMP_LLAMA_ARCHIVE"
    fi

    rm -rf "$TEMP_EXTRACT"
    mkdir -p "$TEMP_EXTRACT"
    tar -xzf "$archive" -C "$TEMP_EXTRACT"
    install_verified_runtime "$TEMP_EXTRACT/llama-$LLAMA_VERSION"
    echo "Installed and verified the pinned Qwen runtime."
}

mkdir -p "$QWEN_DIRECTORY"
prepare_model
prepare_runtime
trap - EXIT INT TERM
cleanup_temporary_assets
