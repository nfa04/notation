import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/link_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/markdown/mention.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('the ids a text links to', () {
    expect(linkedNoteIds('see ${noteLink('a1', 'Algebra')} and ${noteLink('b2', 'Biology')} and [web](https://x.y)'), {'a1', 'b2'});
    expect(linkedNoteIds('nothing'), isEmpty);
  });

  test('a snippet shows the label of the link, not its address, with the words around', () {
    final text = 'First we looked at ${noteLink('a1', 'Algebra')} in class, which was a long lecture about groups and rings and fields.';
    final snippet = snippetAround(text, noteLinkPattern('a1').firstMatch(text)!);
    expect(snippet, contains('Algebra in class'));
    expect(snippet, isNot(contains('note:')));
    expect(snippet.endsWith('…'), isTrue);
  });

  group('LinkRepository', () {
    late Database db;
    late NoteRepository notes;
    late LinkRepository links;

    setUpAll(AppDatabase.initFfi);
    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      notes = NoteRepository(db);
      links = LinkRepository(db);
    });
    tearDown(() => db.close());

    Future<void> box(String note, int page, String text) =>
        db.insert('text_boxes', {'id': 'b${text.hashCode}', 'note_id': note, 'page_index': page, 'x': 0, 'y': 0, 'width': 100, 'height': 50, 'text': text});

    test('links in text boxes and in the written document are found, with their page', () async {
      final target = await notes.createNote(title: 'Algebra');
      final a = await notes.createNote(title: 'Lecture');
      final b = await notes.createNote(title: 'Diary');
      await box(a, 2, 'Revise ${noteLink(target, 'Algebra')} before Friday');
      await db.update('notes', {'document_text': 'Today: ${noteLink(target, 'my algebra notes')}.'}, where: 'id = ?', whereArgs: [b]);
      await box(a, 0, 'Nothing here');
      final found = await links.linksTo(target);
      expect(found.map((l) => (l.noteId, l.page)).toSet(), {(a, 2), (b, null)});
      expect(found.every((l) => l.linked), isTrue);
      expect(found.firstWhere((l) => l.noteId == a).snippet, contains('Revise Algebra before Friday'));
      expect(found.firstWhere((l) => l.noteId == a).title, 'Lecture');
    });

    test('a link to another note, a note linking to itself, trashed and locked notes are not backlinks', () async {
      final target = await notes.createNote(title: 'Algebra');
      final other = await notes.createNote(title: 'Other');
      final self = target;
      final gone = await notes.createNote(title: 'Gone');
      final locked = await notes.createNote(title: 'Secret');
      await box(other, 0, 'See ${noteLink('someone-else', 'X')}');
      await box(self, 0, 'I am ${noteLink(target, 'me')}');
      await box(gone, 0, 'Old ${noteLink(target, 'Algebra')}');
      await box(locked, 0, 'Hidden ${noteLink(target, 'Algebra')}');
      await notes.trashNote(gone);
      await db.update('notes', {'lock_mode': 1}, where: 'id = ?', whereArgs: [locked]);
      expect(await links.linksTo(target), isEmpty);
    });

    test('ids with % or _ in them do not match other ids', () async {
      final a = await notes.createNote(title: 'A', id: 'x_y');
      final other = await notes.createNote(title: 'Other');
      await box(other, 0, 'See ${noteLink('xzy', 'Z')}');
      expect(await links.linksTo(a), isEmpty);
    });

    test('the title written without a link is an unlinked mention', () async {
      final target = await notes.createNote(title: 'Linear Algebra');
      final a = await notes.createNote(title: 'Plan');
      final linked = await notes.createNote(title: 'Linked');
      await box(a, 1, 'We should finish linear algebra this week');
      await box(linked, 0, 'See ${noteLink(target, 'Linear Algebra')}');
      final mentions = await links.mentionsOf(target, 'Linear Algebra');
      expect(mentions.single.noteId, a);
      expect(mentions.single.page, 1);
      expect(mentions.single.linked, isFalse);
    });

    test('short and default titles are not searched for', () async {
      final a = await notes.createNote(title: 'Plan');
      await box(a, 0, 'Untitled Note and Art and so on');
      expect(await links.mentionsOf('x', 'Art'), isEmpty);
      expect(await links.mentionsOf('x', 'Untitled Note'), isEmpty);
    });
  });
}
