#!/usr/bin/env python3
"""Runs the statistics of every LayerNorm of a float16 TexTeller encoder in float32.
usage: fix_ln.py enc_plain.onnx OUT.onnx"""
import sys, numpy as np, onnx
from onnx import helper as h, numpy_helper as nh, TensorProto as T
m = onnx.load(sys.argv[1]); g = m.graph
nodes = list(g.node); out = []
byname = {n.name: n for n in nodes}
count = 0
for n in nodes:
    if n.op_type == 'ReduceMean' and 'layernorm' in n.name and n.name.endswith('/ReduceMean'):
        p = n.name[:-len('/ReduceMean')]
        sub, pw, add, sq, dv = (byname[p + s] for s in ('/Sub', '/Pow', '/Add', '/Sqrt', '/Div'))
        x = n.input[0]; x32 = x + '__to32'
        out.append(h.make_node('Cast', [x], [x32], to=T.FLOAT, name=p + '/to32'))
        n.input[0] = x32; sub.input[0] = x32
        for c in (byname[p + '/Constant'], byname[p + '/Constant_1']):
            a = c.attribute[0]; a.t.CopyFrom(nh.from_array(nh.to_array(a.t).astype(np.float32), a.t.name))
        orig = dv.output[0]; dv.output[0] = orig + '__32'
        dv_after = h.make_node('Cast', [orig + '__32'], [orig], to=T.FLOAT16, name=p + '/to16')
        out.append(n); pending = dv_after; count += 1
        continue
    out.append(n)
    if n.op_type == 'Div' and 'layernorm' in n.name and n.output[0].endswith('__32'):
        out.append(pending)
del g.node[:]; g.node.extend(out); del g.value_info[:]
onnx.save(m, sys.argv[2]); print(count, 'layernorms fixed')
