import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/page_background.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DrawingStroke _stroke() => DrawingStroke(
  color: Colors.black,
  width: 3,
  points: [for (var i = 0; i < 20; i++) Offset(100.0 + i * 5, 300.0 + i)],
);

void main() {
  setUpAll(AppDatabase.initFfi);

  // needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

  testWidgets('the pages of a PDF can be inserted and deleted, with their drawings, and each is taken back', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('pp_');
      final doc = pw.Document();
      for (final text in ['one', 'two']) {
        doc.addPage(pw.Page(build: (_) => pw.Text(text)));
      }
      final file = File('${dir.path}/a.pdf')..writeAsBytesSync(await doc.save());
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.pdfName = 'a.pdf';
      note.pdfPath = file.path;
      note.pdfPageCount = 2;
      note.background = PageBackground.grid;
      note.strokes[1] = [_stroke(), _stroke()];
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));

    // (PDFium works outside the test's clock, and a page that is loading keeps a spinner going)
    Future<void> settle() async {
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await settle();

    // (pages in the saved PDF, strokes by page)
    Future<String> saved() async {
      await tester.pump(const Duration(seconds: 1)); // the note is saved a moment after a change
      return (await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final n = (await repo.loadNote(id))!;
        final doc = await PdfDocument.openFile(n.pdfPath!);
        final pages = doc.pages.length;
        doc.dispose();
        return '$pages pages, strokes ${{for (final e in n.strokes.entries) if (e.value.isNotEmpty) e.key: e.value.length}}, notebook pages ${n.nativePages.toList()..sort()}';
      }))!;
    }

    Future<void> choose(String item) async {
      await tester.tap(find.byKey(const ValueKey('pages-menu')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text(item));
      await settle();
    }

    expect(find.byKey(const ValueKey('pages-menu')), findsOneWidget);
    expect(await saved(), '2 pages, strokes {1: 2}, notebook pages []');

    await choose('Insert a blank page before'); // the page in view is the first one
    expect(await saved(), '3 pages, strokes {2: 2}, notebook pages [0]');

    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await settle();
    expect(await saved(), '2 pages, strokes {1: 2}, notebook pages []');

    await tester.tap(find.byKey(const ValueKey('redo-any')));
    await settle();
    expect(await saved(), '3 pages, strokes {2: 2}, notebook pages [0]');

    // the added page shows the paper of the note (the grid), the others the file
    int papers() => find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PageBackgroundPainter).evaluate().length;
    expect(papers(), greaterThan(0));

    await choose('Delete page'); // the blank one, in view
    expect(await saved(), '2 pages, strokes {1: 2}, notebook pages []');
  });
}
