import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/pdf/pdf_page_loader.dart';
import 'package:pdf/pdf.dart' as pw;
import 'package:pdf/widgets.dart' as pw_widgets;
import 'package:pdfrx/pdfrx.dart';

void main() {
  test('lines are built from word fragments', () {
    Rect r(double l, double t) => Rect.fromLTWH(l, t, 10, 10);
    final lines = linesOf([
      PdfFragment('Hello', [r(0, 0), r(10, 0), r(20, 0), r(30, 0), r(40, 0)]),
      PdfFragment(' ', [r(50, 0)]),
      // last word of the line carries the line break, whose rects are dummies
      PdfFragment('world\r\n', [r(60, 0), r(70, 0), r(80, 0), r(90, 0), r(100, 0), Rect.zero, Rect.zero]),
      PdfFragment('Next', [r(0, 20), r(10, 20), r(20, 20), r(30, 20)]),
    ]);
    expect(lines.map((l) => l.text), ['Hello world', 'Next']);
    expect(lines.first.words.map((w) => (w.text, w.startIndex, w.endIndex)), [('Hello', 0, 5), ('world', 6, 11)]);
    expect(lines.first.xMin, 0);
    expect(lines.first.xMax, 110); // dummy rects at the origin do not widen it
    expect(lines.last.yMin, 20);
  });

  test('the sharper image is only asked for when the normal one is too soft, in steps', () {
    expect(hiResPixelWidth(1000, normal: 1280), 0);
    expect(hiResPixelWidth(1400, normal: 1280), 0); // within a tenth of the normal width
    expect(hiResPixelWidth(1500, normal: 1280), 1600); // a quarter more
    expect(hiResPixelWidth(1600, normal: 1280), 1600);
    expect(hiResPixelWidth(1700, normal: 1280), 2048); // the next step: a pinch does not render at every size
    expect(hiResPixelWidth(1650, normal: 1280), hiResPixelWidth(1990, normal: 1280));
    expect(hiResPixelWidth(1e9, normal: 1280), 16384); // only what is on screen is rendered, but not past what PDFium takes
  });

  test('a page is drawn as wide as the screen shows it, in steps, never past the resolution of the settings', () {
    // a tablet of 1200 pixels across, an A4 page (595 points)
    expect(pagePixelWidth(screenPixels: 1200, pageWidth: 595, dpi: 200), 1280);
    expect(pagePixelWidth(screenPixels: 1190, pageWidth: 595, dpi: 200), 1280, reason: 'a window a little narrower renders nothing again');
    // a big screen: the resolution of the settings is the most
    expect(pagePixelWidth(screenPixels: 3000, pageWidth: 595, dpi: 200), (595 * 200 / 72).round());
    // a poster: as wide as the screen, not at 200 dpi
    expect(pagePixelWidth(screenPixels: 1200, pageWidth: 2384, dpi: 200), 1280);
    expect(pagePixelWidth(screenPixels: 9000, pageWidth: 2384, dpi: 300), maxPagePixelWidth);
    // a small window still gets a readable picture
    expect(pagePixelWidth(screenPixels: 200, pageWidth: 595, dpi: 200), 512);
  });

  // needs PDFium, which only a built app bundles: run `flutter build linux
  // --debug` once, then this test finds the library in the build folder.
  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

  testWidgets('renders a real PDF with text positions', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    await tester.runAsync(() async {
    final doc = pw_widgets.Document();
    doc.addPage(pw_widgets.Page(
      pageFormat: pw.PdfPageFormat.a4.landscape,
      margin: const pw_widgets.EdgeInsets.all(72),
      build: (_) => pw_widgets.Text('Hello world', style: const pw_widgets.TextStyle(fontSize: 24)),
    ));
    final file = File('${Directory.systemTemp.path}/loader_test.pdf');
    await file.writeAsBytes(await doc.save());

    final pdf = await PdfDocument.openFile(file.path);
    addTearDown(pdf.dispose);
    final page = pdf.pages.single;
    expect(page.width, greaterThan(page.height)); // landscape

    final data = await loadPdfPicture(page, 1000);
    expect(data.image.width, 1000);
    expect(data.alive, isTrue);
    expect(data.image.width / data.image.height, closeTo(page.width / page.height, 0.01));
    expect(data.bytes, data.image.width * data.image.height * 4);
    expect((await data.png()).take(4), [0x89, 0x50, 0x4E, 0x47]); // PNG signature, made when asked for
    data.release();
    expect(data.alive, isFalse);
    data.release(); // (twice is fine)
    await expectLater(data.png(), throwsStateError);
    // the words are read apart from the picture, and worked out on another isolate
    final words = await loadPdfWords(page);
    expect(words.pageWidth, page.width);
    final line = words.lines.single;
    expect(line.text, 'Hello world');
    // 72pt margin: the text starts there from the top left
    expect(line.xMin, closeTo(72, 3));
    expect(line.yMin, closeTo(72, 8));
  });
  });

  testWidgets('renders a page at the width asked for, within the memory budget', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    await tester.runAsync(() async {
      final doc = pw_widgets.Document();
      doc.addPage(pw_widgets.Page(build: (_) => pw_widgets.Text('Sharp')));
      final file = File('${Directory.systemTemp.path}/loader_sharp_test.pdf');
      await file.writeAsBytes(await doc.save());
      final pdf = await PdfDocument.openFile(file.path);
      addTearDown(pdf.dispose);
      final page = pdf.pages.single;

      final big = await renderPageImage(page, 3000);
      expect(big.width, 3000);
      expect(big.height, closeTo(3000 * page.height / page.width, 1));
      big.dispose();

      // a small budget makes it narrower, in proportion
      final capped = await renderPageImage(page, 4800, maxPixels: 2e6);
      expect(capped.width * capped.height, lessThanOrEqualTo(2e6 * 1.01));
      expect(capped.width, lessThan(4800));
      capped.dispose();

      // a part of the page at a size the whole page could not be rendered at in memory: only that part is made
      final part = await renderPageRegion(page, 12000, const Rect.fromLTWH(1000, 2000, 900, 700));
      expect((part.width, part.height), (900, 700));
      part.dispose();

      // called off: no picture
      final token = page.createCancellationToken()..cancel();
      await expectLater(renderPageImage(page, 1000, cancel: token), throwsStateError);
    });
  });

  testWidgets('the words worked out on another isolate are the ones the main isolate made', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    await tester.runAsync(() async {
      final doc = pw_widgets.Document();
      for (var p = 0; p < 2; p++) {
        doc.addPage(pw_widgets.Page(
          pageFormat: p == 0 ? pw.PdfPageFormat.a4 : pw.PdfPageFormat.a4.landscape,
          build: (_) => pw_widgets.Column(crossAxisAlignment: pw_widgets.CrossAxisAlignment.start, children: [
            pw_widgets.Text('Integrals and graphs, page ${p + 1}', style: const pw_widgets.TextStyle(fontSize: 20)),
            for (var l = 0; l < 30; l++) pw_widgets.Text('line $l: the quick brown fox jumps over the lazy dog, $l times.'),
            pw_widgets.Row(children: [pw_widgets.Text('left column'), pw_widgets.SizedBox(width: 120), pw_widgets.Text('right column')]),
          ]),
        ));
      }
      final file = File('${Directory.systemTemp.path}/loader_words_test.pdf');
      await file.writeAsBytes(await doc.save());
      final pdf = await PdfDocument.openFile(file.path);
      addTearDown(pdf.dispose);
      for (final page in pdf.pages) {
        // what loadPdfPageData did before, on the main isolate
        final structured = await page.loadStructuredText();
        final before = linesOf(structured.fragments.map((f) => PdfFragment(f.text, [for (final r in f.charRects) r.toRect(page: page)])));
        final now = (await loadPdfWords(page)).lines;
        expect(now.length, before.length);
        expect(now.length, greaterThan(30));
        for (var i = 0; i < now.length; i++) {
          expect(now[i].text, before[i].text);
          expect([now[i].xMin, now[i].yMin, now[i].xMax, now[i].yMax], [before[i].xMin, before[i].yMin, before[i].xMax, before[i].yMax]);
          expect(now[i].words.map((w) => (w.text, w.startIndex, w.xMin, w.yMax)), before[i].words.map((w) => (w.text, w.startIndex, w.xMin, w.yMax)));
        }
      }
    });
  });
}
