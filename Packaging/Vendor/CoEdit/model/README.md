---
language: en
tags:
- grammar
- grammar-correction
- onnx
- int8
- quantized
- t5
- text2text-generation
- grammatical-error-correction
license: apache-2.0
base_model: Unbabel/gec-t5_small
---

# Unbabel/gec-t5_small — ONNX INT8 Quantized

This is an **ONNX INT8 dynamically quantized** version of [Unbabel/gec-t5_small](https://huggingface.co/Unbabel/gec-t5_small) for grammatical error correction in English.

**This is a derivative work.** All credit for the original model goes to **Unbabel**. This repository only provides a quantized ONNX conversion for easier deployment. We do not claim ownership of the model architecture or weights.

## Original Model

| | |
|---|---|
| **Original Repository** | [Unbabel/gec-t5_small](https://huggingface.co/Unbabel/gec-t5_small) |
| **Original Author** | Unbabel |
| **Architecture** | T5-small (encoder-decoder) |
| **Parameters** | 60.5M |
| **Training Data** | cLang-8 + CoNLL |
| **License** | Apache 2.0 (inherited from original) |

## What’s in this repo?

- `encoder_model.onnx` — Encoder graph (INT8 quantized)
- `decoder_model.onnx` — Decoder graph (INT8 quantized)
- `decoder_with_past_model.onnx` — Decoder with KV-cache (INT8 quantized)
- `config.json`, `generation_config.json` — Model configuration
- `tokenizer.json`, `tokenizer_config.json`, `special_tokens_map.json` — Tokenizer files

## Quantization Details

| Step | Detail |
|---|---|
| Export | PyTorch → ONNX FP32 via HuggingFace Optimum (`ORTModelForSeq2SeqLM`) |
| Quantization | `onnxruntime.quantization.quantize_dynamic` with `QuantType.QInt8` |
| Validation | Verified ONNX FP32 output matches PyTorch FP32 exactly (0 delta) before quantizing |

## Benchmark Results — This Model

Benchmarked on a 50-sentence English grammar correction test set (2-thread CPU, Google Colab).

### Quality

| Format | BLEU | chrF++ | Exact Match | Δ BLEU | Δ chrF++ |
|---|---|---|---|---|---|
| PyTorch FP32 (baseline) | 77.42 | 86.84 | 60% | — | — |
| **ONNX INT8 (this repo)** | **77.60** | **86.69** | **60%** | **+0.18** | **-0.15** |

### Speed & Size

| Metric | PyTorch FP32 | ONNX INT8 (this repo) |
|---|---|---|
| P50 Latency | 226 ms | **117 ms** |
| P95 Latency | 282 ms | **203 ms** |
| Disk Size | 231 MB | **152 MB** |
| Throughput | — | 53.42 sentences/sec |

### Quantization Stability

| Metric | Value |
|---|---|
| Sentences with changed output (INT8 vs FP32) | 1/50 sentences changed |
| Deployment Scorecard Verdict | **GO** |

**Recommended model.** Best quality-to-size ratio. Rock-solid INT8 stability with only 1 sentence regression. Based on the paper 'A Simple Recipe for Multilingual Grammatical Error Correction'.

---

## Cross-Model Comparison (7 Models Benchmarked)

This model was benchmarked alongside 6 other grammar correction models. All models were evaluated on the same 50-sentence test set under identical conditions.

### PyTorch FP32 Baseline (all models)

| Model | Params | BLEU | chrF++ | P50 (ms) | Size (MB) | Exact Match |
|---|---|---|---|---|---|---|
| prithivida | 222.9M | 76.88 | 86.40 | 602 | 850 | 58% |
| **coedit-small** **←** | 60.5M | **77.42** | **86.84** | **226** | **231** | **60%** |
| vennify-t5-base | 222.9M | 78.57 | 87.87 | 539 | 850 | 58% |
| aventiq-t5-small | 60.5M | 34.43 | 45.88 | 213 | 231 | 16% |
| visheratin-mini | 31.2M | 66.84 | 81.77 | 133 | 119 | 46% |
| visheratin-tiny | 15.6M | 66.08 | 82.69 | 85 | 59 | 48% |
| pszemraj-small | 77.0M | 57.11 | 77.13 | 363 | 294 | 28% |


### ONNX INT8 Quantized (all models)

| Model | Params | BLEU (FP32) | BLEU (INT8) | chrF++ (INT8) | P50 (ms) | Disk (MB) | Exact Match | Scorecard |
|---|---|---|---|---|---|---|---|---|
| prithivida | 222.9M | 76.88 | 74.44 | 84.79 | 222 | 426 | 54% | NO-GO |
| **coedit-small** **← this model** | 60.5M | 77.42 | **77.60** | **86.69** | **117** | **152** | **60%** | GO |
| vennify-t5-base | 222.9M | 78.57 | 77.24 | 86.74 | 224 | 426 | 56% | GO |
| aventiq-t5-small | 60.5M | 34.43 | 40.66 | 51.95 | 120 | 152 | 22% | GO* |
| visheratin-mini | 31.2M | 66.84 | 66.65 | 82.67 | 78 | 93 | 46% | GO |
| visheratin-tiny | 15.6M | 66.08 | 64.51 | 82.28 | 60 | 55 | 44% | GO |
| pszemraj-small | 77.0M | 57.11 | 3.15 | 18.72 | 138 | 153 | 0% | NO-GO |


### Statistical Significance (Bootstrap, 1000 resamples)

Key cross-model comparisons (INT8 variants):

| Model A | Model B | chrF++ A | chrF++ B | p-value | Significant? |
|---|---|---|---|---|---|
| coedit-small | vennify-t5-base | 86.69 | 86.74 | 1.000 | No (identical) |
| coedit-small | visheratin-mini | 86.69 | 82.67 | 0.038 | **Yes** |
| coedit-small | visheratin-tiny | 86.69 | 82.28 | 0.010 | **Yes** |
| coedit-small | prithivida | 86.69 | 84.79 | 0.324 | No |
| visheratin-mini | visheratin-tiny | 82.67 | 82.28 | 0.824 | No (identical) |
| prithivida | vennify-t5-base | 84.79 | 86.74 | 0.324 | No |


### Recommendation

| Use Case | Recommended Model | Why |
|---|---|---|
| **Best overall (desktop)** | **coedit-small INT8** (152 MB) | Highest INT8 quality (chrF++ 86.69), 117ms latency, only 1 regression |
| **Smallest (mobile/edge)** | **visheratin-tiny INT8** (55 MB) | 60ms latency, 55 MB disk, acceptable quality (chrF++ 82.28) |
| **Highest baseline quality** | vennify-t5-base INT8 (426 MB) | chrF++ 86.74, but 3x larger than coedit-small for no significant quality gain |

---

## Usage

```python
from optimum.onnxruntime import ORTModelForSeq2SeqLM
from transformers import AutoTokenizer

model_id = "YOUR_USERNAME/gec-t5-small-coedit-onnx-int8"
tokenizer = AutoTokenizer.from_pretrained(model_id)
model = ORTModelForSeq2SeqLM.from_pretrained(model_id)

text = "gec: She go to school yesterday"
inputs = tokenizer([text], return_tensors="pt", max_length=128, truncation=True)
outputs = model.generate(**inputs, max_new_tokens=128, num_beams=1, repetition_penalty=1.3)
corrected = tokenizer.decode(outputs[0], skip_special_tokens=True)
print(corrected)
```

**Input prefix:** `gec: `

## Acknowledgments

All credit for the original model goes to **Unbabel**. This repository only provides an ONNX INT8 quantized conversion to make the model easier to deploy in production environments (mobile, edge, browser).

Quantization and benchmarking performed as part of the **Smart Desktop Keyboard Grammar Engine** project.

## Citation

If you use this model, please cite the original authors:
```
@misc{coedit_small_onnx_int8,
  title = {Unbabel/gec-t5_small — ONNX INT8 Quantized},
  note = {Quantized version of Unbabel/gec-t5_small},
  url = {https://huggingface.co/Unbabel/gec-t5_small},
}
```
