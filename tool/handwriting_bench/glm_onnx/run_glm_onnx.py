"""Reads lines with the exported GLM-OCR graphs (vision.onnx, text.onnx, embed.npy in one folder), greedy, like the app would.
  python3 run_glm_onnx.py OUT_DIR PICTURE_DIR NAME [--dir fp32] [--limit N] [--check-ref]
The HF processor still does the picture preparation here (the app will have to do it itself)."""
import json, os, sys, time, numpy as np, onnxruntime as ort
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from glm_parts import vision_pos_ids, text_position_ids
from PIL import Image
from transformers import AutoProcessor

out, pics, name = sys.argv[1:4]
arg = lambda k, d=None: sys.argv[sys.argv.index(k) + 1] if k in sys.argv else d
folder = arg('--dir', 'fp32'); embed_mode = arg('--embed', 'fp32'); limit = int(arg('--limit', 0)) or None
root = os.path.expanduser('~/hw-bench/glm_onnx')
proc = AutoProcessor.from_pretrained(os.path.expanduser('~/hw-bench/models/glm-ocr'))
opt = ort.SessionOptions(); opt.intra_op_num_threads = int(arg('--threads', 4))
vision = ort.InferenceSession(os.path.join(root, folder, 'vision.onnx'), opt, providers=['CPUExecutionProvider'])
text = ort.InferenceSession(os.path.join(root, folder, 'text.onnx'), opt, providers=['CPUExecutionProvider'])
embed = np.load(f'{root}/embed.npy', mmap_mode='r')
if embed_mode == 'bin':                                                                   # the release file: int8 rows, then a float32 scale per row
    _raw = np.fromfile(os.path.join(root, folder, 'embeddings.bin'), dtype=np.uint8); _n = 59392
    _q = _raw[:_n * 1536].view(np.int8).reshape(_n, 1536); _sc = _raw[_n * 1536:].view('<f4')
    embed = type('Q', (), {'__getitem__': lambda self, i: _q[i].astype(np.float32) * (_sc[i][..., None] if np.ndim(i) else _sc[i])})()
elif embed_mode == 'fp16': embed = np.asarray(embed).astype(np.float16)                 # (rows are widened again when read)
elif embed_mode == 'int8row':                                                             # one scale per row (word)
    _e = np.asarray(embed); _s = np.abs(_e).max(1, keepdims=True) / 127 + 1e-12
    embed = type('Q', (), {'q': np.round(_e / _s).astype(np.int8), 's': _s.astype(np.float32), '__getitem__': lambda self, i: self.q[i].astype(np.float32) * self.s[i]})()
import time as _t
TIMES = {'vision': [], 'prefill': [], 'decode': [], 'tokens': 0}
IMG, EOS, LAYERS = 59280, {59246, 59253}, 16
names = [f'past_key_values.{i}.{kv}' for i in range(LAYERS) for kv in ('key', 'value')]

def read(png, max_tokens=80):
    msgs = [{'role': 'user', 'content': [{'type': 'image', 'image': Image.open(png).convert('RGB')}, {'type': 'text', 'text': 'Text Recognition:'}]}]
    inp = proc.apply_chat_template(msgs, add_generation_prompt=True, tokenize=True, return_dict=True, return_tensors='pt')
    ids = inp['input_ids'][0].numpy(); g = inp['image_grid_thw'][0].numpy()
    _t0 = _t.perf_counter()
    feats = vision.run(None, {'pixel_values': inp['pixel_values'].numpy(), 'pos_ids': vision_pos_ids(int(g[1]), int(g[2]))})[0]
    TIMES['vision'].append(_t.perf_counter() - _t0)
    emb = np.asarray(embed[ids]).astype(np.float32)
    emb[ids == IMG] = feats
    pos = text_position_ids((ids == IMG).astype(int), int(g[1]), int(g[2]))
    past = {n: np.zeros((1, 8, 1, 128), np.float32) for n in names}
    mask = np.zeros((1, 1), np.int64)
    def step(e, p):
        nonlocal past, mask
        mask = np.concatenate([mask, np.ones((1, e.shape[1]), np.int64)], 1)
        # (the mask of the cache so far, i.e. before these tokens: all but the last len(e) entries)
        o = text.run(None, {'inputs_embeds': e, 'position_ids': p[:, None, :], 'attention_mask': mask[:, :-e.shape[1]], **past})
        past = {n: o[1 + k] for k, n in enumerate(names)}
        return o[0]
    _t0 = _t.perf_counter(); logits = step(emb[None], pos); TIMES['prefill'].append(_t.perf_counter() - _t0)
    _t0 = _t.perf_counter()
    nxt = int(pos.max()) + 1; res = []
    for _ in range(max_tokens):
        best = int(logits[0, -1].argmax())
        if best in EOS: break
        res.append(best)
        logits = step(np.asarray(embed[best]).astype(np.float32)[None, None], np.full((3, 1), nxt, np.int64)); nxt += 1
    TIMES['decode'].append(_t.perf_counter() - _t0); TIMES['tokens'] += len(res) + 1
    return res, pos, ids

if '--check-ref' in sys.argv:
    import glob
    for f in sorted(glob.glob(f'{root}/ref/*.npz')):
        d = np.load(f); i = os.path.basename(f)[:-4]
        t = time.time(); res, pos, ids = read(f'{out}/{pics}/{i}.png')
        print(i, 'positions equal:', bool((pos == d['pos'][1:, 0, :]).all()), '| tokens equal:', res == d['generated'].tolist()[:len(res)] and len(res) == len(d['generated']) - 1,
              '|', proc.tokenizer.decode(res), '|', round(time.time() - t, 1), 's')
    sys.exit()
ids_ = list(json.load(open(f'{out}/truth.json')))[:limit]
resu = {}; t0 = time.time()
for i in ids_:
    r, _, _ = read(f'{out}/{pics}/{i}.png'); resu[i] = proc.tokenizer.decode(r).strip(); print(i, '|', resu[i], flush=True)
os.makedirs(f'{out}/results', exist_ok=True)
json.dump(resu, open(f'{out}/results/{name}.json', 'w'), ensure_ascii=False, indent=0)
import resource
n = len(resu)
print(f"{n} lines, vision {1000*sum(TIMES['vision'])/n:.0f} ms, prefill {1000*sum(TIMES['prefill'])/n:.0f} ms, decode {1000*sum(TIMES['decode'])/TIMES['tokens']:.0f} ms/token ({TIMES['tokens']/n:.1f} tokens/line), "
      f"total {sum(TIMES['vision'])/n + sum(TIMES['prefill'])/n + sum(TIMES['decode'])/n:.2f} s/line, peak RSS {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024} MB")
