import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/graph/graph_service.dart';
import 'package:notes/main.dart';
import 'package:notes/screens/graph_view.dart';
import 'package:notes/screens/accessibility_settings.dart';
import 'package:notes/style/accessibility.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/color_names.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('what is asked for is added to what the system asks for', () {
    const system = MediaQueryData(textScaler: TextScaler.linear(1.25), boldText: false);
    final plain = AccessibilitySettings.inMemory();
    expect(plain.changed, isFalse);
    expect(plain.apply(system).textScaler.scale(10), 12.5);
    final big = AccessibilitySettings.inMemory(textScale: 1.5, reduceMotion: true, boldText: true, highContrast: true);
    final applied = big.apply(system);
    expect(applied.textScaler.scale(10), closeTo(18.75, 1e-9));
    expect(applied.disableAnimations, isTrue);
    expect(applied.boldText, isTrue);
    expect(applied.highContrast, isTrue);
    // never less than the system makes it
    expect(AccessibilitySettings.inMemory(textScale: 0.8).apply(system).textScaler.scale(10), closeTo(10, 1e-9));
  });

  test('more contrast gives a scheme that differs, and big buttons a roomier theme', () {
    final normal = AccessibilitySettings.inMemory();
    final strong = AccessibilitySettings.inMemory(highContrast: true, bigTargets: true);
    expect(strong.scheme(Colors.blue, Brightness.light).onSurfaceVariant, isNot(normal.scheme(Colors.blue, Brightness.light).onSurfaceVariant));
    final t = strong.theme(ThemeData());
    expect(t.materialTapTargetSize, MaterialTapTargetSize.padded);
    expect(t.visualDensity, VisualDensity.comfortable);
    expect(normal.theme(ThemeData()).materialTapTargetSize, ThemeData().materialTapTargetSize);
  });

  test('roomier text, bigger icons and the strong look of more contrast are in the theme', () {
    final base = ThemeData();
    final roomy = AccessibilitySettings.inMemory(roomyText: true).theme(base);
    expect(roomy.textTheme.bodyMedium!.height, 1.5);
    expect(roomy.textTheme.bodyMedium!.letterSpacing, greaterThan(base.textTheme.bodyMedium!.letterSpacing ?? 0));
    expect(AccessibilitySettings.inMemory().theme(base).textTheme.bodyMedium!.height, base.textTheme.bodyMedium!.height);
    expect(AccessibilitySettings.inMemory(bigTargets: true).theme(base).iconTheme.size, 28);
    final strong = AccessibilitySettings.inMemory(highContrast: true).theme(base);
    expect(strong.textTheme.bodySmall!.color, strong.colorScheme.onSurface, reason: 'no softer greys');
    expect(strong.outlinedButtonTheme.style, isNotNull);
    expect(AccessibilitySettings.inMemory(roomyText: true).changed, isTrue);
  });

  test('the text of the screens takes its colour from the theme, so that more contrast and the dark theme reach it', () {
    final grey = RegExp(r'TextStyle\([^()]*color: Colors\.grey(\[\d+\])?[,)\s]');
    final found = [
      for (final f in Directory('lib/screens').listSync().whereType<File>().where((f) => f.path.endsWith('.dart')))
        if (grey.hasMatch(f.readAsStringSync())) f.path,
    ];
    expect(found, isEmpty);
  });

  testWidgets('the graph screen fits a phone with the biggest text', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late GraphService service;
    await tester.runAsync(() async => service = GraphService(NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath))));
    final a = AccessibilitySettings.inMemory(textScale: 2);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(data: a.apply(MediaQuery.of(context)), child: child!),
      home: GraphView(service: service, onOpen: (_, _) {}),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('graph-generate')), findsOneWidget);
  });

  test('settings are kept', () async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    final repo = SettingsRepository(db);
    final a = AccessibilitySettings(repo);
    await a.setTextScale(1.4);
    await a.setBigTargets(true);
    await a.setHighContrast(true);
    await a.setRoomyText(true);
    final b = AccessibilitySettings(repo);
    await b.load();
    expect(b.textScale, 1.4);
    expect(b.bigTargets, isTrue);
    expect(b.highContrast, isTrue);
    expect(b.roomyText, isTrue);
    expect(b.reduceMotion, isFalse);
    await a.setTextScale(5); // (kept to what makes sense)
    expect(a.textScale, AccessibilitySettings.maxScale);
  });

  test('colours are named for someone who cannot see them', () {
    expect(colorName(Colors.black), 'Black');
    expect(colorName(Colors.redAccent), 'Red');
    expect(colorName(Colors.blueAccent), 'Blue');
    expect(colorName(Colors.green), 'Green');
    expect(colorName(Colors.yellow.withValues(alpha: 0.35)), 'Yellow, see-through');
  });

  testWidgets('the card changes the settings, and the app follows', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final a = AccessibilitySettings.inMemory();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: AccessibilitySettingsCard(settings: a)))));
    expect(find.byKey(const ValueKey('a11y-reset')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('a11y-contrast')));
    await tester.tap(find.byKey(const ValueKey('a11y-targets')));
    await tester.pump();
    expect(a.highContrast, isTrue);
    expect(a.bigTargets, isTrue);
    await tester.drag(find.byKey(const ValueKey('a11y-text-scale')), const Offset(120, 0));
    await tester.pump();
    expect(a.textScale, greaterThan(1));
    await tester.tap(find.byKey(const ValueKey('a11y-reset')));
    await tester.pump();
    expect(a.changed, isFalse);

    late TaskRepository tasks;
    late CalDavService caldav;
    late DeviceCalendarService device;
    late NoteRepository repo;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      tasks = TaskRepository(db);
      caldav = CalDavService(SettingsRepository(db), tasks);
      device = DeviceCalendarService.forPlatform(SettingsRepository(db));
    });
    final scaled = AccessibilitySettings.inMemory(textScale: 2);
    await tester.pumpWidget(NotationApp(services: AppServices(
      repository: repo,
      tasks: tasks,
      caldav: caldav,
      device: device,
      style: StyleService.inMemory(),
      appTheme: AppTheme.inMemory(),
      accessibility: scaled,
    )));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    final context = tester.element(find.byType(Scaffold).first);
    expect(MediaQuery.of(context).textScaler.scale(10), 20);
    await tester.pumpWidget(const SizedBox());
  });
}
