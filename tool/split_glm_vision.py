"""Cuts the handwriting reader's 16-bit vision network (vision-gpu.onnx, 868 MB) into parts that run one after the other.

Why: QNN on a phone compiles a session's whole graph at once, and for the full network that took the app past 3.3 GB on a 6 GB phone
(Android killed it). Each part is compiled on its own, one at a time, and kept as its own compiled file.

Every part takes the picture size the same way: the patch dimension of each input is named '4*m', as in the whole network, so fixing
that one name fixes the sizes of all parts. Between parts the values are float32 (the parts cast to and from 16 bits inside).

    python3 tool/split_glm_vision.py vision-gpu.onnx out_dir [parts: 1, 4 or 5 (the default)]

writes vision-gpu.part1.onnx (+ .data) ... and checks on the processor that the parts in a row give the whole network's answer.
"""

import heapq
import os
import sys

import numpy as np
import onnx
from onnx import TensorProto, helper

# the blocks each part ends after (24 blocks; the last part has the merger too, 118 MB). 'front': a part of the rotary tables alone (from
# pos_ids: GatherND, Cos, Sin; no weights), which QNN's GPU backend on a Snapdragon 865 compiled but could not run (error 6999): with it
# on its own, the app runs it on the processor and the four parts of weights on QNN
ENDS = {1: [23], 4: [6, 12, 18, 23], 5: ['front', 6, 12, 18, 23]}


def topo(g):
    prod = {o: i for i, n in enumerate(g.node) for o in n.output}
    deps = [set(prod[x] for x in n.input if x in prod) for n in g.node]
    users = [[] for _ in g.node]
    for i, d in enumerate(deps):
        for j in d:
            users[j].append(i)
    indeg = [len(d) for d in deps]
    h = [i for i in range(len(g.node)) if indeg[i] == 0]
    heapq.heapify(h)
    order = []
    while h:
        i = heapq.heappop(h)
        order.append(i)
        for u in users[i]:
            indeg[u] -= 1
            if indeg[u] == 0:
                heapq.heappush(h, u)
    assert len(order) == len(g.node)
    return [g.node[i] for i in order]


def main():
    src, out = sys.argv[1], sys.argv[2]
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 5
    os.makedirs(out, exist_ok=True)
    stem = os.path.basename(src)[: -len('.onnx')]
    m = onnx.load(src)  # with the weights
    g = m.graph
    nodes = topo(g)
    inits = {t.name: t for t in g.initializer}
    ginputs = {i.name: i for i in g.input}
    # types of the values between parts
    bare = onnx.load(src, load_external_data=False)
    sorted_nodes = topo(bare.graph)
    bare.graph.ClearField('node')
    bare.graph.node.extend(sorted_nodes)  # (inference goes through the nodes in their order)
    typed = onnx.shape_inference.infer_shapes(bare)
    vtype = {v.name: v.type.tensor_type.elem_type for v in list(typed.graph.value_info) + list(typed.graph.input) + list(typed.graph.output)}

    pos = {o: k for k, n in enumerate(nodes) for o in n.output}
    for t in ginputs:
        pos[t] = -1
    last = {}
    for k, n in enumerate(nodes):
        for x in n.input:
            if x and x not in inits:
                last[x] = max(last.get(x, -1), k)
    for o in g.output:
        last[o.name] = len(nodes)

    def crossing(k):
        return [t for t, p in pos.items() if p <= k and last.get(t, -1) > k]

    # a cut a few nodes after each block's Softmax, where only the hidden state and the two rotary tables cross
    softmax = [k for k, n in enumerate(nodes) if n.op_type == 'Softmax']
    cuts = []
    for a, b in zip(softmax, softmax[1:] + [len(nodes) - 1]):
        cuts.append(min(range(a, b), key=lambda k: len(crossing(k))))
    # (the front: the nodes before the first that reads the picture; only the rotary tables cross there, besides the inputs)
    front = min(k for k, n in enumerate(nodes) if 'pixel_values' in n.input) - 1
    assert all(t in ginputs or t.startswith('unsqueeze') for t in crossing(front)), crossing(front)
    ends = [front if b == 'front' else cuts[b] for b in ENDS[count][:-1]] + [len(nodes) - 1]
    for k in ends[:-1]:
        missing = [t for t in crossing(k) if t not in vtype]
        assert not missing, f'no type known for {missing}'

    start = 0
    names = []
    for p, end in enumerate(ends):
        part = nodes[start:end + 1]
        ins = [t for t in crossing(start - 1)] if start > 0 else [i.name for i in g.input]
        made = {o for n in part for o in n.output}
        # (the rotary tables are made by the first part only: the later ones get them from it, as the caller keeps every output)
        outs = [t for t in crossing(end) if t in made] if end < len(nodes) - 1 else [o.name for o in g.output]
        used = {x for n in part for x in n.input}
        new_nodes, inputs, outputs = [], [], []
        for t in ins:
            if t in ginputs:
                inputs.append(ginputs[t])
                continue
            # float32 in, cast to the type inside
            inner = vtype.get(t, TensorProto.FLOAT)
            inputs.append(helper.make_tensor_value_info(t + '_f32' if inner != TensorProto.FLOAT else t, TensorProto.FLOAT, None))
            if inner != TensorProto.FLOAT:
                new_nodes.append(helper.make_node('Cast', [t + '_f32'], [t], to=inner, name='part_in_' + t))
        new_nodes += part
        for t in outs:
            if t in {o.name for o in g.output}:
                outputs.append([o for o in g.output if o.name == t][0])
                continue
            inner = vtype.get(t, TensorProto.FLOAT)
            if inner != TensorProto.FLOAT:
                new_nodes.append(helper.make_node('Cast', [t], [t + '_f32'], to=TensorProto.FLOAT, name='part_out_' + t))
            outputs.append(helper.make_tensor_value_info(t + '_f32' if inner != TensorProto.FLOAT else t, TensorProto.FLOAT, None))
        graph = helper.make_graph(new_nodes, f'{g.name}_part{p + 1}', inputs, outputs, [inits[x] for x in sorted(used) if x in inits])
        model = helper.make_model(graph, opset_imports=m.opset_import, ir_version=m.ir_version)
        name = f'{stem}.part{p + 1}.onnx'
        path = os.path.join(out, name)
        for f in (path, path + '.data'):
            if os.path.exists(f):
                os.remove(f)
        onnx.save(model, path, save_as_external_data=True, all_tensors_to_one_file=True, location=name + '.data', size_threshold=1024)
        names.append(name)
        print(name, 'nodes', len(part), 'in', [i.name for i in inputs], 'out', [o.name for o in outputs],
              f'{os.path.getsize(path + ".data") / 1e6:.0f} MB')
        start = end + 1
    name_dims(out, names)
    check(src, [os.path.join(out, n) for n in names])


def name_dims(out, names):
    """Shapes of the inputs and outputs between parts, from a run, with the patch dimension named '4*m' (fixed by the app per size)."""
    import onnxruntime as ort
    patches = 52  # (not a size the model has elsewhere: the rotary tables are 64 wide)
    feeds = {'pixel_values': np.random.rand(patches, 1176).astype(np.float32), 'pos_ids': np.stack([np.arange(patches) // 8, np.arange(patches) % 8], 1).astype(np.int64)}
    values = dict(feeds)
    shapes = {}
    for n in names:
        s = ort.InferenceSession(os.path.join(out, n), providers=['CPUExecutionProvider'])
        res = s.run(None, {i.name: values[i.name] for i in s.get_inputs()})
        for o, v in zip(s.get_outputs(), res):
            values[o.name] = v
            shapes[o.name] = v.shape
    whole = {'pixel_values', 'pos_ids', 'features'}  # (the network's own: their shapes are kept)
    for n in names:
        path = os.path.join(out, n)
        m = onnx.load(path, load_external_data=False)
        for v in list(m.graph.input) + list(m.graph.output):
            if v.name not in shapes or v.name in whole:
                continue
            dims = v.type.tensor_type.shape
            dims.ClearField('dim')
            for d in shapes[v.name]:
                dim = dims.dim.add()
                if d == patches:
                    dim.dim_param = '4*m'
                else:
                    dim.dim_value = d
        onnx.save(m, path)  # (the weights stay in the .data file, which is not rewritten)
        print(n, {v.name: [d.dim_param or d.dim_value for d in v.type.tensor_type.shape.dim] for v in list(m.graph.input) + list(m.graph.output)})


def check(src, paths):
    import onnxruntime as ort
    # (graph optimisations off. Not exactly the whole network's numbers: the processor works 16-bit operators out in 32 bits and keeps a
    # value in 32 bits from one operator to the next where it can, which a cut stops (a value between parts is rounded to 16 bits).
    # With 1 part (the sorted whole) the difference is 0; with 4 it was 1.4e-3 on values up to 0.4, the size of what turning ONNX
    # Runtime's own graph optimisations on or off changes in the whole network: 1.2e-3)
    o = ort.SessionOptions()
    o.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    whole = ort.InferenceSession(src, o, providers=['CPUExecutionProvider'])
    parts = [ort.InferenceSession(p, o, providers=['CPUExecutionProvider']) for p in paths]
    for patches in (16, 64, 200):
        rng = np.random.default_rng(patches)
        side = 8
        feeds = {'pixel_values': rng.random((patches, 1176), dtype=np.float32), 'pos_ids': np.stack([np.arange(patches) // side, np.arange(patches) % side], 1).astype(np.int64)}
        want = whole.run(None, feeds)[0]
        values = dict(feeds)
        for s in parts:
            for o, v in zip(s.get_outputs(), s.run(None, {i.name: values[i.name] for i in s.get_inputs()})):
                values[o.name] = v
        got = values['features']
        print(f'{patches} patches: features {got.shape}, largest difference from the whole network {np.abs(got - want).max():.3g} (values up to {np.abs(want).max():.3g})')


if __name__ == '__main__':
    main()
