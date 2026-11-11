import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/ai_switch.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/ink/handwriting_service.dart';
import 'package:notes/ink/math_service.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/main_shell.dart';
import 'package:notes/screens/settings_screen.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'close_editor.dart';

class _Provider extends ChangeNotifier implements TextModelProvider {
  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  String get description => '';
  @override
  ProviderState get state => ProviderState.ready;
  @override
  String? get reason => null;
  @override
  Future<void> prepare() async {}
  @override
  Future<String> complete(AiPrompt prompt, {int maxTokens = 256, void Function(String partial)? onPartial, AiCancel? cancel}) async => 'x';
}

void main() {
  setUpAll(AppDatabase.initFfi);

  test('AI is on until it is switched off, and the choice is kept', () async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    await db.delete('settings', where: "key = 'ai_enabled'");
    final settings = SettingsRepository(db);
    final a = AiSwitch(settings);
    await a.load();
    expect(a.enabled, isTrue);
    var changes = 0;
    a.addListener(() => changes++);
    await a.setEnabled(false);
    await a.setEnabled(false); // nothing new
    expect((a.enabled, changes), (false, 1));
    final again = AiSwitch(settings);
    await again.load();
    expect(again.enabled, isFalse);
    await again.setEnabled(true);
    final third = AiSwitch(settings);
    await third.load();
    expect(third.enabled, isTrue);
    expect(AiSwitch().enabled, isTrue); // without a store it just works in memory
  });

  testWidgets('settings: the switch turns every AI feature off and on', (tester) async {
    final db = await tester.runAsync(() => AppDatabase.open(path: inMemoryDatabasePath));
    await tester.runAsync(() => db!.delete('settings', where: "key = 'ai_enabled'"));
    final aiSwitch = AiSwitch(SettingsRepository(db!));
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), aiSwitch: aiSwitch)));
    await tester.tap(find.byKey(const ValueKey('settings-tab-AI and models')));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('ai-switch'))).value, isTrue);
    await tester.ensureVisible(find.byKey(const ValueKey('ai-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-switch')));
    await tester.pumpAndSettle();
    expect(aiSwitch.enabled, isFalse);
    expect(find.textContaining('nothing in the app uses AI'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-switch')));
    await tester.pumpAndSettle();
    expect(aiSwitch.enabled, isTrue);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  });

  testWidgets('with AI off, an open note loses the assistant, summaries and handwriting, and gets them back', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository notes;
    late TaskRepository tasks;
    late SettingsRepository settings;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
      settings = SettingsRepository(db);
      await notes.createNote(title: 'Physics');
    });
    final aiSwitch = AiSwitch();
    await tester.pumpWidget(MaterialApp(
      home: MainShellNavigation(services: AppServices(
        repository: notes,
        tasks: tasks,
        caldav: CalDavService(settings, tasks),
        device: DeviceCalendarService(settings),
        style: StyleService.inMemory(),
        appTheme: AppTheme.inMemory(),
        ai: AiService(providers: [_Provider()]),
        handwriting: HandwritingService(),
        math: MathService(),
        aiSwitch: aiSwitch,
      )),
    ));
    Future<void> wait(bool Function() done) async {
      for (var i = 0; i < 60 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await wait(() => find.text('Physics').evaluate().isNotEmpty);
    await tester.tap(find.text('Physics').first);
    await wait(() => find.byType(FixedPageNoteEditor).evaluate().isNotEmpty && find.byKey(const ValueKey('assistant-button')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('assistant-button')), findsOneWidget);

    // the assistant is open when the switch is turned
    await tester.ensureVisible(find.byKey(const ValueKey('assistant-button'))); // (the buttons scroll sideways)
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('assistant-panel')), findsOneWidget);
    // one AI button in the top bar; what the AI can make of the note is in the panel
    expect(find.byKey(const ValueKey('note-ai-button')), findsNothing);
    expect(find.byKey(const ValueKey('assistant-note-ai')), findsOneWidget);
    expect(find.byKey(const ValueKey('assistant-make-summary')), findsOneWidget);
    expect(find.byKey(const ValueKey('assistant-make-quiz')), findsOneWidget);
    expect(find.byKey(const ValueKey('assistant-suggestion-Summarize this document')), findsNothing); // (the summary is offered once)

    aiSwitch.setEnabled(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('assistant-button')), findsNothing);
    expect(find.byKey(const ValueKey('assistant-panel')), findsNothing);
    expect(find.byType(FixedPageNoteEditor), findsOneWidget); // the note itself stays open

    aiSwitch.setEnabled(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('assistant-button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('assistant-panel')), findsOneWidget); // a fresh assistant
    await closeEditor(tester); // (the fresh assistant and the note's kept readings are loaded from the database)
  });

  testWidgets('the assistant that answers from all notes has its own place in the menu, takes the whole page, and goes with the AI switch', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository notes;
    late TaskRepository tasks;
    late SettingsRepository settings;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
      settings = SettingsRepository(db);
    });
    final aiSwitch = AiSwitch();
    await tester.pumpWidget(MaterialApp(
      home: MainShellNavigation(services: AppServices(
        repository: notes,
        tasks: tasks,
        caldav: CalDavService(settings, tasks),
        device: DeviceCalendarService(settings),
        style: StyleService.inMemory(),
        appTheme: AppTheme.inMemory(),
        ai: AiService(providers: [_Provider()]),
        handwriting: HandwritingService(),
        math: MathService(),
        aiSwitch: aiSwitch,
      )),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('ask-notes')), findsNothing, reason: 'no button on the dashboard any more');
    expect(find.text('Graph'), findsOneWidget);
    await tester.tap(find.text('Assistant'));
    await tester.pump(const Duration(milliseconds: 300));
    final panel = find.byKey(const ValueKey('notes-assistant'));
    expect(panel, findsOneWidget);
    final rail = tester.getSize(find.byType(NavigationRail)).width;
    expect(tester.getSize(panel).width, closeTo(1600 - rail - 1, 2), reason: 'all of the screen but the menu');
    expect(tester.getSize(panel).height, closeTo(1000, 1));
    expect(find.byKey(const ValueKey('assistant-close')), findsNothing);

    aiSwitch.setEnabled(false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Assistant'), findsNothing);
    expect(find.text('Graph'), findsNothing, reason: 'the graph goes with the AI too');
    expect(panel, findsNothing);
  });
}
