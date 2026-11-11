import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/search/search_query.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('what the handwriting reader made travels in the note file, and does not change what counts as the same note', () async {
    final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
    final id = await repo.createNote(title: 'Statistics');
    await repo.text.saveInkText(id, [InkText(key: 'k1', page: 2, text: 'Var(Y)=1/4', bounds: const Rect.fromLTRB(1, 2, 30, 40))], {'k1'});
    await repo.text.saveInkReads(id, [(key: 'k2', ids: '', text: null, latex: r'\frac{1}{2}'), (key: 'k3', ids: 'a,b', text: 'hi', latex: null)]);

    final dir = await Directory.systemTemp.createTemp('ink_readings_');
    addTearDown(() => dir.delete(recursive: true));
    final files = NoteFileService(repo, supportDirectory: () async => dir);
    final bytes = (await files.exportBytes(id))!;
    final copy = await files.importBytes(bytes);

    final texts = await repo.text.inkTexts(copy.noteId);
    expect(texts.single.key, 'k1');
    expect(texts.single.page, 2);
    expect(texts.single.text, 'Var(Y)=1/4');
    expect(texts.single.bounds, const Rect.fromLTRB(1, 2, 30, 40));
    final reads = {for (final r in await repo.text.inkReads(copy.noteId)) r.key: r};
    expect(reads['k2']!.latex, r'\frac{1}{2}');
    expect(reads['k3']!.ids, 'a,b');
    expect(reads['k3']!.text, 'hi');

    // a device that read more is still the same note
    await repo.text.saveInkText(id, [InkText(key: 'k9', page: 0, text: 'more', bounds: const Rect.fromLTRB(0, 0, 1, 1))], {'k1', 'k9'});
    final more = (await files.exportBytes(id))!;
    expect(sameNoteContent(bytes, more), isTrue);
    expect(noteContentDigest(bytes), noteContentDigest(more));
  });

  test('a note without readings writes no ink section and imports none', () async {
    final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
    final id = await repo.createNote(title: 'Plain');
    final dir = await Directory.systemTemp.createTemp('ink_readings_');
    addTearDown(() => dir.delete(recursive: true));
    final files = NoteFileService(repo, supportDirectory: () async => dir);
    final bytes = (await files.exportBytes(id))!;
    expect(decodeNoteFile(bytes).ink.isEmpty, isTrue);
    final copy = await files.importBytes(bytes);
    expect(await repo.text.inkTexts(copy.noteId), isEmpty);
    expect(await repo.text.inkReads(copy.noteId), isEmpty);
  });

  test('a note that is replaced by one from another device keeps the readings it has and gains those of the file', () async {
    final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
    final from = await repo.createNote(title: 'Tablet');
    await repo.text.saveInkText(from, [InkText(key: 'shared', page: 0, text: 'tablet reading', bounds: const Rect.fromLTRB(0, 0, 1, 1))], {'shared'});
    await repo.text.saveInkReads(from, [(key: 'f1', ids: '', text: null, latex: 'a+b')]);
    final dir = await Directory.systemTemp.createTemp('ink_readings_');
    addTearDown(() => dir.delete(recursive: true));
    final files = NoteFileService(repo, supportDirectory: () async => dir);
    final bytes = (await files.exportBytes(from))!;

    final here = await repo.createNote(title: 'Laptop');
    await repo.text.saveInkText(here, [
      InkText(key: 'shared', page: 0, text: 'laptop reading', bounds: const Rect.fromLTRB(0, 0, 1, 1)),
      InkText(key: 'mine', page: 1, text: 'only here', bounds: const Rect.fromLTRB(0, 0, 2, 2)),
    ], {'shared', 'mine'});
    await repo.text.saveInkReads(here, [(key: 'f2', ids: '', text: null, latex: 'c+d')]);
    await files.restoreInto(here, bytes);

    final texts = {for (final t in await repo.text.inkTexts(here)) t.key: t.text};
    expect(texts, {'shared': 'tablet reading', 'mine': 'only here'});
    final reads = {for (final r in await repo.text.inkReads(here)) r.key: r.latex};
    expect(reads, {'f1': 'a+b', 'f2': 'c+d'});
  });
}
