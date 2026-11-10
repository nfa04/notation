import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/trash_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('a trashed note leaves the lists, comes back, and is purged after its time', () async {
    final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
    final a = await repo.createNote(title: 'A');
    final b = await repo.createNote(title: 'B');
    await repo.trashNote(a);
    expect((await repo.listNotes()).map((n) => n.id), [b]);
    expect((await repo.listTrash()).single.id, a);
    await repo.restoreNote(a);
    expect(await repo.listTrash(), isEmpty);
    await repo.trashNote(a);
    expect(await repo.purgeTrash(), 0); // too recent
    expect(await repo.purgeTrash(keep: Duration.zero), 1);
    expect(await repo.loadNote(a), isNull);
    expect(await repo.loadNote(b), isNotNull);
  });

  testWidgets('the trash view restores and empties', (tester) async {
    late NoteRepository repo;
    late String a;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      a = await repo.createNote(title: 'Gone note');
      await repo.trashNote(a);
    });
    await tester.pumpWidget(MaterialApp(home: TrashView(repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.text('Gone note'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(ValueKey('restore-$a')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(find.text('Gone note'), findsNothing);
    expect((await tester.runAsync(repo.listNotes))!.map((n) => n.id), contains(a));
  });
}
