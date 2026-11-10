import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DrawingStroke _stroke() => DrawingStroke(
  color: Colors.black,
  width: 3,
  points: [for (var i = 0; i < 20; i++) Offset(100.0 + i * 5, 300.0 + i)],
);

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets(
    'a page can be inserted, moved and deleted, and each is taken back',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late NoteRepository repo;
      late String id;
      await tester.runAsync(() async {
        repo = NoteRepository(
          await AppDatabase.open(path: inMemoryDatabasePath),
        );
        id = await repo.createNote();
        final note = (await repo.loadNote(id))!;
        note.strokes[0] = [_stroke()];
        note.strokes[1] = [_stroke(), _stroke()];
        await repo.saveNote(note);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FixedPageNoteEditor(noteId: id, repository: repo),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();

      Future<Map<int, int>> saved() async {
        await tester.pump(
          const Duration(seconds: 1),
        ); // the note is saved a moment after a change
        return tester
            .runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 300));
              final n = (await repo.loadNote(id))!;
              return {
                for (final e in n.strokes.entries)
                  if (e.value.isNotEmpty) e.key: e.value.length,
              };
            })
            .then((v) => v!);
      }

      Future<void> choose(String item) async {
        await tester.tap(find.byKey(const ValueKey('pages-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(item));
        await tester.pumpAndSettle();
      }

      await choose(
        'Insert a blank page before',
      ); // the page in view is the first one
      expect(await saved(), {1: 1, 2: 2});

      await tester.tap(find.byKey(const ValueKey('undo-any')));
      await tester.pumpAndSettle();
      expect(await saved(), {0: 1, 1: 2});

      await tester.tap(find.byKey(const ValueKey('redo-any')));
      await tester.pumpAndSettle();
      expect(await saved(), {1: 1, 2: 2});

      await choose('Move page down'); // the empty first page swaps with the one below it
      expect(await saved(), {0: 1, 2: 2});

      await choose('Delete page'); // the page in view is the first one again; what is below moves up
      expect(await saved(), {1: 2});
    },
  );
}
