import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';

void main() {
  test('a sharp patch cut on whole pixels still covers the bottom of the page (a slide of 362.8 x 272.1 pt, 1280 px wide)', () {
    // (the numbers of a lecture PDF on the tablet: the patch ended at 959 of 959.999 pixels, 0.62 of a unit short of the page)
    const paper = 800.0, width = 1280;
    final k = width / paper;
    final pageHeight = paper * 272.1260070800781 / 362.8349914550781;
    final fullHeight = width * 272.1260070800781 / 362.8349914550781;
    final patch = Rect.fromLTRB(0, 0, paper, fullHeight.floorToDouble() / k);
    final visible = Rect.fromLTRB(0, 0, paper, pageHeight);
    expect(sharpPatchCovers(patch, visible, paperWidth: paper, pixelWidth: width), isTrue);
    // (more than a pixel short is not covered: the patch is made again)
    expect(sharpPatchCovers(Rect.fromLTRB(0, 0, paper, pageHeight - 2), visible, paperWidth: paper, pixelWidth: width), isFalse);
  });
}
