import 'dart:io';
import 'dart:ui' show Size;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/pdf/pdf_content_editor.dart';
import 'package:notes/pdf/pdf_pages.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart' show Pdfrx;

void main() {
  group('PageArrangement.fromJson', () {
    Map<String, Object?> json({Object? o = const [1, -1, 0], Object? from = 2, Object? w = 595, Object? h = 842}) => {'o': o, 'from': from, 'w': w, 'h': h};

    test('reads what toJson wrote', () {
      const a = PageArrangement([2, null, 0], 3, Size(595.5, 842));
      final b = PageArrangement.fromJson(a.toJson())!;
      expect(b.order, a.order);
      expect((b.from, b.blank), (a.from, a.blank));
    });

    test('refuses what cannot be done to a PDF', () {
      expect(PageArrangement.fromJson(json()), isNotNull);
      expect(PageArrangement.fromJson(null), isNull);
      expect(PageArrangement.fromJson('o'), isNull);
      expect(PageArrangement.fromJson(json(o: 'abc')), isNull);
      expect(PageArrangement.fromJson(json(o: [])), isNull, reason: 'a PDF has a page');
      expect(PageArrangement.fromJson(json(o: [0, 0])), isNull, reason: 'a page once');
      expect(PageArrangement.fromJson(json(o: [0, 2])), isNull, reason: 'no page 2 in two');
      expect(PageArrangement.fromJson(json(o: [0, 1.5])), isNull);
      expect(PageArrangement.fromJson(json(o: [0, '1'])), isNull);
      expect(PageArrangement.fromJson(json(o: List.filled(PageArrangement.maxPages + 1, -1))), isNull);
      expect(PageArrangement.fromJson(json(from: 0)), isNull);
      expect(PageArrangement.fromJson(json(from: 2.5)), isNull);
      expect(PageArrangement.fromJson(json(w: 0)), isNull);
      expect(PageArrangement.fromJson(json(w: -5)), isNull);
      expect(PageArrangement.fromJson(json(h: double.nan)), isNull);
      expect(PageArrangement.fromJson(json(h: double.infinity)), isNull);
      expect(PageArrangement.fromJson(json(w: PageArrangement.maxSide + 1)), isNull);
    });
  });

  // needs PDFium, which only a built app bundles (see pdf_content_editor_test.dart)
  final pdfium = File('build/native_assets/linux/libpdfium.so');
  final skip = !pdfium.existsSync();

  group('arrangePdfFile', () {
    late Directory dir;
    late String path;

    setUp(() async {
      Pdfrx.pdfiumModulePath = pdfium.absolute.path;
      dir = await Directory.systemTemp.createTemp('arrange_');
      final doc = pw.Document();
      for (final text in ['one', 'two', 'three']) {
        doc.addPage(pw.Page(pageFormat: pdf.PdfPageFormat.a4, build: (_) => pw.Text(text)));
      }
      path = '${dir.path}/a.pdf';
      await File(path).writeAsBytes(await doc.save());
    });
    tearDown(() => dir.delete(recursive: true));

    Future<List<String>> texts(String file, int pages) async {
      final e = await PdfContentEditor.open(await File(file).readAsBytes(), modulePath: pdfium.absolute.path);
      try {
        final out = <String>[];
        for (var i = 0; i < pages; i++) {
          final t = (await e.objects(i)).where((o) => o.kind == PdfObjectKind.text).map((o) => o.text).join();
          out.add(t);
        }
        return out;
      } finally {
        await e.close();
      }
    }

    test('moves, deletes and adds pages, and writes the file it says', skip: skip, () async {
      final moved = await arrangePdfFile(path, [2, null, 0], fileName: 'b.pdf');
      expect(moved.path, '${dir.path}/b.pdf');
      expect(moved.pages, 3);
      expect(moved.blank.width, closeTo(595, 1));
      expect(moved.sha256, sha256.convert(await File(moved.path).readAsBytes()).toString());
      expect(await texts(moved.path, 3), ['three', '', 'one']);
      expect(await File(path).exists(), isTrue, reason: 'the file it was done on stays');
    });

    test('a new page is as big as the one it is asked to be like, or as it is told', skip: skip, () async {
      final told = await arrangePdfFile(path, [0, null], fileName: 'c.pdf', blank: const Size(200, 300));
      expect(told.blank, const Size(200, 300));
    });

    test('refuses an order that is not one, and leaves no file', skip: skip, () async {
      for (final order in [<int?>[0, 0], <int?>[0, 3], <int?>[-5]]) {
        await expectLater(arrangePdfFile(path, order, fileName: 'x.pdf'), throwsA(anything), reason: '$order');
      }
      expect(await File('${dir.path}/x.pdf').exists(), isFalse);
    });
  });
}
