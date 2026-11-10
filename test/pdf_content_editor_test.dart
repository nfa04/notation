import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/pdf/pdf_content_editor.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart' show Pdfrx;

void main() {
  // needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
  final pdfium = File('build/native_assets/linux/libpdfium.so');
  final skip = !pdfium.existsSync();
  setUpAll(() => Pdfrx.pdfiumModulePath = pdfium.absolute.path);

  Future<Uint8List> sample({pw.Font? font}) async {
    final doc = pw.Document();
    doc.addPage(pw.Page(
      pageFormat: pdf.PdfPageFormat.a4,
      build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('Hello world', style: pw.TextStyle(fontSize: 24, font: font)),
        pw.SizedBox(height: 20),
        pw.Text('Second line', style: pw.TextStyle(fontSize: 12, font: font)),
        pw.SizedBox(height: 20),
        pw.Container(width: 100, height: 40, color: pdf.PdfColors.red),
      ]),
    ));
    return doc.save();
  }

  Future<PdfContentEditor> open(Uint8List bytes, {Uint8List? fallback, Map<String, Uint8List>? fonts}) =>
      PdfContentEditor.open(bytes, modulePath: pdfium.absolute.path, fallbackFonts: fonts ?? (fallback == null ? const {} : {'sans': fallback}));

  test('lists the text runs and shapes of a page, in the page as shown', skip: skip, () async {
    final e = await open(await sample());
    addTearDown(e.close);
    final objects = (await e.objects(0));
    final texts = objects.where((o) => o.kind == PdfObjectKind.text).toList();
    expect(texts.map((o) => o.text), ['Hello world', 'Second line']);
    expect(texts.first.rect.top, lessThan(texts.last.rect.top)); // top of the page first
    expect(texts.first.rect.top, greaterThan(0));
    expect(texts.first.fontSize, closeTo(24, 0.01));
    expect(objects.any((o) => o.kind == PdfObjectKind.path), isTrue);
  });

  test('changing a run keeps the rest and shows in a reread file', skip: skip, () async {
    final e = await open(await sample());
    final first = (await e.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.text);
    await e.setText(0, first, 'Goodbye moon');
    final saved = await e.save();
    await e.close();

    final again = await open(saved);
    addTearDown(again.close);
    // (read top to bottom: the file lists new text after the old)
    final texts = (await again.objects(0)).where((o) => o.kind == PdfObjectKind.text).toList()..sort((a, b) => a.rect.top.compareTo(b.rect.top));
    expect(texts.map((o) => o.text), ['Goodbye moon', 'Second line']);
  });

  test('editing a TeX line keeps its spaces although the embedded font has no space glyph', skip: skip, () async {
    // (TeX sets words apart by moving, the subset has only the letters used: a space written in that font takes no room)
    final e = await open(File('test/fixtures/tex_sans_title.pdf').readAsBytesSync());
    final line = (await e.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.text);
    expect(line.text, 'Algorithms and Data Structures');
    await e.setText(0, line, 'Algorithms and Data Structure');
    final saved = await e.save();
    await e.close();

    final again = await open(saved);
    addTearDown(again.close);
    final lines = (await again.objects(0)).where((o) => o.kind == PdfObjectKind.text).toList();
    expect(lines.map((o) => o.text), ['Algorithms and Data Structure']);
    // (the text alone does not tell: a space with no width still reads as a space. The line must be as wide as before less one letter)
    expect(lines.single.rect.width, greaterThan(line.rect.width * 0.95));
    expect(lines.single.rect.width, lessThan(line.rect.width));
  });

  test('characters the font lacks move the run to another font instead of being lost', skip: skip, () async {
    final roboto = File('assets/fonts/LiberationSans-Regular.ttf').readAsBytesSync();
    final e = await open(await sample(), fallback: roboto);
    final first = (await e.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.text);
    await e.setText(0, first, 'Привет мир');
    final saved = await e.save();
    await e.close();

    final again = await open(saved);
    addTearDown(again.close);
    expect((await again.objects(0)).where((o) => o.kind == PdfObjectKind.text).map((o) => o.text), contains('Привет мир'));
  });

  test('moving, resizing and deleting objects', skip: skip, () async {
    final e = await open(await sample());
    final box = (await e.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.path);
    await e.moveObject(0, box, const Offset(30, 50));
    final movedBox = (await e.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.path);
    final moved = movedBox.rect;
    expect(moved.left - box.rect.left, closeTo(30, 0.1));
    expect(moved.top - box.rect.top, closeTo(50, 0.1));

    await e.resizeObject(0, movedBox, Rect.fromLTWH(moved.left, moved.top, moved.width * 2, moved.height * 1.5));
    final grown = (await e.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.path).rect;
    expect(grown.width, closeTo(moved.width * 2, 0.2));
    expect(grown.height, closeTo(moved.height * 1.5, 0.2));
    expect(grown.topLeft.dx, closeTo(moved.left, 0.2));
    expect(grown.topLeft.dy, closeTo(moved.top, 0.2));

    await e.removeObject(0, movedBox);
    final saved = await e.save();
    await e.close();
    final again = await open(saved);
    addTearDown(again.close);
    expect((await again.objects(0)).any((o) => o.kind == PdfObjectKind.path), isFalse);
  });

  test('tells what kind of font a line is set in', skip: skip, () async {
    final plain = await open(await sample());
    addTearDown(plain.close);
    final info = await plain.fontInfo(0, (await plain.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.text));
    expect(info.name, contains('Helvetica'));
    expect(info.key, 'sans');

    final doc = pw.Document();
    doc.addPage(pw.Page(
        build: (_) => pw.Column(children: [
              pw.Text('a', style: pw.TextStyle(font: pw.Font.timesBold())),
              pw.Text('b', style: pw.TextStyle(font: pw.Font.courierOblique())),
            ])));
    final styled = await open(await doc.save());
    addTearDown(styled.close);
    final keys = [for (final o in (await styled.objects(0)).where((o) => o.kind == PdfObjectKind.text)) (await styled.fontInfo(0, o)).key];
    expect(keys, ['serif-bold', 'mono-italic']);
  });

  test('resizing puts an object exactly in the rectangle given, anywhere on the page', skip: skip, () async {
    final e = await open(await sample());
    addTearDown(e.close);
    final box = (await e.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.path);
    const target = Rect.fromLTWH(200, 300, 50, 80);
    await e.resizeObject(0, box, target);
    final now = (await e.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.path).rect;
    expect(now.left, closeTo(target.left, 0.2));
    expect(now.top, closeTo(target.top, 0.2));
    expect(now.width, closeTo(target.width, 0.2));
    expect(now.height, closeTo(target.height, 0.2));
  });

  test('text takes a colour, bold and italic, and lines under and through it that follow it', skip: skip, () async {
    final roboto = File('assets/fonts/LiberationSans-Regular.ttf').readAsBytesSync();
    final bold = File('assets/fonts/LiberationSans-Bold.ttf').readAsBytesSync();
    final e = await open(await sample(), fonts: {'sans': roboto, 'sans-bold': bold});
    addTearDown(e.close);
    Future<PdfEditObject> first() async => (await e.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.text);
    expect((await first()).color, 0xFF000000);

    await e.formatText(0, await first(), color: 0xFFFF0000);
    expect((await first()).color, 0xFFFF0000);

    await e.formatText(0, await first(), underline: true);
    var line = await first();
    expect(line.underlined, isTrue);
    expect(line.struckThrough, isFalse);
    expect((await e.objects(0)).where((o) => o.kind == PdfObjectKind.path), hasLength(1)); // (the red box; the line is part of the text)
    expect(line.underlines, hasLength(1));

    await e.formatText(0, line, strikethrough: true);
    line = await first();
    expect(line.underlined && line.struckThrough, isTrue);

    // it follows the text when that moves, and goes with it when that is deleted
    final before = line.rect;
    await e.moveObject(0, line, const Offset(10, 40));
    line = await first();
    expect(line.rect.left - before.left, closeTo(10, 0.1));
    expect(line.underlined && line.struckThrough, isTrue);

    await e.formatText(0, line, underline: false);
    line = await first();
    expect(line.underlined, isFalse);
    expect(line.struckThrough, isTrue);

    // and when the words change
    await e.setText(0, line, 'a much longer line of text');
    line = await first();
    expect(line.text, 'a much longer line of text');
    expect(line.struckThrough, isTrue);

    await e.formatText(0, line, bold: true);
    line = await first();
    expect(line.text, 'a much longer line of text');
    expect((await e.fontInfo(0, line)).bold, isTrue);
    expect(line.struckThrough, isTrue);
    expect(line.color, 0xFFFF0000);

    await e.removeObject(0, line);
    expect((await e.objects(0)).where((o) => o.kind == PdfObjectKind.path), hasLength(1));
  });

  test('knows the line the text sits on', skip: skip, () async {
    final e = await open(await sample());
    addTearDown(e.close);
    final line = (await e.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.text);
    expect(line.baseline, isNotNull);
    expect(line.baseline!, greaterThan(line.rect.top));
    expect(line.baseline!, lessThanOrEqualTo(line.rect.bottom + 1));
    // (24 pt text: the letters stand about three quarters of that above the line)
    expect(line.baseline! - line.rect.top, closeTo(24 * 0.72, 3));
  });

  test('a font the PDF only carries the used letters of is not asked for others; symbols come from a font that has them', skip: skip, () async {
    final sans = File('assets/fonts/LiberationSans-Regular.ttf').readAsBytesSync();
    final dejavu = File('assets/fonts/DejaVuSans.ttf').readAsBytesSync();
    final e = await open(await sample(font: pw.Font.ttf(ByteData.sublistView(sans))), fonts: {'sans': sans, 'symbols': dejavu});
    addTearDown(e.close);
    final first = (await e.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.text);
    // letters the page has are fine where they are; others are set again in the stand-in, which has them all
    await e.setText(0, first, 'Zebra zone');
    var line = (await e.objects(0)).firstWhere((o) => o.text == 'Zebra zone');
    expect(line.baseline, closeTo(first.baseline!, 0.5)); // (and on the same line)
    // chess pieces and keyboard signs are in no Liberation font: they are set in DejaVu
    await e.setText(0, line, '♞ ⌘ ☂');
    line = (await e.objects(0)).firstWhere((o) => o.text == '♞ ⌘ ☂');
    expect((await e.fontInfo(0, line)).name, contains('DejaVu'));
  });

  test('a uniform text is set whole in one stand-in font, not letter by letter in the PDF font where it has them', skip: skip, () async {
    final sans = File('assets/fonts/LiberationSans-Regular.ttf').readAsBytesSync();
    final e = await open(await sample(font: pw.Font.ttf(ByteData.sublistView(sans))), fonts: {'sans': sans});
    addTearDown(e.close);
    final first = (await e.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.text);
    await e.setText(0, first, 'Zebra zone', sizeFactor: 0.9, uniform: true);
    final line = (await e.objects(0)).firstWhere((o) => o.text == 'Zebra zone');
    expect(line.parts.length, 1);
    expect(line.baseline, closeTo(first.baseline!, 0.5));
  });

  group('a PDF from LibreOffice, with Symbola and fonts it falls back on', () {
    // "Mixed serif text ☺ ∑ [♞ 😀 ⚽ in fonts of their own] and more text after." / "Emoji line 😀 🎉 ♠ ♥ ⚽ ✈ and words." (all Symbola)
    Map<String, Uint8List> stands() => {
          'sans': File('assets/fonts/LiberationSans-Regular.ttf').readAsBytesSync(),
          'sans-bold': File('assets/fonts/LiberationSans-Bold.ttf').readAsBytesSync(),
          'serif': File('assets/fonts/LiberationSerif-Regular.ttf').readAsBytesSync(),
          'symbols': File('assets/fonts/DejaVuSans.ttf').readAsBytesSync(),
          'symbols-bold': File('assets/fonts/DejaVuSans-Bold.ttf').readAsBytesSync(),
        };
    Future<PdfContentEditor> opened() => open(File('test/fixtures/libreoffice_symbols.pdf').readAsBytesSync(), fonts: stands());

    test('pieces of a line that sit inside the gap of another are one line, read left to right', skip: skip, () async {
      final e = await opened();
      addTearDown(e.close);
      final lines = (await e.objects(0)).where((o) => o.kind == PdfObjectKind.text).map((o) => o.text).toList();
      expect(lines, ['Mixed serif text ☺ ∑ ♞ 😀 ⚽ and more text after.', 'Emoji line 😀 🎉 ♠ ♥ ⚽ ✈ and words.', 'Plain sans line for reference.']);
    });

    test('changing a word keeps the emoji above U+FFFF, which PDFium cannot write back by their Unicode', skip: skip, () async {
      final e = await opened();
      addTearDown(e.close);
      final line = (await e.objects(0)).firstWhere((o) => o.text!.startsWith('Emoji'));
      await e.setText(0, line, 'Emoji line 😀 🎉 ♠ ♥ ⚽ ✈ and wards.'); // (every letter is in the font)
      final saved = await e.save();
      final again = await open(saved, fonts: stands());
      addTearDown(again.close);
      final now = (await again.objects(0)).where((o) => o.kind == PdfObjectKind.text).map((o) => o.text).toList();
      expect(now, contains('Emoji line 😀 🎉 ♠ ♥ ⚽ ✈ and wards.'));
    });

    test('a letter the font lacks is set in a stand-in and the rest stays', skip: skip, () async {
      final e = await opened();
      addTearDown(e.close);
      final line = (await e.objects(0)).firstWhere((o) => o.text!.startsWith('Emoji'));
      await e.setText(0, line, 'Emoji line 😀 🎉 ♠ ♥ ⚽ ✈ and wordz.'); // (no z in the font)
      final now = (await e.objects(0)).where((o) => o.kind == PdfObjectKind.text).map((o) => o.text).toList();
      expect(now, contains('Emoji line 😀 🎉 ♠ ♥ ⚽ ✈ and wordz.'));
    });

    test('a line with colour emoji says which characters it cannot set again, and is left as it was', skip: skip, () async {
      final e = await opened();
      addTearDown(e.close);
      final line = (await e.objects(0)).firstWhere((o) => o.text!.startsWith('Mixed'));
      await expectLater(e.setText(0, line, line.text!.replaceFirst('more', 'much more')), throwsA(isA<PdfEditException>().having((x) => x.message, 'message', contains('⚽'))));
      final after = (await e.objects(0)).where((o) => o.kind == PdfObjectKind.text).map((o) => o.text).toList();
      expect(after.first, 'Mixed serif text ☺ ∑ ♞ 😀 ⚽ and more text after.');
    });

    test('bold on a line with symbols is bold: the symbols come from a bold font too', skip: skip, () async {
      final e = await opened();
      addTearDown(e.close);
      final line = (await e.objects(0)).firstWhere((o) => o.text!.startsWith('Plain'));
      await e.formatText(0, line, bold: true);
      final bolder = (await e.objects(0)).firstWhere((o) => o.text!.startsWith('Plain'));
      expect((await e.fontInfo(0, bolder)).bold, isTrue);
    });
  });
}
