import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/markdown/grammar.dart';
import 'package:notes/markdown/live_markdown.dart';
import 'package:notes/markdown/markdown_formatting.dart';
import 'package:notes/markdown/markdown_parser.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A long document with what people write in one, widgets among it.
String longText({int sections = 40}) => [
      for (var i = 0; i < sections; i++) ...[
        '## Section $i',
        '',
        '${List.filled(6, 'Alexander the Great of Macedon conquered the Persian Empire and reached as far as India.').join(' ')} **Bold** and *italic*.',
        '',
        '- one item',
        '- [ ] a task',
        '> a quote',
        '',
        '| a | b |',
        '|---|---|',
        '| $i | 2 |',
        '',
      ],
    ].join('\n');

/// How many pieces [text] comes to.
int liveMarkdownPiecesCount(WidgetTester tester, String text) => liveMarkdownPieces(tester.element(find.byType(Scaffold).first), LiveMarkdownController()..text = text, documentTextStyle(16), width: 600).length;

void main() {
  group('the document that is only read', () {
    final text = longText();
    Widget at(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: Align(alignment: Alignment.topLeft, child: SizedBox(width: 600, child: child)))));

    testWidgets('a long one is in pieces, and they end where blocks end', (tester) async {
      final c = LiveMarkdownController()..text = text;
      await tester.pumpWidget(at(LiveMarkdownView(controller: c, fontSize: 16, references: false)));
      final pieces = tester.widgetList<RichText>(find.byWidgetPredicate((w) => w.key is LivePieceKey)).toList();
      expect(pieces.length, greaterThan(5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('pieces take as much room as one paragraph with all of it would, and no line moves', (tester) async {
      final c = LiveMarkdownController()..text = text;
      await tester.pumpWidget(at(LiveMarkdownView(controller: c, fontSize: 16, references: false)));
      final inPieces = tester.getSize(find.byType(LiveMarkdownView)).height;
      final tops = [for (final e in find.byWidgetPredicate((w) => w.key is LivePieceKey).evaluate()) (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy];
      expect(tops, orderedEquals([...tops]..sort()));

      late TextSpan whole;
      await tester.pumpWidget(at(Builder(builder: (context) {
        whole = liveMarkdownSpan(context, c, documentTextStyle(16), width: 597);
        return RichText(strutStyle: StrutStyle.disabled, text: whole);
      })));
      expect(inPieces, closeTo(tester.getSize(find.byType(RichText).first).height, 0.5), reason: 'a paragraph is a whole number of pixels tall: what pieces add up must not be');
    });

    test('a window shows the pieces it touches', () {
      const tops = [0.0, 100.0, 250.0, 400.0];
      expect(piecesBetween(tops, 0, 90), (first: 0, end: 1, top: 0.0));
      expect(piecesBetween(tops, 120, 260), (first: 1, end: 3, top: 100.0));
      expect(piecesBetween(tops, 250, 400), (first: 2, end: 3, top: 250.0));
      expect(piecesBetween(tops, 500, double.infinity), (first: 3, end: 4, top: 400.0));
      expect(piecesBetween(const [0.0], 300, 500), (first: 0, end: 1, top: 0.0));
    });

    testWidgets('in the editor each sheet near the screen shows its own part, and the unseen copy that is measured is the only whole one', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      AppDatabase.initFfi();
      late NoteRepository repo;
      late String id;
      await tester.runAsync(() async {
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote();
        final note = (await repo.loadNote(id))!;
        note.documentText = text;
        await repo.saveNote(note);
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      final views = tester.widgetList<LiveMarkdownView>(find.byType(LiveMarkdownView, skipOffstage: false)).toList();
      expect(views.length, greaterThan(2));
      expect(views.first.pieces, isNull);
      expect(views.skip(1).every((v) => v.pieces != null), isTrue);
      final total = find.descendant(of: find.byWidget(views.first, skipOffstage: false), matching: find.byWidgetPredicate((w) => w.key is LivePieceKey, skipOffstage: false), skipOffstage: false).evaluate().length;
      for (final v in views.skip(1)) {
        expect(v.pieces!.length, lessThan(total), reason: 'a sheet has a whole copy of the text');
      }
      // on each sheet the pieces are where they are in the whole text
      Map<int, double> topsIn(LiveMarkdownView view) => {
            for (final e in find.descendant(of: find.byWidget(view, skipOffstage: false), matching: find.byWidgetPredicate((w) => w.key is LivePieceKey, skipOffstage: false), skipOffstage: false).evaluate())
              (e.widget.key! as LivePieceKey).value: tester.getTopLeft(find.byWidget(e.widget, skipOffstage: false)).dy,
          };
      final whole = topsIn(views.first);
      for (final v in views.skip(1)) {
        final here = topsIn(v);
        final first = here.keys.reduce((a, b) => a < b ? a : b);
        for (final e in here.entries) {
          expect(e.value - here[first]!, closeTo(whole[e.key]! - whole[first]!, 0.5));
        }
      }
      expect(views.first.ended, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
    });
  });

  group('typing in a long document', () {
    test('it is read once for a text, and again when the text changes', () {
      final c = LiveMarkdownController()..text = '# One';
      final first = parsedMarkdown(c);
      expect(identical(parsedMarkdown(c), first), isTrue);
      c.text = '# Two';
      expect(identical(parsedMarkdown(c), first), isFalse);
      expect(parsedMarkdown(c).single.runs.single.text, 'Two');
    });

    test('what was parsed already gives what the text alone gives', () {
      final text = longText(sections: 3);
      final blocks = parseMarkdown(text);
      expect(wordCount(text, blocks: blocks), wordCount(text));
      expect(grammarIssues('$text  a apple', blocks: parseMarkdown('$text  a apple')).length, grammarIssues('$text  a apple').length);
    });

    test('the grammar check looks at the word before a sentence as it did', () {
      List<String> starts(String t) => [for (final g in grammarIssues(t)) if (g.replacement.length == 1 && g.message.contains('capital')) t.substring(g.start, g.end)];
      expect(starts('It was over. then it began.'), ['t']);
      expect(starts('See e.g. this one.'), isEmpty);
      expect(starts('Dr. who came.'), isEmpty);
      expect(starts('And so... on it went.'), isEmpty);
      expect(starts('And so… on it went.'), isEmpty);
      expect(starts('A word.   \n\n  next line.'), ['n']);
    });

    testWidgets('a table stays what it is while something is typed before it', (tester) async {
      final c = LiveMarkdownController()..text = 'Some text\n\n- [ ] a task\n\n| a | b |\n|---|---|\n| 1 | 2 |\n';
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 500, child: TextField(controller: c, maxLines: null, strutStyle: StrutStyle.disabled)))));
      final table = tester.element(find.byKey(const ValueKey('live-table-0')));
      final task = tester.element(find.byKey(const ValueKey('task-0')));
      final shown = tester.widget<SizedBox>(find.byKey(const ValueKey('live-table-0'))).child;
      c.value = TextEditingValue(text: 'New ${c.text}', selection: const TextSelection.collapsed(offset: 4));
      await tester.pump();
      expect(identical(tester.element(find.byKey(const ValueKey('live-table-0'))), table), isTrue, reason: 'it was made anew');
      expect(identical(tester.element(find.byKey(const ValueKey('task-0'))), task), isTrue);
      expect(identical(tester.widget<SizedBox>(find.byKey(const ValueKey('live-table-0'))).child, shown), isTrue, reason: 'it was laid out anew');

      // a task still ticks the right box after the text moved
      await tester.tap(find.byKey(const ValueKey('task-0')));
      await tester.pump();
      expect(c.text, contains('- [x] a task'));
      expect(c.text, startsWith('New Some text'));
    });

    group('opening a long one', () {
      final text = longText(sections: 200);

      Future<(NoteRepository, String)> saved(WidgetTester tester, String text) async {
        tester.view.physicalSize = const Size(1600, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        AppDatabase.initFfi();
        late NoteRepository repo;
        late String id;
        await tester.runAsync(() async {
          repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
          id = await repo.createNote();
          final note = (await repo.loadNote(id))!;
          note.documentText = text;
          await repo.saveNote(note);
        });
        return (repo, id);
      }

      Finder allPieces() => find.byWidgetPredicate((w) => w.key is LivePieceKey, skipOffstage: false);
      Finder measuring() => find.byWidgetPredicate((w) => w is LiveMarkdownView && w.inTurn != null, skipOffstage: false);
      int madeSoFar(WidgetTester tester) => find.descendant(of: measuring(), matching: allPieces(), skipOffstage: false).evaluate().length;
      int sheets() => find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('document-sheet-'), skipOffstage: false).evaluate().length;

      Future<void> closed(WidgetTester tester) async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
      }

      testWidgets('the first of the text is there at once, and the rest comes frame by frame until all of it is', (tester) async {
        final (repo, id) = await saved(tester, text);
        await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pump();
        final atFirst = madeSoFar(tester);
        expect(atFirst, greaterThan(0));
        expect(find.textContaining('Section 0', findRichText: true), findsWidgets);
        await tester.pumpAndSettle();
        final all = liveMarkdownPiecesCount(tester, text);
        expect(atFirst, lessThan(all));
        expect(madeSoFar(tester), all);
        expect(sheets(), greaterThan(2));
        await closed(tester);
      });

      testWidgets('where it opens with a page to go to, all of it is there first', (tester) async {
        final (repo, id) = await saved(tester, text);
        await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, initialPage: 1)));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pump();
        expect(madeSoFar(tester), liveMarkdownPiecesCount(tester, text));
        await tester.pumpAndSettle();
        await closed(tester);
      });

      testWidgets('a sheet far down has no text until the screen comes near it, and has it then', (tester) async {
        final (repo, id) = await saved(tester, text);
        await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pumpAndSettle();
        final last = sheets() - 1;
        expect(last, greaterThan(12), reason: 'long enough to have sheets away from the screen');
        Finder onLast() => find.descendant(of: find.byKey(ValueKey('document-sheet-$last'), skipOffstage: false), matching: find.byType(LiveMarkdownView, skipOffstage: false), skipOffstage: false);
        expect(onLast(), findsNothing);
        final scroll = tester.state<ScrollableState>(find.descendant(of: find.byType(FixedPageNoteEditor), matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down)).first).position;
        scroll.jumpTo(tester.getSize(find.byKey(const ValueKey('document-sheet-0'), skipOffstage: false)).height * last);
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect(onLast(), findsOneWidget);
        await closed(tester);
      });

      testWidgets('a change of the text while it comes in ends up shown, with nothing left of what it was', (tester) async {
        final (repo, id) = await saved(tester, text);
        await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pump();
        final c = tester.widget<LiveMarkdownView>(measuring()).controller;
        c.text = '# Only this now';
        await tester.pumpAndSettle();
        expect(madeSoFar(tester), 1);
        expect(sheets(), 0);
        await closed(tester);
      });
    });
  });
}
