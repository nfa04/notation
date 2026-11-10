"""Runs GLM-OCR in PyTorch (fp32) on a few lines and keeps what goes into and out of its parts, as reference for the ONNX export.
  python3 ref_capture.py OUT_DIR PICTURE_DIR N  ->  ~/hw-bench/glm_onnx/ref/<line>.npz"""
import json, os, sys, numpy as np, torch
from PIL import Image
from transformers import AutoProcessor, AutoModelForImageTextToText
out, pics, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
torch.set_num_threads(4)
path = os.path.expanduser('~/hw-bench/models/glm-ocr')
proc = AutoProcessor.from_pretrained(path)
model = AutoModelForImageTextToText.from_pretrained(path, dtype=torch.float32).eval()
os.makedirs(os.path.expanduser('~/hw-bench/glm_onnx/ref'), exist_ok=True)
cap = {}
vis = model.model.visual
vis.register_forward_hook(lambda m, a, k, o: cap.update(vis_in=a[0].detach().clone(), vis_grid=k['grid_thw'].detach().clone(), vis_out=o.pooler_output.detach().clone()), with_kwargs=True)
lm = model.model.language_model
def pre(m, a, k):
    if 'prefill_pos' not in cap:
        cap['prefill_pos'] = k['position_ids'].detach().clone(); cap['prefill_embeds'] = k['inputs_embeds'].detach().clone()
lm.register_forward_pre_hook(pre, with_kwargs=True)
for i in list(json.load(open(f'{out}/truth.json')))[:n]:
    cap.clear()
    msgs = [{'role': 'user', 'content': [{'type': 'image', 'image': Image.open(f'{out}/{pics}/{i}.png').convert('RGB')}, {'type': 'text', 'text': 'Text Recognition:'}]}]
    inp = proc.apply_chat_template(msgs, add_generation_prompt=True, tokenize=True, return_dict=True, return_tensors='pt')
    print(i, {k: tuple(v.shape) for k, v in inp.items()})
    inp.pop('token_type_ids', None)
    with torch.no_grad(): gen = model.generate(**inp, max_new_tokens=60, do_sample=False)
    ids = gen[0][inp['input_ids'].shape[1]:].tolist()
    print('  ->', proc.decode(ids, skip_special_tokens=True), '| tokens', ids[:12], len(ids))
    np.savez(os.path.expanduser(f'~/hw-bench/glm_onnx/ref/{i}.npz'), input_ids=inp['input_ids'].numpy(), pixel_values=inp['pixel_values'].numpy(),
             grid=inp['image_grid_thw'].numpy(), mm=inp.get('mm_token_type_ids', torch.zeros(1)).numpy(), pos=cap['prefill_pos'].numpy(),
             vis_out=cap['vis_out'].numpy(), vis_in=cap['vis_in'].numpy(), generated=np.array(ids))
    if 'mm_token_type_ids' in inp: print('  mm types', inp['mm_token_type_ids'].shape)
