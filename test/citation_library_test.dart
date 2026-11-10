import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/citations/citation_document.dart';
import 'package:notes/citations/citation_library_screen.dart';
import 'package:notes/citations/citation_repository.dart';
import 'package:notes/citations/citation_service.dart';
import 'package:notes/citations/cite_picker.dart';
import 'package:notes/citations/source.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const smith = CitationSource(id: 'smith2020', type: SourceType.article, title: 'Alpha: a Study', authors: [Person('Smith', 'John')], year: 2020, container: 'J', doi: '10.1000/abc');
const doe = CitationSource(id: 'doe2019', title: 'Beta', authors: [Person('Doe', 'Jane')], year: 2019, publisher: 'P');
const unused = CitationSource(id: 'unused2000', title: 'Gamma', authors: [Person('Lee', 'Kim')], year: 2000, publisher: 'P');

void main() {
  setUpAll(AppDatabase.initFfi);

  late CitationService service;

  // (an in-memory database is shared by the tests of a file)
  Future<CitationService> fresh({Future<Map<String, List<NoteRef>>> Function(bool Function(String) isSource)? citedIn}) async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    addTearDown(db.close);
    await db.delete('settings');
    return CitationService(CitationRepository(SettingsRepository(db)), citedIn: citedIn);
  }

  /// Lets what the app does with the database run (it only does inside runAsync), then draws.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
  }

  setUp(() => made = null);

  Future<void> make(WidgetTester tester, {Future<Map<String, List<NoteRef>>> Function(bool Function(String) isSource)? citedIn, List<CitationSource> sources = const [smith, doe, unused]}) async {
    await tester.runAsync(() async {
      service = await fresh(citedIn: citedIn);
      for (final s in sources) {
        await service.add(s);
      }
    });
  }

  Future<void> openLibrary(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: CitationLibraryScreen(service: service)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  group('a source twice', () {
    test('the same DOI, in any spelling, or the same title in other letters', () async {
      final s = await fresh();
      await s.add(smith);
      expect(s.duplicateOf(const CitationSource(id: 'x', title: 'Other', doi: 'https://doi.org/10.1000/ABC')), isNotNull);
      expect(s.duplicateOf(const CitationSource(id: 'x', title: 'ALPHA - a study!', authors: [Person('Smith')], year: 2020)), isNotNull);
      expect(s.duplicateOf(const CitationSource(id: 'x', title: 'alpha a study', authors: [Person('Smith', 'J.')], year: 2020))?.id, 'smith2020');
    });

    test('not another year, another author, or the source being changed', () async {
      final s = await fresh();
      await s.add(smith);
      expect(s.duplicateOf(smith.copyWith(id: 'x', doi: '', year: 2021)), isNull);
      expect(s.duplicateOf(smith.copyWith(id: 'x', doi: '', authors: [const Person('Jones')])), isNull);
      expect(s.duplicateOf(smith, except: 'smith2020'), isNull);
      expect(s.duplicateOf(const CitationSource(id: 'x', title: '')), isNull); // (no title: nothing to compare)
    });
  });

  testWidgets('the library says where each source is cited, and what is not cited yet', (tester) async {
    await make(tester, citedIn: (isSource) async => {
          'smith2020': [(id: 'n1', title: 'Lecture'), (id: 'n2', title: '')],
          'doe2019': [(id: 'n1', title: 'Lecture')],
        });
    await openLibrary(tester);
    expect(find.byKey(const ValueKey('cited-in-smith2020')), findsOneWidget);
    expect(find.text('Cited in 2 notes: Lecture, Untitled'), findsOneWidget);
    expect(find.text('Cited in 1 note: Lecture'), findsOneWidget);
    expect(find.text('Not cited in any note'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('uncited-only')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('source-unused2000')), findsOneWidget);
    expect(find.byKey(const ValueKey('source-smith2020')), findsNothing);
    expect(find.byKey(const ValueKey('source-doe2019')), findsNothing);
  });

  testWidgets('a key the notes cite and the library lacks is listed, and can be added', (tester) async {
    await make(tester, citedIn: (isSource) async => {
          'smith2020': [(id: 'n1', title: 'Lecture')],
          'gone2010': [(id: 'n1', title: 'Lecture'), (id: 'n2', title: 'Essay')],
        });
    await openLibrary(tester);
    expect(find.byKey(const ValueKey('unknown-gone2010')), findsOneWidget);
    expect(find.byKey(const ValueKey('unknown-smith2020')), findsNothing);
    expect(find.text('Lecture, Essay'), findsOneWidget);

    // adding it by the same key makes the citation readable again
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('unknown-gone2010')), matching: find.byType(TextButton)));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('source-key'))).controller!.text, 'gone2010');
    await tester.enterText(find.byKey(const ValueKey('source-title')), 'A found book');
    await tester.tap(find.byKey(const ValueKey('source-save')));
    await settle(tester);
    expect(service.has('gone2010'), isTrue);
    expect(find.byKey(const ValueKey('unknown-gone2010')), findsNothing);
  });

  testWidgets('without a way to find the notes the library is as before', (tester) async {
    await make(tester);
    await openLibrary(tester);
    expect(find.byKey(const ValueKey('uncited-only')), findsNothing);
    expect(find.byKey(const ValueKey('cited-in-smith2020')), findsNothing);
    expect(find.byKey(const ValueKey('source-smith2020')), findsOneWidget);
  });

  testWidgets('a source that is there already is offered instead of a second copy', (tester) async {
    await make(tester);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(onPressed: () async => made = await addSourceByHand(context, service, initial: smith.copyWith(id: '')), child: const Text('go')))));
    Future<void> fillAndSave() async {
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-save')));
      await settle(tester);
    }

    await fillAndSave();
    expect(find.text('Already in the library'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('duplicate-cancel')));
    await tester.pumpAndSettle();
    expect(made, isNull);
    expect(service.sources, hasLength(3));

    await fillAndSave();
    await tester.tap(find.byKey(const ValueKey('duplicate-use')));
    await settle(tester);
    expect(made?.id, 'smith2020');
    expect(service.sources, hasLength(3));

    await fillAndSave();
    await tester.tap(find.byKey(const ValueKey('duplicate-add')));
    await settle(tester);
    expect(made?.id, isNot('smith2020'));
    expect(service.sources, hasLength(4));
  });

  testWidgets('a source that is new is added without asking', (tester) async {
    await make(tester);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(onPressed: () async => made = await addSourceByHand(context, service, initial: const CitationSource(id: '', title: 'Brand new', year: 1990)), child: const Text('go')))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-save')));
    await settle(tester);
    expect(find.text('Already in the library'), findsNothing);
    expect(made?.title, 'Brand new');
    expect(service.sources, hasLength(4));
  });

  testWidgets('the export menu offers the formats', (tester) async {
    await make(tester);
    await openLibrary(tester);
    await tester.tap(find.byKey(const ValueKey('export-sources')));
    await tester.pumpAndSettle();
    expect(find.text('Save as BibTeX...'), findsOneWidget);
    expect(find.text('Save as RIS...'), findsOneWidget);
    expect(find.text('Save as CSL-JSON...'), findsOneWidget);
    expect(find.text('Copy as BibTeX'), findsOneWidget);
  });

  testWidgets('the picker keeps what a citation says and lets it be changed', (tester) async {
    await make(tester);
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showCitePicker(context, service, editing: const [CiteRef('smith2020', prefix: 'see', suffix: 'emphasis added')]),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('cite-prefix-smith2020'))).controller!.text, 'see');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('cite-suffix-smith2020'))).controller!.text, 'emphasis added');

    // saved as it was
    await tester.tap(find.byKey(const ValueKey('cite-insert')));
    await tester.pumpAndSettle();
    expect(result, '[see @smith2020, emphasis added]');

    // changed: a place, no author
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('cite-locator-smith2020')), '3-5');
    await tester.tap(find.byKey(const ValueKey('cite-no-author-smith2020')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cite-insert')));
    await tester.pumpAndSettle();
    expect(result, '[see -@smith2020, pp. 3–5, emphasis added]');
  });
}

CitationSource? made;
