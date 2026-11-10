import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/history/note_history.dart';
import 'package:notes/markdown/document_toolbar.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/style/tool_columns.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  // a group goes to a next column as a whole: its tools are never at the bottom of one column and the top of the next
  testWidgets('in a short window the groups of tools run down the column first, and only the rest goes on in a next one', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    final undo = tester.getRect(find.byKey(const ValueKey('undo-button')));
    final redo = tester.getRect(find.byKey(const ValueKey('redo-button')));
    expect(redo.left, undo.left, reason: 'the same column');
    expect(redo.top, greaterThan(undo.top));
    final add = tester.getRect(find.byTooltip('Add a color (hold an added color to remove it)'));
    expect(add.left, greaterThan(undo.left), reason: 'in a next column');
    final colors = find.bySemanticsLabel(RegExp('^Pen color'));
    expect(colors, findsWidgets);
    expect({for (final e in colors.evaluate()) tester.getCenter(find.byWidget(e.widget)).dx}, {add.center.dx}, reason: 'the colors stay with the button that adds one');

    await tester.tap(find.text('Document').first);
    await tester.pumpAndSettle();
    double left(String key) => tester.getCenter(find.byKey(ValueKey(key))).dx;
    expect(left('doc-align-justify'), left('doc-align-left'), reason: 'the paragraph tools stay together');
    expect(left('doc-spacing'), left('doc-align-left'));
  });
  testWidgets('the drawing tools are as wide as the tools, so the larger touch targets are not squeezed', (tester) async {
    tester.view.physicalSize = const Size(1200, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
    });
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: const Size(52, 52)))),
      home: FixedPageNoteEditor(noteId: id, repository: repo),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('undo-button'))).width, greaterThanOrEqualTo(52));
    await tester.tap(find.text('Document').first);
    await tester.pumpAndSettle();
  });
  testWidgets('the menus and the word count take a line across the document bar, the columns only hold icons', (tester) async {
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final height in const [1300.0, 700.0]) {
      tester.view.physicalSize = Size(1200, height);
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Document').first);
      await tester.pumpAndSettle();
      final bar = tester.getRect(find.byType(DocumentToolbar));
      expect(tester.getSize(find.byKey(const ValueKey('doc-style'))).width, bar.width, reason: 'at a height of $height');
      expect(tester.getSize(find.byKey(const ValueKey('doc-font'))).width, bar.width);
      final bold = tester.getRect(find.byTooltip('Bold'));
      expect(bold.top, greaterThan(tester.getRect(find.byKey(const ValueKey('doc-size'))).bottom), reason: 'the columns start under the lines');
      final count = tester.getRect(find.byKey(const ValueKey('doc-word-count')));
      expect(count.bottom, lessThanOrEqualTo(bar.bottom));
      expect(count.bottom, greaterThan(bar.bottom - 40), reason: 'at the foot of the bar');
      if (height > 1000) expect(bar.width, lessThan(100), reason: 'two columns of icons, and the lines no wider');
      await tester.tap(find.byKey(const ValueKey('doc-style')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('doc-style-heading1')), findsOneWidget, reason: 'the line is a working menu');
      await tester.tap(find.byKey(const ValueKey('doc-style-heading1')));
      await tester.pumpAndSettle();
    }
  });
  testWidgets('the page moves aside by degrees when a bar comes, and back when it goes, without being laid out again', (tester) async {
    tester.view.physicalSize = const Size(1200, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    final page = find.byKey(const ValueKey('page-0'));
    final before = tester.getCenter(page).dx;
    final wide = tester.getSize(find.byType(CustomScrollView).first).width;
    await tester.tap(find.text('Draw'));
    await tester.pump(); // (the slide starts when this frame is done)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final partway = tester.getCenter(page).dx;
    final during = tester.getSize(find.byType(CustomScrollView).first).width;
    await tester.pumpAndSettle();
    final after = tester.getCenter(page).dx;
    expect(after, lessThan(before - 20), reason: 'the bar takes room, so the page ends up further left');
    expect(partway, lessThan(before), reason: 'the page has begun to move');
    expect(partway, greaterThan(after), reason: 'but has not got there yet');
    expect(during, lessThan(wide), reason: 'the pages are laid out at the size they end up with at once');
    expect(tester.getSize(find.byType(CustomScrollView).first).width, during, reason: 'and not again while the bar slides');
    // the bar is all there once it has come
    expect(tester.getRect(find.byKey(const ValueKey('undo-button'))).right, lessThanOrEqualTo(1200));
    await tester.tap(find.text('Select'));
    await tester.pump(); // (the slide starts when this frame is done)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(const ValueKey('undo-button')), findsOneWidget, reason: 'the bar slides out, it does not vanish');
    expect(tester.getCenter(page).dx, inExclusiveRange(after, before));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('undo-button')), findsNothing);
    expect(tester.getCenter(page).dx, before);
    expect(tester.getSize(find.byType(CustomScrollView).first).width, wide);
  });
  testWidgets('a panel beside the page slides in and out too, and the page moves aside by degrees', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late NoteHistory history;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('side_panel_');
      Directory('${dir.path}/support').createSync();
      final db = await AppDatabase.open(path: '${dir.path}/n.db');
      repo = NoteRepository(db);
      history = NoteHistory(db, repo, supportDirectory: () async => Directory('${dir.path}/support'));
      id = await repo.createNote();
    });
    addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo, history: history)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 1));
    final page = find.byKey(const ValueKey('page-0'));
    final before = tester.getCenter(page).dx;
    final wide = tester.getSize(find.byType(CustomScrollView).first).width;
    await tester.ensureVisible(find.byKey(const ValueKey('history-button')));
    await tester.tap(find.byKey(const ValueKey('history-button')));
    await tester.pump(); // (the slide starts when this frame is done)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final partway = tester.getCenter(page).dx;
    final during = tester.getSize(find.byType(CustomScrollView).first).width;
    await tester.pump(const Duration(seconds: 1));
    final after = tester.getCenter(page).dx;
    expect(find.byKey(const ValueKey('history-panel')), findsOneWidget);
    expect(after, lessThan(before - 50), reason: 'the panel takes room, so the page ends up further left');
    expect(partway, inExclusiveRange(after, before), reason: 'the page has begun to move, and has not got there');
    expect(during, lessThan(wide), reason: 'laid out at the size it ends up with at once');
    expect(tester.getSize(find.byType(CustomScrollView).first).width, during, reason: 'and not again while the panel slides');
    expect(tester.getRect(find.byKey(const ValueKey('history-panel'))).right, lessThanOrEqualTo(1600));

    await tester.tap(find.byKey(const ValueKey('history-button')));
    await tester.pump(); // (the slide starts when this frame is done)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(const ValueKey('history-panel')), findsOneWidget, reason: 'the panel slides out, it does not vanish');
    expect(tester.getCenter(page).dx, inExclusiveRange(after, before));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('history-panel')), findsNothing);
    expect(tester.getCenter(page).dx, before);
    // (the panel has asked the database for the versions, whose guard timer has to be let go)
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
  });
  testWidgets('from Draw to Document the page eases to its place, down as well as sideways (the ruler comes above it)', (tester) async {
    tester.view.physicalSize = const Size(1200, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    final page = find.byKey(const ValueKey('page-0'));
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    final from = tester.getTopLeft(page);
    await tester.tap(find.text('Document').first);
    await tester.pump(); // (the slide starts when this frame is done)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final partway = tester.getTopLeft(page);
    await tester.pumpAndSettle();
    final to = tester.getTopLeft(page);
    expect(to.dy, greaterThan(from.dy + 10), reason: 'the ruler takes room above the page');
    expect(partway.dy, inExclusiveRange(from.dy, to.dy), reason: 'the page does not drop at once');
    expect(partway.dx, inExclusiveRange(to.dx, from.dx));
  });
  testWidgets('in a window narrower than the page, the page grows and shrinks with the room a bar leaves it, not at once', (tester) async {
    tester.view.physicalSize = const Size(700, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    final page = find.byKey(const ValueKey('page-0'));
    final alone = tester.getRect(page).width;
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    final withDraw = tester.getRect(page).width;
    expect(withDraw, lessThan(alone - 20), reason: 'the page is fitted to the room, which the bar has taken');
    await tester.tap(find.text('Document').first);
    await tester.pump();
    final first = tester.getRect(page).width;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final partway = tester.getRect(page).width;
    await tester.pumpAndSettle();
    final withDocument = tester.getRect(page).width;
    expect(first, closeTo(withDraw, 1), reason: 'it starts at the size it had');
    expect(withDocument, isNot(closeTo(withDraw, 1)));
    final low = withDraw < withDocument ? withDraw : withDocument, high = withDraw < withDocument ? withDocument : withDraw;
    expect(partway, inExclusiveRange(low, high), reason: 'and is on its way at the size between');
    expect(tester.getRect(page).width, withDocument);

    // a bar that comes while the page is on the screen alone: the page shrinks from its full width
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(tester.getRect(page).width, alone);
    await tester.tap(find.text('Draw'));
    await tester.pump(); // (the slide starts when this frame is done)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getRect(page).width, inExclusiveRange(withDraw, alone));
    await tester.pumpAndSettle();
    expect(tester.getRect(page).width, withDraw);
  });
  testWidgets('opening document mode does not scroll the page to where the caret was left', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      await repo.saveNote((await repo.loadNote(id))!..documentText = [for (var i = 0; i < 150; i++) 'Paragraph $i of the long document, with some words in it.\n'].join('\n'));
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    final scroll = find.descendant(of: find.byType(CustomScrollView).first, matching: find.byType(Scrollable)).first;
    await tester.tap(find.text('Document').first);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.state<ScrollableState>(scroll).position.pixels, 0, reason: 'the page stays at the top');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('what is under a bar that has come is reached through it, and the buttons of the bar work', (tester) async {
    tester.view.physicalSize = const Size(1200, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('brush-picker')).first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brush-pen')), findsOneWidget, reason: 'the bar takes taps where it is drawn');
    await tester.tap(find.byKey(const ValueKey('brush-pen')));
    await tester.pumpAndSettle();
  });
  testWidgets('a group higher than the bar is broken, so that all of it can be reached', (tester) async {
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          height: 100,
          child: ToolColumns(children: [for (var i = 0; i < 5; i++) SizedBox(key: ValueKey(i), width: 40, height: 40)]),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(find.byKey(const ValueKey(4))).dx, 80, reason: 'two to a column, so the fifth is in the third');
  });
  testWidgets('the document bar and the drawing tools fill the height beside the page', (tester) async {
    tester.view.physicalSize = const Size(1200, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Document').first);
    await tester.pumpAndSettle();
    // the tools stand in a column that is as high as the page area (the thin line beside it is that high)
    Rect line() => [for (final e in find.byType(VerticalDivider).evaluate()) tester.getRect(find.byElementPredicate((x) => identical(x, e)))]
        .firstWhere((r) => r.width == 1);
    expect(tester.getRect(find.byType(DocumentToolbar)).height, line().height, reason: 'the document bar fills the height');
    expect(tester.getRect(find.byType(DocumentToolbar)).top, line().top);

    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    final bar = find.ancestor(of: find.byKey(const ValueKey('undo-button')), matching: find.byType(Container)).last;
    expect(tester.getRect(bar).height, line().height, reason: 'the drawing tools fill the height');
    expect(tester.getRect(bar).top, line().top);
  });
}
