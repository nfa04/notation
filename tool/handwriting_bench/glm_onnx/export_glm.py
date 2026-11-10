"""Exports the two parts of GLM-OCR (glm_parts.py) to ONNX, fp32, into ~/hw-bench/glm_onnx/fp32/ and checks them against PyTorch.
  python3 export_glm.py vision|text"""
import os, sys, numpy as np, torch
from transformers import AutoModelForImageTextToText
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from glm_parts import VisionPart, TextPart, vision_pos_ids, text_position_ids
torch.set_num_threads(6)
which = sys.argv[1]
root = os.path.expanduser('~/hw-bench/glm_onnx'); os.makedirs(f'{root}/fp32', exist_ok=True)
model = AutoModelForImageTextToText.from_pretrained(os.path.expanduser('~/hw-bench/models/glm-ocr'), dtype=torch.float32).eval()
ref = np.load(f'{root}/ref/mvpp32o7_0_c00_00.npz')
if which == 'vision':
    part = VisionPart(model.model.visual).eval()
    model.model.language_model = None; model.lm_head = None   # (the export of the rest needs the memory)
    import gc; gc.collect()
    px = torch.from_numpy(ref['pixel_values']); g = ref['grid'][0]
    pos = torch.from_numpy(vision_pos_ids(int(g[1]), int(g[2])))
    with torch.no_grad(): out = part(px, pos)
    print('vision part vs transformers:', float(np.abs(out.numpy() - ref['vis_out']).max()), 'max abs diff;', out.shape)
    from torch.export import Dim
    m = Dim('m', min=1, max=2000)
    prog = torch.onnx.export(part, (px, pos), dynamic_shapes={'pixel_values': {0: 4 * m}, 'pos_ids': {0: 4 * m}},
                             input_names=['pixel_values', 'pos_ids'], output_names=['features'], opset_version=18, dynamo=True)
    prog.save(f'{root}/fp32/vision.onnx', external_data=True)
else:
    part = TextPart(model).eval()
    model.model.visual = None
    import gc; gc.collect()
    n = part.layers_n
    t = 20; p = 3
    emb = torch.randn(1, t, 1536); pos = torch.arange(t)[None, None, :].expand(3, 1, -1).contiguous()
    mask = torch.ones(1, p, dtype=torch.int64); mask[0, 0] = 0
    past = [torch.randn(1, 8, p, 128) for _ in range(2 * n)]
    names = [f'past_key_values.{i}.{kv}' for i in range(n) for kv in ('key', 'value')]
    outs = ['logits'] + [f'present.{i}.{kv}' for i in range(n) for kv in ('key', 'value')]
    axes = {'inputs_embeds': {1: 't'}, 'position_ids': {2: 't'}, 'attention_mask': {1: 's'}}
    axes.update({k: {2: 'p'} for k in names}); axes.update({k: {2: 's'} for k in outs[1:]})
    from torch.export import Dim
    T, P = Dim('T', min=1, max=1500), Dim('P', min=1, max=1500)
    shapes = {'inputs_embeds': {1: T}, 'position_ids': {2: T}, 'attention_mask': {1: P}, 'past': [{2: P} for _ in range(2 * n)]}
    prog = torch.onnx.export(part, (emb, pos, mask, past), dynamic_shapes=shapes,
                             input_names=['inputs_embeds', 'position_ids', 'attention_mask'] + names, output_names=outs, opset_version=18, dynamo=True)
    prog.save(f'{root}/fp32/text.onnx', external_data=True)
print('exported', which)
