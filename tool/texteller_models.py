#!/usr/bin/env python3
"""Makes the two 8-bit ONNX files of TexTeller 3.0 from the published float32 ones.

  encoder.onnx   the vision encoder, dynamic 8-bit quantisation              (about  88 MB)
  decoder.onnx   the text decoder with a key/value cache, 8-bit, with the     (about 229 MB)
                 first step and the later steps merged into one graph

Why the decoder is done in two parts: onnxruntime's quantiser does not look inside the `If` branches of a merged model, so
quantising the published `decoder_model_merged.onnx` leaves it at 909 MB. The decoder without a cache (first step) and the one
with a cache (later steps) are quantised on their own and merged afterwards; the merge shares the weights of the two branches.

usage: texteller_models.py OUT_DIR

The maintained copy of this script, with the pinned requirements and the upload steps, is the repository texteller-onnx-8bit
(next to this one); upload the results to the place `MathService.tellerRepo` (lib/ink/math_service.dart) points to.

The original files are downloaded from https://huggingface.co/OleehyO/TexTeller (Apache-2.0) into the Hugging Face cache.
"""
import hashlib
import os
import sys

import onnxruntime as ort
from huggingface_hub import hf_hub_download
from onnxruntime.quantization import QuantType, quantize_dynamic
from optimum.onnx.graph_transformations import merge_decoders

REPO = 'OleehyO/TexTeller'
#: pinned, so that the same files come out each time (the revision the files were made from)
REVISION = None  # None: the latest; set a commit hash of the Hugging Face repo to pin it


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def main(out: str) -> None:
    os.makedirs(out, exist_ok=True)
    fetch = lambda name: hf_hub_download(REPO, name, revision=REVISION)

    encoder = os.path.join(out, 'encoder.onnx')
    quantize_dynamic(fetch('encoder_model.onnx'), encoder, weight_type=QuantType.QInt8)
    print('encoder.onnx done', flush=True)

    first = os.path.join(out, 'first_step.tmp.onnx')
    later = os.path.join(out, 'later_steps.tmp.onnx')
    decoder = os.path.join(out, 'decoder.onnx')
    quantize_dynamic(fetch('decoder_model.onnx'), first, weight_type=QuantType.QInt8)
    quantize_dynamic(fetch('decoder_with_past_model.onnx'), later, weight_type=QuantType.QInt8)
    merge_decoders(first, later, save_path=decoder, strict=False)
    os.remove(first)
    os.remove(later)
    print('decoder.onnx done', flush=True)

    # the files must load, and have the inputs and outputs the readers expect
    enc = ort.InferenceSession(encoder, providers=['CPUExecutionProvider'])
    dec = ort.InferenceSession(decoder, providers=['CPUExecutionProvider'])
    assert [i.name for i in enc.get_inputs()] == ['pixel_values'], enc.get_inputs()
    assert enc.get_outputs()[0].shape[1:] == [785, 768], enc.get_outputs()[0].shape
    names = {i.name for i in dec.get_inputs()}
    assert {'input_ids', 'encoder_hidden_states', 'use_cache_branch'} <= names and len(names) == 51, names
    assert len(dec.get_outputs()) == 49, len(dec.get_outputs())

    with open(os.path.join(out, 'SHA256SUMS'), 'w') as f:
        for name in ('encoder.onnx', 'decoder.onnx'):
            path = os.path.join(out, name)
            f.write(f'{sha256(path)}  {name}\n')
            print(f'{name}: {os.path.getsize(path) / 1e6:.0f} MB')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
