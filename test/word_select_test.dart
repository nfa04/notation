import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  // needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

  testWidgets('a double click with the mouse selects the word under it, and makes no text box', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('ws_');
      final doc = pw.Document();
      doc.addPage(pw.Page(build: (_) => pw.Text('alpha beta gamma', style: const pw.TextStyle(fontSize: 30))));
      final file = File('${dir.path}/a.pdf')..writeAsBytesSync(await doc.save());
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.pdfName = 'a.pdf';
      note.pdfPath = file.path;
      note.pdfPageCount = 1;
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    for (var i = 0; i < 60 && find.text('beta ').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final beta = find.text('beta ');
    expect(beta, findsOneWidget);
    final at = tester.getCenter(beta);

    // two quick clicks of the mouse in the middle of the word
    for (var i = 0; i < 2; i++) {
      final g = await tester.startGesture(at, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
      await g.up();
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump(const Duration(milliseconds: 600)); // (a page still being read shows a spinner, which never settles)
    expect(find.text('Type text...'), findsNothing); // no text box

    // the word is selected: the highlight button of the top bar marks exactly it
    expect(find.text('Highlight'), findsWidgets);
    await tester.tap(find.text('Highlight').first);
    await tester.pump(const Duration(milliseconds: 600)); // (a page still being read shows a spinner, which never settles)
    final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is HighlightsPainter);
    final marks = [for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as HighlightsPainter).highlights.map((h) => h.rect)];
    expect(marks.length, 1);
    final word = tester.getRect(beta);
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    final mark = marks.single.shift(origin);
    expect(mark.center.dx, closeTo(word.center.dx, word.width)); // on the word "beta", not its neighbours
    expect(mark.width, lessThan(word.width * 2));
  });
}
