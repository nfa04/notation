"""Reads the lines exported by export_lines_test.dart with the PaddleOCR-VL ONNX files the app downloads, the way the app does
(lib/ink/onnx_paddle_vl.dart): the 112-pixel-high picture of the whole line, `OCR:` prompt, greedy decoding, plain running positions.
  python3 -P run_paddle_onnx.py OUT_DIR MODEL_DIR [name] [--pics DIR --height H]   ->  OUT_DIR/results/<name>.json   (name: paddle_app)
With --pics the pictures of DIR (made by render.py) are scaled to H pixels high and padded to a multiple of 28 wide.
MODEL_DIR holds onnx/vision_encoder_q4.onnx, onnx/decoder_q4.onnx, onnx/embedding.onnx.data, tokenizer.json."""
import json, os, re, sys, time
import numpy as np, onnxruntime as ort
from PIL import Image

out, mdir = sys.argv[1], sys.argv[2]
name = sys.argv[3] if len(sys.argv) > 3 else 'paddle_app'
HIDDEN, PATCH, LAYERS, KV_HEADS, HEAD_DIM = 1024, 14, 18, 2, 128
BEFORE = [100273, 2969, 93963, 93919, 101305]; IMG = 100295
AFTER = [101306, 93972, 2497, 93963, 23, 92267, 93963, 23]; END = 2

tok = json.load(open(f'{mdir}/tokenizer.json'))
pieces = {}
for k, v in tok['model']['vocab'].items(): pieces[v] = k
special = set()
for a in tok['added_tokens']:
    pieces[a['id']] = a['content']
    if a.get('special'): special.add(a['id'])
def decode(ids):
    b = bytearray()
    for i in ids:
        if i in special or i not in pieces: continue
        m = re.fullmatch(r'<0x([0-9A-Fa-f]{2})>', pieces[i])
        b += bytes([int(m[1], 16)]) if m else pieces[i].replace('▁', ' ').encode()
    return b.decode('utf-8', 'replace').strip()

def without_loop(t):
    for n in range(1, 9):
        times = 1
        while len(t) >= n * (times + 1) and t[len(t) - n:] == t[len(t) - n * (times + 1):len(t) - n * times]: times += 1
        if times >= 4: return t[:len(t) - n * (times - 1)]
    return t

THREADS = int(sys.argv[sys.argv.index('--threads') + 1]) if '--threads' in sys.argv else 4
LIMIT = int(sys.argv[sys.argv.index('--limit') + 1]) if '--limit' in sys.argv else None
T = {'vision': 0.0, 'prefill': 0.0, 'decode': 0.0, 'tokens': 0}
import time as _t
opt = ort.SessionOptions(); opt.intra_op_num_threads = THREADS; opt.inter_op_num_threads = 1
vision = ort.InferenceSession(f'{mdir}/onnx/vision_encoder_q4.onnx', opt, providers=['CPUExecutionProvider'])
decoder = ort.InferenceSession(f'{mdir}/onnx/decoder_q4.onnx', opt, providers=['CPUExecutionProvider'])
table = np.memmap(f'{mdir}/onnx/embedding.onnx.data', dtype=np.float32, mode='r')
row = lambda i: np.asarray(table[i * HIDDEN:(i + 1) * HIDDEN])

PICS = sys.argv[sys.argv.index('--pics') + 1] if '--pics' in sys.argv else None   # pictures drawn by render.py instead of the app's own
HEIGHT = int(sys.argv[sys.argv.index('--height') + 1]) if '--height' in sys.argv else 112   # (a multiple of 28)

def load(png):
    im = Image.open(png).convert('RGB')
    if PICS is None: return im
    w = max(28, round(im.width * HEIGHT / im.height))
    im = im.resize((w, HEIGHT), Image.LANCZOS)
    W = max(-(-w // 28) * 28, -(-113000 // HEIGHT // 28) * 28)    # a multiple of 28, at least the fewest pixels the model takes
    full = Image.new('RGB', (W, HEIGHT), 'white'); full.paste(im, (0, 0))
    return full

def patches(png):
    a = np.asarray(load(png), dtype=np.float32) / 127.5 - 1
    h, w, _ = a.shape; gh, gw = h // PATCH, w // PATCH
    p = a.reshape(gh, PATCH, gw, PATCH, 3).transpose(0, 2, 4, 1, 3)   # patch rows, patch cols, colour, y, x
    return p.reshape(1, gh * gw, 3, PATCH, PATCH).astype(np.float32), gh, gw

def read(png, max_tokens=160):
    px, gh, gw = patches(png)
    _a = _t.perf_counter()
    feats = vision.run(None, {'pixel_values': px, 'image_grid_thw': np.array([[1, gh, gw]], dtype=np.int64)})[0].reshape(-1, HIDDEN)
    T['vision'] += _t.perf_counter() - _a; _a = _t.perf_counter()
    prompt = BEFORE + [IMG] * (gh * gw // 4) + AFTER
    def rows(a, b):
        return np.stack([feats[i - len(BEFORE)] if prompt[i] == IMG else row(prompt[i]) for i in range(a, b)])[None]
    empty = np.zeros((1, KV_HEADS, 1, HEAD_DIM), np.float32)
    cache = {f'past_key_values.{i}.{kv}': empty for i in range(LAYERS) for kv in ('key', 'value')}
    mask = [0]
    def step(emb):
        nonlocal cache
        mask.extend([1] * emb.shape[1])
        o = decoder.run(None, {'inputs_embeds': emb.astype(np.float32), 'attention_mask': np.array([mask], dtype=np.int64), **cache})
        names = [x.name for x in decoder.get_outputs()]
        d = dict(zip(names, o))
        cache = {k.replace('present.', 'past_key_values.'): v for k, v in d.items() if k != 'logits'}
        return d['logits']
    for at in range(0, len(prompt) - 1, 64):
        step(rows(at, min(at + 64, len(prompt) - 1)))
    logits = step(rows(len(prompt) - 1, len(prompt)))
    T['prefill'] += _t.perf_counter() - _a; _a = _t.perf_counter()
    res = []
    for _ in range(max_tokens):
        best = int(logits[0, -1].argmax())
        if best == END: break
        res.append(best)
        logits = step(row(best)[None, None])
    T['decode'] += _t.perf_counter() - _a; T['tokens'] += len(res) + 1
    return without_loop(res)

lines = json.load(open(f'{out}/lines.json')); only = json.load(open(f'{out}/truth.json')) if '--all' not in sys.argv else None
res = {}; t0 = time.time()
n_done = 0
for l in lines:
    if only is not None and l['id'] not in only: continue
    if LIMIT and n_done >= LIMIT: break
    n_done += 1
    res[l['id']] = decode(read(f"{out}/{PICS or 'paddle'}/{l['id']}.png"))
    print(l['id'], '|', res[l['id']], flush=True)
os.makedirs(f'{out}/results', exist_ok=True)
json.dump(res, open(f'{out}/results/{name}.json', 'w'), ensure_ascii=False, indent=0)
import resource
n = len(res)
print(f"{n} lines, vision {1000*T['vision']/n:.0f} ms, prefill {1000*T['prefill']/n:.0f} ms, decode {1000*T['decode']/T['tokens']:.0f} ms/token ({T['tokens']/n:.1f} tokens/line), total {(T['vision']+T['prefill']+T['decode'])/n:.2f} s/line, peak RSS {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024} MB")
