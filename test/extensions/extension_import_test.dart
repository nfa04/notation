import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/tag_repository.dart';
import 'package:notes/extensions/extension_service.dart';
import 'package:notes/import/extension_import.dart';
import 'package:notes/markdown/document_images.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]);

void main() {
  setUpAll(AppDatabase.initFfi);
  late NoteRepository repo;
  late TagRepository tags;
  late Directory images;

  setUp(() async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    for (final table in ['note_tags', 'notes', 'folders']) {
      await db.delete(table);
    }
    repo = NoteRepository(db);
    tags = TagRepository(db);
    images = Directory.systemTemp.createTempSync('ext_import_images');
    DocumentImages.dir = images.path;
  });
  tearDown(() {
    DocumentImages.dir = null;
    images.deleteSync(recursive: true);
  });

  test('notes land in folders with links, pictures and tags', () async {
    final mapped = <String, String>{};
    final report = await importExtensionNotes(
      notes: [
        ImportedNote(path: 'Inbox/Ideas', title: 'Ideas', markdown: 'See [[Plan]] and [[Plan|the plan]], [[Nowhere]], [x](source:p1)\n\n![fig](fig.png)', tags: ['a', 'b'], sourceId: 'i1', attachments: {'fig.png': png}),
        const ImportedNote(path: 'Inbox/Plan', title: 'Plan', markdown: 'Back to [[ideas]]', sourceId: 'p1'),
        const ImportedNote(path: '', title: 'Loose', markdown: 'x'),
      ],
      repository: repo,
      tags: tags,
      rootName: 'From Test',
      onMapped: (s, n) => mapped[s] = n,
      notices: ['one notice'],
    );
    expect(report.notes, 3);
    expect(report.failed, isEmpty);
    expect(report.pictures, 1);
    expect(report.links, 4);
    expect(report.missing, {'Nowhere'});
    expect(report.notices, ['one notice']);
    final ids = {for (final n in await repo.listNotes()) n.title: n.id};
    final ideas = (await repo.loadNote(ids['Ideas']!))!.documentText;
    expect(ideas, contains('[Plan](note:${ids['Plan']})'));
    expect(ideas, contains('[the plan](note:${ids['Plan']})'));
    expect(ideas, contains('Nowhere'));
    expect(ideas, isNot(contains('[[')));
    expect(ideas, matches(RegExp(r'!\[fig\]\(image:[^)]+\.png\)')));
    expect((await repo.loadNote(ids['Plan']!))!.documentText, contains('[ideas](note:${ids['Ideas']})'));
    expect(await tags.tagsOf(ids['Ideas']!), ['a', 'b']);
    final folders = {for (final f in await repo.listFolders()) f.name: f};
    expect(folders.keys, {'From Test', 'Inbox'});
    expect(folders['Inbox']!.parentId, folders['From Test']!.id);
    expect((await repo.listNotes()).firstWhere((n) => n.title == 'Loose').folderId, folders['From Test']!.id);
    expect(mapped, {'i1': ids['Ideas'], 'p1': ids['Plan']});
  });

  test('the dates the other app had are kept', () async {
    final created = DateTime(2020, 3, 4, 5, 6), updated = DateTime(2021, 7, 8, 9, 10);
    await importExtensionNotes(notes: [ImportedNote(path: '', title: 'Old', markdown: 'x', created: created, updated: updated), ImportedNote(path: '', title: 'OnlyEdited', markdown: 'x', updated: updated)], repository: repo);
    final ids = {for (final n in await repo.listNotes()) n.title: n.id};
    final times = (await repo.noteTimes(ids['Old']!))!;
    expect(times.created, created);
    expect(times.edited, updated);
    final one = (await repo.noteTimes(ids['OnlyEdited']!))!;
    expect(one.created, updated);
    expect(one.edited, updated);
  });

  test('running it again updates the note it made before instead of making another', () async {
    final mapped = <String, String>{};
    await importExtensionNotes(notes: [const ImportedNote(path: '', title: 'Same', markdown: 'one', sourceId: 's')], repository: repo, onMapped: (s, n) => mapped[s] = n);
    final again = <String, String>{};
    final report = await importExtensionNotes(
      notes: [const ImportedNote(path: '', title: 'Same (edited)', markdown: 'two', sourceId: 's')],
      repository: repo,
      known: mapped,
      onMapped: (s, n) => again[s] = n,
    );
    expect(report.notes, 1);
    expect(again, mapped);
    final all = await repo.listNotes();
    expect(all, hasLength(1));
    expect(all.single.title, 'Same (edited)');
    expect((await repo.loadNote(all.single.id))!.documentText, 'two');
  });
}
