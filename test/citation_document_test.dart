import 'dart:convert';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/citations/citation_document.dart';
import 'package:notes/citations/citation_repository.dart';
import 'package:notes/citations/citation_service.dart';
import 'package:notes/citations/citation_style.dart';
import 'package:notes/citations/cite_picker.dart';
import 'package:notes/citations/source.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/devicesync/sync_library.dart' show syncedSetting;
import 'package:notes/markdown/markdown_parser.dart';
import 'package:notes/markdown/markdown_view.dart';
import 'package:notes/models/rich_text.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const smith = CitationSource(id: 'smith2020', type: SourceType.article, title: 'T', authors: [Person('Smith', 'J')], year: 2020, container: 'J');
const doe = CitationSource(id: 'doe2019', title: 'Book', authors: [Person('Doe', 'J')], year: 2019, publisher: 'P');

void main() {
  setUpAll(AppDatabase.initFfi);
  expansionTests();

  group('finding citations', () {
    test('in running text', () {
      final marks = findCitations('As shown [@smith2020, p. 42; @doe2019] and [@doe2019].');
      expect(marks, hasLength(2));
      expect(marks.first.items.map((i) => i.key), ['smith2020', 'doe2019']);
      expect(marks.first.items.first.locator!.text(), 'p. 42');
      expect(marks.first.start, 9);
    });

    test('not links, e-mail addresses or code', () {
      expect(findCitations('[@a](https://x.org) and me@x.org and [text] and [a, b]'), isEmpty);
      expect(findCitations('```\n[@a]\n```\nand `[@b]`'), hasLength(1)); // inline code is the parser's to skip
    });
  });

  test('the parser makes a run of a citation, and leaves a link alone', () {
    final runs = parseMarkdown('See [@smith2020, p. 4] and [a link](note:1).').single.runs;
    expect(runs.map((r) => r.text), ['See ', '[@smith2020, p. 4]', ' and ', 'a link', '.']);
    expect(runs[1].cite!.single.key, 'smith2020');
    expect(runs[3].link, 'note:1');
  });

  group('a document', () {
    final lib = {smith.id: smith, doe.id: doe};

    test('numbers by first use and lists in the style of the order', () {
      const text = 'First [@doe2019]. Then [@smith2020] and [@doe2019].';
      final ieee = CitationDocument(const IeeeStyle(), lib, text);
      expect(ieee.inText(findCitations(text).first.items), '[1]');
      expect(ieee.bibliography().first, startsWith('[1] J. Doe'));
      final apa = CitationDocument(const ApaStyle(), lib, text);
      expect(apa.bibliography().map((e) => e.split(',').first), ['Doe', 'Smith']);
    });

    test('an unknown key stays visible', () {
      final doc = CitationDocument(const ApaStyle(), lib, '[@nobody2000]');
      expect(doc.missing, ['nobody2000']);
      expect(doc.inText(findCitations('[@nobody2000]').single.items), '[@nobody2000?]');
    });
  });

  test('a citation is written at the cursor, after a space', () {
    final v = withCitation(const TextEditingValue(text: 'A claim', selection: TextSelection.collapsed(offset: 7)), '[@a]');
    expect(v.text, 'A claim [@a]');
    expect(v.selection.baseOffset, v.text.length);
    expect(citationText([('a', 'p. 3')]), '[@a, p. 3]');
    expect(citationText([('a', '3-5'), ('b', '')]), '[@a, pp. 3–5; @b]');
  });

  group('the library', () {
    late Database db;
    late CitationService service;
    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      service = CitationService(CitationRepository(SettingsRepository(db)));
      await service.load();
    });
    tearDown(() => db.close());

    test('keeps sources, gives keys, skips duplicates', () async {
      final a = await service.add(const CitationSource(id: '', title: 'A', authors: [Person('Lee', 'A')], year: 2020, doi: '10.1/a'));
      expect(a.id, 'lee2020');
      final b = await service.add(const CitationSource(id: 'lee2020', title: 'B', authors: [Person('Lee', 'B')], year: 2020));
      expect(b.id, 'lee2020a');
      expect(await service.addAll([const CitationSource(id: 'x', title: 'again', doi: '10.1/A')]), 0);

      final again = CitationService(CitationRepository(SettingsRepository(db)));
      await again.load();
      expect(again.sources.map((s) => s.id), ['lee2020', 'lee2020a']);
      expect(again.sources.first.doi, '10.1/a');
    });

    test('edit, rename, delete', () async {
      final a = await service.add(smith);
      await service.update(a.id, a.copyWith(title: 'New'));
      expect(service.byId['smith2020']!.title, 'New');
      await service.update('smith2020', a.copyWith(id: 'smith20'));
      expect(service.byId.keys, ['smith20']);
      await service.remove('smith20');
      expect(service.sources, isEmpty);
    });

    test('the style is remembered', () async {
      await service.setStyle(citationStyleById('ieee'));
      expect(await SettingsRepository(db).get('citation_style'), 'ieee');
      final again = CitationService(CitationRepository(SettingsRepository(db)));
      await again.load();
      expect(again.style.id, 'ieee');
      expect(citationStyleById('nonsense').id, 'apa');
    });

    testWidgets('a text shows its citations in the style, and the list under a document', (tester) async {
      await tester.runAsync(() async {
        await service.add(smith);
        await service.add(doe);
      });
      final controller = RichInlineTextController()..text = 'Claim [@smith2020, p. 4].';
      Widget app({bool bibliography = false}) => MaterialApp(
            home: CitationScope(service: service, child: Scaffold(body: MarkdownView(controller: controller, fontSize: 16, bibliography: bibliography))),
          );
      await tester.pumpWidget(app());
      expect(find.textContaining('(Smith, 2020, p. 4)', findRichText: true), findsOneWidget);
      expect(find.textContaining('References', findRichText: true), findsNothing);

      await tester.pumpWidget(app(bibliography: true));
      expect(find.textContaining('References', findRichText: true), findsOneWidget);
      expect(find.textContaining('Smith, J. (2020)', findRichText: true), findsOneWidget);

      await tester.runAsync(() => service.setStyle(citationStyleById('ieee')));
      await tester.pump();
      expect(find.textContaining('Claim [1, p. 4].', findRichText: true), findsOneWidget);
    });

    testWidgets('without citations on, the text stays as written', (tester) async {
      final off = CitationService(CitationRepository(SettingsRepository(db)), enabled: () => false);
      final controller = RichInlineTextController()..text = 'Claim [@smith2020].';
      await tester.pumpWidget(MaterialApp(home: CitationScope(service: off, child: Scaffold(body: MarkdownView(controller: controller, fontSize: 16)))));
      expect(find.textContaining('[@smith2020]', findRichText: true), findsOneWidget);
    });
  });
}

void expansionTests() {
  group('works of the same author and year', () {
    const a = CitationSource(id: 'a', title: 'Alpha', authors: [Person('Lee', 'A')], year: 2020, publisher: 'P');
    const b = CitationSource(id: 'b', title: 'Beta', authors: [Person('Lee', 'A')], year: 2020, publisher: 'P');
    const c = CitationSource(id: 'c', title: 'Gamma', authors: [Person('Lee', 'A')], year: 2021, publisher: 'P');
    final lib = {'a': a, 'b': b, 'c': c};

    test('are told apart by letters in the text and in the list', () {
      const text = 'Beta [@b], alpha [@a], other [@c].';
      final doc = CitationDocument(const ApaStyle(), lib, text);
      final marks = findCitations(text);
      expect(doc.inText(marks[0].items), '(Lee, 2020b)');
      expect(doc.inText(marks[1].items), '(Lee, 2020a)');
      expect(doc.inText(marks[2].items), '(Lee, 2021)');
      final list = doc.bibliography();
      expect(list[0], startsWith('Lee, A. (2020a). *Alpha*'));
      expect(list[1], startsWith('Lee, A. (2020b). *Beta*'));
      expect(list[2], startsWith('Lee, A. (2021). *Gamma*'));
    });

    test('a numbered style needs no letters', () {
      const text = '[@a] [@b]';
      expect(CitationDocument(const IeeeStyle(), lib, text).inText(findCitations(text).first.items), '[1]');
    });
  });

  test('ISO 690', () {
    const s = Iso690Style();
    const article = CitationSource(
        id: 'k', type: SourceType.article, title: 'A paper', authors: [Person('Smith', 'John'), Person('Jones', 'Mary')], year: 2020, container: 'Nature', volume: '5', issue: '2', pages: '1-9', doi: '10.1/x');
    expect(s.entry(article), 'SMITH, John and JONES, Mary, 2020. A paper. *Nature*. 5(2), 1–9. DOI 10.1/x.');
    expect(s.inText([Cite(article, Locator.parse('42'))], {}), '(Smith and Jones 2020, p. 42)');
  });

  group('a style for one note', () {
    late Database db;
    setUp(() async => db = await AppDatabase.open(path: inMemoryDatabasePath));
    tearDown(() => db.close());

    testWidgets('overrides the one for every note', (tester) async {
      final service = CitationService(CitationRepository(SettingsRepository(db)));
      await tester.runAsync(() => service.add(smith));

      final controller = RichInlineTextController()..text = 'See [@smith2020].';
      await tester.pumpWidget(MaterialApp(
        home: CitationScope(
          service: service,
          child: CitationStyleScope(style: citationStyleById('ieee'), child: Scaffold(body: MarkdownView(controller: controller, fontSize: 16))),
        ),
      ));
      expect(find.textContaining('See [1].', findRichText: true), findsOneWidget);
    });
  });

  group('shared between devices', () {
    late Database db;
    setUp(() async => db = await AppDatabase.open(path: inMemoryDatabasePath));
    tearDown(() => db.close());

    test('the library and the styles travel with the settings', () {
      expect(syncedSetting('cite:smith2020'), isTrue);
      expect(syncedSetting('citation_style'), isTrue);
      expect(syncedSetting('citation_style_note:n1'), isTrue);
      expect(syncedSetting('citation_style_folder:f1'), isTrue);
    });

    test('a source, its deletion and a style come to the other device as settings', () async {
      final here = SettingsRepository(db);
      final service = CitationService(CitationRepository(here));
      await service.add(smith);
      await service.add(doe);
      await service.remove('doe2019');
      await service.setStyle(citationStyleById('mla'));

      // what the sync takes over: every synced setting with the time it was set
      final sent = await here.allWhere(syncedSetting);
      final other = await AppDatabase.open(path: inMemoryDatabasePath);
      addTearDown(other.close);
      final there = SettingsRepository(other);
      for (final e in sent.entries) {
        await there.setFromSync(e.key, e.value.value, e.value.changedAt);
      }
      final copy = CitationService(CitationRepository(there));
      await copy.load();
      expect(copy.sources.map((s) => s.id), ['smith2020']); // the deleted one stays deleted
      expect(copy.sources.single.title, smith.title);
      expect(copy.style.id, 'mla');
    });

    test('editing keeps the place in the list; renaming moves the key', () async {
      final service = CitationService(CitationRepository(SettingsRepository(db)));
      await service.add(smith);
      await Future<void>.delayed(const Duration(milliseconds: 5)); // (the order is the time they were added)
      await service.add(doe);
      await service.update('smith2020', smith.copyWith(id: 'smith20', title: 'New'));
      final again = CitationService(CitationRepository(SettingsRepository(db)));
      await again.load();
      expect(again.sources.map((s) => s.id), ['smith20', 'doe2019']);
    });

    test('the library of the first version is taken over once', () async {
      await db.execute('CREATE TABLE citation_sources (id TEXT PRIMARY KEY, data TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)');
      await db.insert('citation_sources', {'id': 'old1', 'data': jsonEncode(smith.toJson()), 'created_at': 5, 'updated_at': 5});
      final service = CitationService(CitationRepository(SettingsRepository(db), legacy: db));
      await service.load();
      expect(service.sources.map((s) => s.id), ['old1']);
      expect(await db.rawQuery("SELECT name FROM sqlite_master WHERE name = 'citation_sources'"), isEmpty);
      await service.load(); // (nothing left to take)
      expect(service.sources, hasLength(1));
    });
  });

  group('styles of folders and notes', () {
    late Database db;
    setUp(() async => db = await AppDatabase.open(path: inMemoryDatabasePath));
    tearDown(() => db.close());

    test('the nearest choice wins: the note, then the folder, then the folders around it, then every note', () async {
      // note n is in folder "inner", which is in "outer"
      final service = CitationService(CitationRepository(SettingsRepository(db)), folderChain: (id) async => ['inner', 'outer']);
      await service.load();
      expect(await service.styleOfNote('n'), isNull);
      await service.setFolderStyle('outer', citationStyleById('harvard'));
      expect((await service.styleOfNote('n'))!.id, 'harvard');
      await service.setFolderStyle('inner', citationStyleById('mla'));
      expect((await service.styleOfNote('n'))!.id, 'mla');
      await service.setNoteStyle('n', citationStyleById('ieee'));
      expect((await service.styleOfNote('n'))!.id, 'ieee');
      await service.setNoteStyle('n', null);
      await service.setFolderStyle('inner', null);
      expect((await service.styleOfNote('n'))!.id, 'harvard');

      final again = CitationService(CitationRepository(SettingsRepository(db)), folderChain: (id) async => ['inner', 'outer']);
      await again.load();
      expect((await again.styleOfNote('n'))!.id, 'harvard');
    });
  });
}
