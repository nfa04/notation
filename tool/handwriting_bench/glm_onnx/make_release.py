"""Makes the files the app downloads, into ~/hw-bench/glm_release/ (and the vocabulary into the app's assets):
  vision.onnx, text.onnx   one file each (the weights inside; the graphs of parts/<vision>, parts/<text>)
  embeddings.bin           the word table as int8, one row of 1536 per word, then one float32 scale per row (row value = int8 * scale)
  SHA256SUMS
  python3 make_release.py [VISION_PART] [TEXT_PART]      (default v_nb8_b128 t_nb4_b128)"""
import hashlib, json, os, sys, numpy as np, onnx
root = os.path.expanduser('~/hw-bench/glm_onnx'); out = os.path.expanduser('~/hw-bench/glm_release'); os.makedirs(out, exist_ok=True)
vpart = sys.argv[1] if len(sys.argv) > 1 else 'v_nb8_b128'; tpart = sys.argv[2] if len(sys.argv) > 2 else 't_nb4_b128'
for part, src in (('vision', vpart), ('text', tpart)):
    m = onnx.load(f'{root}/parts/{src}/{part}.onnx')                    # (reads the .data file beside it)
    onnx.save_model(m, f'{out}/{part}.onnx')                            # (and writes everything into one file)
    print(part, os.path.getsize(f'{out}/{part}.onnx') // 2**20, 'MB')
e = np.load(f'{root}/embed.npy').astype(np.float32)
scale = np.abs(e).max(1) / 127 + 1e-12
q = np.round(e / scale[:, None]).astype(np.int8)
with open(f'{out}/embeddings.bin', 'wb') as f:
    f.write(q.tobytes()); f.write(scale.astype('<f4').tobytes())
print('embeddings.bin', os.path.getsize(f'{out}/embeddings.bin') // 2**20, 'MB', e.shape)
# the vocabulary (the spelling of every word, byte-level BPE; the 59246 ordinary tokens): the app decodes the model's ids with it
tok = json.load(open(os.path.expanduser('~/hw-bench/models/glm-ocr/tokenizer.json')))
vocab = tok['model']['vocab']; inv = {i: k for k, i in vocab.items()}
assert len(inv) == 59246 and all(i in inv for i in range(59246))
assets = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'assets', 'glm_ocr')  # (the repository's)
os.makedirs(assets, exist_ok=True)
open(os.path.join(assets, 'vocab.txt'), 'w', encoding='utf-8').write('\n'.join(inv[i] for i in range(59246)) + '\n')
with open(f'{out}/SHA256SUMS', 'w') as f:
    for name in ('vision.onnx', 'text.onnx', 'embeddings.bin'):
        h = hashlib.sha256(open(f'{out}/{name}', 'rb').read()).hexdigest(); f.write(f'{h}  {name}\n'); print(h, name)
