#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
DOWNLOAD_DIRECTORY="$PROJECT_DIRECTORY/Downloads"
HARPER_DIRECTORY="$PROJECT_DIRECTORY/Packaging/Vendor/Harper"
COEDIT_DIRECTORY="$PROJECT_DIRECTORY/Packaging/Vendor/CoEdit"
MODEL_DIRECTORY="$COEDIT_DIRECTORY/model"
QWEN_DIRECTORY="$PROJECT_DIRECTORY/Packaging/Vendor/Qwen"
QWEN_RUNTIME_DIRECTORY="$QWEN_DIRECTORY/runtime"

HARPER_VERSION="v2.8.0"
HARPER_SHA256="b3dfa4f439462f2d4a6cc4ce36e01802d128716f384ff2f2fd9477e96e7eeae0"
MODEL_REVISION="1b76cab579f033f1da0e6c98557beeab5d33dd5b"
MODEL_REPOSITORY="TonyRaju/gec-t5-small-coedit-onnx-int8"
NODE_VERSION="v24.19.0"
NODE_SHA256="8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d"
QWEN_REVISION="90862c4b9d2787eaed51d12237eafdfe7c5f6077"
QWEN_MODEL_SHA256="061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a"
QWEN_LICENSE_SHA256="5de36594c10839788a8c589443a8ef9d8b8d17c65a1b5807206ae037fc36c6bd"
QWEN_README_SHA256="60706b0c6aa38e0d1e73a7b21f98e50cad82ee1eaea636fd1f3a49617bccdb0d"
LLAMA_VERSION="b10218"
LLAMA_SHA256="f3e87f1664c09183a861f16758c55a5adc925672705cd3a47e3dc4444504c914"

mkdir -p "$DOWNLOAD_DIRECTORY" "$HARPER_DIRECTORY" "$MODEL_DIRECTORY" "$QWEN_DIRECTORY"

HARPER_ARCHIVE="$DOWNLOAD_DIRECTORY/harper-cli-aarch64-apple-darwin.tar.gz"
if [[ ! -f "$HARPER_ARCHIVE" ]]; then
  curl -fL --retry 3 \
    "https://github.com/Automattic/harper/releases/download/$HARPER_VERSION/harper-cli-aarch64-apple-darwin.tar.gz" \
    -o "$HARPER_ARCHIVE"
fi
echo "$HARPER_SHA256  $HARPER_ARCHIVE" | shasum -a 256 -c -
tar -xzf "$HARPER_ARCHIVE" -C "$HARPER_DIRECTORY"
chmod 755 "$HARPER_DIRECTORY/harper-cli"
if [[ ! -f "$HARPER_DIRECTORY/LICENSE" ]]; then
  curl -fL --retry 3 \
    "https://raw.githubusercontent.com/Automattic/harper/$HARPER_VERSION/LICENSE" \
    -o "$HARPER_DIRECTORY/LICENSE"
fi

MODEL_FILES=(
  README.md
  config.json
  decoder_model.onnx
  decoder_with_past_model.onnx
  encoder_model.onnx
  generation_config.json
  special_tokens_map.json
  spiece.model
  tokenizer.json
  tokenizer_config.json
)

for MODEL_FILE in "${MODEL_FILES[@]}"; do
  if [[ ! -f "$MODEL_DIRECTORY/$MODEL_FILE" ]]; then
    curl -fL --retry 3 \
      "https://huggingface.co/$MODEL_REPOSITORY/resolve/$MODEL_REVISION/$MODEL_FILE?download=true" \
      -o "$MODEL_DIRECTORY/$MODEL_FILE"
  fi
done

echo "b1affe3d212b97750432487b462f360a56d0bb87199b8c214659fab5b1936b2e  $MODEL_DIRECTORY/decoder_model.onnx" | shasum -a 256 -c -
echo "c7fa63bf198de6c14699e8ad2390f7ef20fba65f518e8dbe5eff78cfca385f82  $MODEL_DIRECTORY/decoder_with_past_model.onnx" | shasum -a 256 -c -
echo "19d8dfa93feda7791e101382d3159d427ca18b0dff1e901133ff0a5c2004569d  $MODEL_DIRECTORY/encoder_model.onnx" | shasum -a 256 -c -
echo "d60acb128cf7b7f2536e8f38a5b18a05535c9e14c7a355904270e15b0945ea86  $MODEL_DIRECTORY/spiece.model" | shasum -a 256 -c -

(
  cd "$MODEL_DIRECTORY"
  shasum -a 256 "${MODEL_FILES[@]}" > SHA256SUMS
)

echo "$MODEL_REVISION" > "$MODEL_DIRECTORY/REVISION"

NODE_ARCHIVE="$DOWNLOAD_DIRECTORY/node-$NODE_VERSION-darwin-arm64.tar.gz"
if [[ ! -f "$NODE_ARCHIVE" ]]; then
  curl -fL --retry 3 \
    "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-darwin-arm64.tar.gz" \
    -o "$NODE_ARCHIVE"
fi
echo "$NODE_SHA256  $NODE_ARCHIVE" | shasum -a 256 -c -
tar -xOf "$NODE_ARCHIVE" "node-$NODE_VERSION-darwin-arm64/bin/node" > "$COEDIT_DIRECTORY/node"
tar -xOf "$NODE_ARCHIVE" "node-$NODE_VERSION-darwin-arm64/LICENSE" > "$COEDIT_DIRECTORY/NODE_LICENSE"
chmod 755 "$COEDIT_DIRECTORY/node"

if [[ ! -d "$COEDIT_DIRECTORY/node_modules/onnxruntime-node/bin/napi-v6/darwin/arm64" ]]; then
  (
    cd "$COEDIT_DIRECTORY"
    npm install --omit=dev --ignore-scripts=false
  )
fi

# onnxruntime-node installs download/proxy helpers and binaries for every OS.
# They are not used after installation, so ship only the audited macOS arm64 runtime.
rm -rf \
  "$COEDIT_DIRECTORY/node_modules/.bin" \
  "$COEDIT_DIRECTORY/node_modules/@emnapi" \
  "$COEDIT_DIRECTORY/node_modules/@img" \
  "$COEDIT_DIRECTORY/node_modules/@protobufjs" \
  "$COEDIT_DIRECTORY/node_modules/@types" \
  "$COEDIT_DIRECTORY/node_modules/adm-zip" \
  "$COEDIT_DIRECTORY/node_modules/boolean" \
  "$COEDIT_DIRECTORY/node_modules/define-data-property" \
  "$COEDIT_DIRECTORY/node_modules/define-properties" \
  "$COEDIT_DIRECTORY/node_modules/detect-node" \
  "$COEDIT_DIRECTORY/node_modules/es-define-property" \
  "$COEDIT_DIRECTORY/node_modules/es-errors" \
  "$COEDIT_DIRECTORY/node_modules/es6-error" \
  "$COEDIT_DIRECTORY/node_modules/escape-string-regexp" \
  "$COEDIT_DIRECTORY/node_modules/global-agent" \
  "$COEDIT_DIRECTORY/node_modules/globalthis" \
  "$COEDIT_DIRECTORY/node_modules/gopd" \
  "$COEDIT_DIRECTORY/node_modules/has-property-descriptors" \
  "$COEDIT_DIRECTORY/node_modules/json-stringify-safe" \
  "$COEDIT_DIRECTORY/node_modules/matcher" \
  "$COEDIT_DIRECTORY/node_modules/object-keys" \
  "$COEDIT_DIRECTORY/node_modules/roarr" \
  "$COEDIT_DIRECTORY/node_modules/semver" \
  "$COEDIT_DIRECTORY/node_modules/semver-compare" \
  "$COEDIT_DIRECTORY/node_modules/serialize-error" \
  "$COEDIT_DIRECTORY/node_modules/sprintf-js" \
  "$COEDIT_DIRECTORY/node_modules/type-fest" \
  "$COEDIT_DIRECTORY/node_modules/onnxruntime-node/bin/napi-v6/linux" \
  "$COEDIT_DIRECTORY/node_modules/onnxruntime-node/bin/napi-v6/win32" \
  "$COEDIT_DIRECTORY/node_modules/onnxruntime-node/script" \
  "$COEDIT_DIRECTORY/node_modules/onnxruntime-node/lib"
find "$COEDIT_DIRECTORY/node_modules/onnxruntime-node/dist" -type f -name '*.map' -delete

test ! -e "$COEDIT_DIRECTORY/node_modules/adm-zip"
test -f "$COEDIT_DIRECTORY/node_modules/onnxruntime-node/bin/napi-v6/darwin/arm64/onnxruntime_binding.node"
COEDIT_SMOKE_RESULT="$(printf 'This are a sentence with bad grammer.' | \
  "$COEDIT_DIRECTORY/node" "$COEDIT_DIRECTORY/runner.mjs" "$MODEL_DIRECTORY" 1)"
[[ "$COEDIT_SMOKE_RESULT" == "This is a sentence with bad grammar." ]]

QWEN_MODEL="$QWEN_DIRECTORY/Qwen3-1.7B-Q8_0.gguf"
if [[ ! -f "$QWEN_MODEL" ]]; then
  curl -fL --retry 3 \
    "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/$QWEN_REVISION/Qwen3-1.7B-Q8_0.gguf?download=true" \
    -o "$QWEN_MODEL"
fi
echo "$QWEN_MODEL_SHA256  $QWEN_MODEL" | shasum -a 256 -c -

if [[ ! -f "$QWEN_DIRECTORY/MODEL_LICENSE" ]]; then
  curl -fL --retry 3 \
    "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/$QWEN_REVISION/LICENSE?download=true" \
    -o "$QWEN_DIRECTORY/MODEL_LICENSE"
fi
if [[ ! -f "$QWEN_DIRECTORY/MODEL_README.md" ]]; then
  curl -fL --retry 3 \
    "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/$QWEN_REVISION/README.md?download=true" \
    -o "$QWEN_DIRECTORY/MODEL_README.md"
fi
echo "$QWEN_LICENSE_SHA256  $QWEN_DIRECTORY/MODEL_LICENSE" | shasum -a 256 -c -
echo "$QWEN_README_SHA256  $QWEN_DIRECTORY/MODEL_README.md" | shasum -a 256 -c -
echo "$QWEN_REVISION" > "$QWEN_DIRECTORY/REVISION"

LLAMA_ARCHIVE="$DOWNLOAD_DIRECTORY/llama-$LLAMA_VERSION-bin-macos-arm64.tar.gz"
if [[ ! -f "$LLAMA_ARCHIVE" ]]; then
  curl -fL --retry 3 \
    "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_VERSION/llama-$LLAMA_VERSION-bin-macos-arm64.tar.gz" \
    -o "$LLAMA_ARCHIVE"
fi
echo "$LLAMA_SHA256  $LLAMA_ARCHIVE" | shasum -a 256 -c -
if [[ ! -x "$QWEN_RUNTIME_DIRECTORY/llama-cli" ]]; then
  TEMP_DIRECTORY="$(mktemp -d)"
  tar -xzf "$LLAMA_ARCHIVE" -C "$TEMP_DIRECTORY"
  ditto "$TEMP_DIRECTORY/llama-$LLAMA_VERSION" "$QWEN_RUNTIME_DIRECTORY"
  rm -rf "$TEMP_DIRECTORY"
fi
chmod 755 "$QWEN_RUNTIME_DIRECTORY/llama-cli"
test -f "$QWEN_RUNTIME_DIRECTORY/LICENSE"

(
  cd "$QWEN_DIRECTORY"
  shasum -a 256 Qwen3-1.7B-Q8_0.gguf MODEL_LICENSE MODEL_README.md > SHA256SUMS
)

echo "Vendor assets downloaded and verified."
