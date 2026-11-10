import numpy as np, onnxruntime as ort, sys, glob, time, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from glm_parts import vision_pos_ids
root = os.path.expanduser('~/hw-bench/glm_onnx'); which = sys.argv[1] if len(sys.argv) > 1 else 'fp32'
opt = ort.SessionOptions(); opt.intra_op_num_threads = 4
s = ort.InferenceSession(f'{root}/{which}/vision.onnx', opt, providers=['CPUExecutionProvider'])
for f in sorted(glob.glob(f'{root}/ref/*.npz')):
    d = np.load(f); g = d['grid'][0]; t = time.time()
    o = s.run(None, {'pixel_values': d['pixel_values'].astype(np.float32), 'pos_ids': vision_pos_ids(int(g[1]), int(g[2]))})[0]
    print(os.path.basename(f), d['pixel_values'].shape, g, o.shape, 'maxdiff', float(np.abs(o - d['vis_out']).max()), 'rel', float(np.abs(o - d['vis_out']).mean() / np.abs(d['vis_out']).mean()), round(time.time() - t, 2), 's')
