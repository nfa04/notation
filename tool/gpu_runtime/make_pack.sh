#!/usr/bin/env bash
# Makes a runtime pack (a folder with a whole ONNX Runtime that has the providers of a graphics card) for the app on Linux x86-64.
#
#   make_pack.sh cuda12|cuda13|migraphx|openvino  <output folder>
#
# The folder it writes (<output>/<name>) goes into the app's data folder, in `onnx_runtimes` (the settings screen lists it from
# there); see docs/gpu-runtime-packs.md. Needs: curl, unzip, tar, python3 (a venv is made for patchelf), rpm2cpio + cpio (migraphx).
# What a pack does NOT contain is the driver and the vendor's own big libraries: CUDA/cuDNN (cuda packs), ROCm (migraphx pack: the
# system's hip, hiprtc, MIOpen, rocBLAS are used), the Intel GPU/NPU drivers (openvino pack).
set -euo pipefail

kind=${1:?cuda12|cuda13|migraphx|openvino}
out=${2:?output folder}
ORT_VERSION=${ORT_VERSION:-1.28.3}          # cuda packs: same as the runtime bundled with the app
ROCM=${ROCM:-7.1}                           # migraphx pack: the ROCm version of the system (7.1 -> the wheel/rpm of AMD's 7.1)
OPENVINO_ORT=${OPENVINO_ORT:-1.24.1}        # openvino pack: onnxruntime-openvino wheel on PyPI

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"
venv="$work/venv"

patchelf_bin() {
  if command -v patchelf >/dev/null; then command -v patchelf; return; fi
  python3 -m venv "$venv" && "$venv/bin/pip" -q install patchelf >/dev/null
  echo "$venv/bin/patchelf"
}

case "$kind" in
  cuda12|cuda13)
    # Microsoft's own build with the CUDA provider. The user needs the CUDA ${kind#cuda} runtime and cuDNN on the system (libcudart,
    # libcublas, libcudnn ...): the provider says so itself when it cannot find them.
    name="cuda-${kind#cuda}-ort-$ORT_VERSION"
    curl -fL -o "$work/ort.tgz" "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/onnxruntime-linux-x64-gpu_${kind}-$ORT_VERSION.tgz"
    tar -xzf "$work/ort.tgz" -C "$work"
    src=$(echo "$work"/onnxruntime-linux-x64-gpu*)
    rm -rf "$out/$name"; mkdir -p "$out/$name"
    cp -a "$src"/lib/libonnxruntime* "$out/$name/"
    cp "$src/LICENSE" "$out/$name/" 2>/dev/null || true
    ;;
  migraphx)
    # AMD's build of ONNX Runtime with the MIGraphX provider (from their wheel) and AMD's MIGraphX libraries (from their package,
    # MIT licensed), made to use the hip of the system: a second copy of the HIP runtime in one process breaks the provider.
    name="migraphx-rocm-$ROCM"
    pe=$(patchelf_bin)
    whl=$(curl -fsL "https://repo.radeon.com/rocm/manylinux/rocm-rel-$ROCM/" | grep -oE 'onnxruntime_migraphx-[^"]*cp312[^"]*\.whl' | head -1)
    rpm=$(curl -fsL "https://repo.radeon.com/rocm/rhel9/$ROCM/main/" | grep -oE 'href="migraphx-[0-9][^"]*\.rpm"' | head -1 | sed 's/href="//;s/"//')
    [ -n "$whl" ] && [ -n "$rpm" ] || { echo "no wheel or rpm found for ROCm $ROCM"; exit 1; }
    curl -fL -o "$work/w.whl" "https://repo.radeon.com/rocm/manylinux/rocm-rel-$ROCM/$whl"
    curl -fL -o "$work/m.rpm" "https://repo.radeon.com/rocm/rhel9/$ROCM/main/$rpm"
    mkdir "$work/w" "$work/m"
    (cd "$work/w" && unzip -q ../w.whl)
    (cd "$work/m" && rpm2cpio ../m.rpm | cpio -idm 2>/dev/null)
    rm -rf "$out/$name"; mkdir -p "$out/$name/lib"
    cp -a "$work"/w/onnxruntime/capi/libonnxruntime* "$out/$name/"
    mig=$(echo "$work"/m/opt/rocm-*/lib)
    cp -a "$mig"/libmigraphx_c.so* "$out/$name/lib/"
    mkdir -p "$out/$name/lib/migraphx"
    cp -a "$mig"/migraphx/lib "$out/$name/lib/migraphx/"
    # the provider: look next to itself and in lib/, and take the hip of the system
    "$pe" --set-rpath '$ORIGIN:$ORIGIN/lib' "$out/$name/libonnxruntime_providers_migraphx.so"
    "$pe" --replace-needed "$(readelf -d "$out/$name/libonnxruntime_providers_migraphx.so" | grep -oE 'libamdhip64-[^]]*')" libamdhip64.so.7 "$out/$name/libonnxruntime_providers_migraphx.so"
    # MIGraphX's own libraries: where they look is already $ORIGIN-relative
    ;;
  openvino)
    # Intel's build of ONNX Runtime with the OpenVINO provider (their wheel) and the OpenVINO runtime (the `openvino` wheel, Apache-2.0).
    name="openvino-ort-$OPENVINO_ORT"
    pe=$(patchelf_bin)
    pip3 download --no-deps --only-binary=:all: --python-version 3.12 --platform manylinux_2_28_x86_64 -d "$work/d" "onnxruntime-openvino==$OPENVINO_ORT" >/dev/null
    ov=$(unzip -p "$work"/d/onnxruntime_openvino-*.whl '*/METADATA' | grep -iE '^Requires-Dist: openvino[ =(<>~]' | head -1 | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -1)
    pip3 download --no-deps --only-binary=:all: --python-version 3.12 --platform manylinux2014_x86_64 -d "$work/d" "openvino==${ov:?no openvino version in the metadata}" >/dev/null
    mkdir "$work/w" "$work/o"
    (cd "$work/w" && unzip -q ../d/onnxruntime_openvino-*.whl)
    (cd "$work/o" && unzip -q ../d/openvino-*.whl)
    rm -rf "$out/$name"; mkdir -p "$out/$name"
    cp -a "$work"/w/onnxruntime/capi/libonnxruntime* "$out/$name/"
    cp -a "$work"/o/openvino/libs/* "$out/$name/"
    for f in "$out/$name"/*.so*; do [ -L "$f" ] || "$pe" --set-rpath '$ORIGIN' "$f" 2>/dev/null || true; done
    ;;
  *) echo "unknown kind: $kind"; exit 1;;
esac

# manifest.json for the download in the app: upload the folder's files and this to nfa04/onnxruntime-packs/<kind>/
python3 - "$out/$name" "$kind" <<'PY'
import hashlib, json, os, sys
root, kind = sys.argv[1], sys.argv[2]
files = []
for dp, _, fs in os.walk(root):
    for f in sorted(fs):
        path = os.path.join(dp, f)
        rel = os.path.relpath(path, root)
        if rel == "manifest.json":
            continue
        if os.path.islink(path):
            files.append({"path": rel, "link": os.readlink(path)})
        else:
            files.append({"path": rel, "bytes": os.path.getsize(path), "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest()})
json.dump({"name": os.path.basename(root), "files": files}, open(os.path.join(root, "manifest.json"), "w"), indent=1)
PY

echo "pack written: $out/$name"
