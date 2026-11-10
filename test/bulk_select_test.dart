import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/dashboard_view.dart';
import 'package:notes/screens/folder_view.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  Future<NoteRepository> repoWith(WidgetTester tester, List<String> titles) async {
    late NoteRepository repo;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('bulk_');
      addTearDown(() => dir.delete(recursive: true));
      repo = NoteRepository(await AppDatabase.open(path: '${dir.path}/n.db')); // (a database of its own: the in-memory one is shared)
      for (final t in titles) {
        await repo.createNote(title: t);
      }
    });
    return repo;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(); // (what was just tapped is built, and starts reading)
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
  }

  Future<String> idOf(WidgetTester tester, NoteRepository repo, String title) async => (await tester.runAsync(repo.listNotes))!.firstWhere((n) => n.title == title).id;

  testWidgets('dashboard: several notes are selected, starred, moved to a folder and thrown away together', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await repoWith(tester, ['One', 'Two', 'Three', 'Four']);
    final folder = (await tester.runAsync(() => repo.createFolder('Uni')))!;
    String? opened;
    await tester.pumpWidget(MaterialApp(home: DashboardView(repository: repo, onOpenNote: (id) => opened = id)));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('select-notes')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('selection-count')), findsOneWidget);
    await tester.tap(find.text('One'));
    await tester.tap(find.text('Two'));
    await tester.pumpAndSettle();
    expect(opened, isNull); // a tap selects while selecting
    expect(find.text('2 notes selected'), findsOneWidget);

    // star both
    await tester.tap(find.byKey(const ValueKey('selection-star')));
    await settle(tester);
    var notes = (await tester.runAsync(repo.listNotes))!;
    expect(notes.where((n) => n.favorite).map((n) => n.title).toSet(), {'One', 'Two'});

    // move both to the folder
    await tester.tap(find.byKey(const ValueKey('selection-move')));
    await settle(tester);
    expect(find.text('Move 2 notes to'), findsOneWidget);
    await tester.tap(find.text('Uni'));
    await settle(tester);
    notes = (await tester.runAsync(repo.listNotes))!;
    expect(notes.where((n) => n.folderId == folder).map((n) => n.title).toSet(), {'One', 'Two'});
    expect(find.byKey(const ValueKey('selection-count')), findsNothing); // done: the selection ends

    // select two others with a long press and the menu, and throw them away
    await tester.tap(find.byKey(const ValueKey('select-notes')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Three'));
    await tester.tap(find.text('Four'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('selection-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Move 2 notes to the trash?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bulk-confirm-delete')));
    await settle(tester);
    expect((await tester.runAsync(repo.listNotes))!.map((n) => n.title).toSet(), {'One', 'Two'});
    expect((await tester.runAsync(repo.listTrash))!.map((n) => n.title).toSet(), {'Three', 'Four'});
    expect(find.text('Three'), findsNothing);
  });

  testWidgets('folders: a long press starts selecting, select all, move together, and a selected note drags the others along', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await repoWith(tester, ['Alpha', 'Beta', 'Gamma']);
    final folder = (await tester.runAsync(() => repo.createFolder('Archive')))!;
    await tester.pumpWidget(MaterialApp(home: FolderView(repository: repo, onOpenNote: (_) {})));
    await settle(tester);

    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('1 note selected'), findsOneWidget);
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(find.text('2 notes selected'), findsOneWidget);

    // dragging one of the selected ones onto a folder takes both
    final archive = find.descendant(of: find.byType(ListTile), matching: find.text('Archive')).first;
    final gesture = await tester.startGesture(tester.getCenter(find.text('Alpha')));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(tester.getCenter(find.text('Alpha')) + const Offset(30, 0));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(archive));
    await tester.pump();
    await gesture.up();
    await settle(tester);
    var notes = (await tester.runAsync(repo.listNotes))!;
    expect(notes.where((n) => n.folderId == folder).map((n) => n.title).toSet(), {'Alpha', 'Beta'});
    expect(notes.firstWhere((n) => n.title == 'Gamma').folderId, isNull);

    // select all in "All notes" and move them out again
    await tester.tap(find.byKey(const ValueKey('select-notes')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('selection-all')));
    await tester.pumpAndSettle();
    expect(find.text('3 notes selected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('selection-move')));
    await settle(tester);
    await tester.tap(find.text('No folder (top level)'));
    await settle(tester);
    notes = (await tester.runAsync(repo.listNotes))!;
    expect(notes.every((n) => n.folderId == null), isTrue);
    expect(await idOf(tester, repo, 'Gamma'), isNotEmpty);
  });

  testWidgets('the trash is a place in the folders: thrown-away notes are listed there and can be brought back', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await repoWith(tester, ['Keep', 'Gone']);
    final gone = await idOf(tester, repo, 'Gone');
    await tester.runAsync(() => repo.trashNote(gone));
    await tester.pumpWidget(MaterialApp(home: FolderView(repository: repo, onOpenNote: (_) {})));
    await settle(tester);

    await tester.tap(find.widgetWithText(ListTile, 'Trash'));
    await settle(tester);
    expect(find.byKey(ValueKey('trashed-$gone')), findsOneWidget);
    expect(find.text('New note'), findsNothing); // (nothing is made in the trash)
    await tester.tap(find.byKey(ValueKey('restore-$gone')));
    await settle(tester);
    expect(find.byKey(ValueKey('trashed-$gone')), findsNothing);
    expect((await tester.runAsync(repo.listNotes))!.map((n) => n.title).toSet(), {'Keep', 'Gone'});
  });
}
