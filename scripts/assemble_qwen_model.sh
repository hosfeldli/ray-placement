#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
QWEN_DIRECTORY="$PROJECT_DIRECTORY/Packaging/Vendor/Qwen"
PARTS_DIRECTORY="$QWEN_DIRECTORY/ModelParts"
MODEL="$QWEN_DIRECTORY/Qwen3-1.7B-Q8_0.gguf"
EXPECTED_SHA256="061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a"

if [[ -f "$MODEL" ]] && [[ "$(shasum -a 256 "$MODEL" | awk '{print $1}')" == "$EXPECTED_SHA256" ]]; then
    exit 0
fi

PARTS=("$PARTS_DIRECTORY"/Qwen3-1.7B-Q8_0.gguf.part-*(N))
if (( ${#PARTS[@]} != 6 )); then
    echo "The bundled Qwen model chunks are incomplete. Install Git LFS and run: git lfs pull"
    exit 1
fi

(
    cd "$PARTS_DIRECTORY"
    shasum -a 256 -c SHA256SUMS
)

TEMP_MODEL="$QWEN_DIRECTORY/.Qwen3-1.7B-Q8_0.gguf.assembling.$$"
cleanup_partial_model() {
    rm -f "$TEMP_MODEL"
}
trap cleanup_partial_model EXIT INT TERM
: > "$TEMP_MODEL"
for PART in "${PARTS[@]}"; do
    /bin/cat "$PART" >> "$TEMP_MODEL"
done

ACTUAL_SHA256="$(shasum -a 256 "$TEMP_MODEL" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "The reconstructed Qwen model failed its SHA-256 check."
    exit 1
fi
mv "$TEMP_MODEL" "$MODEL"
trap - EXIT INT TERM
echo "Reconstructed and verified the bundled Qwen model."
