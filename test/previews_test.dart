import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/pdf_note.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/previews/note_preview.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('the first page of a note is drawn once, kept, and drawn again when the note changed', (tester) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('previews_');
      addTearDown(() => dir.delete(recursive: true));
      final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      final id = await repo.createNote(title: 'Pic');
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = [DrawingStroke(color: Colors.black, width: 4, points: const [Offset(50, 50), Offset(400, 300)])];
      await repo.saveNote(note);

      final previews = NotePreviews(repo, directory: () async => dir);
      final changed = DateTime.fromMillisecondsSinceEpoch(1000);
      final file = await previews.of(id, changed);
      expect(file, isNotNull);
      expect(file!.lengthSync(), greaterThan(200));
      expect(identical(await previews.of(id, changed), file) || (await previews.of(id, changed))!.path == file.path, isTrue);

      final newer = await NotePreviews(repo, directory: () async => dir).of(id, DateTime.fromMillisecondsSinceEpoch(2000));
      expect(newer!.path, isNot(file.path));
      expect(file.existsSync(), isFalse); // the picture of the earlier state went

    });
  });

  testWidgets('the pictures of another note stay, also when its id begins like this one', (tester) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('previews_');
      addTearDown(() => dir.delete(recursive: true));
      final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      final id = await repo.createNote(title: 'Pic');
      final leftOver = File('${dir.path}/$id-1000.png')..writeAsBytesSync([1]); // from an earlier run of the app
      final other = File('${dir.path}/$id-more-1000.png')..writeAsBytesSync([1]);
      final file = await NotePreviews(repo, directory: () async => dir).of(id, DateTime.fromMillisecondsSinceEpoch(2000));
      expect(file, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(leftOver.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
      expect(file!.existsSync(), isTrue);
    });
  });

  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');
  testWidgets('a note made from a PDF holds it, and its preview is the first page', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('pdf_note_');
      addTearDown(() => dir.delete(recursive: true));
      final doc = pw.Document();
      doc.addPage(pw.Page(build: (_) => pw.Text('First')));
      doc.addPage(pw.Page(build: (_) => pw.Text('Second')));
      final source = File('${dir.path}/Lecture 1.pdf')..writeAsBytesSync(await doc.save());
      final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      final id = await createNoteFromPdf(repo, source.path, directory: Directory('${dir.path}/copies'));
      final note = (await repo.loadNote(id))!;
      expect(note.title, 'Lecture 1');
      expect(note.pdfPageCount, 2);
      expect(note.pdfName, 'Lecture 1.pdf');
      expect(File(note.pdfPath!).existsSync(), isTrue);
      expect(note.pdfSha256, isNotNull);
      final preview = await NotePreviews(repo, directory: () async => Directory('${dir.path}/p')).of(id, DateTime.now());
      expect(preview, isNotNull);
    });
  });
}
