import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_pdfs.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/pdf/pdf_content_editor.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'pdf_words.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  // needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

  testWidgets('the text of a PDF is edited in the file its page comes from, in a note with several PDFs', skip: !pdfium.existsSync(), timeout: const Timeout(Duration(minutes: 3)), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    late Directory dir;
    late String shaOfA;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('pt_');
      Future<NotePdf> make(String name, String text) async {
        final doc = pw.Document();
        doc.addPage(pw.Page(build: (_) => pw.Text(text, style: const pw.TextStyle(fontSize: 30))));
        final file = File('${dir.path}/$name.pdf')..writeAsBytesSync(await doc.save());
        return NotePdf(name: '$name.pdf', path: file.path, sha256: sha256.convert(file.readAsBytesSync()).toString(), pages: 1);
      }

      final a = await make('a', 'alpha beta gamma');
      final b = await make('b', 'bravo');
      shaOfA = a.sha256;
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      // b's page first, then a's
      final table = NotePdfs([a, b], const [PdfPageRef(1, 0), PdfPageRef(0, 0)]);
      note.pdfName = a.name;
      note.pdfPath = a.path;
      note.pdfSha256 = a.sha256;
      note.pdfPageCount = 2;
      note.pdfs = table;
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

    List<PdfEditObject> objects() => ((layer()?.painter as dynamic)?.objects as List<PdfEditObject>?) ?? const [];

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await settle(() => find.text('Edit PDF').evaluate().isNotEmpty && pdfWords(tester, 'bravo').isNotEmpty);
    await tester.tap(find.text('Edit PDF'));
    await settle(() => objects().isNotEmpty);
    expect(objects().single.text, 'bravo', reason: 'the first page is the first page of b');

    // the line is changed on the page
    final page = tester.getRect(find.byKey(const ValueKey('page-0')));
    final scale = page.width / 595.28;
    await tester.tapAt(page.topLeft + objects().single.rect.center * scale);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Edit text'));
    await settle(() => find.widgetWithText(TextField, 'bravo').evaluate().isNotEmpty);
    await tester.enterText(find.widgetWithText(TextField, 'bravo'), 'charlie');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(() => objects().isNotEmpty && objects().single.text == 'charlie');
    expect(objects().single.text, 'charlie');

    // the note has b as the edited file; a is the file it was, and the pages are where they were
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    final saved = (await tester.runAsync(() async => (await repo.loadNote(id))!))!;
    final table = saved.pdfs!;
    expect(table.layout.join(' '), '1:0 0:0');
    expect(table.files[0].path, '${dir.path}/a.pdf');
    expect(table.files[0].sha256, shaOfA);
    expect(table.files[1].path, isNot('${dir.path}/b.pdf'));
    expect(table.files[1].sha256, sha256.convert(File(table.files[1].path).readAsBytesSync()).toString());
    final editor = await tester.runAsync(() => PdfContentEditor.open(File(table.files[1].path).readAsBytesSync(), modulePath: pdfium.absolute.path));
    addTearDown(editor!.close);
    expect((await tester.runAsync(() => editor.objects(0)))!.map((o) => o.text), ['charlie']);

    // taking the edit back gives the file it was
    await tester.tap(find.byTooltip('Undo the last change to the PDF'));
    await settle(() => objects().isNotEmpty && objects().single.text == 'bravo');
    expect(objects().single.text, 'bravo');
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    final back = (await tester.runAsync(() async => (await repo.loadNote(id))!.pdfs!))!;
    expect(back.files[1].path, '${dir.path}/b.pdf');
  });
}
