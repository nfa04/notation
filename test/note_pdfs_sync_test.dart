import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_pdfs.dart';
import 'package:notes/data/note_repository.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('a note with many big PDFs travels as a note file between devices (how the devices and the cloud folder carry notes), and again after a change of order', () async {
    final root = await Directory.systemTemp.createTemp('pdf_sync_');
    addTearDown(() => root.delete(recursive: true));
    final here = Directory('${root.path}/here')..createSync();
    final there = Directory('${root.path}/there')..createSync();
    final notesHere = NoteRepository(await AppDatabase.open(path: '${here.path}/n.db'));
    final notesThere = NoteRepository(await AppDatabase.open(path: '${there.path}/n.db'));
    final hereFiles = NoteFileService(notesHere, supportDirectory: () async => here);
    final thereFiles = NoteFileService(notesThere, supportDirectory: () async => there);

    // eight files of 4 MB each (a PDF of that size does not compress)
    final random = Random(3);
    final files = <NotePdf>[];
    final pdfs = Directory('${here.path}/pdfs')..createSync();
    for (var i = 0; i < 8; i++) {
      final bytes = Uint8List(4 * 1024 * 1024);
      for (var k = 0; k < bytes.length; k += 4) {
        bytes[k] = random.nextInt(256);
      }
      bytes.setRange(0, 5, '%PDF-'.codeUnits);
      final f = File('${pdfs.path}/$i.pdf')..writeAsBytesSync(bytes);
      files.add(NotePdf(name: 'part $i.pdf', path: f.path, sha256: sha256.convert(bytes).toString(), pages: 10));
    }
    final table = NotePdfs.inOrder(files);
    final id = await notesHere.createNote(title: 'Big');
    final note = (await notesHere.loadNote(id))!
      ..pdfName = files.first.name
      ..pdfPath = files.first.path
      ..pdfSha256 = files.first.sha256
      ..pdfPageCount = table.pageCount
      ..pdfs = table;
    await notesHere.saveNote(note);

    final watch = Stopwatch()..start();
    final bytes = (await hereFiles.exportBytes(id))!;
    final exported = watch.elapsed;

    // it is put on the other device as a note that has the same id as the one it came from (a sync)
    final theirId = await notesThere.createNote(title: 'placeholder');
    watch.reset();
    await thereFiles.restoreInto(theirId, bytes);
    final restored = watch.elapsed;
    final got = (await notesThere.loadNote(theirId))!;
    expect(got.pdfs!.files.length, 8);
    expect(got.pdfs!.layout.join(' '), table.layout.join(' '));
    expect(got.pdfPageCount, 80);
    for (var i = 0; i < 8; i++) {
      expect(sha256.convert(File(got.pdfs!.files[i].path).readAsBytesSync()).toString(), files[i].sha256);
      expect(got.pdfs!.files[i].path, startsWith(there.path));
    }
    printOnFailure('export ${exported.inMilliseconds} ms, restore ${restored.inMilliseconds} ms, ${bytes.length ~/ 1024 ~/ 1024} MB');

    // pages put in another order here, and the change goes there
    final moved = (await notesHere.loadNote(id))!..pdfs = table.withLayout(table.layout.reversed.toList());
    await notesHere.saveNote(moved);
    final again = (await hereFiles.exportBytes(id))!;
    await thereFiles.restoreInto(theirId, again);
    final after = (await notesThere.loadNote(theirId))!;
    expect(after.pdfs!.layout.first.toString(), '7:9');
    expect(after.pdfs!.files.length, 8);
    // (what the first restore wrote is not left behind)
    final left = Directory('${there.path}/pdfs').listSync().whereType<File>().length;
    expect(left, 8, reason: 'files on the other device after two restores (the files that came again are the ones it had)');

    // the same as a copy of the note
    final copy = await thereFiles.importBytes(again);
    final copied = (await notesThere.loadNote(copy.noteId))!;
    expect(copied.pdfs!.files.length, 8);
    expect(copied.pdfs!.layout.first.toString(), '7:9');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
