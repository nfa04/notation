# Handwriting reader benchmark

Compares the handwriting readers on real ink, drawn the way the app draws it. Data lives outside the repo (`~/hw-bench`).

1. `python3 -P` a dump of the strokes of some pages to `select.json` (`[{id, strokes: [{c, b, pts}]}]`).
2. `flutter test tool/handwriting_bench/export_lines_test.dart --dart-define=SELECT=... --dart-define=OUT=...` cuts them into lines like the app's ink index and writes `lines.json`, `trocr/` and `paddle/` pictures.
3. Write `OUT/truth.json` (line id -> text) by hand for the lines worth scoring.
4. Readers: `run_paddle_onnx.py` (the app's PaddleOCR-VL files), `run_hf.py` (GLM-OCR, Paddle fp32, Florence-2 through transformers; needs `huggingface_hub<2` and `torchvision` in a venv), `render.py` (neutral pictures).
5. `score.py OUT` prints CER per reader (`-v` lists every line).

## GLM-OCR in the app (2026-11-10)

`glm_onnx/` makes the files the app downloads (`make_release.py` -> `~/hw-bench/glm_release/`: `vision.onnx`, `text.onnx`,
`embeddings.bin`, `SHA256SUMS`; the checksums are copied into `lib/ink/glm_ocr_service.dart`). They are published, with these scripts, a model card and the MIT notice,
at https://huggingface.co/nfa04/glm-ocr-onnx (`GlmOcrService.defaultRepo`); the card says it is the original GLM-OCR converted and
quantised, not retrained.
`glm_onnx/patches_check.py test/fixtures` writes the numbers `test/glm_ocr_test.dart` compares the Dart code with.
End to end with the real files: `integration_test/glm_ocr_onnx_test.dart` (the command is at the top of it).

Measured on 68 lines of the author's handwriting (CER, lower is better; LaTeX counts as errors): GLM-OCR fp32 11.2 %; 8-bit vision +
4-bit text 10.8 %; 4-bit vision 13.3-15.5 %; picture of 12 / 10 / 8 / 6 rows of patches 10.7 / 10.8 / 12.0 / 14.3 %; PaddleOCR-VL as the
app ran it 31.5 %; TrOCR 42.6 %; Florence-2 37.1 %.

(TrOCR, the reader the app shipped until 2026-11-10, was benchmarked with an earlier version of this folder; it was taken out of the app because of the IAM licence and its 42.6 % CER.)
