"""Writes a CoreML cache key into a model's metadata (COREML_CACHE_KEY), and nothing else: the graph, and where it finds its weights
(external data), stay as they are.

  python add_cache_key.py MODEL.onnx OUT.onnx KEY

Why: ONNX Runtime names CoreML's cache folder by the key when the model has one, and by a hash of the model's PATH when it has not. On
iOS the app's folder can move (an app update), which would make CoreML build the model again; with a key it finds its cache wherever the
file is. The key must be letters and digits, at most 64 (coreml_execution_provider.cc). Other runtimes ignore the entry.
"""
import sys

import onnx


def main():
    src, dst, key = sys.argv[1:4]
    if not key.isalnum() or len(key) > 64:
        sys.exit('the key must be letters and digits, at most 64')
    m = onnx.load(src, load_external_data=False)
    entries = [p for p in m.metadata_props if p.key != 'COREML_CACHE_KEY']
    del m.metadata_props[:]
    m.metadata_props.extend(entries)
    m.metadata_props.add(key='COREML_CACHE_KEY', value=key)
    onnx.save(m, dst)
    print({p.key: p.value for p in m.metadata_props})


if __name__ == '__main__':
    main()
