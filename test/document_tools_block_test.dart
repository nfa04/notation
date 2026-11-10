import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/block_editor.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/bookmark_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/markdown/live_markdown.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// What the other tools of the editor do with a long document, now that it is written line by line.
String longText() => [
      for (var i = 1; i <= 120; i++) ...[
        '## Heading number $i',
        'Paragraph $i. ${List.filled(5 + i % 4, 'Alexander the Great of Macedon conquered the Persian Empire.').join(' ')}',
        '',
      ],
      'The zebra is here.',
    ].join('\n');

void main() {
  setUpAll(AppDatabase.initFfi);

  Future<void> open(WidgetTester tester, {required bool writing}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late BookmarkRepository bookmarks;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      bookmarks = BookmarkRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.documentText = longText();
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, bookmarks: bookmarks)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    if (!writing) return;
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    final state = tester.state<BlockEditorState>(find.byType(BlockEditor));
    for (var i = 0; i < 2000 && !state.allMeasured; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Future<void> closed(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  }

  /// Whether [text] is drawn in the part of the screen the pages are in.
  bool onScreen(WidgetTester tester, Pattern text) {
    final view = tester.getRect(find.byType(CustomScrollView).first);
    final seen = find.textContaining(text, findRichText: true, skipOffstage: true).evaluate().map((e) => tester.getRect(find.byWidget(e.widget).first));
    return seen.any((r) => r.overlaps(view));
  }

  Future<void> findWord(WidgetTester tester, String word) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('find-field')), word);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> outlineTo(WidgetTester tester, String title) async {
    await tester.tap(find.byKey(const ValueKey('outline-button')));
    await tester.pumpAndSettle();
    final list = tester.state<ScrollableState>(find.ancestor(of: find.byKey(const ValueKey('outline-entry-0')), matching: find.byType(Scrollable)).first).position;
    while (find.text(title).evaluate().isEmpty && list.pixels < list.maxScrollExtent) {
      list.jumpTo(list.pixels + 200);
      await tester.pump();
    }
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  for (final (name, writing) in const [('read', false), ('written', true)]) {
    testWidgets('find in a document that is $name goes to the match, however far down', (tester) async {
      await open(tester, writing: writing);
      await findWord(tester, 'zebra');
      expect(onScreen(tester, 'zebra'), isTrue);
      await closed(tester);
    });

    testWidgets('a heading in the outline of a document that is $name goes to that heading', (tester) async {
      await open(tester, writing: writing);
      await outlineTo(tester, 'Heading number 60');
      expect(onScreen(tester, 'Heading number 60'), isTrue);
      await closed(tester);
    });
  }

  group('what changes the text from elsewhere', () {
    ScrollController pages(WidgetTester tester) => tester.widget<CustomScrollView>(find.byType(CustomScrollView).first).controller!;
    LiveMarkdownController text(WidgetTester tester) => tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;

    Future<void> writeHalfWay(WidgetTester tester) async {
      await open(tester, writing: true);
      // (for a moment after a document opens nothing brings the caret into view, and that goes by the real clock)
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
      await tester.tapAt(tester.getCenter(find.byType(CustomScrollView).first));
      await tester.pump(const Duration(milliseconds: 400));
      pages(tester).jumpTo(20000);
      await tester.pumpAndSettle();
    }

    testWidgets('the whole text replaced (undo, a newer copy) leaves the page where it is', (tester) async {
      await writeHalfWay(tester);
      final was = pages(tester).offset;
      text(tester).text = '${text(tester).text}\nmore at the end';
      await tester.pumpAndSettle();
      expect(pages(tester).offset, was);
      await closed(tester);
    });

    testWidgets('a change above the caret by someone else leaves the page where it is', (tester) async {
      await writeHalfWay(tester);
      final was = pages(tester).offset;
      final c = text(tester);
      final s = c.selection;
      c.value = TextEditingValue(text: 'x${c.text}', selection: TextSelection.collapsed(offset: s.baseOffset + 1));
      await tester.pumpAndSettle();
      expect(pages(tester).offset, closeTo(was, 40));
      await closed(tester);
    });

    testWidgets('what is put in at the caret stays in view: the caret goes with it', (tester) async {
      await writeHalfWay(tester);
      final c = text(tester);
      final s = c.selection;
      c.value = TextEditingValue(text: c.text.replaceRange(s.start, s.end, 'pasted'), selection: TextSelection.collapsed(offset: s.start + 6));
      await tester.pumpAndSettle();
      expect(pages(tester).offset, lessThan(19000), reason: 'the caret was far above');
      await closed(tester);
    });
  });

  testWidgets('changes tracked while writing: what is typed and taken away is marked, through the keyboard too', (tester) async {
    await open(tester, writing: true);
    final c = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    c.suggesting = true;
    final state = tester.state<BlockEditorState>(find.byType(BlockEditor));
    await tester.tapAt(state.screenRectOf(const TextRange(start: 20, end: 21))!.center);
    await tester.pump(const Duration(milliseconds: 400));
    final length = c.text.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(c.text.length, greaterThan(length - 1), reason: 'marked, not gone');
    expect(tester.takeException(), isNull);
    await closed(tester);
  });

  testWidgets('with no scrolling around it (a presentation) there is paper under all of the text', (tester) async {
    final c = LiveMarkdownController()..value = TextEditingValue(text: longText(), selection: const TextSelection.collapsed(offset: 0));
    final near = ValueNotifier<(double, double)>((0, 4000));
    final focus = FocusNode();
    addTearDown(focus.dispose);
    addTearDown(near.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Material(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          maxHeight: double.infinity,
          child: BlockEditor(controller: c, focusNode: focus, style: documentTextStyle(16), width: 700, nearby: near, sheets: const (room: 1000, step: 1155)),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final state = tester.state<BlockEditorState>(find.byType(BlockEditor));
    expect(near.value.$2, greaterThanOrEqualTo(state.documentHeight));
  });
}
