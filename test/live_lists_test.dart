import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/debounced_changes.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/screens/calendar_view.dart';
import 'package:notes/screens/dashboard_view.dart';
import 'package:notes/screens/folder_view.dart';
import 'package:notes/screens/trash_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The lists of notes, folders, trash and tasks look again on their own when something changes behind their back (an agent over MCP, a
/// sync): they listen to the repositories' streams through [debouncedChanges].
void main() {
  setUpAll(AppDatabase.initFfi);

  group('debouncedChanges', () {
    const wait = Duration(milliseconds: 40);

    test('a burst of events on any source is one event, after the last of them', () async {
      final a = StreamController<void>.broadcast(), b = StreamController<int>.broadcast();
      final fired = <int>[];
      final sub = debouncedChanges([a.stream, b.stream, null], wait: wait).listen((_) => fired.add(DateTime.now().millisecondsSinceEpoch));
      final start = DateTime.now().millisecondsSinceEpoch;
      a.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      b.add(1);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      a.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(fired, isEmpty, reason: 'still within the wait of the last event');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(fired, hasLength(1));
      // (the last event was about 30 ms in, the wait 40: well after the first event's own wait of 40, which would have been over at 40)
      expect(fired.single - start, greaterThanOrEqualTo(60), reason: 'after the last event, not the first');
      b.add(2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fired, hasLength(2));
      await sub.cancel();
      await a.close();
      await b.close();
    });

    test('nothing is listened to until it is, and nothing after it is cancelled', () async {
      final source = StreamController<void>.broadcast();
      final stream = debouncedChanges([source.stream], wait: wait);
      expect(source.hasListener, isFalse);
      final fired = <void>[];
      final sub = stream.listen(fired.add);
      expect(source.hasListener, isTrue);
      source.add(null);
      await sub.cancel(); // before the wait is over
      expect(source.hasListener, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fired, isEmpty);
      await source.close();
    });
  });

  /// Lets the change reach the screen's listener (a microtask in the fake zone), the wait pass, and the screen load again (real IO).
  Future<void> reaction(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
  }

  Future<NoteRepository> open(WidgetTester tester) async {
    late NoteRepository repo;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['notes', 'folders', 'tasks', 'note_tags']) {
        await db.delete(t);
      }
      repo = NoteRepository(db);
    });
    return repo;
  }

  testWidgets('the dashboard shows a note that is made, renamed and put in the trash by someone else, without being touched', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await open(tester);
    await tester.pumpWidget(MaterialApp(home: DashboardView(repository: repo, onOpenNote: (_) {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.text('From the agent'), findsNothing);

    late String id;
    await tester.runAsync(() async => id = await repo.createNote(title: 'From the agent'));
    await reaction(tester);
    expect(find.text('From the agent'), findsOneWidget, reason: 'a note that was made');

    await tester.runAsync(() => repo.renameNote(id, 'Renamed by the agent'));
    await reaction(tester);
    expect(find.text('Renamed by the agent'), findsOneWidget);
    expect(find.text('From the agent'), findsNothing);

    await tester.runAsync(() => repo.trashNote(id));
    await reaction(tester);
    expect(find.text('Renamed by the agent'), findsNothing, reason: 'a note that was put in the trash');
    await tester.pumpWidget(const SizedBox()); // (the screen goes: its listener goes with it)
  });

  testWidgets('the folder view shows a folder and a note that are made behind its back', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await open(tester);
    await tester.pumpWidget(MaterialApp(home: FolderView(repository: repo, onOpenNote: (_) {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.text('No folders yet. Use the button at the top to create one.'), findsOneWidget);

    await tester.runAsync(() async {
      final folder = await repo.createFolder('Agent folder');
      await repo.createNote(title: 'Agent note', folderId: folder);
    });
    await reaction(tester);
    expect(find.text('No folders yet. Use the button at the top to create one.'), findsNothing);
    expect(find.text('Agent folder'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the trash shows a note that is put there behind its back, and drops one that is brought back', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = await open(tester);
    late String id;
    await tester.runAsync(() async => id = await repo.createNote(title: 'Soon gone'));
    await tester.pumpWidget(MaterialApp(home: TrashView(repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.text('Soon gone'), findsNothing);

    await tester.runAsync(() => repo.trashNote(id));
    await reaction(tester);
    expect(find.text('Soon gone'), findsOneWidget);

    await tester.runAsync(() => repo.restoreNote(id));
    await reaction(tester);
    expect(find.text('Soon gone'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the calendar shows a task that is added and one that is ticked off behind its back', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late TaskRepository tasks;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('tasks');
      tasks = TaskRepository(db);
    });
    await tester.pumpWidget(MaterialApp(home: CalendarView(repository: tasks)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.text('Nothing planned.'), findsOneWidget);

    late String id;
    await tester.runAsync(() async => id = await tasks.createTask('Agent task', dueDate: DateTime.now()));
    await reaction(tester);
    expect(find.text('Agent task'), findsWidgets);
    expect(find.text('Nothing planned.'), findsNothing);

    await tester.runAsync(() => tasks.setDone(id, true));
    await reaction(tester);
    expect(tester.widget<Checkbox>(find.byType(Checkbox).first).value, isTrue, reason: 'ticked off');
    await tester.pumpWidget(const SizedBox());
  });
}
