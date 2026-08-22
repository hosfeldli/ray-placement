import process from 'node:process';
import path from 'node:path';
import fs from 'node:fs';
import { Tokenizer } from '@huggingface/tokenizers';
import * as ort from 'onnxruntime-node';

const modelArgument = process.argv[2];
if (!modelArgument) {
  process.stderr.write('The bundled model directory was not provided.\n');
  process.exit(2);
}
const modelDirectory = path.resolve(modelArgument);
const requestedThreads = Number.parseInt(process.argv[3] ?? '1', 10);
const threadLimit = Number.isFinite(requestedThreads)
  ? Math.min(4, Math.max(1, requestedThreads))
  : 1;
const sessionOptions = {
  executionMode: 'sequential',
  interOpNumThreads: 1,
  intraOpNumThreads: threadLimit,
};

const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const source = Buffer.concat(chunks).toString('utf8').trim();
if (!source) {
  process.stderr.write('No writing was provided.\n');
  process.exit(2);
}

try {
  const tokenizerJSON = JSON.parse(fs.readFileSync(`${modelDirectory}/tokenizer.json`, 'utf8'));
  const tokenizerConfig = JSON.parse(fs.readFileSync(`${modelDirectory}/tokenizer_config.json`, 'utf8'));
  const tokenizer = new Tokenizer(tokenizerJSON, tokenizerConfig);
  const encoded = tokenizer.encode(`gec: ${source}`);

  const encoder = await ort.InferenceSession.create(`${modelDirectory}/encoder_model.onnx`, sessionOptions);
  const decoder = await ort.InferenceSession.create(`${modelDirectory}/decoder_model.onnx`, sessionOptions);
  const decoderWithPast = await ort.InferenceSession.create(`${modelDirectory}/decoder_with_past_model.onnx`, sessionOptions);
  const inputIds = asOrtInt64(encoded.ids);
  const attentionMask = asOrtInt64(encoded.attention_mask);
  const encoderOutput = await encoder.run({ input_ids: inputIds, attention_mask: attentionMask });
  const encoderHiddenStates = encoderOutput.last_hidden_state;

  const tokens = [];
  let nextToken = 0; // T5 decoder_start_token_id / pad_token_id
  let decoderPast = null;
  let encoderPast = null;
  for (let step = 0; step < 256; step += 1) {
    const decoderInput = new ort.Tensor('int64', BigInt64Array.of(BigInt(nextToken)), [1, 1]);
    let output;
    if (decoderPast === null) {
      output = await decoder.run({
        input_ids: decoderInput,
        encoder_attention_mask: attentionMask,
        encoder_hidden_states: encoderHiddenStates,
      });
      decoderPast = collectPast(output, 'decoder');
      encoderPast = collectPast(output, 'encoder');
    } else {
      const feeds = {
        input_ids: decoderInput,
        encoder_attention_mask: attentionMask,
        encoder_hidden_states: encoderHiddenStates,
      };
      for (let layer = 0; layer < 6; layer += 1) {
        feeds[`past_key_values.${layer}.decoder.key`] = decoderPast[layer].key;
        feeds[`past_key_values.${layer}.decoder.value`] = decoderPast[layer].value;
        feeds[`past_key_values.${layer}.encoder.key`] = encoderPast[layer].key;
        feeds[`past_key_values.${layer}.encoder.value`] = encoderPast[layer].value;
      }
      output = await decoderWithPast.run(feeds);
      decoderPast = collectPast(output, 'decoder');
    }

    nextToken = argmaxLastToken(output.logits);
    if (nextToken === 1) break; // T5 eos_token_id
    tokens.push(nextToken);
  }

  const corrected = tokenizer.decode(tokens, { skip_special_tokens: true })?.trim();
  if (!corrected) throw new Error('The model returned no corrected text.');
  process.stdout.write(corrected);
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
}

function asOrtInt64(values) {
  return new ort.Tensor('int64', BigInt64Array.from(values, (value) => BigInt(value)), [1, values.length]);
}

function collectPast(output, section) {
  return Array.from({ length: 6 }, (_, layer) => ({
    key: output[`present.${layer}.${section}.key`],
    value: output[`present.${layer}.${section}.value`],
  }));
}

function argmaxLastToken(logits) {
  const vocabularySize = logits.dims[logits.dims.length - 1];
  const start = logits.data.length - vocabularySize;
  let bestIndex = 0;
  let bestValue = -Infinity;
  for (let index = 0; index < vocabularySize; index += 1) {
    const value = logits.data[start + index];
    if (value > bestValue) {
      bestValue = value;
      bestIndex = index;
    }
  }
  return bestIndex;
}
