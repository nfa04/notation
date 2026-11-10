import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/folder_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('create folder, new note inside, move it out', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    String? opened;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
    });
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(MaterialApp(
      home: FolderView(repository: repo, onOpenNote: (id) => opened = id),
    ));
    await settle();
    expect(find.text('No folders yet. Use the button at the top to create one.'), findsOneWidget);

    // new folder
    await tester.tap(find.byTooltip('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Uni');
    await tester.tap(find.text('OK'));
    await settle();
    expect(find.text('Uni'), findsWidgets); // tree row and the heading
    expect(find.text('This folder has no notes yet.'), findsOneWidget);

    // new note in it
    await tester.tap(find.text('New note here'));
    await settle();
    expect(opened, isNotNull);
    final notes = await tester.runAsync(() => repo.listNotes());
    expect(notes!.single.folderId, isNotNull);

    // back on the screen: move it out
    await tester.pumpWidget(MaterialApp(
      home: FolderView(key: UniqueKey(), repository: repo, onOpenNote: (id) => opened = id),
    ));
    await settle();
    await tester.tap(find.widgetWithText(ListTile, 'All notes'));
    await settle();
    await tester.tap(find.byTooltip('Note actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to...'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No folder (top level)'));
    await settle();
    final after = await tester.runAsync(() => repo.listNotes());
    expect(after!.single.folderId, isNull);
  });

  testWidgets('drag and drop', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String a, b, note;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      // the in-memory database is shared with the test above
      for (final f in await repo.listFolders()) {
        await repo.deleteFolder(f.id);
      }
      for (final n in await repo.listNotes()) {
        await repo.deleteNote(n.id);
      }
      a = await repo.createFolder('Alpha');
      b = await repo.createFolder('Beta');
      note = await repo.createNote(title: 'My note');
    });
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }

    Future<void> dragTo(Finder from, Finder to) async {
      final g = await tester.startGesture(tester.getCenter(from));
      await tester.pump(const Duration(milliseconds: 50));
      await g.moveTo(tester.getCenter(from) + const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 50));
      await g.moveTo(tester.getCenter(to));
      await tester.pump(const Duration(milliseconds: 50));
      await g.up();
      await settle();
    }

    await tester.pumpWidget(MaterialApp(home: FolderView(repository: repo, onOpenNote: (_) {})));
    await settle();

    // note -> folder Alpha
    await dragTo(find.text('My note'), find.widgetWithText(ListTile, 'Alpha'));
    var notes = (await tester.runAsync(() => repo.listNotes()))!;
    expect(notes.firstWhere((n) => n.id == note).folderId, a);

    // folder Beta -> folder Alpha
    await dragTo(find.widgetWithText(ListTile, 'Beta'), find.widgetWithText(ListTile, 'Alpha'));
    var folders = (await tester.runAsync(() => repo.listFolders()))!;
    expect(folders.firstWhere((f) => f.id == b).parentId, a);

    // folder Alpha -> its own child Beta is refused (Alpha is expanded after the drop)
    await dragTo(find.widgetWithText(ListTile, 'Alpha'), find.widgetWithText(ListTile, 'Beta'));
    folders = (await tester.runAsync(() => repo.listFolders()))!;
    expect(folders.firstWhere((f) => f.id == a).parentId, isNull);

    // note -> "No folder"
    await tester.tap(find.widgetWithText(ListTile, 'Alpha'));
    await settle();
    await dragTo(find.text('My note'), find.widgetWithText(ListTile, 'No folder'));
    notes = (await tester.runAsync(() => repo.listNotes()))!;
    expect(notes.firstWhere((n) => n.id == note).folderId, isNull);
  });

  testWidgets('the notes can be put in order, and the order is kept', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      await repo.settings.remove('notes_sort');
      await repo.settings.remove('notes_starred_first');
      await repo.createNote(title: 'Zz sort first');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await repo.createNote(title: 'Aa sort second');
    });
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pumpAndSettle();
    }

    double top(String title) => tester.getTopLeft(find.text(title)).dy;
    await tester.pumpWidget(MaterialApp(home: FolderView(repository: repo, onOpenNote: (_) {})));
    await settle();
    expect(top('Aa sort second'), lessThan(top('Zz sort first'))); // the one changed last first

    await tester.tap(find.byKey(const ValueKey('folder-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('folder-sort-titleDescending')));
    await settle();
    expect(top('Zz sort first'), lessThan(top('Aa sort second')));

    // a new screen starts with the order that was chosen
    await tester.pumpWidget(MaterialApp(home: FolderView(key: UniqueKey(), repository: repo, onOpenNote: (_) {})));
    await settle();
    await settle(); // (the order is read once the notes are)
    expect(top('Zz sort first'), lessThan(top('Aa sort second')));
    await tester.pumpWidget(const SizedBox());
  });
}
