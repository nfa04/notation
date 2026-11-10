import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/tag_repository.dart';
import 'package:notes/tags/tag_names.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('names', () {
    test('a tag is lower case, without #, with - for spaces and / for levels', () {
      expect(normalizeTag('  #School / Maths 1 '), 'school/maths-1');
      expect(normalizeTag('##Work'), 'work');
      expect(normalizeTag('a//b/'), 'a/b');
      expect(normalizeTag('   '), isNull);
      expect(normalizeTag('#'), isNull);
    });

    test('a list is split on commas and hashes, with duplicates once', () {
      expect(parseTags('#work #Home, school/maths; work'), ['work', 'home', 'school/maths']);
      expect(parseTags(''), isEmpty);
    });

    test('paths, leaves and nesting', () {
      expect(tagPath('a/b/c'), ['a', 'a/b', 'a/b/c']);
      expect(tagLeaf('a/b/c'), 'c');
      expect(tagLeaf('a'), 'a');
      expect(tagIsUnder('a/b', 'a'), isTrue);
      expect(tagIsUnder('a', 'a'), isTrue);
      expect(tagIsUnder('ab', 'a'), isFalse);
    });

    test('the tree counts a note once per node and invents the levels in between', () {
      final tree = buildTagTree({
        'n1': {'school/maths', 'school/physics'},
        'n2': {'school/maths/algebra'},
        'n3': {'home'},
      });
      expect(tree.map((t) => t.tag), ['home', 'school']);
      final school = tree.last;
      expect(school.notes, 2); // n1 once
      expect(school.children.map((t) => (t.tag, t.notes)), [('school/maths', 2), ('school/physics', 1)]);
      expect(school.children.first.children.single.tag, 'school/maths/algebra');
      expect(school.children.first.children.single.depth, 2);
    });
  });

  group('TagRepository', () {
    late Database db;
    late TagRepository tags;

    setUpAll(AppDatabase.initFfi);
    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      tags = TagRepository(db);
      for (final id in ['n1', 'n2', 'n3']) {
        await db.insert('notes', {'id': id, 'created_at': 1, 'updated_at': 1});
      }
    });
    tearDown(() => db.close());

    test('tags are set, normalised and listed', () async {
      await tags.setTags('n1', ['Work', '#school/Maths', 'work', '  ']);
      expect(await tags.tagsOf('n1'), ['school/maths', 'work']);
      await tags.setTags('n1', ['home']);
      expect(await tags.tagsOf('n1'), ['home']);
    });

    test('a note is found under a tag and the tags nested in it, and "a" is not "ab"', () async {
      await tags.setTags('n1', ['school']);
      await tags.setTags('n2', ['school/maths']);
      await tags.setTags('n3', ['schoolbus', 'school_x']);
      expect(await tags.notesWith('school'), {'n1', 'n2'});
      expect(await tags.notesWith('school/maths'), {'n2'});
    });

    test('adding and removing for several notes', () async {
      await tags.add(['n1', 'n2'], '#Todo');
      await tags.add(['n1'], 'todo'); // again: nothing happens
      expect(await tags.counts(), {'todo': 2});
      await tags.remove(['n1'], 'todo');
      expect(await tags.notesWith('todo'), {'n2'});
    });

    test('renaming moves the tags nested under it too', () async {
      await tags.setTags('n1', ['school/maths']);
      await tags.setTags('n2', ['school']);
      expect(await tags.rename('school', 'uni'), 2);
      expect(await tags.all(), {'n1': {'uni/maths'}, 'n2': {'uni'}});
    });

    test('renaming onto an existing tag merges the two, and a note with both keeps one', () async {
      await tags.setTags('n1', ['a', 'b']);
      await tags.setTags('n2', ['a']);
      await tags.setTags('n3', ['b/x']);
      await tags.rename('a', 'b');
      expect(await tags.all(), {'n1': {'b'}, 'n2': {'b'}, 'n3': {'b/x'}});
      expect(await tags.counts(), {'b': 2, 'b/x': 1});
    });

    test('renaming does not touch tags that only start with the same letters', () async {
      await tags.setTags('n1', ['ab']);
      await tags.rename('a', 'z');
      expect(await tags.tagsOf('n1'), ['ab']);
    });

    test('deleting a tag, with or without what is nested under it', () async {
      await tags.setTags('n1', ['a', 'a/b']);
      await tags.setTags('n2', ['a/b']);
      await tags.delete('a', nested: false);
      expect(await tags.counts(), {'a/b': 2});
      await tags.delete('a/b');
      expect(await tags.all(), isEmpty);
    });

    test('deleting a note forgets its tags', () async {
      await tags.setTags('n1', ['a']);
      await db.delete('notes', where: 'id = ?', whereArgs: ['n1']);
      expect(await tags.all(), isEmpty);
    });

    test('changes are announced', () async {
      var n = 0;
      final sub = tags.changes.listen((_) => n++);
      await tags.setTags('n1', ['a']);
      await tags.rename('a', 'b');
      await tags.delete('b');
      await Future<void>.delayed(Duration.zero);
      expect(n, 3);
      await sub.cancel();
    });
  });
}
