import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/dashboard_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('a library of many notes makes only the cards in view, and the others as they are scrolled to', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      for (final n in await repo.listNotes()) {
        await repo.deleteNote(n.id);
      }
      for (var i = 0; i < 400; i++) {
        await repo.createNote(title: 'Note $i');
      }
    });
    await tester.pumpWidget(MaterialApp(home: DashboardView(repository: repo, onOpenNote: (_) {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(find.byType(Card).evaluate().length, lessThan(60));

    await tester.fling(find.byType(CustomScrollView), const Offset(0, -6000), 3000);
    await tester.pumpAndSettle();
    expect(find.byType(Card), findsWidgets);
    expect(find.byType(Card).evaluate().length, lessThan(60));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async { // (the tests of a file share this database)
      for (final n in await repo.listNotes()) {
        await repo.deleteNote(n.id);
      }
    });
  });

  testWidgets('a note can be deleted from the dashboard', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      await repo.createNote(title: 'Keep me');
      await repo.createNote(title: 'Delete me');
    });
    await tester.pumpWidget(MaterialApp(home: DashboardView(repository: repo, onOpenNote: (_) {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.text('Delete me'), findsOneWidget);

    // the menu of that note's card
    final card = find.ancestor(of: find.text('Delete me'), matching: find.byType(Card));
    await tester.tap(find.descendant(of: card, matching: find.byTooltip('More')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Move note to the trash?'), findsOneWidget); // asks first
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();

    expect(find.text('Delete me'), findsNothing);
    expect(find.text('Keep me'), findsOneWidget);
    expect((await tester.runAsync(repo.listNotes))!.map((n) => n.title), ['Keep me']);
    expect((await tester.runAsync(repo.listTrash))!.map((n) => n.title), ['Delete me']); // not gone: in the trash
  });

  testWidgets('a right click or a long press on a card opens the menu with Delete', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      await repo.createNote(title: 'Only one');
    });
    await tester.pumpWidget(MaterialApp(home: DashboardView(repository: repo, onOpenNote: (_) {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Only one'));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Move note to the trash?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Only one'), findsOneWidget); // asked first, and nothing was lost
  });
}
