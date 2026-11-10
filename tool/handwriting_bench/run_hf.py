"""Reads pictures with a model run by transformers (PyTorch, CPU).
  python3 run_hf.py OUT_DIR MODEL PICTURE_DIR NAME [--limit N]
MODEL: glm (zai-org/GLM-OCR, MIT) | paddle (PaddlePaddle/PaddleOCR-VL-1.5, Apache-2.0, full precision) | florence (Florence-2, MIT)
Results go to OUT_DIR/results/NAME.json. Needs a transformers that can run them (see README of this folder)."""
import json, os, sys, time
import torch
from PIL import Image

out, which, pics, name = sys.argv[1:5]
limit = int(sys.argv[sys.argv.index('--limit') + 1]) if '--limit' in sys.argv else None
torch.set_num_threads(4)
home = os.path.expanduser('~/hw-bench/models')
ids = list(json.load(open(f'{out}/truth.json')))[:limit]

if which in ('glm', 'paddle'):
    from transformers import AutoProcessor, AutoModelForImageTextToText
    path = f'{home}/glm-ocr' if which == 'glm' else f'{home}/paddle-hf'
    prompt = 'Text Recognition:' if which == 'glm' else 'OCR:'
    proc = AutoProcessor.from_pretrained(path)
    model = AutoModelForImageTextToText.from_pretrained(path, dtype=torch.bfloat16 if which == 'glm' else torch.float32).eval()
    def read(png):
        msgs = [{'role': 'user', 'content': [{'type': 'image', 'image': Image.open(png).convert('RGB')}, {'type': 'text', 'text': prompt}]}]
        inp = proc.apply_chat_template(msgs, add_generation_prompt=True, tokenize=True, return_dict=True, return_tensors='pt')
        inp.pop('token_type_ids', None)
        with torch.no_grad(): gen = model.generate(**inp, max_new_tokens=120, do_sample=False)
        return proc.decode(gen[0][inp['input_ids'].shape[1]:], skip_special_tokens=True).strip()
elif which == 'florence':
    from transformers import AutoProcessor, Florence2ForConditionalGeneration
    path = f'{home}/florence-community'
    proc = AutoProcessor.from_pretrained(path)
    model = Florence2ForConditionalGeneration.from_pretrained(path, dtype=torch.float32).eval()
    def read(png):
        inp = proc(text='<OCR>', images=Image.open(png).convert('RGB'), return_tensors='pt')
        with torch.no_grad(): gen = model.generate(**inp, max_new_tokens=60, num_beams=3, do_sample=False)
        return proc.batch_decode(gen, skip_special_tokens=True)[0].strip()

res = {}; t0 = time.time()
for i in ids:
    res[i] = read(f'{out}/{pics}/{i}.png'); print(i, '|', res[i], flush=True)
os.makedirs(f'{out}/results', exist_ok=True)
json.dump(res, open(f'{out}/results/{name}.json', 'w'), ensure_ascii=False, indent=0)
print(len(res), 'lines', round(time.time() - t0), 's, per line', round((time.time() - t0) / len(res), 1))
