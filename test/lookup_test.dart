
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/lookup_panel.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('one or two words can be looked up, nothing else', () {
    expect(isLookupTerm('entropy'), isTrue);
    expect(isLookupTerm('  black hole '), isTrue);
    expect(isLookupTerm("Schrödinger's"), isTrue);
    expect(isLookupTerm('too many words'), isFalse);
    expect(isLookupTerm('x^2'), isFalse);
    expect(isLookupTerm('2x + 3 = 11'), isFalse);
    expect(isLookupTerm(''), isFalse);
    expect(isLookupTerm(null), isFalse);
  });

  test('words are prose, a lone letter is not', () {
    expect(isPlainWords('black hole'), isTrue);
    expect(isPlainWords('x'), isFalse);
    expect(isPlainWords('2x + 3 = 11'), isFalse);
  });

  test('the search addresses', () {
    expect(LookupSource.web.urlFor('black hole').toString(), 'https://duckduckgo.com/?q=black+hole');
    expect(LookupSource.wikipedia.urlFor('entropy').host, 'en.wikipedia.org');
    expect(LookupSource.wikipedia.urlFor('a&b').queryParameters['search'], 'a&b');
  });

  test('translating: sentences yes, formulas no', () {
    expect(isTranslatable('Der Hund läuft schnell.'), isTrue);
    expect(isTranslatable('Hallo'), isTrue);
    expect(isTranslatable('x'), isFalse);
    expect(isTranslatable('2x + 3 = 11'), isFalse);
    expect(isTranslatable(r'$a^2$'), isFalse);
    expect(isTranslatable('a' * 501), isFalse);
    final url = LookupSource.translate.urlFor('Guten Tag', language: 'fr');
    expect(url.host, 'translate.google.com');
    expect((url.queryParameters['tl'], url.queryParameters['text']), ('fr', 'Guten Tag'));
  });

  test('a page is linked the way a note\'s text writes links', () {
    expect(markdownLink(Uri.parse('https://en.wikipedia.org/wiki/Black_hole'), 'Black hole - Wikipedia'),
        '[Black hole - Wikipedia](https://en.wikipedia.org/wiki/Black_hole)');
    // brackets in the title and brackets or spaces in the address would end the link early
    expect(markdownLink(Uri.parse('https://en.wikipedia.org/wiki/Entropy_(disambiguation)'), 'A [b]\nc'),
        '[A b c](https://en.wikipedia.org/wiki/Entropy_%28disambiguation%29)');
    expect(markdownLink(Uri.parse('https://example.org/x'), null), '[example.org](https://example.org/x)');
  });

  testWidgets('highlighted words open Wikipedia beside the note', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: r'black hole and $x+1=2$')];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(
      home: FixedPageNoteEditor(
        key: ValueKey(id),
        noteId: id,
        repository: repo,
        webPage: (url) => Text('PAGE $url', key: const ValueKey('fake-page')),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await tester.tapAt(origin + const Offset(150, 130));
    await tester.pumpAndSettle();
    final field = tester.state<EditableTextState>(find.byType(EditableText).first);

    // a formula: calculate, no look-up
    field.widget.controller.selection = const TextSelection(baseOffset: 15, extentOffset: 21);
    await tester.pump();
    field.showToolbar();
    await tester.pumpAndSettle();
    expect(find.text('Calculate'), findsOneWidget);
    expect(find.text('Wikipedia'), findsNothing);
    field.hideToolbar();
    await tester.pumpAndSettle();

    // two words: look-up, no calculating
    field.widget.controller.selection = const TextSelection(baseOffset: 0, extentOffset: 10);
    await tester.pump();
    field.showToolbar();
    await tester.pumpAndSettle();
    expect(find.text('Calculate'), findsNothing);
    expect(find.text('Search the web'), findsOneWidget);
    await tester.tap(find.text('Wikipedia'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lookup-panel')), findsOneWidget);
    expect(find.textContaining('en.wikipedia.org'), findsOneWidget);
    expect(find.textContaining('black+hole'), findsOneWidget);

    // the button links the page on the note, in a text box of its own
    await tester.tap(find.byKey(const ValueKey('lookup-link')));
    await tester.pumpAndSettle();
    expect(find.text('Linked on page 1'), findsOneWidget);
    final linked = tester
        .widgetList<EditableText>(find.byType(EditableText))
        .map((e) => e.controller.text)
        .where((t) => t.startsWith('[black hole (Wikipedia)]('));
    expect(linked.single, contains('https://en.wikipedia.org/w/index.php?search=black+hole'));

    // the bar between note and panel resizes it
    final before = tester.getSize(find.byKey(const ValueKey('lookup-panel'))).width;
    await tester.drag(find.byKey(const ValueKey('lookup-resize')), const Offset(-100, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('lookup-panel'))).width, before + 100);
    await tester.drag(find.byKey(const ValueKey('lookup-resize')), const Offset(900, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('lookup-panel'))).width, 280); // not narrower than this

    // translation has a target language to pick
    await tester.tap(find.text('Translate').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('translate.google.com'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lookup-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('to Français').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('tl=fr'), findsOneWidget);
    expect(await tester.runAsync(() => repo.settings.get('translate_to')), 'fr');

    // switch to the web search, then close
    await tester.tap(find.text('Web'));
    await tester.pumpAndSettle();
    expect(find.textContaining('duckduckgo.com'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lookup-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lookup-panel')), findsNothing);
  });

  testWidgets('a web link in the note opens in the panel, as the page itself', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: '[Example](https://www.example.org/a)')];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(
      home: FixedPageNoteEditor(
        key: ValueKey(id),
        noteId: id,
        repository: repo,
        webPage: (url) => Text('PAGE $url', key: const ValueKey('fake-page')),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('link-https://www.example.org/a')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lookup-panel')), findsOneWidget);
    expect(find.text('PAGE https://www.example.org/a'), findsOneWidget);
    expect(find.text('example.org'), findsOneWidget); // the title of the panel
    expect(find.byKey(const ValueKey('lookup-source')), findsNothing); // no search to switch
  });

  testWidgets('text selected on the web page can be added to the note, with or without a link to the page', (tester) async {
    final selection = ValueNotifier<String>('');
    final added = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LookupPanel(
          term: 'black hole',
          source: LookupSource.wikipedia,
          onClose: () {},
          page: (url) => const SizedBox(),
          selection: selection,
          onAddText: added.add,
        ),
      ),
    ));
    expect(find.byKey(const ValueKey('lookup-selection')), findsNothing); // nothing selected: no button

    selection.value = 'A region of space from which nothing can escape.';
    await tester.pump();
    expect(find.byKey(const ValueKey('lookup-selection')), findsOneWidget);
    expect(find.textContaining('A region of space'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lookup-add-text')));
    expect(added.single, startsWith('A region of space from which nothing can escape.\n\n[black hole](https://en.wikipedia.org/'));

    await tester.tap(find.byKey(const ValueKey('lookup-with-source')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('lookup-add-text')));
    expect(added.last, 'A region of space from which nothing can escape.'); // as it was, nothing else

    selection.value = ''; // the selection went away (or another page was opened)
    await tester.pump();
    expect(find.byKey(const ValueKey('lookup-selection')), findsNothing);

    // without a way to add text there is no bar at all
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LookupPanel(term: 'x y', source: LookupSource.web, onClose: () {}, page: (url) => const SizedBox(), selection: selection)),
    ));
    selection.value = 'something';
    await tester.pump();
    expect(find.byKey(const ValueKey('lookup-selection')), findsNothing);
  });

  testWidgets('the editor puts what the panel hands over into a text box on the page on screen', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: 'black hole')];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(
      home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, webPage: (url) => const SizedBox()),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await tester.tapAt(origin + const Offset(150, 130));
    await tester.pumpAndSettle();
    final field = tester.state<EditableTextState>(find.byType(EditableText).first);
    field.widget.controller.selection = const TextSelection(baseOffset: 0, extentOffset: 10);
    await tester.pump();
    field.showToolbar();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wikipedia'));
    await tester.pumpAndSettle();
    final panel = tester.widget<LookupPanel>(find.byKey(const ValueKey('lookup-panel')));
    expect(panel.onAddText, isNotNull);
    panel.onAddText!('Quoted from the page');
    await tester.pumpAndSettle();
    expect(find.text('Added to page 1'), findsOneWidget);
    expect(tester.widgetList<EditableText>(find.byType(EditableText)).any((e) => e.controller.text == 'Quoted from the page'), isTrue);
  });
}
