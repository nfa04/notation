"""Makes a copy of the GLM vision graph with the tensors inside each block as extra outputs, to see where CoreML's answer moves away
from the processor's (probe_glm_vision.py bisect). Only the graph is written; it is saved next to the original and keeps reading the
original's weights file (vision-gpu.onnx.data), so nothing large is copied.

  python add_outputs.py MODEL.onnx OUT.onnx

Per block b (24 of them), in the order they are computed:
  b.attn_scores   the attention weights (Softmax)
  b.attn_proj     the attention's output projection
  b.after_attn    the stream after adding it
  b.mlp_hidden    gate * up, the input of the feed-forward's last product
  b.mlp_down      that product
  b.after_mlp     the stream after adding it (the block's output)
"""
import sys

import onnx
from onnx import TensorProto, helper


def main():
    src, dst = sys.argv[1:3]
    m = onnx.load(src, load_external_data=False)
    g = m.graph
    by_output = {o: n for n in g.node for o in n.output}
    consumers = {}
    for n in g.node:
        for i in n.input:
            consumers.setdefault(i, []).append(n)

    def adder_after(tensor):
        return next(n for n in consumers[tensor] if n.op_type == 'Add').output[0]

    wanted = []
    softmaxes = [n for n in g.node if n.op_type == 'Softmax']
    for n in g.node:
        if n.op_type != 'Gemm':
            continue
        w = n.input[1]
        if '.attn.proj.weight' in w:
            b = int(w.split('blocks.')[1].split('.')[0])
            wanted += [(f'{b}.attn_scores', softmaxes[b].output[0]), (f'{b}.attn_proj', n.output[0]), (f'{b}.after_attn', adder_after(n.output[0]))]
        elif '.mlp.down_proj.weight' in w:
            b = int(w.split('blocks.')[1].split('.')[0])
            wanted += [(f'{b}.mlp_hidden', n.input[0]), (f'{b}.mlp_down', n.output[0]), (f'{b}.after_mlp', adder_after(n.output[0]))]
    order = {name: i for i, name in enumerate(o for n in g.node for o in n.output)}
    wanted.sort(key=lambda x: order[x[1]])
    for label, tensor in wanted:
        # (the inner tensors are 16-bit; the norm statistics, the only 32-bit ones, are not among these)
        g.output.append(helper.make_tensor_value_info(tensor, TensorProto.FLOAT16, None))
        g.output[-1].doc_string = label
    # the weights stay where they are: same folder, same file name
    onnx.save(m, dst)
    print('\n'.join(f'{label}\t{tensor}' for label, tensor in wanted))


if __name__ == '__main__':
    main()
