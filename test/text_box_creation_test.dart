import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late String id;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  /// How many new boxes are on the page.
  int boxes(WidgetTester tester) => find.text('Type text...').evaluate().length;

  Future<void> clicks(WidgetTester tester, Offset at, int n, {PointerDeviceKind kind = PointerDeviceKind.mouse, int gap = 80}) async {
    for (var i = 0; i < n; i++) {
      final g = await tester.startGesture(at, kind: kind, buttons: kind == PointerDeviceKind.mouse ? kPrimaryMouseButton : 0);
      await g.up();
      // (the clicks are timed by the clock, which the test's pumping does not move)
      await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: gap)));
      await tester.pump(Duration(milliseconds: gap));
    }
  }

  testWidgets('with a mouse it takes three clicks to make a text box, two do nothing', (tester) async {
    await open(tester);
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await clicks(tester, origin + const Offset(300, 300), 2);
    await tester.pumpAndSettle();
    expect(boxes(tester), 0);
    await clicks(tester, origin + const Offset(300, 300), 3);
    await tester.pumpAndSettle();
    expect(boxes(tester), 1);

    // three clicks that are far apart, or slow, are not a triple click (and the first box, still empty, goes when it is left)
    await clicks(tester, origin + const Offset(500, 600), 1);
    await clicks(tester, origin + const Offset(600, 650), 1);
    await clicks(tester, origin + const Offset(500, 600), 1);
    await tester.pumpAndSettle();
    expect(boxes(tester), 0);
    await clicks(tester, origin + const Offset(500, 700), 3, gap: 700);
    await tester.pumpAndSettle();
    expect(boxes(tester), 0);
  });

  testWidgets('in draw mode too, and without leaving lines behind', (tester) async {
    await open(tester);
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await clicks(tester, origin + const Offset(300, 300), 3);
    await tester.pumpAndSettle();
    expect(boxes(tester), 1);
  });

  testWidgets('touch keeps the double tap', (tester) async {
    await open(tester);
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await tester.tapAt(origin + const Offset(300, 300));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(origin + const Offset(300, 300));
    await tester.pumpAndSettle();
    expect(boxes(tester), 1);
  });

  testWidgets('the top bar has a button that makes a text box on the page on screen', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('add-text-box')), findsOneWidget);
    final button = tester.widget<IconButton>(find.byKey(const ValueKey('add-text-box')));
    expect(button.tooltip, startsWith('Add a text box (or '));
    await tester.tap(find.byKey(const ValueKey('add-text-box')));
    await tester.pumpAndSettle();
    expect(boxes(tester), 1);
    // it is selected, ready to type in
    expect(find.byKey(const ValueKey('delete-text-box')), findsOneWidget);
  });
}
