import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/pdf/pdf_content_editor.dart';
import 'package:notes/pdf/pdf_stand_in_fonts.dart';

void main() {
  test('the names a PDF font may be installed under', () {
    expect(systemFamilyNames(const PdfFontInfo(name: 'BAAAAA+Symbola')), ['Symbola']);
    expect(systemFamilyNames(const PdfFontInfo(name: 'EAAAAA+LiberationSerif-Bold')), ['LiberationSerif', 'Liberation Serif']);
    expect(systemFamilyNames(const PdfFontInfo(name: 'DejaVuSans')), ['DejaVuSans', 'DejaVu Sans', 'Deja Vu Sans']);
    expect(systemFamilyNames(const PdfFontInfo(name: '')), isEmpty);
  });

  testWidgets('a font the PDF names is used when the device has it, and not when it has not', (tester) async {
    final file = File('assets/fonts/LiberationSerif-Regular.ttf');
    await tester.runAsync(() async {
      final loader = FontLoader('Symbola')..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
      await loader.load();
    });
    expect(systemFontInstalled(const PdfFontInfo(name: 'BAAAAA+Symbola')), isTrue);
    expect(systemFontInstalled(const PdfFontInfo(name: 'ZZZZZZ+NoSuchFontAnywhere')), isFalse);
    // and then it is the font the text is set in
    final style = standInStyle(const PdfFontInfo(name: 'BAAAAA+Symbola'), family: 'system');
    expect(style.fontFamily, 'Symbola');
  });
}
