# How models are downloaded

One mechanism, three layers. Anything that fetches a model or a runtime goes through it.

1. **Fetching** (`lib/llm/download.dart`, `downloadToFile`): one HTTP client for the whole app (timeouts, the bundled roots, a clear message
   for a certificate that is refused, and the browser variant that keeps the bytes in `lib/web/web_files_web.dart`).
2. **A model is a service** (`lib/llm/model_files.dart`, `ModelFilesService`): a folder under `models/`, a map `files` (name -> url, size),
   a status and progress for the settings. The base class does everything else:
   * each file goes to `<name>.part` and only takes its place when all of it came, so a model is never half there;
   * `checksums` (name -> SHA-256) pins the files **we publish ourselves**: a file that does not hash to it is thrown away and the download
     fails with "is not the one that was published". Files of other publishers (`onnx-community`, `Xenova`, `monkt`, LibreOffice) follow their
     `main` branch and are not pinned: they may change;
   * `keepExisting` services (the handwriting model, whose files change one at a time) leave files that are already right alone, and fetch a
     pinned file again if it is not the published one;
   * `remove`, `load` (are all files there), `sizeMb`.
   A subclass only says *which* files, and what it does with them once they are there (open, unload, drop unused files).
3. **A runtime pack** (`lib/llm/onnx_runtime_packs.dart`) is a folder of files with a `manifest.json` (every file with size and SHA-256), made
   by `tool/gpu_runtime/make_pack.sh`; it uses the same fetching and the same kind of check, and does not go through `models/`, because a
   runtime is not a model and is chosen at the start of the app.

## Rules

* Our own files (`nfa04/...` on Hugging Face or GitHub): **always pinned**. `test/model_downloads_test.dart` fails when a file of ours
  that a service downloads has no checksum.
* One service per kind of model. They do not share a catalogue on purpose: they differ in how they are opened and used.
* A new model: a `ModelFilesService` subclass with `files`, `folderName`, and `checksums` if we host it; a place in the settings; a German
  line for each new text (`test/german_coverage_test.dart`).
* Where a model is published: Hugging Face first (a browser can read it, GitHub's release files it cannot); a GitHub release only as a
  faster second place for big files (`MathService` does both, same checksums).
* A change of the files of a pinned model means new checksums in the same commit.

## Hosts today

| Service | Host | Pinned |
|---|---|---|
| Handwriting (GLM-OCR; vision 8-bit, 4-bit, 16-bit for graphics cards; text; words) | `nfa04/glm-ocr-onnx` | yes (all) |
| Formulas (TexTeller 8-bit) | `nfa04/texteller-onnx-8bit` (+ GitHub release) | yes |
| Formulas (pix2text, older) | `breezedeus/pix2text-mfr-1.5` | no |
| Background removal | `nfa04/u2netp-onnx` (+ rembg release) | yes |
| Assistant (Qwen) | `onnx-community/...` | no |
| Scan OCR (PaddleOCR) | `monkt/paddleocr-onnx` | no |
| Dictation (Whisper) | `onnx-community/whisper-*` | no |
| Search by meaning (MiniLM) | `Xenova/...` | no |
| PaddleOCR-VL | `onnx-community/PaddleOCR-VL-1.5-ONNX` | no |
| Spelling dictionaries | LibreOffice, hermitdave on GitHub | no |
| Runtime packs | `nfa04/onnxruntime-packs` (not uploaded yet) | manifest |

What is still not unified: the settings screens each draw their own download row; there is no single "downloaded models" overview with
disk use. The pins of other publishers' files would need us to mirror them first.
