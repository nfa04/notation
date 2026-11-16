"""Can CoreML run the GLM-OCR vision network (vision-gpu.onnx), and how far is its answer from the processor's?

The app's own check (integration_test/coreml_check_test.dart) found that CoreML cannot build this network as an MLProgram
("error code: -14" on the dynamic part). The network's input size is a free dimension ('4*m': four patches per token); pinning it with
a free dimension override makes every shape fixed. This tries that, one way per process (a hang cannot stop the others):

  python probe_glm_vision.py MODEL OUT_DIR reference ROWSxCOLS          # the processor's answer, kept as a .npy
  python probe_glm_vision.py MODEL OUT_DIR coreml ROWSxCOLS UNITS STATIC  # UNITS: ALL, CPUAndGPU, CPUAndNeuralEngine, CPUOnly; STATIC 0/1
  python probe_glm_vision.py PROBE_MODEL OUT_DIR bisect ROWSxCOLS MAP UNITS  # (add_outputs.py) each inner tensor against the processor
  python probe_glm_vision.py MODEL OUT_DIR lines LINES_DIR WAY             # WAY: cpu or a CoreML UNITS (static): NN.<way> features of
                                                                          # every picture (tool/coreml_probe/make_lines.py), for read_lines.py

Prints one JSON line per run ("probe-result ..."). The picture is made here: white paper with wavy pen lines, normalised and cut into
patches like lib/ink/glm_ocr.dart does, so the numbers inside the network have their real range (the fp16 overflow depends on it).
"""
import json
import os
import sys
import time

import numpy as np
import onnxruntime as ort

PATCH = 14
MEAN = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)
SPREAD = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)


def picture(rows, cols):
    """A line of handwriting stand-in: (rows*14) x (cols*14) grey pixels, ink 0, paper 255."""
    h, w = rows * PATCH, cols * PATCH
    img = np.full((h, w), 255, dtype=np.float32)
    xs = np.arange(int(w * 0.04), int(w * 0.96))
    for word in range(max(1, cols // 12)):
        start = word * w / max(1, cols // 12)
        for x in xs[(xs >= start + 6) & (xs < start + w / max(1, cols // 12) - 10)]:
            y = h / 2 + h * 0.22 * np.sin((x - start) / 6.0) + h * 0.1 * np.cos((x - start) / 2.3)
            y0, y1 = int(max(0, y - 3)), int(min(h, y + 3))
            img[y0:y1, max(0, x - 1):x + 2] = 0
    return img


def patches(img, rows, cols):
    """Like glmPatches: blocks of 2x2 patches, each patch 3 colours x 2 frames x 14 x 14."""
    out = []
    for by in range(rows // 2):
        for bx in range(cols // 2):
            for my in range(2):
                for mx in range(2):
                    y0, x0 = (by * 2 + my) * PATCH, (bx * 2 + mx) * PATCH
                    tile = img[y0:y0 + PATCH, x0:x0 + PATCH] / 255.0
                    one = []
                    for c in range(3):
                        v = (tile - MEAN[c]) / SPREAD[c]
                        one += [v, v]
                    out.append(np.stack(one).reshape(-1))
    return np.stack(out).astype(np.float32)


def positions(rows, cols):
    out = []
    for by in range(rows // 2):
        for bx in range(cols // 2):
            for my in range(2):
                for mx in range(2):
                    out.append([by * 2 + my, bx * 2 + mx])
    return np.array(out, dtype=np.int64)


def open_session(model, out_dir, way, count, label):
    so = ort.SessionOptions()
    so.log_severity_level = 2
    if way == 'cpu':
        return ort.InferenceSession(model, so, providers=['CPUExecutionProvider'])
    so.add_free_dimension_override_by_name('4*m', count)
    cache = os.path.join(out_dir, f'cache-lines-{way}-{label}')
    os.makedirs(cache, exist_ok=True)
    return ort.InferenceSession(model, so, providers=[
        ('CoreMLExecutionProvider', {'ModelFormat': 'MLProgram', 'MLComputeUnits': way, 'ModelCacheDirectory': cache}), 'CPUExecutionProvider'])


def lines(model, out_dir, lines_dir, way):
    """Features of every picture of [lines_dir] with [way], one session per picture size (as the app would keep one per width)."""
    from PIL import Image
    sessions = {}
    for f in sorted(x for x in os.listdir(lines_dir) if x.endswith('.png')):
        img = np.asarray(Image.open(os.path.join(lines_dir, f)).convert('L'), dtype=np.float32)
        rows, cols = img.shape[0] // PATCH, img.shape[1] // PATCH
        label = f'{rows}x{cols}'
        feeds = {'pixel_values': patches(img, rows, cols), 'pos_ids': positions(rows, cols)}
        result = {'mode': 'lines', 'way': way, 'file': f, 'size': label}
        t = time.time()
        if label not in sessions:
            sessions[label] = open_session(model, out_dir, way, feeds['pixel_values'].shape[0], label)
            result['openS'] = round(time.time() - t, 2)
        t = time.time()
        answer = sessions[label].run(None, feeds)[0]
        result['runS'] = round(time.time() - t, 3)
        answer.astype(np.float32).tofile(os.path.join(out_dir, f'{f[:-4]}.{way}'))
        print('probe-result', json.dumps(result), flush=True)


def bisect(model, out_dir, size, map_file, units):
    """[model] is a copy with the tensors inside the blocks as outputs (add_outputs.py, labels in [map_file]): how far each is from the
    processor's, and how large its numbers are, so that the place where CoreML's answer moves away shows."""
    rows, cols = (int(v) for v in size.split('x'))
    feeds = {'pixel_values': patches(picture(rows, cols), rows, cols), 'pos_ids': positions(rows, cols)}
    count = feeds['pixel_values'].shape[0]
    labels = dict(line.rstrip('\n').split('\t')[::-1] for line in open(map_file))
    answers = {}
    for way in ('cpu', units):
        so = ort.SessionOptions()
        so.log_severity_level = 2
        so.add_free_dimension_override_by_name('4*m', count)
        if way == 'cpu':
            providers = ['CPUExecutionProvider']
        else:
            cache = os.path.join(out_dir, f'cache-bisect-{way}-{size}')
            os.makedirs(cache, exist_ok=True)
            providers = [('CoreMLExecutionProvider', {'ModelFormat': 'MLProgram', 'MLComputeUnits': way, 'ModelCacheDirectory': cache}), 'CPUExecutionProvider']
        session = ort.InferenceSession(model, so, providers=providers)
        names = [o.name for o in session.get_outputs()]
        t = time.time()
        answers[way] = dict(zip(names, session.run(None, feeds)))
        print('probe-result', json.dumps({'mode': 'bisect', 'way': way, 'size': size, 'runS': round(time.time() - t, 2)}), flush=True)
        del session
    for name in names:
        ref = answers['cpu'][name].astype(np.float64)
        got = answers[units][name].astype(np.float64)
        rel = float(np.linalg.norm(got - ref) / max(np.linalg.norm(ref), 1e-30))
        row = {'mode': 'bisect', 'size': size, 'units': units, 'at': labels.get(name, name), 'relativeError': round(rel, 5),
               'largest': round(float(np.abs(ref).max()), 2), 'rms': round(float(np.sqrt((ref ** 2).mean())), 3),
               'largestDifference': round(float(np.abs(got - ref).max()), 4)}
        print('probe-result', json.dumps(row), flush=True)


def main():
    if sys.argv[3] == 'bisect':
        bisect(sys.argv[1], sys.argv[2], sys.argv[4], sys.argv[5], sys.argv[6])
        return
    if sys.argv[3] == 'lines':
        lines(sys.argv[1], sys.argv[2], sys.argv[4], sys.argv[5])
        return
    model, out_dir, way, size = sys.argv[1:5]
    rows, cols = (int(v) for v in size.split('x'))
    feeds = {'pixel_values': patches(picture(rows, cols), rows, cols), 'pos_ids': positions(rows, cols)}
    count = feeds['pixel_values'].shape[0]
    so = ort.SessionOptions()
    so.log_severity_level = 1  # (info: the CoreML provider says how many nodes it took, in how many pieces)
    result = {'size': size, 'patches': count, 'way': way}
    if way == 'reference':
        providers = ['CPUExecutionProvider']
    else:
        units, static = sys.argv[5], sys.argv[6] == '1'
        result.update(units=units, static=static)
        if static:
            so.add_free_dimension_override_by_name('4*m', count)
        # (CoreML keys its cache by the model's path only: every size needs a folder of its own, or it gets another size's model)
        cache = os.path.join(out_dir, f'cache-{units}-{int(static)}-{size}')
        os.makedirs(cache, exist_ok=True)
        providers = [('CoreMLExecutionProvider', {'ModelFormat': 'MLProgram', 'MLComputeUnits': units, 'ModelCacheDirectory': cache}),
                     'CPUExecutionProvider']
    t = time.time()
    try:
        session = ort.InferenceSession(model, so, providers=providers)
    except Exception as e:  # noqa: BLE001
        result['error'] = str(e)[:600]
        print('probe-result', json.dumps(result), flush=True)
        return
    result['openS'] = round(time.time() - t, 2)
    times = []
    answer = None
    for i in range(3):
        t = time.time()
        answer = session.run(None, feeds)[0]
        times.append(round(time.time() - t, 3))
    result['firstS'], result['runS'] = times[0], sorted(times[1:])[len(times[1:]) // 2]
    ref_file = os.path.join(out_dir, f'ref-{size}.npy')
    if way == 'reference':
        np.save(ref_file, answer)
    elif os.path.exists(ref_file):
        ref = np.load(ref_file)
        if ref.shape != answer.shape:
            result['error'] = f'shape {answer.shape} against {ref.shape}'
        else:
            result['relativeError'] = float(np.linalg.norm(answer - ref) / np.linalg.norm(ref))
            result['largestDifference'] = float(np.abs(answer - ref).max())
            result['nan'] = bool(np.isnan(answer).any())
    print('probe-result', json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
