import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/main.dart';
import 'package:notes/screens/settings_screen.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/platform_look.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  group('PlatformLook', () {
    test('automatic is iOS only on iOS, the others are what they say', () {
      expect(PlatformLook.ios.isIos, isTrue);
      expect(PlatformLook.material.isIos, isFalse);
      // (tests run as Android)
      expect(PlatformLook.automatic.isIos, isFalse);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(PlatformLook.automatic.isIos, isTrue);
    });

    test('an unknown name is automatic', () {
      expect(PlatformLook.fromName(null), PlatformLook.automatic);
      expect(PlatformLook.fromName('nonsense'), PlatformLook.automatic);
      expect(PlatformLook.fromName('ios'), PlatformLook.ios);
    });

    test('AppTheme remembers it and tells only about a real change', () async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings');
      final settings = SettingsRepository(db);
      final theme = AppTheme(settings);
      await theme.load();
      expect(theme.look, PlatformLook.automatic);
      var calls = 0;
      theme.addListener(() => calls++);
      await theme.setLook(PlatformLook.automatic);
      expect(calls, 0);
      await theme.setLook(PlatformLook.ios);
      expect(calls, 1);
      final again = AppTheme(settings);
      await again.load();
      expect(again.look, PlatformLook.ios);
    });

    test('the iOS look keeps the accent and changes the platform', () {
      final base = ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFEC6FA3)));
      final ios = iosLook(base);
      expect(ios.platform, TargetPlatform.iOS);
      expect(ios.colorScheme.primary, base.colorScheme.primary);
      expect(ios.appBarTheme.centerTitle, isTrue);
      expect(ios.cardTheme.elevation, 0);
      // buttons: no ripple, the iOS shapes, and a segmented control without its tick
      expect(ios.textButtonTheme.style?.splashFactory, NoSplash.splashFactory);
      expect(ios.filledButtonTheme.style?.shape?.resolve({}), isA<RoundedRectangleBorder>());
      expect(ios.outlinedButtonTheme.style?.side?.resolve({}), BorderSide.none);
      expect(ios.iconButtonTheme.style?.splashFactory, NoSplash.splashFactory);
      expect(ios.segmentedButtonTheme.style?.side?.resolve({}), BorderSide.none);
    });
  });

  testWidgets('the whole app follows the look picked in the settings', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository notes;
    late TaskRepository tasks;
    late CalDavService caldav;
    late DeviceCalendarService device;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
      caldav = CalDavService(SettingsRepository(db), tasks);
      device = DeviceCalendarService.forPlatform(SettingsRepository(db));
    });
    final app = AppTheme.inMemory();
    await tester.pumpWidget(NotationApp(services: AppServices(
      repository: notes,
      tasks: tasks,
      caldav: caldav,
      device: device,
      style: StyleService.inMemory(),
      appTheme: app,
    )));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.byType(Scaffold).first)).platform, TargetPlatform.android);

    await tester.runAsync(() => app.setLook(PlatformLook.ios));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.byType(Scaffold).first)).platform, TargetPlatform.iOS);

    await tester.runAsync(() => app.setLook(PlatformLook.material));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.byType(Scaffold).first)).platform, TargetPlatform.android);
  });

  testWidgets('the widgets with an iOS version of their own take it under the iOS look', (tester) async {
    Future<void> show(ThemeData theme) => tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Material(
            child: Column(children: [
              Switch.adaptive(value: true, onChanged: (_) {}),
              Slider.adaptive(value: 0.5, onChanged: (_) {}),
              const CircularProgressIndicator.adaptive(),
            ]),
          ),
        ));
    final base = ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue));

    await show(base);
    expect(find.byType(CupertinoSlider), findsNothing);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);

    await show(iosLook(base));
    await tester.pump(const Duration(seconds: 1)); // (the theme change is animated)
    expect(find.byType(CupertinoSlider), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
  });

  testWidgets('settings: the look is picked in the Appearance section', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final app = AppTheme.inMemory();
    await tester.pumpWidget(ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final base = ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: app.accent));
        return MaterialApp(theme: app.look.isIos ? iosLook(base) : base, home: SettingsScreen(theme: app));
      },
    ));
    expect(Theme.of(tester.element(find.byType(Switch).first)).platform, TargetPlatform.android);

    await tester.tap(find.descendant(of: find.byKey(const ValueKey('platform-look')), matching: find.text('iOS')));
    await tester.pumpAndSettle();

    expect(app.look, PlatformLook.ios);
    expect(Theme.of(tester.element(find.byType(Switch).first)).platform, TargetPlatform.iOS);
  });
}
