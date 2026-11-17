# Handwriting reader benchmark

Compares the handwriting readers on real ink, drawn the way the app draws it. Data lives outside the repo (`~/hw-bench`).

1. `python3 -P` a dump of the strokes of some pages to `select.json` (`[{id, strokes: [{c, b, pts}]}]`).
2. `flutter test tool/handwriting_bench/export_lines_test.dart --dart-define=SELECT=... --dart-define=OUT=...` cuts them into lines like the app's ink index and writes `lines.json` and `paddle/` pictures.
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
app ran it 31.5 %; Florence-2 37.1 %.

## Handwritten code (2026-11-17, `code/`)

Measures how well the readers do on code, and which simple repair rules (`code/repair.py`) would pay for themselves, before anything is
built into the app. Needs about 56 lines of the author's own handwriting.

1. `python3 -P code/make_sheet.py` prints the sheet (31 snippets in 10 languages, indentation included; `--md FILE` writes it as Markdown).
   Write it by hand on ONE page of a note, a line to a line, top to bottom, in order, a free line between snippets.
2. Dump the page and cut it into lines as in steps 1-2 above (`select.json`, `export_lines_test.dart`).
3. `python3 -P code/make_truth.py OUT` matches the lines to the sheet by order and writes `truth.json` + `truth_meta.json` (if the app cut
   the lines differently it lists where each line starts; `OUT/map.json` can name the right ones by hand).
4. Run the readers (`run_hf.py`, `glm_onnx/run_glm_onnx.py`) as usual: they read `truth.json`.
5. `python3 -P code/score_code.py OUT [-v]`: CER (also without spaces), lines right, how many of the symbols `{}[]()<>;:=...` came out
   right, CER by language, the most common mix-ups, what each repair rule does (CER change, lines helped / harmed), and how well the
   indentation can be told from where the lines start (the best size of one level, as a multiple of the line height).

`python3 -P code/selftest.py` checks the scripts with made-up lines. It already found that a repair rule must not treat a word that
differs from a keyword only by capitals as a mistake (the variable `list` is not Dart's `List`).

What decides the feature: symbols right (below ~90 % code is not usable without a code-aware step), whether `ALL` helps more lines than it
harms, and whether indentation is predictable from geometry (one level a stable multiple of the line height).
