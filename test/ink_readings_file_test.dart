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
}
