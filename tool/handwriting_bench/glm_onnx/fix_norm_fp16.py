"""Makes an fp16 GLM-OCR vision file safe for runtimes that compute in plain fp16 (AMD's MIGraphX).
  python3 fix_norm_fp16.py vision-gpu.onnx OUT/vision-gpu.onnx
The residual stream of the later blocks reaches about 2000, and an RMS norm squares it: above 255 that is more than fp16 can hold (65504), so
it becomes infinity and the reading is garbage (error 0.69 against fp32 on MIGraphX). The processor's optimiser fuses the norm and adds up in
fp32, so it never showed there. This casts the Pow / ReduceMean / Add / Sqrt / Reciprocal chain of each of the 97 norms to fp32 and casts the
reciprocal back; everything else stays fp16. Measured on MIGraphX: error 0.006 against fp32, 94 ms for 320 patches (fp32: 189 ms)."""
import sys, numpy as np, onnx
from onnx import helper as h, TensorProto as T, numpy_helper as nh

src, dst = sys.argv[1:3]
m = onnx.load(src); g = m.graph
inits = {i.name: i for i in g.initializer}

def f32(name):
    n = name + '__f32'
    if n not in inits:
        t = nh.from_array(nh.to_array(inits[name]).astype(np.float32), n); g.initializer.append(t); inits[n] = t
    return n

nodes = list(g.node); byin = {}
for n in nodes:
    for i in n.input: byin.setdefault(i, []).append(n)
before, after, cnt = {}, {}, 0
for n in nodes:
    if n.op_type == 'Pow' and n.input[1] in inits and inits[n.input[1]].data_type == T.FLOAT16:
        rm = byin[n.output[0]][0]; ad = byin[rm.output[0]][0]; sq = byin[ad.output[0]][0]; rc = byin[sq.output[0]][0]
        assert (rm.op_type, ad.op_type, sq.op_type, rc.op_type) == ('ReduceMean', 'Add', 'Sqrt', 'Reciprocal')
        cx = f'{n.input[0]}__to32_{cnt}'
        before[id(n)] = [h.make_node('Cast', [n.input[0]], [cx], to=T.FLOAT)]
        n.input[0] = cx; n.input[1] = f32(n.input[1])
        for j, i in enumerate(ad.input):
            if i in inits: ad.input[j] = f32(i)
        orig = rc.output[0]; rc.output[0] = orig + '__r32'
        after[id(rc)] = [h.make_node('Cast', [orig + '__r32'], [orig], to=T.FLOAT16)]
        cnt += 1
final = []
for n in nodes:
    final += before.get(id(n), []); final.append(n); final += after.get(id(n), [])
del g.node[:]; g.node.extend(final); del g.value_info[:]
print('rewrote', cnt, 'norms')
onnx.save(m, dst, save_as_external_data=True, all_tensors_to_one_file=True, location=dst.split('/')[-1] + '.data')
