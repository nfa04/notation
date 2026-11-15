# AI support: where things stand (2026-11-12)

Everything below runs on the device with ONNX Runtime through the local plugin `packages/flutter_onnxruntime`, except the optional
cloud provider. "Verified" means it was run on the development machine (Linux, AMD Ryzen 7 8845HS, Radeon 780M, no NVIDIA or Intel
hardware). Everything in this file is uncommitted work unless it says otherwise.

## 1. What uses a model

| Feature | Model (download) | Where it runs | Accelerator |
|---|---|---|---|
| Built-in assistant, summaries, quiz, titles | Qwen 0.5B ... 14B (see 2.) | processor, always | no: text models decode one token at a time, and the Qwen3.5 operators are not in MIGraphX or OpenVINO |
| Handwriting reader | GLM-OCR: vision (8-bit 430 MB, or 4-bit `vision-web.onnx` 261 MB), text 4-bit 310 MB, words 91 MB (`nfa04/glm-ocr-onnx`) | vision network may use the accelerator, the text model never | see 4. |
| Formula reader | TexTeller encoder 88 MB + decoder 229 MB (`nfa04/texteller-onnx-8bit`); pix2text as the older choice | encoder may use the accelerator | works on MIGraphX with the installed 8-bit file: 148 ms (an fp32 file 111 ms, the processor 320 ms with fp32); first compile 3 min, then cached. The AMD runtime's own processor build lacks `ConvInteger`, so this file cannot fall back to the processor there |
| Scan OCR | PaddleOCR detector + recogniser per language (`monkt/paddleocr-onnx`) | both may use the accelerator | not tried |
| Background removal | u2netp 5 MB | may use the accelerator | not tried |
| Dictation | Whisper tiny/base (`onnx-community`) | encoder may use the accelerator, decoder not | encoder (fp32, no quantised ops) 70 ms on MIGraphX against 200 ms on the processor for 30 s of audio; first compile 1 min, cached |
| Search by meaning | multilingual MiniLM, quantised | processor | no |
| Cloud assistant | any OpenAI-compatible endpoint (`openai_provider.dart`) | remote | n/a |

Each feature has its own `ModelFilesService` subclass (download, progress, folder under `models/`). They do not share a catalogue.

## 2. The on-device assistant

* Models are `ChatModelSpec`s in `lib/llm/chat_models.dart`, smallest first: Qwen3.5 0.8B, Qwen2.5 0.5B, Qwen3 0.6B,
  Qwen2.5 1.5B, Qwen3.5 2B, Qwen3 1.7B, Qwen3.5 4B, Qwen3 4B-2507, Qwen3 8B, Qwen3 14B. 4-bit weights, 32-bit cache.
* Qwen3.5 is a hybrid (three of four layers are linear attention), so a token costs about a quarter of Qwen3's. The 2B and 4B only
  exist as multimodal split exports: the app runs the decoder plus a separate word-embedding model and leaves the vision part out
  (`embedFile`). Measured in the app on the CPU: 0.8B 51 tokens in 3.3 s, 2B 24 tokens in 2.9 s, 4B 40 tokens in 7.4 s.
* **Models under 1B are hidden** in the picker until "Show extra small models" is pressed (still shown when selected or downloaded).
* **Default** with no choice: the biggest model that fits and is at most a 2.2 GB download; a device with 10 GB or more to use
  starts with Qwen3.5 4B (3.1 GB).
* **Memory rule:** a model is offered when the device's usable memory is at least its `minRamMb`. On iOS and iPadOS usable is 70 % of
  the physical memory (`usableRamMb`, `lib/ai/device_memory.dart`); elsewhere all of it. `ios/Runner/Runner.entitlements` asks for
  `com.apple.developer.kernel.increased-memory-limit` (about 12 GB instead of 5 GB on a 16 GB iPad Pro; figures from developer
  reports, not Apple). Not tried on a device; the provisioning profile may need the capability.
* Not done: Qwen3.5 9B; an export with `num_logits_to_keep` (the 2B/4B compute scores for every prompt position); the Qwen3 GPU
  export (36 ms/token on MIGraphX against 65 ms CPU) was not hosted, because Qwen3.5 0.8B on the CPU (17 ms) beats it.

## 3. Acceleration

* **Setting** (Settings > AI > Run models on): "Accelerator when available" / "Processor only". Models opened with
  `openOnnxSession(..., accelerate: true)` get the accelerators of `onnxPlatformAccelerators()`; `accelerate: false` is chosen per call site.
* **macOS / iOS:** CoreML. **Android:** NNAPI. **Browser:** WebGPU. None of these were run in this work.
* **Linux:** the bundled ONNX Runtime 1.28.3 is the processor build. A graphics card needs a **runtime pack** (a whole ONNX Runtime
  with the provider libraries), chosen in the same settings section and used from the next start. Kinds: `cuda12`, `cuda13`
  (Microsoft's GPU build), `migraphx` (AMD's ORT 1.23.1 + MIGraphX, uses the system ROCm), `openvino` (Intel). Built by
  `tool/gpu_runtime/make_pack.sh`, which also writes `manifest.json`. The settings screen has a Download button for the pack that
  fits the machine; the host (`nfa04/onnxruntime-packs` on Hugging Face) **is empty**, so it fails today. Details: `docs/gpu-runtime-packs.md`.
* **Windows:** processor only. DirectML would be the way; not started.
* The AGPL section 7 exception for the vendor libraries is in `LICENSE-EXCEPTION`. The packs do not yet carry the upstream licence
  texts (needed for MIT and Apache-2.0), and AMD's MIGraphX package licence was not read.
* **Verified** (780M, MIGraphX): a 12-layer MLP 3x faster; TexTeller encoder compiles in about 3 min, then is cached;
  GLM vision fp32 1.4 s against 1.8-2.1 s on the CPU; **GLM vision fp16 0.24-0.35 s** (about 6x); compile 4-5 min per input size.
* **Not verified:** CUDA and OpenVINO packs (never run), a GTX 1050 Mobile (Pascal; may lack kernels in current builds), CoreML, NNAPI.

## 4. Why the AMD path is not usable yet

1. **MIGraphX compiles for exact input sizes**, 3-5 min each, cached in `~/.cache/flutter_onnxruntime/migraphx`. It has no generic
   kernels (the old ROCm provider that had them was removed in ONNX Runtime 1.23).
2. **The handwriting vision model changes size with every line** (the width is a multiple of 28 pixels), so it would compile for
   almost every line.
3. **The file the app uses is quantised.** `vision-web.onnx` (4-bit) has 126 `MatMulNBits` nodes; the 8-bit `vision.onnx` is
   quantised too. MIGraphX cannot run those operators, so it cuts the graph into many pieces, compiles each, and runs the rest on the
   processor (symptom: the processor at 170 %, memory growing, the GPU idle). The fast result above was with an **unquantised** file.

## 5. Built since (same day, uncommitted, not yet run on the GPU through the app)

* **fp16 vision file** `vision-gpu.onnx` (+ `.data`, 870 MB) published in `nfa04/glm-ocr-onnx`. Same readings as fp32 on the 68 benchmark lines
  (CER 11.1 % both; the 4-bit text model was used for all). New choice `GlmWeights.gpu` in Settings > Handwriting > Size of the model, shown
  where a graphics card runtime is active. A quantised vision file is no longer sent to MIGraphX (it stays on the processor).
* **Pad to fixed sizes** (Settings > AI > Run models on): default on, locked on while MIGraphX is the accelerator. Pictures get one of the widths
  in `glmPaddedWidths` (7 distinct widths on the benchmark instead of 66, 21 % more patches). **Measured cost: CER 11.1 % -> 12.5 %** (23 -> 20 of 68
  lines exact). On the processor it only costs time and accuracy, so switch it off there.
* **CPU fallback while a plan compiles** (`lib/llm/warm_session.dart`): with an accelerator that compiles per input size (MIGraphX), the
  vision network, the formula encoder and the Whisper encoder open as a `WarmSession`: a size with no plan yet is read on the processor at
  once, while the accelerator makes the plan on a thread of its own (the plugin's new `ownThread` session option, Linux: otherwise the
  compile blocks every session on the same worker); a plan on disk is loaded within 4 s and used. One plan at a time; the rest read on the
  processor. If the processor part of the pack cannot open the file (8-bit formula encoder), the plan is waited for. Models with variable
  sizes and no fallback yet (scan OCR, PaddleOCR-VL, the older formula model) now stay on the processor under MIGraphX. Tested with stand-in
  engines only; **not run against the real plugin** (an integration test cannot launch while the user's own app is open).
* **Model downloads** were consolidated: see `docs/model-downloads.md` (checksums in the base class, a test that every file of ours is pinned).
* Not built: timing the fp16 file on the GPU through the app (each of the 7 widths is a
  4-5 minute first compile); Windows.

## 6. What is messy (honest list)

* One download service per feature, with different file hosts (Hugging Face, GitHub releases, nfa04 mirrors).
* Three handwriting readers in the tree (GLM-OCR standard, PaddleOCR-VL, the older pix2text path for formulas); only GLM and
  TexTeller are the standard ones.
* `accelerate: true/false` is decided at each call site, with no rule about which model kinds can use it; nothing tells the user
  that the file they installed cannot run on the accelerator they selected.
* The settings show the runtime packs, but nothing yet checks that a selected pack matches the installed model files.
* The plugin's Linux code grew a worker-thread layer (low-priority sessions) and the runtime-pack loader. A bug there (an
  unconstructed `std::set`) crashed the app on formula detection today; it is fixed, with no regression test. Windows and macOS plugin code was not touched.
* All of this is uncommitted (see `git status`); the full test suite has not been run since today's changes (the AI, LLM, German
  coverage and runtime-pack tests pass).
