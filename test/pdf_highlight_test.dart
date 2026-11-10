import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('highlighting a word marks that word, not another copy of it', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    late Directory dir;
    const line = 'alpha beta alpha gamma alpha';
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('hl_');
      final doc = pw.Document();
      doc.addPage(pw.Page(build: (_) => pw.Text(line, style: const pw.TextStyle(fontSize: 30))));
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

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    // the page's text layer has one piece per word: 'alpha ' twice and the last 'alpha'
    final pieces = [find.text('alpha ').at(0), find.text('alpha ').at(1), find.text('alpha').last];
    for (var i = 0; i < 60 && find.text('alpha ').evaluate().length < 2; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('alpha '), findsNWidgets(2));

    List<Rect> marks() {
      final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is HighlightsPainter);
      return [for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as HighlightsPainter).highlights.map((h) => h.rect)];
    }

    final lefts = <double>[];
    for (final at in [0, 1, 2]) {
      final point = tester.getCenter(pieces[at]);
      final before = marks().length;
      // a long press selects the word under the finger
      await tester.longPressAt(point);
      await tester.pump(const Duration(milliseconds: 400));
      // (in a browser a press outside the text drops its selection, and the button with it, before the press ends: so the top bar's
      // buttons are part of the selection's own tap group, which a native run cannot show)
      expect(
        find.ancestor(of: find.byIcon(Icons.highlight).first, matching: find.byWidgetPredicate((w) => w is TapRegion && w.groupId == SelectableRegion)),
        findsOneWidget,
      );
      await tester.tap(find.text('Highlight').first);
      await tester.pump(const Duration(milliseconds: 600)); // (a page still being read shows a spinner, which never settles)
      final now = marks();
      expect(now.length, before + 1, reason: 'one word, one mark (copy at $at)');
      lefts.add(now.last.left);
      // click on an empty part of the page: the selection goes away
      await tester.tapAt(tester.getTopLeft(find.byKey(const ValueKey('page-0'))) + const Offset(300, 700));
      await tester.pump(const Duration(milliseconds: 600)); // (a page still being read shows a spinner, which never settles)
    }
    expect(lefts[0], lessThan(lefts[1]));
    expect(lefts[1], lessThan(lefts[2]));
  });

  // window width, and how many times zoomed in
  for (final (width, zoomIns) in [(1600.0, 0), (1000.0, 0), (800.0, 0), (1000.0, 3), (600.0, 0), (600.0, 3)]) {
    testWidgets('a new comment is a bubble beside the page that stays when clicked (window $width wide, zoomed in $zoomIns times)', skip: !pdfium.existsSync(), (tester) async {
      Pdfrx.pdfiumModulePath = pdfium.absolute.path;
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late NoteRepository repo;
      late String id;
      late Directory dir;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('cm_');
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

      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
      for (var i = 0; i < 60 && find.text('beta ').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      // Ctrl and the wheel
      if (zoomIns > 0) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      for (var i = 0; i < zoomIns; i++) {
        final mouse = TestPointer(1, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(mouse.hover(tester.getCenter(find.byKey(const ValueKey('page-0')))));
        await tester.sendEventToBinding(mouse.scroll(const Offset(0, -100)));
        await tester.pump(const Duration(milliseconds: 300));
      }
      if (zoomIns > 0) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      for (var i = 0; i < zoomIns * 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      final word = find.text('beta ');
      await tester.ensureVisible(word);
      await tester.pump(const Duration(milliseconds: 300));
      if (tester.getRect(word).top < 200) { // (under the top bar: the wheel brings it further down)
        final mouse = TestPointer(2, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(mouse.hover(const Offset(500, 500)));
        await tester.sendEventToBinding(mouse.scroll(Offset(0, tester.getRect(word).top - 300)));
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.longPressAt(tester.getCenter(word));
      await tester.pump(const Duration(milliseconds: 400));
      // the button in the top bar (in a narrow window it is scrolled out of sight first)
      final comment = find.text('Comment').first;
      await tester.ensureVisible(comment);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(comment);
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      final card = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('comment-card-'));
      expect(card, findsOneWidget, reason: 'the comment is a bubble');
      final page = tester.getRect(find.byKey(const ValueKey('page-0')));
      expect(tester.getRect(card).left, greaterThanOrEqualTo(page.right - 1), reason: 'beside the page, not on it');

      final field = find.descendant(of: card, matching: find.byType(TextField));
      await tester.ensureVisible(field);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(field, kind: width < 700 ? PointerDeviceKind.touch : PointerDeviceKind.mouse); // (a tablet is touched)
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(card, findsOneWidget, reason: 'clicking it keeps it');
      await tester.enterText(field, 'Comment: noted');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.descendant(of: card, matching: find.text('Comment: noted')), findsOneWidget);
    });
  }
}
