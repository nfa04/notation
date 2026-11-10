import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/style_repository.dart' show StyleScope;
import 'package:notes/data/task_repository.dart';
import 'package:notes/screens/main_shell.dart';
import 'package:notes/screens/settings_screen.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/calendar_style.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late SettingsRepository settings;
  setUp(() async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    await db.delete('settings');
    settings = SettingsRepository(db);
  });

  group('AppTheme', () {
    test('starts with the original blue and remembers a change', () async {
      final theme = AppTheme(settings);
      await theme.load();
      expect(theme.accent, AppTheme.defaultAccent);

      await theme.setAccent(const Color(0xFFEC6FA3));
      final again = AppTheme(settings);
      await again.load();
      expect(again.accent, const Color(0xFFEC6FA3));
    });

    test('notifies listeners only when the colour really changes', () async {
      final theme = AppTheme.inMemory();
      var calls = 0;
      theme.addListener(() => calls++);
      await theme.setAccent(AppTheme.defaultAccent);
      expect(calls, 0);
      await theme.setAccent(const Color(0xFF123456));
      expect(calls, 1);
    });

    test('an accent picked before it had its own setting is kept', () async {
      // saved by the previous version, inside the calendar theme
      await settings.set('calendar_theme', '{"accent": ${0xFFEC6FA3}, "radius": 10}');
      final theme = AppTheme(settings);
      await theme.load();
      expect(theme.accent, const Color(0xFFEC6FA3));

      // and the calendar theme still reads fine without it
      final calendar = CalendarTheme.fromJson({'accent': 0xFFEC6FA3, 'radius': 10});
      expect(calendar.radius, 10);
    });

    test('its own setting wins over the old one', () async {
      await settings.set('calendar_theme', '{"accent": ${0xFFEC6FA3}}');
      await settings.set('app_accent', '${0xFF00FF00}');
      final theme = AppTheme(settings);
      await theme.load();
      expect(theme.accent, const Color(0xFF00FF00));
    });

    test('an unreadable old theme is ignored', () async {
      await settings.set('calendar_theme', 'garbage');
      final theme = AppTheme(settings);
      await theme.load();
      expect(theme.accent, AppTheme.defaultAccent);
    });

    test('tasks follow the app accent', () async {
      final app = AppTheme.inMemory();
      final style = StyleService.inMemory(app);
      var changed = 0;
      style.addListener(() => changed++);
      const task = Task(id: 't', title: 'x');
      expect(style.resolveTask(task).color, AppTheme.defaultAccent);

      await app.setAccent(const Color(0xFFEC6FA3));
      expect(style.resolveTask(task).color, const Color(0xFFEC6FA3));
      expect(changed, 1); // views listening to the style repaint

      // unless the task has a colour of its own
      await style.setStyle(StyleScope.task, 't', const ItemStyle(color: Color(0xFF000000)));
      expect(style.resolveTask(task).color, const Color(0xFF000000));
    });
  });

  testWidgets('settings screen: pick an accent, the whole app follows', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final app = AppTheme.inMemory();
    // like main.dart: the app's colours come from the accent
    await tester.pumpWidget(ListenableBuilder(
      listenable: app,
      builder: (context, _) => MaterialApp(
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: app.accent)),
        home: SettingsScreen(theme: app),
      ),
    ));
    final before = Theme.of(tester.element(find.byType(FilledButton))).colorScheme.primary;

    await tester.tap(find.byKey(ValueKey('accent-${swatchColors[1].toARGB32()}')));
    await tester.pumpAndSettle();

    expect(app.accent, swatchColors[1]);
    expect(Theme.of(tester.element(find.byType(FilledButton))).colorScheme.primary, isNot(before));
  });

  testWidgets('Settings is in the left bar and opens', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository notes;
    late TaskRepository tasks;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
    });
    await tester.pumpWidget(MaterialApp(
      home: MainShellNavigation(services: AppServices(
        repository: notes,
        tasks: tasks,
        caldav: CalDavService(settings, tasks),
        device: DeviceCalendarService(settings),
        style: StyleService.inMemory(),
        appTheme: AppTheme.inMemory(),
      )),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Accent color'), findsOneWidget);
  });
}
