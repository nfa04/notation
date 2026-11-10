import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:pdf/widgets.dart' as pw_widgets;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  // needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

  Future<(NoteRepository, String, Directory)> pdfNote(WidgetTester tester, int pages) async {
    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('pdf_scroll_');
      final doc = pw_widgets.Document();
      for (var p = 0; p < pages; p++) {
        doc.addPage(pw_widgets.Page(build: (_) => pw_widgets.Text('Page number ${p + 1}', style: const pw_widgets.TextStyle(fontSize: 30))));
      }
      final file = File('${dir.path}/a.pdf')..writeAsBytesSync(await doc.save());
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.pdfName = 'a.pdf';
      note.pdfPath = file.path;
      note.pdfPageCount = pages;
      await repo.saveNote(note);
    });
    return (repo, id, dir);
  }

  /// Lets real work (PDFium, the isolate for the words) go on until [done], pumping frames meanwhile.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('a page shows its picture first and its words after, as wide as the screen shows it', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (repo, id, dir) = await pdfNote(tester, 3);
    addTearDown(() => dir.delete(recursive: true));

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    final picture = find.byWidgetPredicate((w) => w is RawImage && w.image != null);
    await until(tester, () => picture.evaluate().isNotEmpty);
    expect(picture, findsWidgets);
    // the page is 800 across on this screen of one pixel per unit: its picture is 1024 (a step of 256), not the 1654 of 200 dpi
    expect((picture.evaluate().first.widget as RawImage).image!.width, 1024);

    // (the text layer has a piece of text for each word: the line's words with the space after them)
    final words = find.byWidgetPredicate((w) => w is Text && (w.data ?? '').trim() == 'number');
    await until(tester, () => words.evaluate().isNotEmpty);
    expect(words, findsOneWidget, reason: 'the words of the page come to its text layer');
  });

  testWidgets('dragging the scrollbar previews small pictures, and only of the page it is at', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (repo, id, dir) = await pdfNote(tester, 30);
    addTearDown(() => dir.delete(recursive: true));

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await until(tester, () => find.byWidgetPredicate((w) => w is RawImage && w.image != null).evaluate().isNotEmpty);

    // a quick drag down most of the bar, too quick for anything to be read on the way, then the finger rests
    final thumb = find.byKey(const ValueKey('page-scrollbar-thumb'));
    final gesture = await tester.startGesture(tester.getCenter(thumb));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(0, 50));
      await tester.pump();
    }
    final preview = find.byKey(const ValueKey('page-preview'));
    expect(preview, findsOneWidget);
    final shown = find.descendant(of: preview, matching: find.byWidgetPredicate((w) => w is RawImage && w.image != null));
    await until(tester, () => shown.evaluate().isNotEmpty);
    expect(shown, findsOneWidget, reason: 'the page the finger rests at');
    expect((shown.evaluate().single.widget as RawImage).image!.width, lessThanOrEqualTo(300), reason: 'a small picture, not the page itself');
    await gesture.up();
    await tester.pump();
  });
}
