# RayPlacement CoEdit runtime notices

This self-contained local runtime includes:

- Node.js v24.19.0 (Krypton LTS). Node's complete license and bundled third-party notices are in `NODE_LICENSE`.
- Microsoft ONNX Runtime Node v1.24.3 under the MIT License (`ONNXRUNTIME_LICENSE`). Only the macOS arm64 runtime files are shipped.
- Hugging Face Tokenizers.js v0.1.3 under Apache License 2.0 (`node_modules/@huggingface/tokenizers/LICENSE`).
- `TonyRaju/gec-t5-small-coedit-onnx-int8` at revision `1b76cab579f033f1da0e6c98557beeab5d33dd5b`, published under Apache License 2.0. The repository identifies it as an INT8 ONNX conversion of `Unbabel/gec-t5_small`; its model card is in `model/README.md` and its file hashes are in `model/SHA256SUMS`.

The published repository name contains “coedit,” but this model is not an official checkpoint from the authors of the CoEdIT paper. RayPlacement preserves that provenance in its Settings UI and documentation.
