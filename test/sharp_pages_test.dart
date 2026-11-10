import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('zooming in swaps in a sharper picture of the page', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('sharp_');
      final doc = pw_widgets.Document();
      doc.addPage(pw_widgets.Page(build: (_) => pw_widgets.Text('Sharp page', style: const pw_widgets.TextStyle(fontSize: 30))));
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
    // (a page is drawn through a RawImage, at the size of the paper: the normal picture has about as many pixels across as the screen
    // shows the page with; the sharper one is only what is on screen, with many more pixels for each unit of the page)
    double density(Element e) => (e.widget as RawImage).image!.width / (e.renderObject! as RenderBox).size.width;
    final pictures = find.byWidgetPredicate((w) => w is RawImage && w.image != null);
    final normal = find.byElementPredicate((e) => pictures.evaluate().contains(e) && density(e) < 2);
    final sharper = find.byElementPredicate((e) => pictures.evaluate().contains(e) && density(e) >= 4);
    for (var i = 0; i < 40 && normal.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(normal, findsWidgets); // the normal picture of the page
    expect(normal.evaluate().first.widget, isA<RawImage>().having((r) => r.image!.width, 'pixels across', lessThanOrEqualTo(1024)),
        reason: 'as wide as the screen shows the page (800), in steps of 256: not the 1654 of 200 dpi');
    expect(sharper, findsNothing); // and nothing sharper at normal size

    // zoom in a lot
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(mouse.hover(const Offset(800, 400)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -700)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    // a moment after the zoom has settled the sharper page is rendered
    for (var i = 0; i < 60 && sharper.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    }
    expect(sharper, findsOneWidget); // more pixels than the normal picture offers
    final patch = sharper.evaluate().single;
    final box = patch.renderObject! as RenderBox;
    expect(box.size.width, lessThan(800), reason: 'only what is on screen (and a little around it), not the whole page');
    expect((patch.widget as RawImage).image!.width * (patch.widget as RawImage).image!.height, lessThan(16e6));
  });
}
