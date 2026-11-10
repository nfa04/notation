import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/lock/note_lock_service.dart';
import 'package:notes/main.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _NoDevice implements DeviceAuth {
  @override
  Future<bool> available() async => false;
  @override
  Future<bool> authenticate(String reason) async => false;
}

class _Vault implements PassphraseVault {
  @override
  Future<String?> read(String id) async => null;
  @override
  Future<void> write(String id, String s) async {}
  @override
  Future<void> delete(String id) async {}
}

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('a locked note shows nothing of itself, asks for its secret, and is put away when left', (tester) async {
    tester.view.physicalSize = const Size(1900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late TaskRepository tasks;
    late CalDavService caldav;
    late DeviceCalendarService device;
    late NoteLockService locks;
    late String secret;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('lockui');
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key = 'rail_hidden'");
      repo = NoteRepository(db);
      tasks = TaskRepository(db);
      caldav = CalDavService(SettingsRepository(db), tasks);
      device = DeviceCalendarService.forPlatform(SettingsRepository(db));
      locks = NoteLockService(repo, NoteFileService(repo, supportDirectory: () async => dir), deviceAuth: _NoDevice(), vault: _Vault(), iterations: 1000);
      secret = await repo.createNote(title: 'Diary of Anna');
      final n = (await repo.loadNote(secret))!;
      n.documentText = 'my deepest secret';
      await repo.saveNote(n);
      await locks.lockEncrypted(secret, 'open sesame');
    });
    addTearDown(() => dir.delete(recursive: true));

    await tester.pumpWidget(NotationApp(services: AppServices(
      repository: repo,
      tasks: tasks,
      caldav: caldav,
      device: device,
      style: StyleService.inMemory(),
      appTheme: AppTheme.inMemory(),
      locks: locks,
    )));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Diary of Anna'), findsNothing);
    expect(find.text('Locked note'), findsOneWidget);

    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.text('Locked note'));
    await settle();
    expect(find.byKey(const ValueKey('unlock-secret')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('unlock-secret')), 'wrong');
    await tester.tap(find.byKey(const ValueKey('unlock-go')));
    await settle();
    expect(find.text('That is not the passphrase.'), findsOneWidget);
    expect(find.byType(FixedPageNoteEditor), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('unlock-secret')), 'open sesame');
    await tester.tap(find.byKey(const ValueKey('unlock-go')));
    await settle();
    expect(find.byType(FixedPageNoteEditor), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Diary of Anna'), findsOneWidget);
    expect(locks.isOpen(secret), isTrue);

    // "Lock now": back to the dashboard, and the note is taken out of the database again
    await tester.ensureVisible(find.byKey(const ValueKey('lock-note'))); // (the buttons scroll sideways)
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('lock-note')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Lock now'), findsOneWidget);
    await tester.tap(find.text('Lock now'));
    await settle();
    expect(find.byType(FixedPageNoteEditor), findsNothing);
    expect(locks.isOpen(secret), isFalse);
    final after = (await tester.runAsync(() => repo.loadNote(secret)))!;
    expect(after.documentText, '');
    expect(after.title, '');
    expect(find.text('Locked note'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });
  testWidgets('a note is locked from its own screen, with a passcode, and then asks for it', (tester) async {
    tester.view.physicalSize = const Size(1900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late TaskRepository tasks;
    late CalDavService caldav;
    late DeviceCalendarService device;
    late NoteLockService locks;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('lockui2');
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key = 'rail_hidden'");
      repo = NoteRepository(db);
      tasks = TaskRepository(db);
      caldav = CalDavService(SettingsRepository(db), tasks);
      device = DeviceCalendarService.forPlatform(SettingsRepository(db));
      locks = NoteLockService(repo, NoteFileService(repo, supportDirectory: () async => dir), deviceAuth: _NoDevice(), vault: _Vault(), iterations: 1000);
      id = await repo.createNote(title: 'Plain at first');
    });
    addTearDown(() => dir.delete(recursive: true));
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(NotationApp(services: AppServices(
      repository: repo,
      tasks: tasks,
      caldav: caldav,
      device: device,
      style: StyleService.inMemory(),
      appTheme: AppTheme.inMemory(),
      locks: locks,
    )));
    await settle();
    await tester.tap(find.text('Plain at first'));
    await settle();
    expect(find.byType(FixedPageNoteEditor), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('lock-note')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('lock-note')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Lock this note...'));
    await settle();
    await tester.enterText(find.byKey(const ValueKey('lock-secret')), '12');
    await tester.enterText(find.byKey(const ValueKey('lock-again')), '12');
    await tester.tap(find.byKey(const ValueKey('lock-go')));
    await tester.pump();
    expect(find.text('Use at least 4 characters.'), findsOneWidget); // (too short)
    await tester.enterText(find.byKey(const ValueKey('lock-secret')), '4321');
    await tester.enterText(find.byKey(const ValueKey('lock-again')), '4320');
    await tester.tap(find.byKey(const ValueKey('lock-go')));
    await tester.pump();
    expect(find.text('The two entries are not the same.'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('lock-again')), '4321');
    await tester.tap(find.byKey(const ValueKey('lock-go')));
    await settle();
    expect(await tester.runAsync(() => repo.locks.lockModeOf(id)), 1);
    expect(find.byType(FixedPageNoteEditor), findsOneWidget); // (a passcode lock does not take the note away from under the person)

    // leaving puts it away; opening it again asks
    await tester.tap(find.byIcon(Icons.home_outlined).first);
    await settle();
    expect(locks.isOpen(id), isFalse);
    expect(find.text('Locked note'), findsWidgets);
    expect(find.text('Plain at first'), findsNothing);
    await tester.tap(find.ancestor(of: find.byKey(ValueKey('star-$id')), matching: find.byType(InkWell)).first);
    await settle();
    await tester.enterText(find.byKey(const ValueKey('unlock-secret')), '4321');
    await tester.tap(find.byKey(const ValueKey('unlock-go')));
    await settle();
    expect(find.byType(FixedPageNoteEditor), findsOneWidget);

    // the app out of sight for a moment: the note stays open; for longer than 30 s it is put away
    final binding = TestWidgetsFlutterBinding.instance;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 10));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 40));
    expect(locks.isOpen(id), isTrue);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 31));
    await settle();
    expect(locks.isOpen(id), isFalse);
    expect(find.byType(FixedPageNoteEditor), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });
}
