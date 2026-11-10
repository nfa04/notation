import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('the colour wheel offers harmony palettes that can be added to the bar', (tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      await repo.settings.setPenColors([const Color(0xFFFF0000)]);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: UniqueKey(), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();

    await tester.tap(find.byWidgetPredicate((w) => w is CircleAvatar && w.backgroundColor == const Color(0xFFFF0000)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('harmony-triadic')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('harmony-keep')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    final saved = await tester.runAsync(() => repo.settings.penColors());
    expect(saved!, containsAll([const Color(0xFF00FF00), const Color(0xFF0000FF)]), reason: 'the new colours of the palette joined the bar');
  });
}
