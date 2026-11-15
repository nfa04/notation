# Graphics card runtimes on Linux

The ONNX Runtime that comes with the app runs on the processor only. For a graphics card the app opens a **runtime pack** instead:
a folder with a whole ONNX Runtime (`libonnxruntime.so` and the provider libraries of the same build next to it). Settings > AI >
*Graphics card runtime* lists the packs and saves the pick; it takes effect when the app is started again.

Packs go in `<app data folder>/onnx_runtimes/<name>/` (on Linux `~/.local/share/<app id>/onnx_runtimes/`; the settings screen shows the
exact folder). Under the hood the choice is one line in `~/.config/flutter_onnxruntime/library` (or the environment variable
`FLUTTER_ONNXRUNTIME_LIBRARY`): the path of the `libonnxruntime.so`. If it cannot be opened the bundled runtime is used and the
settings say why.

## Download in the app

Settings > AI > *Graphics card runtime* has a **Download** button for the pack that fits the machine (found from the NVIDIA driver, `/dev/kfd`
for AMD, an Intel display adapter or NPU). It fetches `manifest.json` and the files listed in it from
`https://huggingface.co/nfa04/onnxruntime-packs/resolve/main/<kind>/`, checks each file's SHA-256, moves the finished pack into the packs
folder and selects it for the next start. The host is the constant `onnxRuntimePackHost` in `lib/llm/onnx_runtime_packs.dart`.
**Nothing is uploaded there yet**: run `make_pack.sh` for each kind (it also writes `manifest.json`) and upload the folder's content to
`<kind>/`. The pack's folder name (the manifest's `name`) must start with the kind (`cuda12-...`) so the list knows it is downloaded.

## Making a pack

    tool/gpu_runtime/make_pack.sh cuda12|cuda13|migraphx|openvino <folder>

| Pack | Hardware | Made from | The system must have |
|---|---|---|---|
| `cuda12`, `cuda13` | NVIDIA | Microsoft's GPU build of the same version as the app's runtime (MIT) | the driver, CUDA 12 / 13 runtime and cuDNN (NVIDIA's licence: install them from NVIDIA, they are not in the pack) |
| `migraphx` | AMD (RDNA/CDNA with ROCm) | AMD's wheel (ORT 1.23) and MIGraphX package (MIT) | ROCm of the same version (hip, hiprtc, MIOpen, rocBLAS, hipBLASLt); `/dev/kfd` |
| `openvino` | Intel CPU / iGPU / NPU | Intel's wheel and the OpenVINO runtime (Apache-2.0) | the Intel compute runtime / NPU driver |

The app's own licence has an additional permission for these libraries (LICENSE-EXCEPTION).

## What was measured (AMD Radeon 780M, ROCm 7.1, 2026-11-12)

* MIGraphX works on the 780M (gfx1103) without `HSA_OVERRIDE_GFX_VERSION`. A 12-layer 1536-wide network: 26 ms against 76 ms on the
  CPU (3x), same output.
* The GLM vision encoder (fp32, 1024 patches): 1.4 s against 1.8-2.1 s on the CPU (1.3x), and the first open **compiles for 4.7 minutes**
  (MIGraphX compiles for fixed shapes; the compiled model is kept in `~/.cache/flutter_onnxruntime/migraphx` and opens in a second
  after that). Every new number of patches compiles again, so the reader would have to pad to a few fixed sizes first.
* Two HIP runtimes in one process break the provider ("std::get: wrong index for variant"); the pack takes the system's hip.
* CUDA and OpenVINO packs are built by the script but were not run: there is no such hardware on the development machine.
