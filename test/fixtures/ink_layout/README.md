# Ink layout fixtures

`mixed_pages.json` holds generated pages of handwriting-like text, formulas, matrices and doodles. Every stroke is stored with its right answer: `t: [block, row, kind]`, where kind is 0 for text, 1 for maths and 2 for a drawing.

`test/ink_layout_test.dart` scores how the app cuts these pages into blocks and lines. `baseline.json` records which page passed which check, so that a case that used to be right and breaks fails the test.

To make the pages again:

    python3 tool/ink_fixtures/make_mixed_pages.py HERSHEY_DIR QUICKDRAW_DIR test/fixtures/ink_layout/mixed_pages.json

The same seed gives the same pages. If the pages are made again, also update the baseline: `flutter test test/ink_layout_test.dart --update-goldens`.

The pages of the owner's own notes are not here. They live in `test/fixtures/ink_layout_private/`, which git ignores, and must never be committed.

## Sources and licences

Letters and digits are glyphs of the Hershey fonts, from `scripts.jhf` and `futural.jhf` in https://github.com/kamalmostafa/hershey-fonts. Every letter is bent and shaken differently.

- The Hershey Fonts were originally created by Dr. A. V. Hershey while working at the U. S. National Bureau of Standards.
- The format of the Font data in this distribution was originally created by James Hurt, Cognition, Inc., 900 Technology Park Drive, Billerica, MA 01821 (mit-eddie!ci-dandelion!hurt).

Doodles are drawings from the Quick, Draw! Dataset (simplified), categories bicycle, car, cat, cloud, eye, flower, house, star, sun and tree. That data was made available by Google, Inc. under the Creative Commons Attribution 4.0 International licence (https://creativecommons.org/licenses/by/4.0/), at https://quickdraw.withgoogle.com/data. The drawings here are scaled and placed on generated pages.

Signs such as fraction bars, brackets, sum signs, roots and arrows are drawn by the generator itself.
