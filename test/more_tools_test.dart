import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('the rarely used tools are behind a button, and it is remembered whether they were opened', (tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
    });
    Future<void> open() async {
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: UniqueKey(), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
    }

    await open();
    expect(find.byKey(const ValueKey('more-tools')), findsOneWidget);
    for (final k in ['symmetry-picker', 'stabiliser-picker', 'straighten-toggle', 'clear-page']) {
      expect(find.byKey(ValueKey(k)), findsNothing, reason: '$k is folded away');
    }
    expect(find.byKey(const ValueKey('eyedropper-button')), findsOneWidget, reason: 'the colour tools stay');
    await tester.tap(find.byKey(const ValueKey('more-tools')));
    await tester.pumpAndSettle();
    for (final k in ['symmetry-picker', 'stabiliser-picker', 'straighten-toggle', 'clear-page']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: '$k is there');
    }
    await open(); // (a new editor: still open)
    expect(find.byKey(const ValueKey('symmetry-picker')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('more-tools')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('symmetry-picker')), findsNothing);
  });
}
