"""Reads the probe's lines with the app's GLM-OCR text model, from vision features computed elsewhere (the CoreML probe on a Mac saves
NN.cpu and NN.coreml, float32 [tokens, 1536]), so that two runtimes' features can be compared by the text they give.

  python read_lines.py check LINES_DIR PROCESSOR_DIR                      # the probe's patches = the processor's pixel_values?
  python read_lines.py read LINES_DIR PROCESSOR_DIR MODEL_DIR FEATURES_DIR SUFFIX [SUFFIX ...]

MODEL_DIR is the app's glm_ocr folder (text.onnx, embeddings.bin); PROCESSOR_DIR the original model's files (zai-org/GLM-OCR) for
the chat template and tokenizer. Greedy decoding, as tool/handwriting_bench/glm_onnx/run_glm_onnx.py and the app do.
"""
import os
import sys

import numpy as np
import onnxruntime as ort
from PIL import Image
from transformers import AutoProcessor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'handwriting_bench', 'glm_onnx'))
from glm_parts import text_position_ids  # noqa: E402
from probe_glm_vision import patches  # noqa: E402

IMG, EOS, LAYERS, HIDDEN = 59280, {59246, 59253}, 16, 1536


def prompt(proc, png):
    msgs = [{'role': 'user', 'content': [{'type': 'image', 'image': Image.open(png).convert('RGB')}, {'type': 'text', 'text': 'Text Recognition:'}]}]
    return proc.apply_chat_template(msgs, add_generation_prompt=True, tokenize=True, return_dict=True, return_tensors='pt')


def grey(png):
    return np.asarray(Image.open(png).convert('L'), dtype=np.float32)


def check(lines, proc_dir):
    proc = AutoProcessor.from_pretrained(proc_dir)
    for f in sorted(x for x in os.listdir(lines) if x.endswith('.png')):
        inp = prompt(proc, os.path.join(lines, f))
        g = inp['image_grid_thw'][0].numpy()
        img = grey(os.path.join(lines, f))
        mine = patches(img, img.shape[0] // 14, img.shape[1] // 14)
        theirs = inp['pixel_values'].numpy()
        same = mine.shape == theirs.shape
        print(f, 'grid', g.tolist(), 'shape', mine.shape, theirs.shape, 'largest difference', float(np.abs(mine - theirs).max()) if same else 'n/a')


def read(lines, proc_dir, model_dir, feats_dir, suffixes):
    proc = AutoProcessor.from_pretrained(proc_dir)
    text = ort.InferenceSession(os.path.join(model_dir, 'text.onnx'), providers=['CPUExecutionProvider'])
    raw = np.fromfile(os.path.join(model_dir, 'embeddings.bin'), dtype=np.uint8)
    rows = (raw.size) // (HIDDEN + 4)
    q = raw[:rows * HIDDEN].view(np.int8).reshape(rows, HIDDEN)
    scale = raw[rows * HIDDEN:].view('<f4')
    embed = lambda i: q[i].astype(np.float32) * (scale[i][..., None] if np.ndim(i) else scale[i])  # noqa: E731
    names = [f'past_key_values.{i}.{kv}' for i in range(LAYERS) for kv in ('key', 'value')]
    truth = dict(line.rstrip('\n').split('\t', 1) for line in open(os.path.join(lines, 'truth.tsv'), encoding='utf-8'))

    def decode(png, feats):
        inp = prompt(proc, png)
        ids = inp['input_ids'][0].numpy()
        g = inp['image_grid_thw'][0].numpy()
        emb = embed(ids).astype(np.float32)
        emb[ids == IMG] = feats
        pos = text_position_ids((ids == IMG).astype(int), int(g[1]), int(g[2]))
        past = {n: np.zeros((1, 8, 1, 128), np.float32) for n in names}
        mask = np.zeros((1, 1), np.int64)

        def step(e, p):
            nonlocal past, mask
            mask = np.concatenate([mask, np.ones((1, e.shape[1]), np.int64)], 1)
            o = text.run(None, {'inputs_embeds': e, 'position_ids': p[:, None, :], 'attention_mask': mask[:, :-e.shape[1]], **past})
            past = {n: o[1 + k] for k, n in enumerate(names)}
            return o[0]

        logits = step(emb[None], pos)
        nxt, res = int(pos.max()) + 1, []
        for _ in range(60):
            best = int(logits[0, -1].argmax())
            if best in EOS:
                break
            res.append(best)
            logits = step(embed(best).astype(np.float32)[None, None], np.full((3, 1), nxt, np.int64))
            nxt += 1
        return proc.tokenizer.decode(res).strip()

    def cer(a, b):
        d = list(range(len(b) + 1))
        for i, ca in enumerate(a, 1):
            prev, d[0] = d[0], i
            for j, cb in enumerate(b, 1):
                prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (ca != cb))
        return d[len(b)] / max(1, len(b))

    totals = {s: [0.0, 0] for s in suffixes}
    same = 0
    for f in sorted(truth):
        stem = f[:-4]
        got = {}
        for s in suffixes:
            path = os.path.join(feats_dir, f'{stem}.{s}')
            if not os.path.exists(path):
                continue
            got[s] = decode(os.path.join(lines, f), np.fromfile(path, dtype=np.float32).reshape(-1, HIDDEN))
            totals[s][0] += cer(got[s], truth[f])
            totals[s][1] += 1
        if len(set(got.values())) == 1 and len(got) == len(suffixes):
            same += 1
        print(f, '|', truth[f], '|', ' | '.join(f'{s}: {t}' for s, t in got.items()), flush=True)
    for s, (c, n) in totals.items():
        print(f'{s}: {n} lines, character error {100 * c / max(1, n):.1f} %')
    print(f'the same text from every runtime on {same} of {len(truth)} lines')


if __name__ == '__main__':
    if sys.argv[1] == 'check':
        check(*sys.argv[2:4])
    else:
        read(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6:])
