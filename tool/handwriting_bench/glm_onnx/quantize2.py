"""Makes one quantised variant of one part:  python3 quantize2.py vision|text SCHEME NAME   ->  ~/hw-bench/glm_onnx/parts/NAME/{part}.onnx(.data)
SCHEME: nb:BITS:BLOCK[:asym][:keephead]  weight-only MatMulNBits (BITS 4 or 8, symmetric unless asym; keephead leaves the output
        projection (lm_head) in 32 bits)   |   dyn8: dynamic int8 per channel (activations too)   |   fp16: weights stored as half floats
Linear layers are turned from Gemm into MatMul first (the quantiser skips Gemm)."""
import os, sys, shutil, numpy as np, onnx
from onnx import helper, numpy_helper, TensorProto
part, scheme, name = sys.argv[1:4]
root = os.path.expanduser('~/hw-bench/glm_onnx'); dst = f'{root}/parts/{name}'
shutil.rmtree(dst, ignore_errors=True); os.makedirs(dst)
base = f'{root}/tmp/{part}_mm.onnx'
if not os.path.exists(base):   # the fp32 graph without the exporter's stale shape notes, linear layers as MatMul + Add
    os.makedirs(f'{root}/tmp', exist_ok=True)
    m = onnx.load(f'{root}/fp32/{part}.onnx'); del m.graph.value_info[:]
    inits = {i.name: i for i in m.graph.initializer}; new = []
    for n in m.graph.node:
        if n.op_type == 'Gemm' and n.input[1] in inits:
            a = {x.name: helper.get_attribute_value(x) for x in n.attribute}
            w = numpy_helper.to_array(inits[n.input[1]]); w = w.T if a.get('transB', 0) else w
            wn = n.input[1] + '_t'; m.graph.initializer.append(numpy_helper.from_array(np.ascontiguousarray(w), wn))
            mm = n.output[0] + '_mm' if len(n.input) > 2 else n.output[0]
            new.append(helper.make_node('MatMul', [n.input[0], wn], [mm], name=n.name + '_mm'))
            if len(n.input) > 2: new.append(helper.make_node('Add', [mm, n.input[2]], [n.output[0]], name=n.name + '_add'))
        else: new.append(n)
    del m.graph.node[:]; m.graph.node.extend(new)
    used = {i for n in m.graph.node for i in n.input}; keep = [i for i in m.graph.initializer if i.name in used]
    del m.graph.initializer[:]; m.graph.initializer.extend(keep)
    onnx.save_model(m, base, save_as_external_data=True, all_tensors_to_one_file=True, location=f'{part}_mm.onnx.data')
m = onnx.load(base)
kind = scheme.split(':')[0]
if kind == 'nb':
    from onnxruntime.quantization.matmul_nbits_quantizer import MatMulNBitsQuantizer
    f = scheme.split(':'); bits, block = int(f[1]), int(f[2]); asym = 'asym' in f
    exclude = []
    if 'keephead' in f:
        out = [n for n in m.graph.node if 'logits' in n.output[0] or n.output[0] == 'logits']
        exclude = [n.name for n in out if n.op_type == 'MatMul']
        print('keeping', exclude)
    attn = []
    if 'mixed' in f:   # attention weights (qkv, proj) in 8 bits, the rest in `bits`: first all the others, then the attention ones
        sizes = {i.name: tuple(i.dims) for i in m.graph.initializer}
        attn = [n.name for n in m.graph.node if n.op_type == 'MatMul' and sizes.get(n.input[1]) in ((1024, 3072), (1024, 1024))]
        print('attention matmuls:', len(attn)); exclude = attn
    q = MatMulNBitsQuantizer(m, block_size=block, is_symmetric=not asym, bits=bits, nodes_to_exclude=exclude)
    q.process(); m = q.model.model
    if attn:
        q8 = MatMulNBitsQuantizer(m, block_size=block, is_symmetric=not asym, bits=8); q8.process(); q = q8
    q.model.save_model_to_file(f'{dst}/{part}.onnx', use_external_data_format=True)
elif kind == 'dyn8':
    from onnxruntime.quantization import quantize_dynamic, QuantType
    quantize_dynamic(base, f'{dst}/{part}.onnx', weight_type=QuantType.QInt8, per_channel=True, op_types_to_quantize=['MatMul'], use_external_data_format=True)
elif kind == 'fp16':
    from onnxruntime.transformers.float16 import convert_float_to_float16
    m16 = convert_float_to_float16(m, keep_io_types=True, disable_shape_infer=True)
    onnx.save_model(m16, f'{dst}/{part}.onnx', save_as_external_data=True, all_tensors_to_one_file=True, location=f'{part}.onnx.data')
print(name, part, [(fn, os.path.getsize(f'{dst}/{fn}') // 2**20) for fn in sorted(os.listdir(dst))])
