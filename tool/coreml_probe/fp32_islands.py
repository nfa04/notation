"""Makes a copy of the GLM vision graph (vision-gpu.onnx, 16-bit) in which chosen parts of chosen blocks compute in 32 bits: everything
they take in is widened, everything they give out narrowed again, their own 16-bit casts and constants made 32-bit. The weights stay in
the shared weights file in 16 bits (widened when the model is built), so the copy is only the graph, saved next to the original.

  python fp32_islands.py MODEL.onnx OUT.onnx FIRST LAST PARTS
PARTS: attn (attention, up to the stream after it), mlp (feed-forward, up to the stream after it), or both.

Why: the CoreML probe (probe_glm_vision.py bisect) found CoreML's answer moving away in blocks 13 to 17, where a few values of the
stream become very large (about 10 to 1500), 18 % off on a line of 960 patches against 2 % before. A 32-bit island there should keep
them right; the cost is that those parts leave the Neural Engine (16 bits only).
"""
import sys

import onnx
from onnx import TensorProto, helper, numpy_helper

F16, F32 = TensorProto.FLOAT16, TensorProto.FLOAT


def main():
    src, dst, first, last, parts = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
    m = onnx.load(src, load_external_data=False)
    g = m.graph
    nodes = list(g.node)
    consumers = {}
    for n in nodes:
        for i in n.input:
            consumers.setdefault(i, []).append(n)
    index = {id(n): k for k, n in enumerate(nodes)}

    def add_after(tensor):
        return next(n for n in consumers[tensor] if n.op_type == 'Add')

    # where each block's two halves end: the Add after the attention's projection and after the feed-forward's last product
    ends = {}
    for n in nodes:
        if n.op_type == 'Gemm' and 'blocks.' in n.input[1]:
            b = int(n.input[1].split('blocks.')[1].split('.')[0])
            if '.attn.proj.weight' in n.input[1]:
                ends.setdefault(b, {})['attn'] = index[id(add_after(n.output[0]))]
            elif '.mlp.down_proj.weight' in n.input[1]:
                ends.setdefault(b, {})['mlp'] = index[id(add_after(n.output[0]))]
    chosen = set()
    for b in range(first, last + 1):
        start_attn = ends[b - 1]['mlp'] + 1 if b > 0 else 0
        if parts in ('attn', 'both'):
            chosen.update(range(start_attn, ends[b]['attn'] + 1))
        if parts in ('mlp', 'both'):
            chosen.update(range(ends[b]['attn'] + 1, ends[b]['mlp'] + 1))

    inside = {k for k in chosen}
    made_inside = {o for k in inside for o in nodes[k].output}
    types = {vi.name: vi.type.tensor_type.elem_type for vi in list(g.input) + list(g.output) + list(g.value_info)}
    init_types = {i.name: i.data_type for i in g.initializer}
    outer_users = {o for k, n in enumerate(nodes) if k not in inside for o in n.input} | {o.name for o in g.output}

    # which tensors coming from outside are 16-bit floats: from the type table, or made by a node outside whose type is known
    def is_f16_from_outside(name):
        if name in init_types:
            return init_types[name] == F16
        return types.get(name) == F16

    # (the graph has no reliable type notes, the 16-bit fix cleared them: every tensor's type is worked out here, in graph order)
    INT64, BOOL = TensorProto.INT64, TensorProto.BOOL
    for vi in g.input:
        types[vi.name] = vi.type.tensor_type.elem_type
    types.update(init_types)
    for n in nodes:
        op = n.op_type
        attr = {a.name: a for a in n.attribute}
        if op == 'Cast':
            t = attr['to'].i
        elif op in ('Shape', 'Size', 'NonZero', 'ArgMax', 'ArgMin'):
            t = INT64
        elif op in ('Equal', 'Less', 'Greater', 'LessOrEqual', 'GreaterOrEqual', 'Not', 'And', 'Or', 'IsNaN', 'IsInf'):
            t = BOOL
        elif op in ('Constant',):
            t = attr['value'].t.data_type if 'value' in attr else None
        elif op == 'ConstantOfShape':
            t = attr['value'].t.data_type if 'value' in attr else F32
        elif op == 'Where':
            t = types.get(n.input[1])
        else:
            t = next((types[i] for i in n.input if i and types.get(i) is not None), None)
        for o in n.output:
            types[o] = t
    unknown = [n.input for k in inside for n in [nodes[k]] if any(i and types.get(i) is None for i in n.input)]
    if unknown:
        print('warning: inputs of unknown type:', unknown[:5])

    new_nodes, widened = [], {}
    for k, n in enumerate(nodes):
        if k in inside:
            for j, name in enumerate(n.input):
                if name and name not in made_inside and is_f16_from_outside(name):
                    if name not in widened:
                        widened[name] = name + '__isl32'
                        new_nodes.append(helper.make_node('Cast', [name], [widened[name]], to=F32, name=name + '__isl32_cast'))
                    n.input[j] = widened[name]
            if n.op_type == 'Cast':
                for a in n.attribute:
                    if a.name == 'to' and a.i == F16:
                        a.i = F32
            if n.op_type == 'Constant':
                for a in n.attribute:
                    if a.name == 'value' and a.t.data_type == F16:
                        a.t.CopyFrom(numpy_helper.from_array(numpy_helper.to_array(a.t).astype('float32'), a.t.name))
            if n.op_type == 'ConstantOfShape':
                for a in n.attribute:
                    if a.name == 'value' and a.t.data_type == F16:
                        a.t.CopyFrom(numpy_helper.from_array(numpy_helper.to_array(a.t).astype('float32'), a.t.name))
            new_nodes.append(n)
            # outputs used outside the island: narrowed back to 16 bits under their old name
            for j, out in enumerate(n.output):
                if out in outer_users and types.get(out) == F16:
                    wide = out + '__isl32out'
                    n.output[j] = wide
                    new_nodes.append(helper.make_node('Cast', [wide], [out], to=F16, name=out + '__isl16_cast'))
                    for c in consumers.get(out, []):
                        if index[id(c)] in inside:
                            for i2, name in enumerate(c.input):
                                if name == out:
                                    c.input[i2] = wide
        else:
            new_nodes.append(n)
    del g.node[:]
    g.node.extend(new_nodes)
    del g.value_info[:]
    onnx.save(m, dst)
    print(f'{len(inside)} nodes in 32 bits (blocks {first}-{last}, {parts}); {len(widened)} inputs widened')


if __name__ == '__main__':
    main()
