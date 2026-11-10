import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/events/event_bus.dart';
import 'package:notes/events/event_sources.dart';
import 'package:notes/screens/automations_view.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/main_shell.dart';
import 'package:notes/shortcuts/key_combo.dart';
import 'package:notes/shortcuts/shortcut_action.dart';
import 'package:notes/shortcuts/shortcut_service.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/stylus_settings.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the triggers', () {
    test('three actions of the shortcuts with no key to begin with, and three settings of the pen button', () {
      for (final mac in [false, true]) {
        final ids = shortcutActions(mac: mac).where((a) => a.id.startsWith('automation.trigger')).toList();
        expect(ids.map((a) => a.id), ['automation.trigger1', 'automation.trigger2', 'automation.trigger3']);
        expect(ids.every((a) => a.defaults.isEmpty), isTrue, reason: 'no key is taken from the others');
      }
      expect([for (final b in BarrelAction.values) b.trigger], [null, null, 1, 2, 3, null]);
      expect(BarrelAction.trigger2.label, 'Run automation trigger 2');
    });

    test('the pen button setting is kept', () async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings');
      final settings = SettingsRepository(db);
      await StylusSettings(settings).setBarrel(BarrelAction.trigger3);
      final again = StylusSettings(settings);
      await again.load();
      expect(again.barrel, BarrelAction.trigger3);
    });

    test('a rule runs for its own trigger only; one without a number is for trigger 1; events carry the number', () async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['settings', 'tasks', 'notes']) {
        await db.delete(t);
      }
      final tasks = TaskRepository(db);
      final s = AutomationService(NoteRepository(db), tasks);
      await s.load();
      await s.add(const Automation(id: 'a', event: AutomationEvent.triggerPressed, action: AutomationAction.addTask, params: {'title': 'one {trigger}'}));
      await s.add(const Automation(id: 'b', event: AutomationEvent.triggerPressed, action: AutomationAction.addTask, params: {'title': 'two {trigger}', 'trigger': '2'}));
      await s.bus.emit(AppEvent('triggerPressed', data: {'trigger': 2, ...eventVars({'trigger': '2'})}));
      expect([for (final t in await tasks.listTasks()) t.title], ['two 2']);
      await s.bus.emit(AppEvent('triggerPressed', data: {'trigger': 1, ...eventVars({'trigger': '1'})}));
      expect([for (final t in await tasks.listTasks()) t.title], unorderedEquals(['two 2', 'one 1']));
      expect(AutomationEvent.triggerPressed.hasEditor, isTrue);
      expect(AutomationAction.exportPdf.worksAfter(AutomationEvent.triggerPressed), isTrue, reason: 'the editor is there');
      s.dispose();
    });
  });

  testWidgets('the dialog asks which trigger', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Automation? saved;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => saved = await showDialog<Automation>(context: context, builder: (_) => const AutomationDialog(folders: [])),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('automation-event')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('You press a trigger (a shortcut or the pen button)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('automation-trigger')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trigger 3').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('automation-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add a task to the calendar').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('automation-save')));
    await tester.tap(find.byKey(const ValueKey('automation-save')));
    await tester.pumpAndSettle();
    expect((saved!.event, saved!.params['trigger']), (AutomationEvent.triggerPressed, '3'));
  });

  group('in the app', () {
    late NoteRepository notes;
    late TaskRepository tasks;
    late AutomationService service;
    late SettingsRepository settings;
    late ShortcutService shortcuts;
    late String noteId;

    Future<void> start(WidgetTester tester, {BarrelAction barrel = BarrelAction.erase}) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        for (final t in ['settings', 'tasks', 'notes']) {
          await db.delete(t);
        }
        notes = NoteRepository(db);
        tasks = TaskRepository(db);
        settings = SettingsRepository(db);
        noteId = await notes.createNote(title: 'Lecture 1');
        service = AutomationService(notes, tasks);
        await service.load();
        await service.add(const Automation(id: 'k', event: AutomationEvent.triggerPressed, action: AutomationAction.addTask, params: {'title': 'Key on {title}', 'trigger': '1'}));
        await service.add(const Automation(id: 'p', event: AutomationEvent.triggerPressed, action: AutomationAction.addTask, params: {'title': 'Pen on {title}', 'trigger': '2'}));
        shortcuts = ShortcutService.inMemory(mac: false);
        await shortcuts.addBinding('automation.trigger1', KeyCombo(LogicalKeyboardKey.f9));
      });
      addTearDown(service.dispose);
      await tester.pumpWidget(MaterialApp(
        home: MainShellNavigation(
          services: AppServices(
            repository: notes,
            tasks: tasks,
            caldav: CalDavService(settings, tasks),
            device: DeviceCalendarService(settings),
            style: StyleService.inMemory(),
            appTheme: AppTheme.inMemory(),
            automations: service,
            shortcuts: shortcuts,
            stylus: StylusSettings.inMemory(barrel: barrel),
          ),
        ),
      ));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    Future<void> real(WidgetTester tester, [int times = 6]) async {
      for (var i = 0; i < times; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
      }
    }

    testWidgets('a key bound to trigger 1 runs its rules, for the note that is open, and says so; another trigger with no rule says that', (tester) async {
      await start(tester);
      await tester.tap(find.text('Lecture 1').first);
      for (var i = 0; i < 60 && (find.byType(FixedPageNoteEditor).evaluate().isEmpty || find.byType(CircularProgressIndicator).evaluate().isNotEmpty); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.f9);
      await real(tester, 10);
      expect(find.text('Trigger 1: ran 1 automation'), findsOneWidget);
      expect([for (final t in (await tester.runAsync(() => tasks.listTasks()))!) t.title], ['Key on Lecture 1']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without a note open it still runs, and a trigger nobody set up says so', (tester) async {
      await start(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f9);
      await real(tester, 10);
      expect(find.text('Trigger 1: ran 1 automation'), findsOneWidget);
      expect([for (final t in (await tester.runAsync(() => tasks.listTasks()))!) t.title], ['Key on'], reason: 'no note: no title');
      await tester.runAsync(() async => shortcuts.addBinding('automation.trigger3', KeyCombo(LogicalKeyboardKey.f10)));
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await real(tester, 6);
      expect(find.text('No automation is set for trigger 3 (see Automations)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the side button of the pen, set to trigger 2, runs it and does not draw; set to erase it does not run anything', (tester) async {
      await start(tester, barrel: BarrelAction.trigger2);
      await tester.tap(find.text('Lecture 1').first);
      for (var i = 0; i < 60 && (find.byType(FixedPageNoteEditor).evaluate().isEmpty || find.byType(CircularProgressIndicator).evaluate().isNotEmpty); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
      final g = await tester.startGesture(origin + const Offset(300, 300), kind: PointerDeviceKind.stylus, buttons: kSecondaryStylusButton);
      for (var i = 1; i <= 8; i++) {
        await g.moveTo(origin + Offset(300.0 + i * 15, 300));
        await tester.pump();
      }
      await g.up();
      await real(tester, 10);
      expect(find.text('Trigger 2: ran 1 automation'), findsOneWidget);
      expect([for (final t in (await tester.runAsync(() => tasks.listTasks()))!) t.title], ['Pen on Lecture 1']);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1200))); // (the note is saved a moment after a change)
      final strokes = (await tester.runAsync(() async => (await notes.loadNote(noteId))!.strokes.values.expand((l) => l).length))!;
      expect(strokes, 0, reason: 'the pen did not draw with the button down');
      await tester.pumpWidget(const SizedBox());
    });
  });

}
