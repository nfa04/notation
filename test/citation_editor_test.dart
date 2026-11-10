import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/block_editor.dart';
import 'package:notes/citations/citation_repository.dart';
import 'package:notes/citations/citation_service.dart';
import 'package:notes/citations/citation_style.dart';
import 'package:notes/citations/source.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const smith = CitationSource(id: 'smith2020', type: SourceType.article, title: 'Alpha', authors: [Person('Smith', 'J')], year: 2020, container: 'J');
const doe = CitationSource(id: 'doe2019', title: 'Beta', authors: [Person('Doe', 'J')], year: 2019, publisher: 'P');

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late CitationService service;
  late String id;

  Future<void> open(WidgetTester tester, {String document = ''}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      addTearDown(db.close);
      repo = NoteRepository(db);
      service = CitationService(CitationRepository(SettingsRepository(db)));
      await service.add(smith);
      await service.add(doe);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.documentText = document;
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(
      home: CitationScope(service: service, child: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  Future<NoteDataSaved> saved(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1300)));
    await tester.pump(const Duration(milliseconds: 1000));
    final note = (await tester.runAsync(() => repo.loadNote(id)))!;
    return NoteDataSaved(note.documentText, [for (final boxes in note.textBoxes.values) for (final b in boxes) b.controller.text]);
  }

  testWidgets('a citation in the written document is tapped to be changed, then to be taken out', (tester) async {
    await open(tester, document: 'Claim [@smith2020, p. 4] holds.');
    await tester.tap(find.text('Document').first);
    await tester.pumpAndSettle();
    if (find.text('Preview').evaluate().isNotEmpty) {
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('(Smith, 2020, p. 4)', findRichText: true), findsOneWidget);
    expect(find.textContaining('References', findRichText: true), findsOneWidget); // the list under the document

    // changed: another source as well
    await tester.tap(find.byKey(const ValueKey('citation-6')));
    await tester.pumpAndSettle();
    expect(find.text('Change the citation'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cite-doe2019')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cite-insert')));
    await tester.pumpAndSettle();
    expect(find.textContaining('(Doe, 2019; Smith, 2020, p. 4)', findRichText: true), findsOneWidget);
    expect((await saved(tester)).document, 'Claim [@smith2020, p. 4; @doe2019] holds.');

    // taken out
    await tester.tap(find.byKey(const ValueKey('citation-6')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cite-remove')));
    await tester.pumpAndSettle();
    expect((await saved(tester)).document, 'Claim holds.');
    expect(find.textContaining('References', findRichText: true), findsNothing);
  });

  testWidgets('on a page written by hand, a citation and the list of sources are put in text boxes', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('note-citations')));
    await tester.pumpAndSettle();
    expect(find.text('Cite a source on the page...'), findsOneWidget);
    await tester.tap(find.text('Cite a source on the page...'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cite-smith2020')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('cite-locator-smith2020')), '42');
    await tester.tap(find.byKey(const ValueKey('cite-insert')));
    await tester.pumpAndSettle();

    // with a text box selected (the one just made) the list goes into it, at the cursor
    await tester.tap(find.byKey(const ValueKey('insert-bibliography')));
    await tester.pumpAndSettle();
    final boxes = (await saved(tester)).boxes;
    expect(boxes, hasLength(1));
    expect(boxes.single, '[@smith2020, p. 42]\n\n[bibliography]');
  });

  testWidgets('with no text box selected the list is a text box of its own, as often as it is asked for', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('insert-bibliography')));
    await tester.pumpAndSettle();
    expect((await saved(tester)).boxes, ['[bibliography]']);
  });

  testWidgets('in the written document the list goes in at the cursor', (tester) async {
    await open(tester, document: 'Claim [@smith2020].\n\nThe end.');
    await tester.tap(find.text('Document').first);
    await tester.pumpAndSettle();
    if (find.text('Edit').evaluate().isNotEmpty) {
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
    }
    final controller = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    controller.selection = const TextSelection.collapsed(offset: 'Claim [@smith2020].'.length);
    await tester.tap(find.byKey(const ValueKey('insert-bibliography')));
    await tester.pumpAndSettle();
    expect(controller.text, 'Claim [@smith2020].\n\n[bibliography]\n\nThe end.');
    expect((await saved(tester)).document, 'Claim [@smith2020].\n\n[bibliography]\n\nThe end.');
  });

  testWidgets('the style chosen for the note is read again when it changes elsewhere', (tester) async {
    await open(tester, document: 'Claim [@smith2020].');
    await tester.tap(find.text('Document').first);
    await tester.pumpAndSettle();
    if (find.text('Preview').evaluate().isNotEmpty) {
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('(Smith, 2020)', findRichText: true), findsOneWidget);
    // (what a folder's new style, or a sync, does)
    await tester.runAsync(() => service.setNoteStyle(id, citationStyleById('ieee')));
    await tester.pumpAndSettle();
    expect(find.text('[1]', findRichText: true), findsOneWidget);
    expect(find.textContaining('(Smith, 2020)', findRichText: true), findsNothing);
  });
}

class NoteDataSaved {
  final String document;
  final List<String> boxes;
  NoteDataSaved(this.document, this.boxes);
}
