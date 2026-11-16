import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/graph/graph_model.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/main.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('two notes can be open side by side, and the second can be closed again', (tester) async {
    tester.view.physicalSize = const Size(1900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late TaskRepository tasks;
    late CalDavService caldav;
    late DeviceCalendarService device;
    late String a, b;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key = 'rail_hidden'");
      repo = NoteRepository(db);
      tasks = TaskRepository(db);
      caldav = CalDavService(SettingsRepository(db), tasks);
      device = DeviceCalendarService.forPlatform(SettingsRepository(db));
      a = await repo.createNote(title: 'Alpha split');
      b = await repo.createNote(title: 'Beta split');
    });
    await tester.pumpWidget(NotationApp(services: AppServices(
      repository: repo,
      tasks: tasks,
      caldav: caldav,
      device: device,
      style: StyleService.inMemory(),
      appTheme: AppTheme.inMemory(),
    )));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Alpha split').first);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(FixedPageNoteEditor), findsOneWidget);
    expect(find.byKey(ValueKey('close-split-$a')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('open-beside')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('pick-note-$a')), findsNothing); // (not the one that is open)
    await tester.enterText(find.byKey(const ValueKey('note-picker-search')), 'beta');
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('pick-note-$b')));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(FixedPageNoteEditor), findsNWidgets(2));
    expect(find.byKey(const ValueKey('split-divider')), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Beta split'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Alpha split'), findsOneWidget);

    // either of the two can be closed
    expect(find.byKey(ValueKey('close-split-$a')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('close-split-$a')));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(FixedPageNoteEditor), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Beta split'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Alpha split'), findsNothing);
    expect(find.byKey(const ValueKey('split-divider')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });

  testWidgets('notes open as tabs, one at a time or all side by side, and a tab can be closed', (tester) async {
    tester.view.physicalSize = const Size(1900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late TaskRepository tasks;
    late CalDavService caldav;
    late DeviceCalendarService device;
    late String a, b;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key = 'rail_hidden'");
      await db.delete('notes');
      repo = NoteRepository(db);
      tasks = TaskRepository(db);
      caldav = CalDavService(SettingsRepository(db), tasks);
      device = DeviceCalendarService.forPlatform(SettingsRepository(db));
      a = await repo.createNote(title: 'Alpha tab');
      b = await repo.createNote(title: 'Beta tab');
    });
    await tester.pumpWidget(NotationApp(services: AppServices(
      repository: repo,
      tasks: tasks,
      caldav: caldav,
      device: device,
      style: StyleService.inMemory(),
      appTheme: AppTheme.inMemory(),
    )));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    Future<void> settle([int n = 6]) async {
      for (var i = 0; i < n; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.text('Alpha tab').first);
    await settle();
    expect(find.byKey(ValueKey('tab-$a')), findsOneWidget);
    expect(find.byType(FixedPageNoteEditor), findsOneWidget);

    // "+" opens another note in a tab of its own: it takes the place of the first on screen
    await tester.tap(find.byKey(const ValueKey('tab-new')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('pick-note-$b')));
    await settle();
    expect(find.byKey(ValueKey('tab-$a')), findsOneWidget);
    expect(find.byKey(ValueKey('tab-$b')), findsOneWidget);
    expect(find.byType(FixedPageNoteEditor), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Beta tab'), findsOneWidget);

    // all tabs next to each other
    await tester.tap(find.byKey(const ValueKey('tab-all')));
    await settle();
    expect(find.byType(FixedPageNoteEditor), findsNWidgets(2));
    expect(find.widgetWithText(TextField, 'Alpha tab'), findsOneWidget);

    // both sides have all the tabs; a click on a tab in the right pane shows it there (the two swap places)
    // (three panes: the dashboard tab stays open)
    expect(find.byKey(ValueKey('tab-$a')), findsNWidgets(3));
    expect(find.byKey(ValueKey('tab-$b')), findsNWidgets(3));
    final before = tester.getTopLeft(find.widgetWithText(TextField, 'Alpha tab')).dx;
    await tester.tap(find.byKey(ValueKey('tab-$a')).last);
    await settle();
    expect(find.byType(FixedPageNoteEditor), findsNWidgets(2));
    expect(tester.getTopLeft(find.widgetWithText(TextField, 'Alpha tab')).dx, isNot(before));

    await tester.tap(find.byKey(const ValueKey('tab-close-page:0')).first); // (the dashboard's tab first, there is room for two only then)
    await settle();
    await tester.tap(find.byKey(ValueKey('tab-close-$b')).first);
    await settle();
    expect(find.byType(FixedPageNoteEditor), findsOneWidget);
    expect(find.byKey(ValueKey('tab-$b')), findsNothing);
    expect(find.widgetWithText(TextField, 'Alpha tab'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });

  testWidgets('a graph tab holds one graph, and sits beside a note', (tester) async {
    tester.view.physicalSize = const Size(1900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late TaskRepository tasks;
    late CalDavService caldav;
    late DeviceCalendarService device;
    late String a;
    late int g2;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key = 'rail_hidden'");
      await db.delete('notes');
      await db.delete('saved_graphs');
      repo = NoteRepository(db);
      tasks = TaskRepository(db);
      caldav = CalDavService(SettingsRepository(db), tasks);
      device = DeviceCalendarService.forPlatform(SettingsRepository(db));
      a = await repo.createNote(title: 'Alpha graph');
      final payload = KnowledgeGraph(mode: 'facts', builtAt: DateTime.now(), nodes: [], edges: [], clusters: []).encode();
      await repo.knowledge.saveGraph(name: 'Graph One', mode: 'facts', folderId: null, payload: payload);
      g2 = await repo.knowledge.saveGraph(name: 'Graph Two', mode: 'facts', folderId: null, payload: payload);
    });
    await tester.pumpWidget(NotationApp(services: AppServices(
      repository: repo,
      tasks: tasks,
      caldav: caldav,
      device: device,
      style: StyleService.inMemory(),
      appTheme: AppTheme.inMemory(),
    )));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    Future<void> settle([int n = 6]) async {
      for (var i = 0; i < n; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.text('Alpha graph').first);
    await settle();
    await tester.tap(find.byIcon(Icons.hub_outlined).first); // the menu place of the graph
    await settle(10);
    // one graph in the tab: the last one made; the view has no tabs of graphs of its own
    expect(find.byKey(ValueKey('tab-graph:$g2')), findsOneWidget);
    expect(find.byKey(const ValueKey('graph-tabs')), findsNothing);
    expect(find.byKey(const ValueKey('graph-new')), findsOneWidget); // (a new graph is made from the tab)
    expect(find.byKey(ValueKey('tab-$a')), findsOneWidget);
    expect(find.text('Graph Two'), findsWidgets);
    expect(find.text('Graph One'), findsNothing);

    // beside the note (both sides have all the tabs)
    await tester.tap(find.byKey(const ValueKey('tab-all')));
    await settle();
    expect(find.byType(FixedPageNoteEditor), findsOneWidget);
    expect(find.byKey(ValueKey('tab-graph:$g2')), findsNWidgets(3));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });

  testWidgets('a note that was left stays in memory for a while, and comes back as it was', (tester) async {
    tester.view.physicalSize = const Size(1900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late TaskRepository tasks;
    late CalDavService caldav;
    late DeviceCalendarService device;
    late String a, b;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key = 'rail_hidden'");
      repo = NoteRepository(db);
      tasks = TaskRepository(db);
      caldav = CalDavService(SettingsRepository(db), tasks);
      device = DeviceCalendarService.forPlatform(SettingsRepository(db));
      a = await repo.createNote(title: 'Alpha split');
      b = await repo.createNote(title: 'Beta split');
    });
    await tester.pumpWidget(NotationApp(services: AppServices(
      repository: repo,
      tasks: tasks,
      caldav: caldav,
      device: device,
      style: StyleService.inMemory(),
      appTheme: AppTheme.inMemory(),
    )));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Alpha split').first);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final editor = tester.state(find.byType(FixedPageNoteEditor));
    await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Dashboard')));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(FixedPageNoteEditor), findsNothing, reason: 'out of sight');
    expect(find.byType(FixedPageNoteEditor, skipOffstage: false), findsOneWidget, reason: 'but kept');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.runAsync(() => repo.renameNote(a, 'Renamed elsewhere')); // (another device wrote it meanwhile)
    await tester.tap(find.byKey(ValueKey('tab-$a')).first);
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(FixedPageNoteEditor), findsOneWidget);
    expect(identical(tester.state(find.byType(FixedPageNoteEditor)), editor), isTrue, reason: 'the same editor, not a new one');
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.widgetWithText(TextField, 'Renamed elsewhere'), findsOneWidget, reason: 'what came meanwhile is taken');
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });

}
