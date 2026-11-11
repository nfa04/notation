import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/style/stylus_settings.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('two fingers scroll the pages in draw mode, where one finger writes, and leave no line behind', (tester) async {
    tester.view.physicalSize = const Size(1600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
    });
    final stylus = StylusSettings.inMemory();
    await stylus.setFingers(FingerMode.draw);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, stylus: stylus)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));

    double offset() => tester.state<ScrollableState>(find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first).position.pixels;
    final before = offset();

    final a = await tester.startGesture(const Offset(700, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(900, 400), pointer: 2);
    for (var i = 1; i <= 6; i++) {
      await a.moveTo(Offset(700, 400 - i * 30.0));
      await b.moveTo(Offset(900, 400 - i * 30.0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(offset(), closeTo(before + 180, 1)); // the pages followed the fingers up

    // one finger still writes
    final w = await tester.startGesture(const Offset(700, 300), pointer: 3);
    for (var i = 1; i <= 5; i++) {
      await w.moveTo(Offset(700 + i * 20.0, 300));
      await tester.pump();
    }
    await w.up();
    await tester.pump(const Duration(seconds: 1));

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    final saved = await tester.runAsync(() => repo.loadNote(id));
    expect(saved!.strokes.values.expand((s) => s).length, 1);
  });
}
