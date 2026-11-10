import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/reminder_repository.dart';
import 'package:notes/data/tag_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/events/event_bus.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/reminders/notification_sink.dart';
import 'package:notes/reminders/reminder_service.dart';
import 'package:notes/screens/automation_log.dart';
import 'package:notes/templates/templates.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_model.dart';

class _Sink implements NotificationSink {
  @override
  bool get supportsScheduling => false;
  @override
  Future<bool> init(void Function(String? payload) onTap) async => true;
  @override
  Future<bool> isPermitted() async => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> show({required int id, required String title, required String body, required String payload}) async {}
  @override
  Future<void> schedule({required int id, required DateTime at, required String title, required String body, required String payload}) async {}
  @override
  Future<void> cancelScheduled() async {}
}

class _Open implements NoteEditorHandle, TitleSetter {
  String title;
  _Open(this.title);
  @override
  Future<void> get ready async {}
  @override
  Future<void> saveNow() async {}
  @override
  String get noteTitle => title;
  @override
  Future<String?> exportPdfTo(String path) async => null;
  @override
  Future<List<String>> pdfTextLines() async => const [];
  @override
  void setNoteTitle(String t) => title = t;
}

const _text = 'A binary heap keeps its largest item at the root. The swim function restores the heap property after an insertion by '
    'exchanging a node with its parent while it is larger.';

void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  late NoteRepository notes;
  late TaskRepository tasks;
  late TagRepository tags;
  late CardRepository cards;
  late ReminderService reminders;
  late FakeModel model;
  late Directory dir;
  var now = DateTime(2026, 5, 4, 10);

  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath);
    for (final t in ['settings', 'tasks', 'notes', 'folders', 'text_boxes', 'note_tags', 'reminders', 'review_cards']) {
      await db.delete(t);
    }
    notes = NoteRepository(db);
    tasks = TaskRepository(db);
    tags = TagRepository(db);
    cards = CardRepository(db);
    reminders = ReminderService(reminders: ReminderRepository(db), sink: _Sink(), read: (k) async => null, write: (k, v) async {}, clock: () => now);
    model = FakeModel('Q: What is a heap?\nA: A tree that keeps its largest item at the root.');
    dir = await Directory.systemTemp.createTemp('log');
    now = DateTime(2026, 5, 4, 10);
  });
  tearDown(() => dir.delete(recursive: true));

  Future<AutomationService> service() async {
    final s = AutomationService(notes, tasks,
        now: () => now,
        ai: AiService(providers: [model]),
        cards: cards,
        tags: tags,
        reminders: reminders,
        templates: TemplateService(notes, NoteFileService(notes, supportDirectory: () async => dir), now: () => now));
    s.editorWait = const Duration(milliseconds: 100);
    await s.load();
    return s;
  }

  Future<String> noteWith(String text, {String title = 'Heaps'}) async {
    final id = await notes.createNote(title: title);
    await notes.putTextBox(id, 0, TextBoxWidgetModel(id: 'b', position: const Offset(40, 100), size: const Size(300, 60), initialText: text));
    return id;
  }

  Future<List<String>> boxes(String id) async => [for (final b in (await notes.loadNote(id))!.textBoxes[0] ?? const <TextBoxWidgetModel>[]) b.controller.text];

  group('the log', () {
    test('every run is in it, the latest first, with the note, what it said; it is there after a restart', () async {
      final id = await noteWith(_text);
      final s = await service();
      await s.add(const Automation(id: 't', event: AutomationEvent.noteStale, action: AutomationAction.addTag, params: {'tag': 'old'}));
      await s.run(AutomationEvent.noteStale, noteId: id, title: 'Heaps');
      now = DateTime(2026, 5, 4, 11);
      await s.run(AutomationEvent.noteStale, noteId: id, title: 'Heaps');
      final runs = s.runsOf('t');
      expect(runs, hasLength(2));
      expect(runs.first.at, DateTime(2026, 5, 4, 11));
      expect((runs.last.noteId, runs.last.title, runs.last.result), (id, 'Heaps', 'Tagged the note "old"'));
      expect(s.runsOf('other'), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      s.dispose();

      final again = await service();
      expect(again.runsOf('t'), hasLength(2));
      expect(again.runsOf('t').last.canUndo, isTrue, reason: 'the first run added the tag');
      expect(again.runsOf('t').first.canUndo, isFalse, reason: 'the second found it there already');
      again.dispose();
    });

    test('the last twenty of a rule are shown, and the log does not grow without end', () async {
      final s = await service();
      await s.add(const Automation(id: 'f', event: AutomationEvent.taskCompleted, action: AutomationAction.addTask, params: {'title': 'x'}));
      for (var i = 0; i < 70; i++) {
        await s.bus.emit(AppEvent('taskCompleted', title: 'task $i'));
      }
      expect(s.runsOf('f'), hasLength(20));
      expect(s.runsOf('f', limit: 60), hasLength(40), reason: 'twice as many are kept as are shown');
      s.dispose();
    });

    test('a run that failed, or was skipped, says so in the log', () async {
      final id = await noteWith(_text);
      final s = await service();
      await s.add(const Automation(id: 'e', event: AutomationEvent.noteClosed, action: AutomationAction.exportPdf, params: {'dir': '/nope'}));
      await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps');
      expect(s.runsOf('e').single.result, 'The note was not open');
      expect(s.runsOf('e').single.canUndo, isFalse);
      s.dispose();
    });
  });

  group('taking back', () {
    test('a tag, a star, a move, a task', () async {
      final folder = await notes.createFolder('Archive');
      final id = await noteWith(_text);
      final s = await service();
      await s.add(const Automation(id: 'a', event: AutomationEvent.noteStale, action: AutomationAction.addTag, params: {'tag': 'old'}));
      await s.add(const Automation(id: 'b', event: AutomationEvent.noteStale, action: AutomationAction.starNote));
      await s.add(Automation(id: 'c', event: AutomationEvent.noteStale, action: AutomationAction.moveToFolder, params: {'folder': folder}));
      await s.add(const Automation(id: 'd', event: AutomationEvent.noteStale, action: AutomationAction.addTask, params: {'title': 'Look at {title}'}));
      await s.run(AutomationEvent.noteStale, noteId: id, title: 'Heaps');
      expect(await tags.tagsOf(id), ['old']);
      expect((await notes.noteInfo(id))!.folderId, folder);
      expect((await tasks.listTasks()).single.title, 'Look at Heaps');

      for (final r in ['a', 'b', 'c', 'd']) {
        expect(s.runsOf(r).single.canUndo, isTrue, reason: r);
        await s.undo(s.runsOf(r).single);
      }
      expect(await tags.tagsOf(id), isEmpty);
      expect((await notes.listNotes()).single.favorite, isFalse);
      expect((await notes.noteInfo(id))!.folderId, isNull);
      expect(await tasks.listTasks(), isEmpty);
      expect(s.runsOf('a').single.undone, isTrue);
      expect(await s.undo(s.runsOf('a').single), 'There is nothing to take back', reason: 'only once');
      s.dispose();
    });

    test('a star that was there before is not taken off', () async {
      final id = await noteWith(_text);
      await notes.setFavorite(id, true);
      final s = await service();
      await s.add(const Automation(id: 'b', event: AutomationEvent.noteStale, action: AutomationAction.starNote));
      await s.run(AutomationEvent.noteStale, noteId: id, title: 'Heaps');
      expect(s.runsOf('b').single.canUndo, isFalse);
      s.dispose();
    });

    test('text that was written into a note, and the daily note that was made for it', () async {
      final s = await service();
      await s.add(const Automation(id: 'a', event: AutomationEvent.taskCompleted, action: AutomationAction.appendToNote, params: {'where': 'daily', 'title': 'Daily', 'text': 'Done: {title}'}));
      await s.bus.emit(AppEvent('taskCompleted', title: 'Pay rent'));
      await s.assistantDone;
      await s.bus.emit(AppEvent('taskCompleted', title: 'Call Sam'));
      await s.assistantDone;
      final daily = (await notes.listNotes()).single;
      expect(await boxes(daily.id), ['Done: Pay rent', 'Done: Call Sam']);
      final runs = s.runsOf('a');
      expect(runs.first.steps.map((x) => x.kind), ['box'], reason: 'the note was there already');
      expect(runs.last.steps.map((x) => x.kind), ['note', 'box'], reason: 'the first run made the note');

      await s.undo(runs.first);
      expect(await boxes(daily.id), ['Done: Pay rent']);
      await s.undo(runs.last);
      expect(await boxes(daily.id), isEmpty);
      expect((await notes.listNotes()), isEmpty, reason: 'the note is in the trash');
      s.dispose();
    });

    test('a note that is open is not changed behind its back: the text stays, and it is said', () async {
      final id = await noteWith(_text);
      final s = await service();
      await s.add(const Automation(id: 's', event: AutomationEvent.noteStale, action: AutomationAction.summarizeToBox));
      await s.run(AutomationEvent.noteStale, noteId: id, title: 'Heaps');
      await s.assistantDone;
      expect((await boxes(id)).length, 2);
      s.openEditor = (n) => n == id ? _Open('Heaps') : null;
      final said = await s.undo(s.runsOf('s').single);
      expect(said, contains('the note is open'));
      expect((await boxes(id)).length, 2);
      s.openEditor = null;
      await s.undo(s.runsOf('s').single);
      expect(await boxes(id), [_text]);
      s.dispose();
    });

    test('a title, through the editor when the note is open and in the database when it is not', () async {
      final id = await noteWith('Chemistry lab report\nmeasured the pH of three samples', title: 'Untitled Note');
      final s = await service();
      await s.add(const Automation(id: 't', event: AutomationEvent.notePaused, action: AutomationAction.titleNote));
      await s.bus.emit(AppEvent('notePaused', noteId: id));
      await s.assistantDone;
      expect((await notes.noteInfo(id))!.title, 'Chemistry lab report');
      final open = _Open('Chemistry lab report');
      s.openEditor = (n) => open;
      await s.undo(s.runsOf('t').single);
      expect(open.title, 'Untitled Note');
      s.dispose();

      final id2 = await noteWith('Biology field trip\nsaw three kinds of beetle', title: '');
      await db.delete('settings'); // (the rule of the first part is not part of this one)
      final s2 = await service();
      await s2.add(const Automation(id: 't2', event: AutomationEvent.notePaused, action: AutomationAction.titleNote));
      await s2.bus.emit(AppEvent('notePaused', noteId: id2));
      await s2.assistantDone;
      await s2.undo(s2.runsOf('t2').single);
      expect((await notes.noteInfo(id2))!.title, '');
      s2.dispose();
    });

    test('a reminder, a note from a template, flashcards (only the ones that were made)', () async {
      final id = await noteWith(_text);
      await cards.addAll(id, const [], now: now);
      final s = await service();
      await s.add(const Automation(id: 'r', event: AutomationEvent.noteStale, action: AutomationAction.setReminder, params: {'when': 'inAWeek'}));
      await s.add(Automation(id: 'n', event: AutomationEvent.noteStale, action: AutomationAction.createNoteFromTemplate, params: {'template': s.runsOf('x').isEmpty ? 'lecture' : '', 'title': 'From template'}));
      await s.add(const Automation(id: 'c', event: AutomationEvent.noteStale, action: AutomationAction.makeFlashcards));
      await s.run(AutomationEvent.noteStale, noteId: id, title: 'Heaps');
      await s.assistantDone;
      expect((await reminders.reminders.all()), hasLength(1));
      expect((await notes.listNotes()).map((n) => n.title), containsAll(['From template', 'Heaps']));
      expect(await cards.count(source: id), 1);

      await s.undo(s.runsOf('r').single);
      await s.undo(s.runsOf('n').single);
      await s.undo(s.runsOf('c').single);
      expect(await reminders.reminders.all(), isEmpty);
      expect((await notes.listNotes()).map((n) => n.title), ['Heaps']);
      expect(await cards.count(source: id), 0);
      s.dispose();
    });

    test('a card that was kept before the run is not taken away with it', () async {
      final id = await noteWith(_text);
      await cards.addAll(id, [const Flashcard('What is a heap?', 'old answer')], now: now);
      final s = await service();
      await s.add(const Automation(id: 'c', event: AutomationEvent.noteStale, action: AutomationAction.makeFlashcards));
      await s.run(AutomationEvent.noteStale, noteId: id, title: 'Heaps');
      await s.assistantDone;
      expect(s.runsOf('c').single.canUndo, isFalse, reason: 'it was kept already, nothing new');
      s.dispose();
    });
  });

  testWidgets('the log of a rule is a list of runs, each with a button to take back what it did', (tester) async {
    late AutomationService s;
    late String id;
    late Automation rule;
    await tester.runAsync(() async {
      id = await noteWith(_text);
      s = await service();
      rule = const Automation(id: 'a', event: AutomationEvent.noteStale, action: AutomationAction.addTag, params: {'tag': 'old'});
      await s.add(rule);
      await s.run(AutomationEvent.noteStale, noteId: id, title: 'Heaps');
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AutomationLog(service: s, rule: rule))));
    expect(find.text('What this rule did'), findsOneWidget);
    expect(find.text('Heaps'), findsOneWidget);
    expect(find.textContaining('Tagged the note "old"'), findsOneWidget);
    final undo = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('log-undo-'));
    expect(undo, findsOneWidget);
    await tester.tap(undo);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(undo, findsNothing);
    expect(find.text('Taken back'), findsOneWidget);
    expect(await tester.runAsync(() => tags.tagsOf(id)), isEmpty);
    await tester.pumpWidget(const SizedBox());
    s.dispose();
  });

  testWidgets('a rule that has not run says so', (tester) async {
    late AutomationService s;
    await tester.runAsync(() async => s = await service());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AutomationLog(service: s, rule: const Automation(id: 'x', event: AutomationEvent.noteClosed, action: AutomationAction.starNote)))));
    expect(find.byKey(const ValueKey('log-empty')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    s.dispose();
  });
}
