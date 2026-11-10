import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/dashboard_view.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/settings_screen.dart';
import 'package:notes/style/app_theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late NoteFileService files;
  late String id;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('flush_');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester, {bool withFiles = true}) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      files = NoteFileService(repo, supportDirectory: () async => dir);
      id = await repo.createNote(title: 'Flush me');
    });
    await tester.pumpWidget(MaterialApp(
      home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, noteFiles: withFiles ? files : null),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  testWidgets('leaving the app writes what changed at once, not when the timer would fire', (tester) async {
    await open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Flush me'), 'Changed title');
    await tester.pump(const Duration(milliseconds: 100)); // far less than the 800 ms of the timer
    expect((await tester.runAsync(() => repo.noteInfo(id)))!.title, 'Flush me');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive); // the first step of leaving
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    expect((await tester.runAsync(() => repo.noteInfo(id)))!.title, 'Changed title');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the note has a button to save it as a file, when files are available', (tester) async {
    await open(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('save-note-file')));
    expect(find.byKey(const ValueKey('save-note-file')), findsOneWidget);
  });

  testWidgets('without the service there is no such button', (tester) async {
    await open(tester, withFiles: false);
    expect(find.byKey(const ValueKey('save-note-file')), findsNothing);
  });

  testWidgets('the dashboard can open a note file and a note offers to be saved as one', (tester) async {
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      files = NoteFileService(repo, supportDirectory: () async => dir);
      await repo.createNote(title: 'On the dashboard');
    });
    await tester.pumpWidget(MaterialApp(home: DashboardView(repository: repo, noteFiles: files, onOpenNote: (_) {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('open-note-file')), findsOneWidget);
    await tester.tap(find.byTooltip('More').first);
    await tester.pumpAndSettle();
    expect(find.text('Save as a file...'), findsOneWidget);
  });

  testWidgets('the settings have a place for note files', (tester) async {
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      files = NoteFileService(repo, supportDirectory: () async => dir);
    });
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), noteFiles: files)));
    await tester.tap(find.byKey(const ValueKey('settings-tab-Sharing and files')));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('note-files-open')));
    expect(find.byKey(const ValueKey('note-files-open')), findsOneWidget);
    expect(find.textContaining('Save the note as a file'), findsOneWidget); // points to the automation
  });
}
