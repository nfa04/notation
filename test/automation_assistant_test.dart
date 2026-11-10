import 'package:flutter/painting.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_model.dart';

const _cards = '''
Q: What does the swim function do?
A: It restores the heap property after an insertion.

Q: Why is a heap useful for a priority queue?
A: The largest item is always at the root.
''';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository notes;
  late TaskRepository tasks;
  late CardRepository cards;
  late FakeModel model;
  late AiService ai;
  var now = DateTime(2026, 3, 1, 9);

  setUp(() async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    for (final t in ['settings', 'tasks', 'notes', 'folders', 'review_cards', 'text_boxes']) {
      await db.delete(t);
    }
    notes = NoteRepository(db);
    tasks = TaskRepository(db);
    cards = CardRepository(db);
    model = FakeModel(_cards);
    ai = AiService(providers: [model]);
    now = DateTime(2026, 3, 1, 9);
  });

  Future<String> noteWithText(String title, String text) async {
    final id = await notes.createNote(title: title);
    await notes.putTextBox(id, 0, TextBoxWidgetModel(id: 'b', position: Offset.zero, size: const Size(100, 0), initialText: text));
    return id;
  }

  Future<AutomationService> service() async {
    final s = AutomationService(notes, tasks, now: () => now, ai: ai, cards: cards);
    await s.load();
    return s;
  }

  const longText = 'A binary heap keeps its largest item at the root. The swim function restores the heap property after an insertion by '
      'exchanging a node with its parent while it is larger. A heap is therefore a good base for a priority queue.';

  group('flashcards from a note', () {
    test('the closed note is read, the cards are kept for review with the note as their source', () async {
      final id = await noteWithText('Heaps', longText);
      final s = await service();
      await s.add(const Automation(id: 'c', event: AutomationEvent.noteClosed, action: AutomationAction.makeFlashcards, params: {'count': '5'}));
      final results = await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps');
      expect(results.single, contains('background'));
      await s.assistantDone;
      expect(await cards.count(source: id), 2);
      expect((await cards.due(now: now, source: id)).map((c) => c.card.front), contains('What does the swim function do?'));
      expect(model.prompts.single.user, contains('swim function'));
      expect(s.all.single.lastResult, contains('Kept 2 new flashcards'));
      s.dispose();
    });

    test('the same note again adds nothing twice', () async {
      final id = await noteWithText('Heaps', longText);
      final s = await service();
      await s.add(const Automation(id: 'c', event: AutomationEvent.noteStale, action: AutomationAction.makeFlashcards));
      for (var i = 0; i < 2; i++) {
        await s.run(AutomationEvent.noteStale, noteId: id, title: 'Heaps');
        await s.assistantDone;
      }
      expect(await cards.count(source: id), 2);
      expect(s.all.single.lastResult, contains('kept already'));
      s.dispose();
    });

    test('a note with hardly any text is left alone and the model is not asked', () async {
      final id = await noteWithText('Tiny', 'milk');
      final s = await service();
      await s.add(const Automation(id: 'c', event: AutomationEvent.noteClosed, action: AutomationAction.makeFlashcards));
      await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Tiny');
      await s.assistantDone;
      expect(model.prompts, isEmpty);
      expect(s.all.single.lastResult, contains('Too little text'));
      s.dispose();
    });

    test('without a ready assistant it says so at once and does nothing', () async {
      final id = await noteWithText('Heaps', longText);
      model.current = ProviderState.needsDownload;
      final s = await service();
      await s.add(const Automation(id: 'c', event: AutomationEvent.noteClosed, action: AutomationAction.makeFlashcards));
      final results = await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps');
      expect(results.single, contains('not ready'));
      expect(await cards.count(), 0);
      s.dispose();
    });

    test('an answer that holds no cards is reported, and the failure does not stop the queue', () async {
      final id = await noteWithText('Heaps', longText);
      model.answer = 'Sorry, I cannot do that.';
      final s = await service();
      await s.add(const Automation(id: 'c', event: AutomationEvent.noteClosed, action: AutomationAction.makeFlashcards));
      await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps');
      await s.assistantDone;
      expect(s.all.single.lastResult, contains('did not make any flashcards'));
      s.dispose();
    });

    test('it works after closing and going stale, not after the app starts', () {
      expect(AutomationAction.makeFlashcards.worksAfter(AutomationEvent.noteClosed), isTrue);
      expect(AutomationAction.makeFlashcards.worksAfter(AutomationEvent.noteStale), isTrue);
      expect(AutomationAction.makeFlashcards.worksAfter(AutomationEvent.appStarted), isFalse);
      expect(AutomationAction.makeFlashcards.worksAfter(AutomationEvent.noteCreated), isFalse);
    });
  });

  group('a task when flashcards are due', () {
    test('one task a day with the number of due cards, none when nothing is due', () async {
      final s = await service();
      await s.add(const Automation(id: 'd', event: AutomationEvent.appStarted, action: AutomationAction.reviewCardsTask));
      expect((await s.run(AutomationEvent.appStarted)).single, 'No flashcards are due');
      await cards.addAll('n', const [Flashcard('a?', 'b'), Flashcard('c?', 'd')], now: now);
      expect((await s.run(AutomationEvent.appStarted)).single, contains('Review 2 flashcards'));
      expect((await s.run(AutomationEvent.appStarted)).single, contains('there already'));
      expect((await tasks.listTasks()).where((t) => t.title == 'Review 2 flashcards'), hasLength(1));
      now = DateTime(2026, 3, 2, 9);
      await s.run(AutomationEvent.appStarted);
      expect((await tasks.listTasks()).where((t) => t.title == 'Review 2 flashcards'), hasLength(2));
      s.dispose();
    });
  });
}
