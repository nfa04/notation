"""Quantises the exported graphs.  python3 quantize.py int8|int4 [block_size]  ->  ~/hw-bench/glm_onnx/<mode>/{vision,text}.onnx (+ .data)
int8: dynamic, per channel, weights of MatMul/Gemm in 8 bits.  int4: MatMulNBits, 4-bit blocks (default 32), symmetric."""
import os, sys, shutil, onnx
from onnxruntime.quantization import quantize_dynamic, QuantType
root = os.path.expanduser('~/hw-bench/glm_onnx'); mode = sys.argv[1]; BITS = 8 if mode == 'int8w' else 4; block = int(sys.argv[2]) if len(sys.argv) > 2 else 32
dst = f'{root}/{mode}'; shutil.rmtree(dst, ignore_errors=True); shutil.rmtree(f'{root}/tmp', ignore_errors=True); os.makedirs(dst, exist_ok=True)   # (the external data file is appended to, not replaced)
def gemm_to_matmul(m):
    # the dynamo exporter writes every Linear as a Gemm; the 4-bit quantiser only takes MatMul (the weights of a Gemm stay 32-bit)
    import numpy as np
    from onnx import helper, numpy_helper
    inits = {i.name: i for i in m.graph.initializer}
    new, count = [], 0
    for n in m.graph.node:
        if n.op_type == 'Gemm' and n.input[1] in inits:
            a = {x.name: helper.get_attribute_value(x) for x in n.attribute}
            if a.get('alpha', 1.0) == 1.0 and a.get('beta', 1.0) == 1.0 and not a.get('transA', 0):
                w = numpy_helper.to_array(inits[n.input[1]])
                if a.get('transB', 0): w = w.T
                wname = n.input[1] + '_t'
                m.graph.initializer.append(numpy_helper.from_array(np.ascontiguousarray(w), wname))
                mm = n.output[0] + '_mm' if len(n.input) > 2 else n.output[0]
                new.append(helper.make_node('MatMul', [n.input[0], wname], [mm], name=n.name + '_mm'))
                if len(n.input) > 2: new.append(helper.make_node('Add', [mm, n.input[2]], [n.output[0]], name=n.name + '_add'))
                count += 1
                continue
        new.append(n)
    del m.graph.node[:]; m.graph.node.extend(new)
    used = {i for n in m.graph.node for i in n.input}
    keep = [i for i in m.graph.initializer if i.name in used]
    del m.graph.initializer[:]; m.graph.initializer.extend(keep)
    print('Gemm -> MatMul:', count)

def stripped(part):
    # the exporter's shape notes (value_info) disagree with onnx's own inference for the patch weight; they are not needed
    m = onnx.load(f'{root}/fp32/{part}.onnx')
    del m.graph.value_info[:]
    if mode != 'int8': gemm_to_matmul(m)
    os.makedirs(f'{root}/tmp', exist_ok=True)
    onnx.save_model(m, f'{root}/tmp/{part}.onnx', save_as_external_data=True, all_tensors_to_one_file=True, location=f'{part}.onnx.data')
    return f'{root}/tmp/{part}.onnx'

for part in ('vision', 'text'):
    src = stripped(part)
    if mode == 'int8':
        quantize_dynamic(src, f'{dst}/{part}.onnx', weight_type=QuantType.QInt8, per_channel=True, op_types_to_quantize=['MatMul', 'Gemm'], use_external_data_format=True)
    else:
        from onnxruntime.quantization.matmul_nbits_quantizer import MatMulNBitsQuantizer
        m = onnx.load(src)
        q = MatMulNBitsQuantizer(m, block_size=block, is_symmetric=True, bits=BITS)
        q.process()
        q.model.save_model_to_file(f'{dst}/{part}.onnx', use_external_data_format=True)
    print(part, 'done', [(f, os.path.getsize(f'{dst}/{f}') // 2**20) for f in os.listdir(dst) if f.startswith(part)])
