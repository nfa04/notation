import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/reminder_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/reminders/notification_sink.dart';
import 'package:notes/reminders/reminder.dart';
import 'package:notes/reminders/reminder_service.dart';
import 'package:notes/screens/ask_card.dart';
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

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository notes;
  late TaskRepository tasks;
  late ReminderService reminders;
  late CardRepository cards;
  late FakeModel model;
  var now = DateTime(2026, 5, 4, 10);

  setUp(() async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    for (final t in ['settings', 'tasks', 'notes', 'folders', 'text_boxes', 'reminders', 'review_cards']) {
      await db.delete(t);
    }
    notes = NoteRepository(db);
    tasks = TaskRepository(db);
    cards = CardRepository(db);
    reminders = ReminderService(reminders: ReminderRepository(db), sink: _Sink(), read: (k) async => null, write: (k, v) async {}, clock: () => now);
    model = FakeModel('Q: What is a heap?\nA: A tree that keeps its largest item at the root.');
    now = DateTime(2026, 5, 4, 10);
  });

  Future<AutomationService> service({bool assistant = true}) async {
    final s = AutomationService(notes, tasks, now: () => now, ai: assistant ? AiService(providers: [model]) : null, cards: assistant ? cards : null, reminders: reminders);
    await s.load();
    await s.add(const Automation(id: 'a', event: AutomationEvent.noteStale, action: AutomationAction.askAboutNote, params: {'weeks': '4'}));
    return s;
  }

  group('asking', () {
    test('a stale note is put on the list once, and the list is there after a restart', () async {
      final id = await notes.createNote(title: 'Old course');
      await notes.markOpened(id, at: DateTime(2026, 3, 1));
      final s = await service();
      expect(await s.checkStale(), 1);
      expect(s.asking.map((a) => a.noteId), [id]);
      expect(s.asking.single.reason, 'A note has not been opened for a while');
      expect(await s.run(AutomationEvent.noteStale, noteId: id, title: 'Old course'), ['It is on the dashboard already']);
      expect(s.asking, hasLength(1));
      s.dispose();

      final again = AutomationService(notes, tasks, now: () => now);
      await again.load();
      expect(again.asking.single.noteId, id);
      again.dispose();
    });

    test('keep: it counts as opened and the question goes; it is not asked about again until it goes stale again', () async {
      final id = await notes.createNote(title: 'Old course');
      await notes.markOpened(id, at: DateTime(2026, 3, 1));
      final s = await service();
      await s.checkStale();
      expect(await s.answer(id, AskAnswer.keep), 'Kept');
      expect(s.asking, isEmpty);
      expect(await s.checkStale(), 0, reason: 'opened just now');
      s.dispose();
    });

    test('archive: into the folder Archive, made if it is not there and used if it is', () async {
      final a = await notes.createNote(title: 'One');
      final b = await notes.createNote(title: 'Two');
      final s = await service();
      await s.run(AutomationEvent.noteStale, noteId: a, title: 'One');
      await s.run(AutomationEvent.noteStale, noteId: b, title: 'Two');
      await s.answer(a, AskAnswer.archive);
      await s.answer(b, AskAnswer.archive);
      final folders = await notes.listFolders();
      expect(folders.where((f) => f.name == 'Archive'), hasLength(1));
      expect((await notes.noteInfo(a))!.folderId, folders.firstWhere((f) => f.name == 'Archive').id);
      expect((await notes.noteInfo(b))!.folderId, (await notes.noteInfo(a))!.folderId);
      expect(s.asking, isEmpty);
      s.dispose();
    });

    test('remind: a reminder for the note in a week at nine', () async {
      final id = await notes.createNote(title: 'Old course');
      final s = await service();
      await s.run(AutomationEvent.noteStale, noteId: id, title: 'Old course');
      expect(await s.answer(id, AskAnswer.remind), 'You will be reminded in a week');
      final r = (await reminders.reminders.all()).single;
      expect((r.kind, r.refId, r.title, r.at), (ReminderKind.note, id, 'Old course', DateTime(2026, 5, 11, 9)));
      s.dispose();
    });

    test('cards: the assistant makes flashcards in the background and the dashboard is told; without it the answer is not offered', () async {
      final id = await notes.createNote(title: 'Heaps');
      await notes.putTextBox(id, 0, await _box('A heap is a tree that keeps its largest item at the root, so the biggest value is always found first. Inserting an item makes it swim up.'));
      final s = await service();
      expect(s.canAskForCards, isTrue);
      await s.run(AutomationEvent.noteStale, noteId: id, title: 'Heaps');
      expect(await s.answer(id, AskAnswer.cards), contains('background'));
      await s.assistantDone;
      expect(await cards.count(source: id), 1);
      expect(s.askNotice, 'Kept 1 new flashcard');
      s.dispose();

      final plain = await service(assistant: false);
      expect(plain.canAskForCards, isFalse);
      plain.dispose();
    });

    test('not now: the question goes and nothing else changes', () async {
      final id = await notes.createNote(title: 'Old course');
      final s = await service();
      await s.run(AutomationEvent.noteStale, noteId: id, title: 'Old course');
      expect(await s.answer(id, AskAnswer.later), 'Left as it is');
      expect(s.asking, isEmpty);
      expect((await notes.noteInfo(id))!.folderId, isNull);
      s.dispose();
    });
  });

  group('on the dashboard', () {
    testWidgets('the notes asked about are listed with the answers; an answer is carried out and the card goes when nothing is left', (tester) async {
      late AutomationService s;
      late String id;
      await tester.runAsync(() async {
        id = await notes.createNote(title: 'Old course');
        s = await service();
        await s.run(AutomationEvent.noteStale, noteId: id, title: 'Old course');
      });
      final opened = <String>[];
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: AskCard(service: s, repository: notes, onOpenNote: opened.add)))));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(find.byKey(const ValueKey('ask-card')), findsOneWidget);
      expect(find.text('Still relevant?'), findsOneWidget);
      expect(find.text('Old course'), findsOneWidget);
      expect(find.byKey(ValueKey('ask-cards-$id')), findsOneWidget);

      await tester.tap(find.text('Old course'));
      expect(opened, [id]);

      await tester.tap(find.byKey(ValueKey('ask-keep-$id')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(find.byKey(const ValueKey('ask-card')), findsNothing);
      expect(find.text('Kept'), findsOneWidget, reason: 'what was done is said');
      await tester.pumpWidget(const SizedBox());
      s.dispose();
    });

    testWidgets('without the assistant the flashcards answer is not offered, and with nothing asked there is no card', (tester) async {
      late AutomationService s;
      late String id;
      await tester.runAsync(() async {
        id = await notes.createNote(title: 'Old course');
        s = await service(assistant: false);
      });
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: AskCard(service: s, repository: notes, onOpenNote: (_) {}))));
      expect(find.byKey(const ValueKey('ask-card')), findsNothing);
      await tester.runAsync(() => s.run(AutomationEvent.noteStale, noteId: id, title: 'Old course'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(find.byKey(const ValueKey('ask-card')), findsOneWidget);
      expect(find.byKey(ValueKey('ask-cards-$id')), findsNothing);
      expect(find.byKey(ValueKey('ask-archive-$id')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      s.dispose();
    });
  });
}

Future<TextBoxWidgetModel> _box(String text) async => TextBoxWidgetModel(id: 'b', position: Offset.zero, size: const Size(300, 60), initialText: text);
