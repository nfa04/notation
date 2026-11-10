import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/pdf_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('the mark of a comment is kept with the note, and names its text box', () async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    final repo = NoteRepository(db);
    final id = await repo.createNote();
    final note = (await repo.loadNote(id))!;
    note.highlights[0] = [
      PdfHighlight(rect: const Rect.fromLTRB(10, 20, 110, 40), color: Colors.yellow),
      PdfHighlight(rect: const Rect.fromLTRB(10, 50, 60, 70), color: Colors.blue.withValues(alpha: 0.3), commentBox: 'box-1'),
    ];
    await repo.saveNote(note);
    final back = (await repo.loadNote(id))!.highlights[0]!;
    expect(back.map((h) => h.commentBox), [null, 'box-1']);
  });

  // needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

  testWidgets('exported, a comment is a comment of the PDF and not a box drawn on the page', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('cm_');
      final doc = pw.Document();
      doc.addPage(pw.Page(build: (_) => pw.Text('some text to comment on', style: const pw.TextStyle(fontSize: 24))));
      final file = File('${dir.path}/a.pdf')..writeAsBytesSync(await doc.save());
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.pdfName = 'a.pdf';
      note.pdfPath = file.path;
      note.pdfPageCount = 1;
      note.highlights[0] = [
        PdfHighlight(rect: const Rect.fromLTRB(60, 60, 260, 90), color: Colors.blueAccent.withValues(alpha: 0.3), commentBox: 'c1'),
        PdfHighlight(rect: const Rect.fromLTRB(60, 200, 260, 230), color: Colors.yellowAccent.withValues(alpha: 0.4)), // a plain highlight
      ];
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'c1', position: const Offset(300, 60), initialText: 'Comment: check the ünïcode ✓')];
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
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
    expect(problem, isNull);

    final text = latin1.decode(File(out).readAsBytesSync());
    expect(RegExp(r'/Subtype\s*/Highlight').allMatches(text).length, 1); // the comment; the plain highlight is part of the page
    expect(text, contains('/QuadPoints'));
    // the note's text, as UTF-16 in hex: "check the ünïcode ✓" and not the label "Comment:"
    String hex(String s) => [for (final u in s.codeUnits) u.toRadixString(16).padLeft(4, '0')].join().toUpperCase();
    final upper = text.toUpperCase();
    expect(upper, contains(hex('check the ünïcode ✓')));
    expect(upper, isNot(contains(hex('Comment:'))));
    // and the box that held it is not drawn on the page as well (its text is not in the overlay)
    expect(text, isNot(contains('check the')));
    await tester.pumpAndSettle();
  });
}
