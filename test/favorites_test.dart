import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/dashboard_view.dart';
import 'package:notes/screens/folder_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('a starred note is in the favourites, on the dashboard and in the folders, and keeps its star', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String a, b;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      a = await repo.createNote(title: 'Alpha');
      b = await repo.createNote(title: 'Beta');
    });
    expect((await tester.runAsync(() => repo.listNotes()))!.where((n) => n.favorite), isEmpty);

    await tester.pumpWidget(MaterialApp(home: DashboardView(repository: repo, onOpenNote: (_) {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.text('Favourites'), findsNothing);
    await tester.tap(find.byKey(ValueKey('star-$a')));
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
    }
    expect(find.text('Favourites'), findsOneWidget);
    expect((await tester.runAsync(() => repo.isFavorite(a)))!, isTrue);
    expect((await tester.runAsync(() => repo.isFavorite(b)))!, isFalse);

    // a star does not count as an edit, and an edit does not take it away
    final n = (await tester.runAsync(() => repo.loadNote(a)))!;
    await tester.runAsync(() => repo.saveNote(n));
    expect((await tester.runAsync(() => repo.isFavorite(a)))!, isTrue);

    await tester.pumpWidget(MaterialApp(home: FolderView(repository: repo, onOpenNote: (_) {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.tap(find.text('Favourites'));
    await tester.pump();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
    await tester.tap(find.byKey(ValueKey('star-$a')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect((await tester.runAsync(() => repo.isFavorite(a)))!, isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
