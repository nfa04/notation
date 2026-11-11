import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/automations/automation_service.dart' show NoteEditorHandle;
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/export/pdf_ink_text.dart';
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/layers.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/search/search_query.dart' show InkText;
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'ink_prefetch_test.dart' show FakeReader, word;

// needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
final _pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

/// The handwriting of two lines: "hello" 94 wide at the top, a shorter word under it.
List<DrawingStroke> _twoLines() => [...word('a', 100, 100, n: 5), ...word('b', 100, 140, n: 3)];

/// The text of the first page of the PDF [path] as the viewer finds it: the text, and where each line of it is (counted from the top).
Future<({String text, List<Rect> lines})> _read(String path) async {
  final doc = await PdfDocument.openFile(path);
  try {
    final page = doc.pages.first;
    final text = await page.loadStructuredText();
    // (the viewer cuts a line into words and spaces: the pieces on one row are one line)
    final lines = <Rect>[];
    for (final f in text.fragments) {
      final r = Rect.fromLTRB(f.bounds.left, page.height - f.bounds.top, f.bounds.right, page.height - f.bounds.bottom);
      if (r.width <= 0) continue;
      final i = lines.indexWhere((l) => (l.center.dy - r.center.dy).abs() < r.height / 2);
      i < 0 ? lines.add(r) : lines[i] = lines[i].expandToInclude(r);
    }
    return (text: text.fullText, lines: lines);
  } finally {
    await doc.dispose();
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  group('where the lines of text go', () {
    test('each line of what was read goes where the line of writing is', () {
      final cluster = clusterStrokes(0, _twoLines()).single;
      final lines = inkTextLines(cluster, 'hello there\nbye');
      expect(lines.map((l) => l.text), ['hello there', 'bye']);
      expect(lines[0].box.left, 100);
      expect(lines[0].box.width, 94); // four letters 20 apart and one 14 wide
      expect(lines[0].box.top, 100);
      expect(lines[1].box.left, 100);
      expect(lines[1].box.width, 54);
      expect(lines[1].box.top, 140);
    });

    test('when the reading has more lines than the writing, the neighbouring ones that fit by length are joined', () {
      final cluster = clusterStrokes(0, _twoLines()).single;
      // (the first line of writing is almost twice as wide as the second)
      final lines = inkTextLines(cluster, 'hello\nthere\nbye');
      expect(lines.map((l) => l.text), ['hello there', 'bye']);
      expect(lines[0].box.top, 100);
      expect(lines[1].box.top, 140);
    });

    test('when the first or last line was not read (the reading is trimmed), the others stay where they are written', () {
      final strokes = [...word('a', 100, 100, n: 3), ...word('b', 100, 140, n: 8), ...word('c', 100, 180, n: 3)];
      final cluster = clusterStrokes(0, strokes).single;
      final last = inkTextLines(cluster, 'ab\nabcdefgh');
      expect(last.map((l) => l.box.top), [100, 140], reason: 'the third line is the one left out');
      final first = inkTextLines(cluster, 'abcdefgh\nab');
      expect(first.map((l) => l.box.top), [140, 180], reason: 'the first line is the one left out');
    });

    test('an empty line of the reading takes its place and leaves no text', () {
      final cluster = clusterStrokes(0, _twoLines()).single;
      final lines = inkTextLines(cluster, '\nbye');
      expect(lines.map((l) => l.text), ['bye']);
      expect(lines.single.box.top, 140, reason: 'still the second line of writing');
    });

    test('a line of a few small letters is taken to be as tall as the others', () {
      final strokes = [...word('a', 100, 100, n: 5), ...word('b', 100, 140, n: 4), ...word('c', 100, 180, n: 3)];
      // the last line only has flat strokes: "so"
      strokes.removeWhere((s) => s.id.startsWith('c'));
      strokes.addAll([for (var i = 0; i < 2; i++) DrawingStroke(id: 'c$i', color: Colors.black, width: 3, points: [for (var k = 0; k < 8; k++) Offset(100 + i * 20 + k * 2.0, 172 + (k.isEven ? 0 : 9))])]);
      final cluster = clusterStrokes(0, strokes).single;
      final lines = inkTextLines(cluster, 'hello there\nfour\nso');
      expect(lines.last.box.height, closeTo(22 * 0.8, 0.01));
      expect(lines.last.box.bottom, closeTo(181, 0.01), reason: 'it grows upwards from where it is written');
    });
  });

  group('the reading of a note', () {
    test('what was read before is used as it is, and the rest is read now and kept', () async {
      final cluster = clusterStrokes(0, _twoLines()).single;
      final reader = FakeReader((_) => 'read now\nlater');
      final ink = PdfInkText(known: {cluster.key: 'hello there\nbye'}, read: reader.recognize);
      expect((await ink.pageLines(0, _twoLines())).map((l) => l.text), ['hello there', 'bye']);
      expect(reader.calls, isEmpty);

      final other = PdfInkText(known: {}, read: reader.recognize);
      expect((await other.pageLines(0, _twoLines())).map((l) => l.text), ['read now', 'later']);
      await other.pageLines(0, _twoLines());
      expect(reader.calls, hasLength(1), reason: 'a second page of the same writing is not read again');
      expect(other.unread, 0);
    });

    test('nothing is read when there is no reader, a reader that fails or one that is out of time leaves the block, and counts it', () async {
      expect(await PdfInkText(known: {}).pageLines(0, _twoLines()), isEmpty);

      final broken = FakeReader((_) => '')..fail = true;
      final failing = PdfInkText(known: {}, read: broken.recognize);
      expect(await failing.pageLines(0, _twoLines()), isEmpty);
      expect(failing.unread, 1);

      final slow = FakeReader((_) => 'text');
      final late = PdfInkText(known: {}, read: slow.recognize, budget: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await late.pageLines(0, [..._twoLines(), ...word('far', 100, 500)]), isEmpty);
      expect(late.unread, greaterThan(0));
      expect(slow.calls.length, lessThanOrEqualTo(1), reason: 'the first block is read before the clock is looked at again');
    });

    test('a block that was read and was empty is not read again', () async {
      final cluster = clusterStrokes(0, _twoLines()).single;
      final reader = FakeReader((_) => 'x');
      final ink = PdfInkText(known: {cluster.key: ''}, read: reader.recognize);
      expect(await ink.pageLines(0, _twoLines()), isEmpty);
      expect(reader.calls, isEmpty);
    });
  });

  group('in a PDF', () {
    testWidgets('the text is found by a viewer where the writing is, and nothing of it is drawn', skip: !_pdfium.existsSync(), (tester) async {
      Pdfrx.pdfiumModulePath = _pdfium.absolute.path;
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('ink_text_');
        addTearDown(() => dir.delete(recursive: true));
        final lines = [const InkTextLine('hello there', Rect.fromLTWH(100, 100, 300, 30)), const InkTextLine('Grüße, ä ö ü ß', Rect.fromLTWH(100, 160, 200, 24))];
        final doc = pw.Document();
        doc.addPage(pw.Page(
          pageFormat: const pdf.PdfPageFormat(595, 842),
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Builder(builder: (context) {
            final font = pdf.PdfFont.helvetica(context.document);
            return pw.CustomPaint(size: const pdf.PdfPoint(595, 842), painter: (canvas, size) => drawInkText(canvas, size.y, lines, font));
          }),
        ));
        final file = File('${dir.path}/a.pdf')..writeAsBytesSync(await doc.save());

        final read = await _read(file.path);
        expect(read.text.replaceAll('\r\n', '\n').trim(), 'hello there\nGrüße, ä ö ü ß');
        expect(read.lines, hasLength(2));
        // each line is selected over its ink: as wide as the writing (give or take the space a letter keeps at its sides), about as tall
        expect(read.lines[0].left, closeTo(100, 6));
        expect(read.lines[0].right, closeTo(400, 6));
        expect(read.lines[1].left, closeTo(100, 6));
        expect(read.lines[1].right, closeTo(300, 6));
        // (and over the ink: the box of the first line is 100 to 130)
        expect(read.lines[0].center.dy, inInclusiveRange(100, 130));
        expect(read.lines[0].bottom, inInclusiveRange(120, 130));
        expect(read.lines[0].height, inInclusiveRange(15, 30));

        // nothing is drawn: the page is as white as a page can be
        final pdfDoc = await PdfDocument.openFile(file.path);
        try {
          final image = await pdfDoc.pages.first.render(width: 300, height: 421);
          expect(image!.pixels.every((b) => b == 0xFF), isTrue);
          image.dispose();
        } finally {
          await pdfDoc.dispose();
        }
      });
    });

    testWidgets('letters the font cannot write are left out, not turned into something else', skip: !_pdfium.existsSync(), (tester) async {
      Pdfrx.pdfiumModulePath = _pdfium.absolute.path;
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('ink_text_');
        addTearDown(() => dir.delete(recursive: true));
        final doc = pw.Document();
        doc.addPage(pw.Page(
          build: (_) => pw.Builder(builder: (context) {
            final font = pdf.PdfFont.helvetica(context.document);
            return pw.CustomPaint(
              size: const pdf.PdfPoint(500, 500),
              painter: (canvas, size) => drawInkText(canvas, size.y, const [InkTextLine('x = αβ ok', Rect.fromLTWH(50, 50, 200, 20)), InkTextLine('αβγ', Rect.fromLTWH(50, 100, 80, 20))], font),
            );
          }),
        ));
        final file = File('${dir.path}/b.pdf')..writeAsBytesSync(await doc.save());
        final text = (await _read(file.path)).text.replaceAll('\r\n', '\n').trim();
        expect(text, 'x = ok');
      });
    });
  });

  group('exported from the editor', () {
    late NoteRepository repo;
    late String id;
    late Directory dir;

    Future<void> noteWith(WidgetTester tester, {List<DrawingStroke>? strokes, Future<void> Function(NoteRepository, String)? more}) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('ink_export_');
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        repo = NoteRepository(db);
        id = await repo.createNote();
        final note = (await repo.loadNote(id))!;
        note.strokes[0] = strokes ?? _twoLines();
        await repo.saveNote(note);
        await more?.call(repo, id);
      });
      addTearDown(() => dir.delete(recursive: true));
    }

    Future<String?> exported(WidgetTester tester, FakeReader? reader) async {
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, handwriting: reader)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
      await tester.pump();
      final handle = tester.state(find.byType(FixedPageNoteEditor)) as NoteEditorHandle;
      final out = '${dir.path}/out.pdf';
      String? problem = 'pending';
      var done = false;
      handle.exportPdfTo(out).then((r) {
        problem = r;
        done = true;
      });
      for (var i = 0; i < 100 && !done; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      return problem;
    }

    testWidgets('the handwriting of a note is text in its PDF, read at the export when it was not before', skip: !_pdfium.existsSync(), (tester) async {
      Pdfrx.pdfiumModulePath = _pdfium.absolute.path;
      await noteWith(tester);
      final reader = FakeReader((_) => 'hello there\nbye');
      expect(await exported(tester, reader), isNull);
      expect(reader.calls, hasLength(1));
      final read = await tester.runAsync(() => _read('${dir.path}/out.pdf'));
      expect(read!.text.replaceAll('\r\n', '\n').trim(), 'hello there\nbye');
      // the PDF page is as big as the paper: the first line is where the writing is (100 to 194 across)
      expect(read.lines.first.left, closeTo(100, 2));
      expect(read.lines.first.right, closeTo(194, 2));
    });

    testWidgets('what the search already read is used and nothing is read again', skip: !_pdfium.existsSync(), (tester) async {
      Pdfrx.pdfiumModulePath = _pdfium.absolute.path;
      final cluster = clusterStrokes(0, _twoLines()).single;
      await noteWith(tester, more: (repo, id) => repo.text.saveInkText(id, [InkText(key: cluster.key, page: 0, text: 'kept text\nsecond', bounds: cluster.bounds)], {cluster.key}));
      final reader = FakeReader((_) => 'must not be read');
      expect(await exported(tester, reader), isNull);
      expect(reader.calls, isEmpty);
      expect((await tester.runAsync(() => _read('${dir.path}/out.pdf')))!.text.replaceAll('\r\n', '\n').trim(), 'kept text\nsecond');
    });

    testWidgets('with no reader, only what was read before is there; with the setting off, nothing', skip: !_pdfium.existsSync(), (tester) async {
      Pdfrx.pdfiumModulePath = _pdfium.absolute.path;
      await noteWith(tester);
      expect(await exported(tester, null), isNull);
      expect((await tester.runAsync(() => _read('${dir.path}/out.pdf')))!.text.trim(), isEmpty);

      final cluster = clusterStrokes(0, _twoLines()).single;
      await tester.runAsync(() async {
        await repo.text.saveInkText(id, [InkText(key: cluster.key, page: 0, text: 'kept text', bounds: cluster.bounds)], {cluster.key});
        await repo.settings.set(pdfInkTextSetting, '0');
      });
      await tester.pumpWidget(const SizedBox());
      expect(await exported(tester, null), isNull);
      expect((await tester.runAsync(() => _read('${dir.path}/out.pdf')))!.text.trim(), isEmpty, reason: 'switched off');

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => repo.settings.set(pdfInkTextSetting, '1'));
      expect(await exported(tester, null), isNull);
      expect((await tester.runAsync(() => _read('${dir.path}/out.pdf')))!.text.trim(), 'kept text');
    });

    testWidgets('on an imported PDF the text of the writing is added to the text it has', skip: !_pdfium.existsSync(), (tester) async {
      Pdfrx.pdfiumModulePath = _pdfium.absolute.path;
      await noteWith(tester, more: (repo, id) async {
        final doc = pw.Document();
        doc.addPage(pw.Page(build: (_) => pw.Text('The printed page', style: const pw.TextStyle(fontSize: 24))));
        final file = File('${dir.path}/base.pdf')..writeAsBytesSync(await doc.save());
        final note = (await repo.loadNote(id))!;
        note.pdfName = 'base.pdf';
        note.pdfPath = file.path;
        note.pdfPageCount = 1;
        await repo.saveNote(note);
      });
      final reader = FakeReader((_) => 'my own note\nsecond');
      expect(await exported(tester, reader), isNull);
      final text = (await tester.runAsync(() => _read('${dir.path}/out.pdf')))!.text.replaceAll('\r\n', '\n');
      expect(text, contains('The printed page'));
      expect(text, contains('my own note'));
      expect(text, contains('second'));
    });

    testWidgets('writing on a hidden layer is not put in the PDF', skip: !_pdfium.existsSync(), (tester) async {
      Pdfrx.pdfiumModulePath = _pdfium.absolute.path;
      final hidden = [...word('h', 100, 400, n: 4)];
      final shown = [...word('s', 100, 100, n: 4)];
      await noteWith(tester, strokes: [...shown, ...hidden], more: (repo, id) async {
        final note = (await repo.loadNote(id))!;
        note.layers = LayerStack([...note.layers.layers, const NoteLayer('secret', 'Secret', visible: false)]);
        for (final s in note.strokes[0]!) {
          if (s.id.startsWith('h')) s.layer = 'secret';
        }
        await repo.saveNote(note);
      });
      final reader = FakeReader((s) => s.first.id.startsWith('h') ? 'the secret' : 'in the open');
      expect(await exported(tester, reader), isNull);
      final text = (await tester.runAsync(() => _read('${dir.path}/out.pdf')))!.text;
      expect(text, contains('in the open'));
      expect(text, isNot(contains('secret')));
      expect(reader.calls.expand((c) => c).any((i) => i.startsWith('h')), isFalse, reason: 'it is not even read');
    });
  });
}
