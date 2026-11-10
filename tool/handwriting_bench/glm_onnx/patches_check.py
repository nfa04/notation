"""Checks the picture -> patches layout the Dart runtime will use against the HF processor, and writes small fixtures for the Dart tests.
  python3 patches_check.py [FIXTURE_DIR]"""
import json, os, sys, numpy as np
from PIL import Image
from transformers import AutoProcessor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from glm_parts import vision_pos_ids, text_position_ids
MEAN = np.array([0.48145466, 0.4578275, 0.40821073], np.float32); STD = np.array([0.26862954, 0.26130258, 0.27577711], np.float32)

def patches(rgb):                       # rgb: [h, w, 3] uint8, h and w multiples of 28
    h, w, _ = rgb.shape; gh, gw = h // 14, w // 14
    x = (rgb.astype(np.float32) / 255 - MEAN) / STD                      # [h, w, 3]
    out = np.zeros((gh * gw, 3, 2, 14, 14), np.float32)
    n = 0
    for by in range(gh // 2):
        for bx in range(gw // 2):
            for my in range(2):
                for mx in range(2):
                    y, xx = (by * 2 + my) * 14, (bx * 2 + mx) * 14
                    blk = x[y:y + 14, xx:xx + 14, :].transpose(2, 0, 1)    # [3, 14, 14]
                    out[n, :, 0] = blk; out[n, :, 1] = blk; n += 1          # the picture twice (two frames)
    return out.reshape(gh * gw, -1)

proc = AutoProcessor.from_pretrained(os.path.expanduser('~/hw-bench/models/glm-ocr'))
rng = np.random.default_rng(7)
for (h, w) in [(112, 140), (140, 252)]:   # (the processor enlarges anything under 12544 pixels, so the pictures must be at least that big)
    rgb = rng.integers(0, 256, (h, w, 3), dtype=np.uint8)
    msgs = [{'role': 'user', 'content': [{'type': 'image', 'image': Image.fromarray(rgb)}, {'type': 'text', 'text': 'Text Recognition:'}]}]
    inp = proc.apply_chat_template(msgs, add_generation_prompt=True, tokenize=True, return_dict=True, return_tensors='pt')
    ref = inp['pixel_values'].numpy(); mine = patches(rgb)
    print((h, w), 'grid', inp['image_grid_thw'][0].tolist(), 'shape equal', ref.shape == mine.shape, 'max diff', float(np.abs(ref - mine).max()) if ref.shape == mine.shape else None)
    ids = inp['input_ids'][0].tolist()
    g = inp['image_grid_thw'][0].tolist(); gh, gw = g[1], g[2]
    types = [1 if i == 59280 else 0 for i in ids]
    pos = text_position_ids(types, gh, gw)
    prompt = [59248, 59250, 59253, 10, 59256] + [59280] * (gh * gw // 4) + [59257, 3649, 7404, 49600, 58, 59254, 10]
    print('   prompt ids equal', ids == prompt, '| positions shape', pos.shape)
if len(sys.argv) > 1:
    os.makedirs(sys.argv[1], exist_ok=True)
    h, w = 112, 140
    rgb = np.fromfunction(lambda y, x, c: (x * 7 + y * 13 + c * 31) % 256, (h, w, 3)).astype(np.uint8)
    msgs = [{'role': 'user', 'content': [{'type': 'image', 'image': Image.fromarray(rgb)}, {'type': 'text', 'text': 'Text Recognition:'}]}]
    inp = proc.apply_chat_template(msgs, add_generation_prompt=True, tokenize=True, return_dict=True, return_tensors='pt')
    ref = inp['pixel_values'].numpy()
    idx = list(range(0, ref.size, 97))
    gh, gw = 8, 10
    ids = inp['input_ids'][0].tolist(); types = [1 if i == 59280 else 0 for i in ids]
    pos = text_position_ids(types, gh, gw)
    gh2, gw2 = 10, 24
    prompt2 = [59248, 59250, 59253, 10, 59256] + [59280] * (gh2 * gw2 // 4) + [59257, 3649, 7404, 49600, 58, 59254, 10]
    pos2 = text_position_ids([1 if i == 59280 else 0 for i in prompt2], gh2, gw2)
    json.dump({'width': w, 'height': h, 'patches': int(ref.shape[0]), 'count': int(ref.size), 'sum': float(ref.astype(np.float64).sum()),
               'samples': [[i, float(ref.reshape(-1)[i])] for i in idx],
               'vision_pos_small': vision_pos_ids(gh, gw).tolist(), 'vision_pos_big_sum': int(vision_pos_ids(10, 24).sum()),
               'text_pos_small': pos.tolist(), 'prompt_small': ids, 'text_pos_big': pos2.tolist()}, open(f'{sys.argv[1]}/glm_golden.json', 'w'))
    print('fixture written', os.path.getsize(f'{sys.argv[1]}/glm_golden.json'), 'bytes')
