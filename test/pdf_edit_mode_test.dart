import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/pdf/pdf_content_editor.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  // needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

  testWidgets('document mode on an imported PDF changes the text in the PDF itself', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('pe_');
      final doc = pw.Document();
      doc.addPage(pw.Page(build: (_) => pw.Text('alpha beta gamma', style: const pw.TextStyle(fontSize: 30))));
      final file = File('${dir.path}/a.pdf')..writeAsBytesSync(await doc.save());
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.pdfName = 'a.pdf';
      note.pdfPath = file.path;
      note.pdfPageCount = 1;
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));

    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 80 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    CustomPaint? layer() {
      for (final p in find.byType(CustomPaint).evaluate()) {
        final w = p.widget as CustomPaint;
        if (w.painter.runtimeType.toString() == '_PdfEditPainter') return w;
      }
      return null;
    }

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await settle(() => find.text('Document').evaluate().isNotEmpty && find.text('alpha').evaluate().isNotEmpty);
    await tester.tap(find.text('Document'));
    await settle(() => layer() != null && (layer()!.painter as dynamic).objects.isNotEmpty);
    final objects = (layer()!.painter as dynamic).objects as List<PdfEditObject>;
    expect(objects.single.text, 'alpha beta gamma');

    // tap on the line
    final page = tester.getRect(find.byKey(const ValueKey('page-0')));
    final scale = page.width / 595.28;
    await tester.tapAt(page.topLeft + objects.single.rect.center * scale);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Edit text'));
    await settle(() => find.widgetWithText(TextField, 'alpha beta gamma').evaluate().isNotEmpty);
    expect(find.byType(AlertDialog), findsNothing); // (edited on the page itself)
    await tester.enterText(find.widgetWithText(TextField, 'alpha beta gamma'), 'one two three');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(() => objects.single.text != (layer()!.painter as dynamic).objects.single.text);

    PdfEditObject line() => ((layer()!.painter as dynamic).objects as List<PdfEditObject>).single;
    expect(line().text, 'one two three');

    // underline it from the bar, then drag its bottom right corner outwards: bigger text, same proportions
    Future<void> pick() async {
      await tester.tapAt(page.topLeft + line().rect.center * scale);
      await tester.pump(const Duration(milliseconds: 300));
    }

    await pick();
    await tester.tap(find.byTooltip('Underline'));
    await settle(() => line().underlined);
    expect(line().underlined, isTrue);
    expect(find.byTooltip('Underline'), findsOneWidget); // (still picked, so its bar is still there)

    // a tap on nothing (beside the page, then on an empty part of it) puts the picked line down
    await tester.tapAt(Offset(page.left / 2, page.center.dy));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('Underline'), findsNothing);
    await pick();
    expect(find.byTooltip('Underline'), findsOneWidget);
    await tester.tapAt(page.topLeft + Offset(page.width / 2, page.height * 0.4));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('Underline'), findsNothing);

    final before = line();
    await pick();
    final corner = page.topLeft + before.rect.bottomRight * scale;
    final drag = await tester.startGesture(corner);
    await drag.moveBy(const Offset(30, 8));
    await drag.moveBy(const Offset(30, 8));
    await drag.up();
    await settle(() => line().rect.width > before.rect.width * 1.05);
    expect(line().rect.width, greaterThan(before.rect.width * 1.1));
    expect(line().rect.width / line().rect.height, closeTo(before.rect.width / before.rect.height, 0.3)); // (proportions kept)
    expect(line().underlined, isTrue);
    expect(line().fontSize, greaterThan(before.fontSize! * 1.05));

    // the editor saves a moment later
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    final saved = await tester.runAsync(() async => (await repo.loadNote(id))!.pdfPath);
    expect(saved, isNot('${dir.path}/a.pdf'));
    final editor = await tester.runAsync(() => PdfContentEditor.open(File(saved!).readAsBytesSync(), modulePath: pdfium.absolute.path));
    addTearDown(editor!.close);
    expect((await tester.runAsync(() => editor.objects(0)))!.map((o) => o.text), ['one two three']);
  });

  testWidgets('switching to another mode while a line is being edited keeps the edit', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('pe_');
      final doc = pw.Document();
      doc.addPage(pw.Page(build: (_) => pw.Text('alpha beta gamma', style: const pw.TextStyle(fontSize: 30))));
      final file = File('${dir.path}/a.pdf')..writeAsBytesSync(await doc.save());
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.pdfName = 'a.pdf';
      note.pdfPath = file.path;
      note.pdfPageCount = 1;
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));

    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 80 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    CustomPaint? layer() {
      for (final p in find.byType(CustomPaint).evaluate()) {
        final w = p.widget as CustomPaint;
        if (w.painter.runtimeType.toString() == '_PdfEditPainter') return w;
      }
      return null;
    }

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await settle(() => find.text('Document').evaluate().isNotEmpty && find.text('alpha').evaluate().isNotEmpty);
    await tester.tap(find.text('Document'));
    await settle(() => layer() != null && (layer()!.painter as dynamic).objects.isNotEmpty);
    final line = ((layer()!.painter as dynamic).objects as List<PdfEditObject>).single;
    final page = tester.getRect(find.byKey(const ValueKey('page-0')));
    await tester.tapAt(page.topLeft + line.rect.center * (page.width / 595.28));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Edit text'));
    await settle(() => find.widgetWithText(TextField, 'alpha beta gamma').evaluate().isNotEmpty);
    await tester.enterText(find.widgetWithText(TextField, 'alpha beta gamma'), 'one two three');

    // (not confirmed: the mode is changed with the text still in the field)
    await tester.tap(find.text('Select'));
    await settle(() => false); // (the edit is made while frames are drawn)
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));

    final saved = await tester.runAsync(() async => (await repo.loadNote(id))!.pdfPath);
    expect(saved, isNot('${dir.path}/a.pdf'));
    final editor = await tester.runAsync(() => PdfContentEditor.open(File(saved!).readAsBytesSync(), modulePath: pdfium.absolute.path));
    addTearDown(editor!.close);
    expect((await tester.runAsync(() => editor.objects(0)))!.map((o) => o.text), ['one two three']);
  });

  testWidgets('a picture in an imported PDF can be resized by its handles', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('pe_');
      final picture = img.Image(width: 40, height: 20);
      img.fill(picture, color: img.ColorRgb8(200, 30, 30));
      final doc = pw.Document();
      doc.addPage(pw.Page(
        build: (_) => pw.Align(
          alignment: pw.Alignment.topLeft,
          child: pw.Image(pw.MemoryImage(img.encodePng(picture)), width: 200, height: 100),
        ),
      ));
      final file = File('${dir.path}/a.pdf')..writeAsBytesSync(await doc.save());
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.pdfName = 'a.pdf';
      note.pdfPath = file.path;
      note.pdfPageCount = 1;
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));

    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 80 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    CustomPaint? layer() {
      for (final p in find.byType(CustomPaint).evaluate()) {
        final w = p.widget as CustomPaint;
        if (w.painter.runtimeType.toString() == '_PdfEditPainter') return w;
      }
      return null;
    }

    List<PdfEditObject> objects() => (layer()!.painter as dynamic).objects as List<PdfEditObject>;

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await settle(() => find.text('Document').evaluate().isNotEmpty);
    await tester.tap(find.text('Document'));
    await settle(() => layer() != null && objects().isNotEmpty);
    final picture = objects().single;
    expect(picture.kind, PdfObjectKind.image);

    final page = tester.getRect(find.byKey(const ValueKey('page-0')));
    final scale = page.width / 595.28;
    Future<void> pick() async {
      await tester.tapAt(page.topLeft + objects().single.rect.center * scale);
      await tester.pump(const Duration(milliseconds: 300));
    }

    await pick();
    final drag = await tester.startGesture(page.topLeft + picture.rect.bottomRight * scale);
    await drag.moveBy(const Offset(30, 15));
    await drag.moveBy(const Offset(30, 15));
    await drag.up();
    await settle(() => objects().single.rect.width > picture.rect.width * 1.05);
    expect(objects().single.rect.width, greaterThan(picture.rect.width * 1.1));

    // and it can be picked and dragged on the edge again afterwards
    await pick();
    final wide = objects().single;
    final edge = await tester.startGesture(page.topLeft + wide.rect.centerRight * scale);
    await edge.moveBy(const Offset(40, 0));
    await edge.moveBy(const Offset(40, 0));
    await edge.up();
    await settle(() => objects().single.rect.width > wide.rect.width * 1.05);
    expect(objects().single.rect.width, greaterThan(wide.rect.width * 1.1));
    expect(objects().single.rect.height, closeTo(wide.rect.height, 1));

    // turn it a quarter by the handle above it: width and height trade places, round the same middle
    await pick();
    final flat = objects().single;
    final grip = page.topLeft + Offset(flat.rect.center.dx, flat.rect.top > 52 ? flat.rect.bottom + 26 : flat.rect.top - 26) * scale;
    final turn = await tester.startGesture(grip);
    await turn.moveBy(const Offset(10, 10));
    // (to the right of the middle, level with it: 90 degrees)
    await turn.moveTo(page.topLeft + Offset(flat.rect.center.dx + 80, flat.rect.center.dy) * scale);
    await turn.up();
    await settle(() => (objects().single.rect.height - flat.rect.height).abs() > 5);
    expect(objects().single.rect.width, closeTo(flat.rect.height, 2));
    expect(objects().single.rect.height, closeTo(flat.rect.width, 2));
    expect(objects().single.rect.center.dx, closeTo(flat.rect.center.dx, 2));
    expect(objects().single.rect.center.dy, closeTo(flat.rect.center.dy, 2));
  });
}
