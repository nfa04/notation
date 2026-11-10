import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/bookmark_repository.dart';
import 'package:notes/outline/outline.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('headings', () {
    test('markdown headings with their level, not tags, code or text', () {
      const text = '# Intro\nsome text\n#tag is not a heading\n## **Setup** `now` ##\n```\n# not a heading\n```\n###### Deep\n####### too deep\n#\n';
      expect(headingsOf(text, 3), [
        const OutlineEntry('Intro', 1, 3),
        const OutlineEntry('Setup now', 2, 3),
        const OutlineEntry('Deep', 6, 3),
      ]);
    });

    test('the outline lists the document first, then the boxes of each page', () {
      final out = buildOutline(
        documentText: '# Chapter 1\ntext\n## Part',
        documentPage: 0,
        boxes: {
          2: ['# On page three'],
          0: ['## A box on the first page'],
          1: ['plain'],
        },
      );
      expect(out, [
        const OutlineEntry('Chapter 1', 1, 0),
        const OutlineEntry('Part', 2, 0),
        const OutlineEntry('A box on the first page', 2, 0),
        const OutlineEntry('On page three', 1, 2),
      ]);
    });

    test('levels are made relative and never jump by more than one', () {
      final out = tidyLevels(const [OutlineEntry('a', 2, 0), OutlineEntry('b', 4, 0), OutlineEntry('c', 3, 1), OutlineEntry('d', 2, 1)]);
      expect(out.map((e) => e.level), [1, 2, 2, 1]);
      expect(tidyLevels(const []), isEmpty);
    });
  });

  group('bookmarks', () {
    late Database db;
    late BookmarkRepository bookmarks;

    setUpAll(AppDatabase.initFfi);
    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      bookmarks = BookmarkRepository(db);
      await db.insert('notes', {'id': 'n1', 'created_at': 1, 'updated_at': 1});
    });
    tearDown(() => db.close());

    test('a page is marked, named and unmarked', () async {
      expect(await bookmarks.toggle('n1', 4), isTrue);
      expect(await bookmarks.toggle('n1', 1), isTrue);
      await bookmarks.setLabel('n1', 4, '  Proof  ');
      expect(await bookmarks.list('n1'), [const PageBookmark(1, ''), const PageBookmark(4, 'Proof')]);
      expect(await bookmarks.toggle('n1', 1), isFalse);
      expect(await bookmarks.list('n1'), [const PageBookmark(4, 'Proof')]);
    });

    test('deleting the note deletes its bookmarks', () async {
      await bookmarks.toggle('n1', 0);
      await db.delete('notes', where: 'id = ?', whereArgs: ['n1']);
      expect(await bookmarks.list('n1'), isEmpty);
    });

    test('pages that moved take their bookmarks along', () async {
      const marks = [PageBookmark(0, 'a'), PageBookmark(2, 'b'), PageBookmark(3, '')];
      // page 1 inserted: 2 -> 3 and 3 -> 4
      expect(moveBookmarks(marks, (i) => i >= 1 ? i + 1 : i), const [PageBookmark(0, 'a'), PageBookmark(3, 'b'), PageBookmark(4, '')]);
      // page 2 deleted: its bookmark goes, 3 -> 2
      expect(moveBookmarks(marks, (i) => i == 2 ? null : (i > 2 ? i - 1 : i)), const [PageBookmark(0, 'a'), PageBookmark(2, '')]);
      await bookmarks.replace('n1', moveBookmarks(marks, (i) => i == 0 ? 3 : i));
      expect((await bookmarks.list('n1')).map((b) => b.page), [2, 3]);
    });

    test('two bookmarks that end up on one page keep the label that exists', () {
      expect(moveBookmarks(const [PageBookmark(0, ''), PageBookmark(1, 'x')], (_) => 0), const [PageBookmark(0, 'x')]);
      expect(moveBookmarks(const [PageBookmark(0, 'first'), PageBookmark(1, 'x')], (_) => 0), const [PageBookmark(0, 'first')]);
    });
  });
}
