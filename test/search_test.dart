import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/l10n/text.dart' as app;
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/rich_text.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/search_view.dart';
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/search/ink_indexer.dart';
import 'package:notes/data/tag_repository.dart';
import 'package:notes/search/search_filter.dart';
import 'package:notes/search/search_memory.dart';
import 'package:notes/search/search_query.dart';
import 'package:notes/data/note_data.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the query', () {
    test('plain words are not patterns', () {
      final q = const SearchQuery('a.c');
      expect(q.find('abc a.c'), [const MatchRange(4, 7)]);
    });

    test('case, whole words and regular expressions', () {
      expect(const SearchQuery('cat').find('Cat cat concat'), hasLength(3));
      expect(const SearchQuery('cat', caseSensitive: true).find('Cat cat concat'), hasLength(2));
      expect(const SearchQuery('cat', wholeWord: true).find('Cat cat concat cat_'), hasLength(2));
      expect(const SearchQuery(r'\d{2,}', regex: true).find('a1 b22 c333'), [const MatchRange(4, 6), const MatchRange(8, 11)]);
      expect(const SearchQuery(r'^\w+', regex: true).find('one two\nthree four'), [const MatchRange(0, 3), const MatchRange(8, 13)]);
    });

    test('a pattern that is not valid says so, and finds nothing', () {
      const q = SearchQuery('(', regex: true);
      expect(q.problem, isNotNull);
      expect(q.find('(('), isEmpty);
      expect(const SearchQuery('').find('abc'), isEmpty);
    });

    test('empty matches are left out', () {
      expect(const SearchQuery('x*', regex: true).find('abc'), isEmpty);
    });

    test('hits carry what is around them', () {
      final r = searchNow(const SearchQuery('needle'), [const SearchSource('n1', SearchPlace.document, 'a haystack with a needle in it\nsecond line', page: 0)], context: 8);
      expect(r.hits.single.before, '… with a ');
      expect(r.hits.single.match, 'needle');
      expect(r.hits.single.after, ' in it s…');
      expect(r.total, 1);
    });

    test('a pattern that never ends is given up on', () async {
      final text = '${'a' * 40}!';
      final run = RunningSearch.start(const SearchQuery(r'(a+)+$', regex: true), [SearchSource('n', SearchPlace.document, text)], timeout: const Duration(milliseconds: 600));
      await expectLater(run.results, throwsA(isA<SearchTooSlow>()));
    });

    test('the matches in several texts, on another isolate', () async {
      final r = await findInTexts(const SearchQuery('b'), ['abc', 'xyz', 'bb']);
      expect(r, [
        [const MatchRange(1, 2)],
        isEmpty,
        [const MatchRange(0, 1), const MatchRange(1, 2)],
      ]);
    });
  });

  group('replacing', () {
    MatchRange first(SearchQuery q, String text) => q.find(text).first;

    test('plain text is replaced as it is, a dollar is no group', () {
      const q = SearchQuery('cat');
      expect(q.replacement(r'$1 dog', 'a cat', first(q, 'a cat')), r'$1 dog');
    });

    test('a regular expression can use its groups, the whole match and a dollar', () {
      const q = SearchQuery(r'(\w+)@(\w+)', regex: true);
      const text = 'mail ann@home now';
      final r = first(q, text);
      expect(q.replacement(r'$2:$1', text, r), 'home:ann');
      expect(q.replacement(r'[$&]', text, r), '[ann@home]');
      expect(q.replacement(r'$$5 $3', text, r), r'$5 $3'); // (no 3rd group: as written)
      expect(q.replacement(r'$12', text, r), 'ann2'); // (no 12th group: the 1st, then a 2)
    });

    test('whole words only are looked at in their surroundings', () {
      const q = SearchQuery('cat', wholeWord: true);
      const text = 'cat concat cat';
      expect(q.find(text).length, 2);
      expect(q.replacement('dog', text, const MatchRange(11, 14)), 'dog');
      expect(q.replacement('dog', text, const MatchRange(7, 10)), isNull); // inside "concat"
    });

    test('a place that is no longer a match is not replaced', () {
      const q = SearchQuery('cat');
      expect(q.replacement('dog', 'a dog', const MatchRange(2, 5)), isNull);
      expect(q.replacement('dog', 'a', const MatchRange(2, 5)), isNull);
    });

    test('the text controller replaces several places and keeps the bold words where they are', () {
      final c = RichInlineTextController()..text = 'cat and dog and cat';
      c.attributes.add(TextSpanAttribute(start: 8, end: 11, type: AttributeType.bold)); // "dog"
      c.attributes.add(TextSpanAttribute(start: 0, end: 3, type: AttributeType.italic)); // the first "cat"
      c.replaceRanges([(start: 0, end: 3, text: 'mouse'), (start: 16, end: 19, text: 'x')]);
      expect(c.text, 'mouse and dog and x');
      expect(c.attributes.map((a) => (a.type, a.start, a.end)), [(AttributeType.bold, 10, 13), (AttributeType.italic, 0, 5)]);
      expect(c.selection, const TextSelection.collapsed(offset: 19));
      // a span that lies in a replaced stretch goes when the stretch becomes empty
      c.replaceRanges([(start: 10, end: 13, text: '')]);
      expect(c.attributes.map((a) => a.type), [AttributeType.italic]);
    });
  });

  group('the filter', () {
    final now = DateTime(2026, 10, 27, 12);
    NoteSummary note(String id, {bool pdf = false, String? folder, bool fav = false, Duration ago = Duration.zero}) =>
        NoteSummary(id: id, title: id, updatedAt: now.subtract(ago), isPdf: pdf, folderId: folder, favorite: fav);
    const folders = {
      'a': FolderEntry(id: 'a', parentId: null, name: 'A', noteCount: 0),
      'b': FolderEntry(id: 'b', parentId: 'a', name: 'B', noteCount: 0),
      'c': FolderEntry(id: 'c', parentId: null, name: 'C', noteCount: 0),
    };

    test('by default it lets everything through', () {
      final f = SearchFilter();
      expect(f.isDefault, isTrue);
      expect(f.activeCount, 0);
      final sources = [const SearchSource('x', SearchPlace.title, 't')];
      expect(f.apply(sources, const {}, const {}), same(sources));
    });

    test('by type, favorites and age', () {
      expect(SearchFilter(kind: SearchKind.pdfs).allowsNote(note('n'), folders), isFalse);
      expect(SearchFilter(kind: SearchKind.pdfs).allowsNote(note('p', pdf: true), folders), isTrue);
      expect(SearchFilter(kind: SearchKind.notes).allowsNote(note('p', pdf: true), folders), isFalse);
      expect(SearchFilter(favoritesOnly: true).allowsNote(note('n'), folders), isFalse);
      expect(SearchFilter(favoritesOnly: true).allowsNote(note('n', fav: true), folders), isTrue);
      final week = SearchFilter(age: SearchAge.week);
      expect(week.allowsNote(note('new', ago: const Duration(days: 2)), folders, now: now), isTrue);
      expect(week.allowsNote(note('old', ago: const Duration(days: 9)), folders, now: now), isFalse);
    });

    test('a folder takes in the folders inside it', () {
      final f = SearchFilter(folderId: 'a');
      expect(f.allowsNote(note('in', folder: 'a'), folders), isTrue);
      expect(f.allowsNote(note('deep', folder: 'b'), folders), isTrue);
      expect(f.allowsNote(note('other', folder: 'c'), folders), isFalse);
      expect(f.allowsNote(note('loose'), folders), isFalse);
    });

    test('a loop of folders does not hang it', () {
      const loop = {
        'x': FolderEntry(id: 'x', parentId: 'y', name: 'X', noteCount: 0),
        'y': FolderEntry(id: 'y', parentId: 'x', name: 'Y', noteCount: 0),
      };
      expect(SearchFilter(folderId: 'a').allowsNote(note('n', folder: 'x'), loop), isFalse);
    });

    test('it limits the places and the notes of the sources', () {
      final sources = [
        const SearchSource('n1', SearchPlace.title, 'a'),
        const SearchSource('n1', SearchPlace.handwriting, 'b', page: 0),
        const SearchSource('p1', SearchPlace.pdfText, 'c', page: 0),
        const SearchSource('gone', SearchPlace.title, 'd'),
      ];
      final notes = {'n1': note('n1'), 'p1': note('p1', pdf: true)};
      expect(SearchFilter(places: {SearchPlace.handwriting}).apply(sources, notes, folders).map((s) => s.noteId), ['n1']);
      expect(SearchFilter(kind: SearchKind.pdfs).apply(sources, notes, folders).map((s) => s.noteId), ['p1']);
      // a note that is not known cannot be shown to pass a limit on notes
      expect(SearchFilter(kind: SearchKind.notes).apply(sources, notes, folders).map((s) => s.noteId), ['n1', 'n1']);
    });

    test('by tag, including the tags nested under it', () {
      final f = SearchFilter(tags: {'school'});
      expect(f.allowsNote(note('n'), folders, noteTags: {'school/maths'}), isTrue);
      expect(f.allowsNote(note('n'), folders, noteTags: {'school'}), isTrue);
      expect(f.allowsNote(note('n'), folders, noteTags: {'schools'}), isFalse);
      expect(f.allowsNote(note('n'), folders), isFalse);
      expect(SearchFilter(tags: {'a', 'b'}).allowsNote(note('n'), folders, noteTags: {'b'}), isTrue);
      expect(f.activeCount, 1);
      expect(f.limitsNotes, isTrue);
      final sources = [const SearchSource('n1', SearchPlace.title, 'a'), const SearchSource('n2', SearchPlace.title, 'b')];
      final notes = {'n1': note('n1'), 'n2': note('n2')};
      expect(f.apply(sources, notes, folders, tagsOfNotes: {'n2': {'school/art'}}).map((s) => s.noteId), ['n2']);
    });

    test('it survives being written down', () {
      final f = SearchFilter(places: {SearchPlace.document}, kind: SearchKind.pdfs, age: SearchAge.month, folderId: 'a', favoritesOnly: true, tags: {'x', 'y/z'});
      final back = SearchFilter.fromJson(f.toJson());
      expect([back.places, back.kind, back.age, back.folderId, back.favoritesOnly, back.tags], [f.places, f.kind, f.age, f.folderId, f.favoritesOnly, f.tags]);
      expect(SearchFilter.fromJson(const {}).isDefault, isTrue);
      expect(SearchFilter.fromJson(const {'kind': 'nonsense', 'places': ['nope']}).isDefault, isTrue);
    });

    test('searches are saved by name and the last ones are remembered', () async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      final memory = SearchMemory(NoteRepository(db).settings);
      await NoteRepository(db).settings.remove(SearchMemory.savedKey);
      await NoteRepository(db).settings.remove(SearchMemory.recentKey);
      expect(await memory.saved(), isEmpty);
      await memory.save(SavedSearch('Exams', const SearchQuery('exam', wholeWord: true), SearchFilter(tags: {'school'})));
      await memory.save(SavedSearch('Other', const SearchQuery('x'), SearchFilter()));
      await memory.save(SavedSearch('exams', const SearchQuery('exam2'), SearchFilter())); // same name: replaced
      final saved = await memory.saved();
      expect(saved.map((s) => s.name), ['exams', 'Other']);
      expect(saved.first.query.text, 'exam2');
      await memory.forget('Other');
      expect((await memory.saved()).map((s) => s.name), ['exams']);

      for (final w in ['a', 'b', 'a', '  ', 'c']) {
        await memory.remember(SearchQuery(w), SearchFilter());
      }
      await memory.remember(const SearchQuery('(', regex: true), SearchFilter());
      expect((await memory.recent()).map((s) => s.query.text), ['c', 'a', 'b']);
      for (var i = 0; i < 20; i++) {
        await memory.remember(SearchQuery('q$i'), SearchFilter());
      }
      expect(await memory.recent(), hasLength(SearchMemory.maxRecent));
      await memory.clearRecent();
      expect(await memory.recent(), isEmpty);
    });

    test('looking nowhere means looking everywhere, and copying changes one part', () {
      expect(SearchFilter(places: {}).isDefault, isTrue);
      final f = SearchFilter(folderId: 'a', favoritesOnly: true).copyWith(kind: SearchKind.pdfs);
      expect([f.folderId, f.favoritesOnly, f.kind, f.activeCount], ['a', true, SearchKind.pdfs, 3]);
      expect(f.copyWith(clearFolder: true).folderId, isNull);
    });
  });

  group('across the notes', () {
    late NoteRepository repo;
    setUp(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
    });

    Future<String> note(String title, {String document = '', List<String> boxes = const []}) async {
      final id = await repo.createNote(title: title);
      final n = (await repo.loadNote(id))!;
      n.documentText = document;
      n.textBoxes = {
        0: [for (var i = 0; i < boxes.length; i++) TextBoxWidgetModel(id: 'b$i', position: const Offset(10, 10), initialText: boxes[i])],
      };
      await repo.saveNote(n);
      return id;
    }

    test('titles, documents and text boxes are searched; the trash is not', () async {
      final a = await note('Biology', document: 'The cell is the unit of life');
      final b = await note('Chemistry', boxes: ['a cell of a battery', 'nothing']);
      final gone = await note('Old cells', document: 'cell');
      await repo.deleteNote(gone);
      final r = searchNow(const SearchQuery('cell'), (await repo.text.searchSources()).where((s) => s.noteId == a || s.noteId == b || s.noteId == gone));
      expect(r.countByNote.keys.toSet(), {a, b});
      expect(r.hits.firstWhere((h) => h.noteId == b).place, SearchPlace.textBox);
      // inside one note
      final one = searchNow(const SearchQuery('cell'), await repo.text.searchSources(noteId: a));
      expect(one.countByNote.keys, [a]);
    });

    test('the text of PDF pages is kept and tells when a PDF still has to be read', () async {
      final id = await note('Paper');
      await repo.text.savePdfText(id, ['first page', 'the second page has a cell']);
      final r = searchNow(const SearchQuery('cell'), await repo.text.searchSources(noteId: id));
      expect(r.hits.single.place, SearchPlace.pdfText);
      expect(r.hits.single.page, 1);
    });

    test('handwriting that was read is searched, by words and by pattern; what is not there any more is dropped', () async {
      final id = await note('Sketches');
      const block = Rect.fromLTWH(10, 20, 100, 30);
      await repo.text.saveInkText(id, [
        const InkText(key: 'a', page: 2, text: 'order 4711 shipped', bounds: block),
        const InkText(key: 'b', page: 0, text: '', bounds: block),
      ], {'a', 'b'});
      expect((await repo.text.inkTexts(id)).map((t) => t.key), ['b', 'a']);
      final r = searchNow(const SearchQuery(r'\b\d{4}\b', regex: true), await repo.text.searchSources(noteId: id));
      expect(r.hits.single.place, SearchPlace.handwriting);
      expect(r.hits.single.page, 2);
      expect(r.hits.single.match, '4711');
      await repo.text.saveInkText(id, const [], {'b'});
      expect((await repo.text.inkTexts(id)).map((t) => t.key), ['b']);
      expect(searchNow(const SearchQuery('order'), await repo.text.searchSources(noteId: id)).hits, isEmpty);
    });

    test('the indexer reads the handwriting of notes once, and again when the strokes change', () async {
      final id = await note('Scribbles');
      final data = (await repo.loadNote(id))!;
      DrawingStroke stroke(String sid, double y) => DrawingStroke(id: sid, color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(100.0 + i * 5, y + i)]);
      data.strokes[0] = [stroke('s1', 100)];
      await repo.saveNote(data);
      var reads = 0;
      final indexer = InkIndexer(repo, (strokes) async => 'read ${++reads}');
      expect(await indexer.run(), 1);
      expect(await indexer.run(), 0);
      expect(searchNow(const SearchQuery('read'), await repo.text.searchSources(noteId: id)).hits, hasLength(1));
      data.strokes[0] = [stroke('s1', 100), stroke('s2', 400)];
      await repo.saveNote(data);
      expect(await indexer.run(), greaterThan(0));
      final texts = await repo.text.inkTexts(id);
      expect(texts.length, greaterThan(0));
      expect(texts.every((t) => t.text.startsWith('read')), isTrue);
    });

    test('a block of writing has the same key on every run of the app, so that what was read of it is read only once', () {
      // (a key made of hash codes would differ in each run: the indexer would read all the writing again after every start)
      final s = DrawingStroke(id: 'abc', color: Colors.black, width: 2, points: [const Offset(1, 2), const Offset(3.5, 4.25)], pressures: [3, 4]);
      expect(InkCluster(0, [s], Rect.zero).key, '1-6d2ec8c5');
      s.points.add(const Offset(5, 6));
      expect(InkCluster(0, [s], Rect.zero).key, isNot('1-6d2ec8c5'));
    });

    test('a block has the same key just drawn and loaded again (its points are kept as 32-bit numbers)', () {
      // (244.5499989... rounds to 2445 tenths, the 32-bit 244.5500030... to 2446: the block was read again after every reopening)
      const x = 244.5499989301142;
      final stored = Float32List.fromList([x])[0];
      expect((x * 10).round(), isNot((stored * 10).round()), reason: 'the case this is about');
      DrawingStroke at(double v) => DrawingStroke(id: 's', color: Colors.black, width: 2.35, points: [Offset(v, 10), Offset(v + 5, 20)]);
      expect(InkCluster(0, [at(x)], Rect.zero).key, InkCluster(0, [at(stored)], Rect.zero).key);
    });
  });

  testWidgets('the search page shows the notes that match, and opens one', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote(title: 'Biology');
      final n = (await repo.loadNote(id))!;
      n.documentText = 'The mitochondria is the powerhouse';
      await repo.saveNote(n);
    });
    SearchQuery? openedWith;
    String? opened;
    await tester.pumpWidget(MaterialApp(home: SearchView(repository: repo, onOpen: (note, q, page) {
      opened = note;
      openedWith = q;
    })));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'power.*se');
    await tester.tap(find.byKey(const ValueKey('search-regex')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
    await tester.pump();
    expect(find.byKey(ValueKey('search-note-$id')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('search-hit-$id-0')));
    expect(opened, id);
    expect(openedWith!.regex, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the filters narrow the search to a kind of place and to a folder', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String inFolder, loose;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      final folder = await repo.createFolder('Biology');
      inFolder = await repo.createNote(title: 'Cells', folderId: folder);
      loose = await repo.createNote(title: 'Loose');
      for (final id in [inFolder, loose]) {
        final n = (await repo.loadNote(id))!;
        n.documentText = 'the mitochondria';
        await repo.saveNote(n);
      }
    });
    SearchFilter? last;
    await tester.pumpWidget(MaterialApp(home: SearchView(repository: repo, onOpen: (_, _, _) {}, onFilterChanged: (f) => last = f)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    Future<void> settle() async {
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
      await tester.pump();
    }

    await tester.enterText(find.byKey(const ValueKey('search-field')), 'mitochondria');
    await settle();
    expect(find.byKey(ValueKey('search-note-$inFolder')), findsOneWidget);
    expect(find.byKey(ValueKey('search-note-$loose')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-filters-toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('search-folder')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Biology').last);
    await settle();
    expect(last!.folderId, isNotNull);
    expect(find.byKey(ValueKey('search-note-$inFolder')), findsOneWidget);
    expect(find.byKey(ValueKey('search-note-$loose')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('search-place-document')));
    await settle();
    expect(last!.places, isNot(contains(SearchPlace.document)));
    expect(find.byKey(ValueKey('search-note-$inFolder')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('search-filters-reset')));
    await settle();
    expect(last!.isDefault, isTrue);
    expect(find.byKey(ValueKey('search-note-$loose')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tags narrow the search, searches can be saved and brought back, and the notes can be put in order', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late TagRepository tags;
    late String alpha, beta;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      tags = TagRepository(db);
      await repo.settings.remove(SearchMemory.savedKey);
      await repo.settings.remove(SearchMemory.recentKey);
      alpha = await repo.createNote(title: 'Alpha');
      beta = await repo.createNote(title: 'Beta');
      final a = (await repo.loadNote(alpha))!..documentText = 'zebra';
      await repo.saveNote(a);
      final b = (await repo.loadNote(beta))!..documentText = 'zebra zebra zebra';
      await repo.saveNote(b);
      await tags.add([alpha], 'school/maths');
    });
    SearchFilter? last;
    await tester.pumpWidget(MaterialApp(home: SearchView(repository: repo, tags: tags, onOpen: (_, _, _) {}, onFilterChanged: (f) => last = f)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    Future<void> settle() async {
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
      await tester.pump();
    }

    await tester.enterText(find.byKey(const ValueKey('search-field')), 'zebra');
    await settle();
    expect(find.byKey(ValueKey('search-note-$alpha')), findsOneWidget);
    expect(find.byKey(ValueKey('search-note-$beta')), findsOneWidget);

    // most matches first: Beta has three, Alpha one
    double top(String id) => tester.getTopLeft(find.byKey(ValueKey('search-note-$id'))).dy;
    await tester.tap(find.byKey(const ValueKey('search-order')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Most matches').last);
    await tester.pumpAndSettle();
    expect(top(beta), lessThan(top(alpha)));
    await tester.tap(find.byKey(const ValueKey('search-order')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Title').last);
    await tester.pumpAndSettle();
    expect(top(alpha), lessThan(top(beta)));

    // by tag: "school" takes in "school/maths"
    await tester.tap(find.byKey(const ValueKey('search-filters-toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('search-tags-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-tag-pick-school/maths')));
    await tester.tap(find.byKey(const ValueKey('search-tags-ok')));
    await tester.pump(const Duration(milliseconds: 400));
    await settle();
    expect(last!.tags, {'school/maths'});
    expect(find.byKey(ValueKey('search-note-$alpha')), findsOneWidget);
    expect(find.byKey(ValueKey('search-note-$beta')), findsNothing);

    // save it, clear everything, bring it back
    await tester.tap(find.byKey(const ValueKey('search-save')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-save-name')), 'Zebras at school');
    await tester.tap(find.byKey(const ValueKey('search-save-ok')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.tap(find.byKey(const ValueKey('search-filters-reset')));
    await settle();
    expect(find.byKey(ValueKey('search-note-$beta')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search-clear')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('search-field')), '');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('search-saved')));
    await tester.pump(const Duration(milliseconds: 400)); // (the dialog is built and starts to read)
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-saved-Zebras at school')));
    await tester.pump(const Duration(milliseconds: 400));
    await settle();
    expect(last!.tags, {'school/maths'});
    expect(find.byKey(ValueKey('search-note-$alpha')), findsOneWidget);
    expect(find.byKey(ValueKey('search-note-$beta')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the last searches are offered when the field is empty', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      await repo.settings.remove(SearchMemory.recentKey);
      await SearchMemory(repo.settings).remember(const SearchQuery('giraffe'), SearchFilter(favoritesOnly: true));
    });
    await tester.pumpWidget(MaterialApp(home: SearchView(repository: repo, onOpen: (_, _, _) {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    for (var i = 0; i < 30 && find.byKey(const ValueKey('search-recent-0')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('search-recent-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search-recent-0')));
    await tester.pump();
    expect(find.widgetWithText(TextField, 'giraffe'), findsOneWidget);
    expect(find.byKey(const ValueKey('search-filters')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump();
    expect(find.byKey(const ValueKey('search-recent')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('in a note, Ctrl+F finds words, counts them and steps between them', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final n = (await repo.loadNote(id))!;
      n.documentText = 'one cat, two cats, three Cats';
      await repo.saveNote(n);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find-field')), findsOneWidget);
    expect(find.byKey(const ValueKey('find-panel')), findsOneWidget, reason: 'beside the note on a wide screen, not a bar over it');

    await tester.enterText(find.byKey(const ValueKey('find-field')), 'cat');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pump();
    expect(tester.widget<app.Text>(find.byKey(const ValueKey('find-count'))).data, '1 / 3');
    await tester.tap(find.byKey(const ValueKey('find-next')));
    await tester.pump();
    expect(tester.widget<app.Text>(find.byKey(const ValueKey('find-count'))).data, '2 / 3');

    await tester.tap(find.byKey(const ValueKey('find-case')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pump();
    expect(tester.widget<app.Text>(find.byKey(const ValueKey('find-count'))).data, '1 / 2');

    // the list of what was found shows the words around each match, and a tap on one goes to it
    expect(find.byKey(const ValueKey('find-result-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('find-result-2')), findsNothing);
    expect(find.descendant(of: find.byKey(const ValueKey('find-result-1')), matching: find.textContaining('two cats', findRichText: true)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('find-result-1')));
    await tester.pump();
    expect(tester.widget<app.Text>(find.byKey(const ValueKey('find-count'))).data, '2 / 2');

    await tester.tap(find.byKey(const ValueKey('find-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find-field')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });

  testWidgets('Ctrl+Alt+F opens replace: one by one, and all at once', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final n = (await repo.loadNote(id))!;
      n.documentText = 'one cat, two cats, three cats';
      await repo.saveNote(n);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    Future<void> found() async {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
      await tester.pump();
    }

    String count() => tester.widget<app.Text>(find.byKey(const ValueKey('find-count'))).data!;
    // (the written document, as it is shown)
    String document() => tester.widgetList<RichText>(find.byType(RichText)).map((w) => w.text.toPlainText()).firstWhere((t) => t.startsWith('one '), orElse: () => '');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find-field')), findsOneWidget);
    expect(find.byKey(const ValueKey('replace-field')), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('replace-one'))).onPressed, isNull); // nothing found yet

    await tester.enterText(find.byKey(const ValueKey('find-field')), 'cat');
    await found();
    expect(count(), '1 / 3');
    await tester.enterText(find.byKey(const ValueKey('replace-field')), 'dog');
    await tester.tap(find.byKey(const ValueKey('replace-one')));
    await found();
    expect(count(), '1 / 2'); // the next one is the one shown
    expect(document(), 'one dog, two cats, three cats');

    await tester.tap(find.byKey(const ValueKey('replace-all')));
    await found();
    expect(document(), 'one dog, two dogs, three dogs');
    expect(count(), '2 replaced');

    await tester.tap(find.byKey(const ValueKey('find-close')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });
}
