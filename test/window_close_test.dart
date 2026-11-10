import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/screens/main_shell.dart' as shell;
import 'package:notes/screens/window_close.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  group('closing the window', () {
    var log = <String>[];
    setUp(() => log = <String>[]); // (a new one for each test: what is still going on from the one before writes in its own)

    WindowCloser closer({
      bool copies = true,
      bool canHide = true,
      Future<void> Function()? save,
      Future<void> Function()? putUp,
      bool desktop = true,
    }) {
      final mine = log;
      return WindowCloser(
          saveNote: save ?? () async => mine.add('saved'),
          hasCopies: () => copies,
          putUpCopies: putUp ?? () async => mine.add('copies up'),
          hideWindow: () async {
            mine.add('window hidden');
            return canHide;
          },
          endProcess: (c) => mine.add('ended $c'),
          desktop: desktop,
          saveLimit: const Duration(milliseconds: 80),
          foreground: const Duration(milliseconds: 80),
          background: const Duration(milliseconds: 150),
          lastResort: const Duration(milliseconds: 80),
        );
    }

    Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

    test('the note is saved, the window goes, and the copies go up after it; then the process ends', () async {
      final c = closer(putUp: () async {
        await wait(30);
        log.add('copies up');
      });
      expect(await c.closeDown(), AppExitResponse.cancel, reason: 'the app stays until the work is done');
      expect(log, ['saved', 'window hidden'], reason: 'the window is gone before the copies are touched');
      await wait(120);
      expect(log, ['saved', 'window hidden', 'copies up', 'ended 0']);
    });

    test('the copies that take too long do not keep the app', () async {
      final c = closer(putUp: () => Completer<void>().future);
      await c.closeDown();
      await wait(100);
      expect(log, ['saved', 'window hidden']);
      await wait(200);
      expect(log, ['saved', 'window hidden', 'ended 0']);
    });

    test('nothing to put up: the window closes at once, the process goes with it', () async {
      final c = closer(copies: false);
      expect(await c.closeDown(), AppExitResponse.exit);
      expect(log, ['saved'], reason: 'the window is not hidden: the app exits');
      await wait(150);
      expect(log, ['saved', 'ended 0'], reason: 'ended if it is still there after it was allowed to go');
    });

    test('where the window cannot be hidden the copies go up first, but only for a while', () async {
      final c = closer(canHide: false, putUp: () async {
        await wait(20);
        log.add('copies up');
      });
      expect(await c.closeDown(), AppExitResponse.exit);
      expect(log, ['saved', 'window hidden', 'copies up']);

      log = <String>[];
      final slow = closer(canHide: false, putUp: () => Completer<void>().future);
      final watch = Stopwatch()..start();
      expect(await slow.closeDown(), AppExitResponse.exit);
      expect(watch.elapsedMilliseconds, lessThan(400), reason: 'it did not wait for ever');
    });

    test('a note that cannot be saved does not stop the closing', () async {
      final c = closer(save: () async => throw StateError('disk'), copies: false);
      expect(await c.closeDown(), AppExitResponse.exit);
      final stuck = closer(save: () => Completer<void>().future, copies: false);
      expect(await stuck.closeDown(), AppExitResponse.exit);
    });

    test('a second click on the close button gets the same answer, and nothing is done twice', () async {
      final c = closer(copies: false);
      final a = c.closeDown();
      final b = c.closeDown();
      expect(await a, await b);
      expect(log.where((l) => l == 'saved'), hasLength(1));
    });

    test('no ending of the process where that is not the app\'s to do', () async {
      final c = closer(copies: false, desktop: false);
      await c.closeDown();
      await wait(200);
      expect(log, ['saved']);
    });
  });

  testWidgets('the shell answers the request to close', (tester) async {
    final ended = <int>[];
    shell.endProcess = ended.add;
    addTearDown(() => shell.endProcess = (c) {});
    late NoteRepository notes;
    late TaskRepository tasks;
    late SettingsRepository settings;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      settings = SettingsRepository(db);
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
    });
    await tester.pumpWidget(MaterialApp(
      home: shell.MainShellNavigation(services: AppServices(
        repository: notes,
        tasks: tasks,
        caldav: CalDavService(settings, tasks),
        device: DeviceCalendarService(settings),
        style: StyleService.inMemory(),
        appTheme: AppTheme.inMemory(),
      )),
    ));
    await tester.pump();
    final first = WidgetsBinding.instance.handleRequestAppExit();
    final second = WidgetsBinding.instance.handleRequestAppExit();
    expect(await first, AppExitResponse.exit);
    expect(await second, AppExitResponse.exit);
    await tester.pump(const Duration(seconds: 4));
    expect(ended, [0]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });
}
