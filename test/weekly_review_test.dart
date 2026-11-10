import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/review/weekly_review.dart';
import 'package:notes/review/weekly_review_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Writer extends ChangeNotifier implements TextModelProvider {
  _Writer(this.answer, {this.fail = false, this.script = const []});
  final String answer;

  /// Answered in turn before [answer]: what the model writes, round by round.
  final List<String Function(AiPrompt prompt)> script;
  final bool fail;
  final prompts = <AiPrompt>[];

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
  Future<String> complete(AiPrompt prompt, {int maxTokens = 256, void Function(String partial)? onPartial, AiCancel? cancel}) async {
    prompts.add(prompt);
    if (fail) throw StateError('no answer');
    final i = prompts.length - 1;
    return i < script.length ? script[i](prompt) : answer;
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the week', () {
    test('a week starts on Monday', () {
      expect(weekStart(DateTime(2026, 10, 28, 15)), DateTime(2026, 10, 26)); // a Wednesday
      expect(weekStart(DateTime(2026, 11, 1)), DateTime(2026, 10, 26)); // the Sunday after
      expect(weekStart(DateTime(2026, 10, 26)), DateTime(2026, 10, 26));
      expect(weekStart(DateTime(2026, 3, 2, 23, 59)), DateTime(2026, 3, 2));
    });

    test('older notes that talk about the same things are found, the one with most in common first', () {
      const mine = [
        ReviewFact(noteId: 'a', title: 'x', tag: 'Fact', sentence: 's', keywords: ['entropy', 'heat', 'engine']),
      ];
      final older = {
        'o1': [const ReviewFact(noteId: 'o1', title: 'x', tag: 'Fact', sentence: 's', keywords: ['entropy', 'heat', 'engine', 'carnot'])],
        'o2': [const ReviewFact(noteId: 'o2', title: 'x', tag: 'Fact', sentence: 's', keywords: ['entropy', 'heat'])],
        'o3': [const ReviewFact(noteId: 'o3', title: 'x', tag: 'Fact', sentence: 's', keywords: ['entropy'])], // only one word: not enough
        'o4': [const ReviewFact(noteId: 'o4', title: 'x', tag: 'Fact', sentence: 's', keywords: ['ab', 'cd'])],
      };
      final notes = {for (final id in older.keys) id: ReviewNote(id, 'Note $id', DateTime(2026, 1, 1))};
      final found = relatedOlderNotes(mine, older, notes);
      expect(found.map((r) => r.note.id), ['o1', 'o2']);
      expect(found.first.shared, containsAll(['entropy', 'heat', 'engine']));
    });
  });

  group('the digest', () {
    final from = DateTime(2026, 10, 26);
    final data = WeekReviewData(
      from: from,
      to: DateTime(2026, 11, 2),
      notes: [ReviewNote('n1', 'Thermodynamics', DateTime(2026, 10, 27, 9, 30), isNew: true), ReviewNote('n2', 'Lab [report]', DateTime(2026, 10, 29, 14))],
      facts: const [
        ReviewFact(noteId: 'n1', title: 'Entropy', tag: 'Fact', sentence: 'Heat flows from hot to cold.'),
        ReviewFact(noteId: 'n1', title: 'Entropy', tag: 'Definition', sentence: 'Entropy measures disorder.'),
      ],
      done: [ReviewTask('Hand in report', doneAt: DateTime(2026, 10, 28))],
      open: [ReviewTask('Read chapter 4', due: DateTime(2026, 10, 30)), const ReviewTask('Tidy desk')],
      dueNextWeek: [ReviewTask('Exam', due: DateTime(2026, 11, 3))],
      nextWeek: [ReviewEvent('Lecture', DateTime(2026, 11, 3, 10, 15)), ReviewEvent('Holiday', DateTime(2026, 11, 5), allDay: true)],
      related: [RelatedNote(ReviewNote('o1', 'Carnot engines', DateTime(2026, 8, 1)), const ['entropy', 'heat'])],
      cardsDue: 12,
    );

    test('the digest has a section for each part of the week, with notes as links', () {
      final md = reviewMarkdown(data, summary: 'You worked on heat.', plan: '- Revise entropy');
      expect(md, startsWith('# Weekly review 2026-10-26 to 2026-11-01\n'));
      expect(md, contains('## The week in short\n\nYou worked on heat.'));
      expect(md, contains('2 notes were written or changed, 1 of them new.'));
      expect(md, contains('- [Thermodynamics](note:n1) (new, Tue 27.10. 09:30)'));
      expect(md, contains('- [Lab (report)](note:n2) (Thu 29.10. 14:00)')); // brackets in a title would break the link
      expect(md, contains('- [x] Hand in report'));
      expect(md, contains('- [ ] Read chapter 4 (was due Fri 30.10.)'));
      expect(md, contains('- [ ] Tidy desk\n'));
      expect(md, contains('- [ ] Exam (Tue 03.11.)'));
      expect(md, contains('- Tue 03.11. 10:15: Lecture'));
      expect(md, contains('- Thu 05.11.: Holiday'));
      expect(md, contains('- Revise entropy'));
      expect(md, contains('- [Carnot engines](note:o1) (entropy, heat)'));
      expect(md, contains('12 flashcards are due for review.'));
    });

    test('what the notes say lists definitions first, per note', () {
      final md = reviewMarkdown(data);
      final at = md.indexOf('**[Thermodynamics](note:n1)**');
      expect(at, greaterThan(0));
      expect(md.indexOf('Entropy measures disorder.'), lessThan(md.indexOf('Heat flows from hot to cold.')));
    });

    test('without a summary and with nothing in a part, those sections are left out', () {
      final md = reviewMarkdown(WeekReviewData(from: from, to: DateTime(2026, 11, 2), notes: [ReviewNote('n1', 'Only note', DateTime(2026, 10, 27))]));
      expect(md, isNot(contains('The week in short')));
      expect(md, isNot(contains('## Tasks')));
      expect(md, isNot(contains('## Next week')));
      expect(md, isNot(contains('## Study')));
      expect(md, contains('1 note was written or changed.'));
      expect(reviewMarkdown(WeekReviewData(from: from, to: DateTime(2026, 11, 2))), contains('Nothing was written'));
    });

    test('the request for the assistant carries the week and asks for a summary and "Next week:"', () {
      final p = reviewPrompt(data);
      expect(p.user, contains('Thermodynamics (new)'));
      expect(p.user, contains('Heat flows from hot to cold.'));
      expect(p.user, contains('Tasks still open: Read chapter 4; Tidy desk'));
      expect(p.user, contains('Events next week: Lecture; Holiday'));
      expect(p.system, contains('Next week:'));
    });

    test('the answer is split into the summary and the suggestions', () {
      var r = parseReviewAnswer('You wrote a lot about heat.\n\nNext week:\n- Read chapter 4\n- Prepare the exam');
      expect(r.summary, 'You wrote a lot about heat.');
      expect(r.plan, '- Read chapter 4\n- Prepare the exam');
      r = parseReviewAnswer('Summary only.');
      expect(r.summary, 'Summary only.');
      expect(r.plan, isNull);
      r = parseReviewAnswer('<think>hm</think>Short.\n**Next week:**\n- One');
      expect(r.summary, 'Short.');
      expect(r.plan, '- One');
      r = parseReviewAnswer('');
      expect(r.summary, isNull);
    });
  });

  group('WeeklyReviewService', () {
    late Database db;
    late NoteRepository notes;
    late TaskRepository tasks;
    late CardRepository cards;
    final now = DateTime(2026, 10, 29, 12); // a Thursday

    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      // (an in-memory database is shared between the tests of a file: start from nothing)
      for (final t in ['notes', 'tasks', 'review_cards', 'folders', 'facts']) {
        await db.delete(t);
      }
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
      cards = CardRepository(db);
    });
    tearDown(() => db.close());

    Future<String> note(String title, DateTime created, DateTime edited, {String text = ''}) async {
      final id = await notes.createNote(title: title);
      if (text.isNotEmpty) {
        final n = (await notes.loadNote(id))!..documentText = text;
        await notes.saveNote(n);
      }
      await notes.setTimes(id, created: created, edited: edited);
      return id;
    }

    Future<void> fact(String noteId, String sentence, List<String> keywords, {String tag = 'Fact'}) =>
        notes.knowledge.replaceFacts(noteId, 1, 'm', 'x', [StoredFact(noteId: noteId, title: 't', tag: tag, sentence: sentence, keywords: keywords)]);

    test('it gathers the notes of the week, their facts, the tasks, the week ahead and the cards', () async {
      final fresh = await note('Thermodynamics', DateTime(2026, 10, 27), DateTime(2026, 10, 28));
      final changed = await note('Old lab', DateTime(2026, 9, 1), DateTime(2026, 10, 29));
      final before = await note('Last week', DateTime(2026, 10, 20), DateTime(2026, 10, 21));
      final carnot = await note('Carnot engines', DateTime(2026, 8, 1), DateTime(2026, 8, 2));
      await fact(fresh, 'Entropy never decreases.', ['entropy', 'heat', 'engine']);
      await fact(carnot, 'A Carnot engine is ideal.', ['entropy', 'heat', 'carnot']);
      await fact(before, 'Unrelated.', ['pottery', 'clay']);

      final t1 = await tasks.createTask('Hand in report', dueDate: DateTime(2026, 10, 28));
      await tasks.setDone(t1, true);
      await db.update('tasks', {'done_at': DateTime(2026, 10, 28).millisecondsSinceEpoch}, where: 'id = ?', whereArgs: [t1]); // (the week here is fixed, the clock is not)
      await tasks.createTask('Read chapter 4', dueDate: DateTime(2026, 10, 30));
      await tasks.createTask('Tidy desk');
      await tasks.createTask('Exam', dueDate: DateTime(2026, 11, 4));
      await tasks.createTask('Far away', dueDate: DateTime(2026, 12, 24));
      final oldDone = await tasks.createTask('Done long ago');
      await tasks.setDone(oldDone, true);
      await db.update('tasks', {'done_at': DateTime(2026, 9, 1).millisecondsSinceEpoch}, where: 'id = ?', whereArgs: [oldDone]);
      await cards.addAll('n', const [Flashcard('Q1', 'A1'), Flashcard('Q2', 'A2')]);

      final service = WeeklyReviewService(
        repository: notes,
        tasks: tasks,
        cards: cards,
        events: (from, to) async {
          expect(from, DateTime(2026, 11, 2));
          expect(to, DateTime(2026, 11, 9));
          return [ReviewEvent('Lecture', DateTime(2026, 11, 3, 10))];
        },
        clock: () => now,
      );
      final d = await service.gather(now);
      expect(d.from, DateTime(2026, 10, 26));
      expect(d.to, DateTime(2026, 11, 2));
      expect(d.notes.map((n) => (n.title, n.isNew)), [('Thermodynamics', true), ('Old lab', false)]);
      expect(d.facts.map((f) => f.sentence), ['Entropy never decreases.']);
      expect(d.related.map((r) => r.note.title), ['Carnot engines']);
      expect(d.done.map((t) => t.title), ['Hand in report']);
      expect(d.open.map((t) => t.title), ['Read chapter 4', 'Tidy desk']); // dated first
      expect(d.dueNextWeek.map((t) => t.title), ['Exam']);
      expect(d.nextWeek.single.title, 'Lecture');
      expect(d.cardsDue, 2);
      expect(changed, isNotEmpty);
    });

    test('locked notes and reviews are not part of the week', () async {
      final secret = await note('Secret', DateTime(2026, 10, 27), DateTime(2026, 10, 28));
      await db.update('notes', {'lock_mode': 1}, where: 'id = ?', whereArgs: [secret]);
      final service = WeeklyReviewService(repository: notes, tasks: tasks, clock: () => now);
      await service.make(now, withAssistant: false);
      final again = await service.gather(now);
      expect(again.notes, isEmpty); // not the locked note, and not the review that was just made
    });

    test('a review is a note in the Reviews folder, made again (not twice) for the same week', () async {
      await note('Thermodynamics', DateTime(2026, 10, 27), DateTime(2026, 10, 28));
      final service = WeeklyReviewService(repository: notes, tasks: tasks, clock: () => now);
      final id = await service.make(now, withAssistant: false);
      final first = (await notes.loadNote(id))!;
      expect(first.title, 'Weekly review 2026-10-26 to 2026-11-01');
      expect(first.documentText, contains('[Thermodynamics](note:'));
      final folder = (await notes.listFolders()).singleWhere((f) => f.name == 'Reviews');
      expect((await notes.noteInfo(id))!.folderId, folder.id);
      expect(await service.existing(now), id);

      await note('Another note', DateTime(2026, 10, 30), DateTime(2026, 10, 30));
      expect(await service.make(now, withAssistant: false), id);
      expect((await notes.loadNote(id))!.documentText, contains('Another note'));
      expect((await notes.listNotes()).where((n) => n.title.startsWith('Weekly review')).length, 1);
      expect(await service.existing(DateTime(2026, 10, 19)), isNull); // the week before has none
    });

    test('the assistant adds a summary and suggestions; when it fails the review is made without them', () async {
      await note('Thermodynamics', DateTime(2026, 10, 27), DateTime(2026, 10, 28));
      final writer = _Writer('You studied heat.\nNext week:\n- Revise');
      final service = WeeklyReviewService(repository: notes, tasks: tasks, ai: AiService(providers: [writer]), clock: () => now);
      final statuses = <String>[];
      var id = await service.make(now, onStatus: statuses.add);
      var text = (await notes.loadNote(id))!.documentText;
      expect(text, contains('## The week in short\n\nYou studied heat.'));
      expect(text, contains('- Revise'));
      expect(writer.prompts.length, 1);
      expect(statuses, ['Gathering the week...', 'The assistant is reading the notes...']);
      expect(writer.prompts.single.user, contains('The review the app made:\n\n# Weekly review 2026-10-26 to 2026-11-01'));

      final failing = WeeklyReviewService(repository: notes, tasks: tasks, ai: AiService(providers: [_Writer('', fail: true)]), clock: () => now);
      id = await failing.make(now);
      text = (await notes.loadNote(id))!.documentText;
      expect(text, isNot(contains('The week in short')));
      expect(text, contains('Thermodynamics'));
    });

    test('an empty week is not sent to the assistant', () async {
      final writer = _Writer('x');
      final service = WeeklyReviewService(repository: notes, tasks: tasks, ai: AiService(providers: [writer]), clock: () => now);
      await service.make(now);
      expect(writer.prompts, isEmpty);
    });
    test('the assistant reads the notes behind the review before it writes', () async {
      final id = await note('Thermodynamics', DateTime(2026, 10, 27), DateTime(2026, 10, 28), text: 'Carnot cycle: the efficiency limit is 1 - Tc/Th.');
      final writer = _Writer('You worked out the [Carnot limit](note:$id).\nNext week:\n- Try the exercises', script: [
        (p) => '<tool>{"name":"notes.read","args":{"id":"$id"}}</tool>',
      ]);
      final service = WeeklyReviewService(repository: notes, tasks: tasks, ai: AiService(providers: [writer]), clock: () => now);
      final statuses = <String>[];
      final review = await service.make(now, onStatus: statuses.add);
      expect(writer.prompts.length, 2);
      expect(writer.prompts.first.user, contains('[Thermodynamics](note:$id)'));
      expect(writer.prompts.last.user, contains('efficiency limit is 1 - Tc/Th'));
      expect(statuses, contains('Read another note'));
      final text = (await notes.loadNote(review))!.documentText;
      expect(text, contains('## The week in short\n\nYou worked out the [Carnot limit](note:$id).'));
      expect(text, contains('- Try the exercises'));
    });

    test('the assistant of the review can only read: a call that would change something is not done', () async {
      final id = await note('Thermodynamics', DateTime(2026, 10, 27), DateTime(2026, 10, 28), text: 'Heat.');
      final writer = _Writer('A week of heat.', script: [
        (p) => '<tool>{"name":"notes.trash","args":{"id":"$id"}}</tool><tool>{"name":"tasks.add","args":{"title":"x"}}</tool>',
      ]);
      final service = WeeklyReviewService(repository: notes, tasks: tasks, ai: AiService(providers: [writer]), clock: () => now);
      await service.make(now);
      expect(writer.prompts.last.user, contains('there is no tool "notes.trash"'));
      expect(writer.prompts.last.user, contains('there is no tool "tasks.add"'));
      expect((await notes.listNotes()).where((n) => n.id == id), isNotEmpty);
      expect(await tasks.listTasks(), isEmpty);
    });

    test('an assistant that never stops calling tools leaves the summary to the short prompt', () async {
      final id = await note('Thermodynamics', DateTime(2026, 10, 27), DateTime(2026, 10, 28), text: 'Heat.');
      var n = 0;
      final writer = _Writer('Short summary.', script: [
        for (var i = 0; i < 8; i++) (p) => '<tool>{"name":"notes.search","args":{"query":"heat ${n++}"}}</tool>',
      ]);
      final service = WeeklyReviewService(repository: notes, tasks: tasks, ai: AiService(providers: [writer]), clock: () => now);
      final review = await service.make(now);
      expect(writer.prompts.length, 9);
      expect(writer.prompts.last.system, contains('Be warm and brief'));
      expect((await notes.loadNote(review))!.documentText, contains('Short summary.'));
      expect(id, isNotEmpty);
    });
    test('with the AI features turned off in the settings, nothing is sent to the assistant', () async {
      await note('Thermodynamics', DateTime(2026, 10, 27), DateTime(2026, 10, 28), text: 'Heat.');
      final writer = _Writer('x');
      var on = false;
      final service = WeeklyReviewService(repository: notes, tasks: tasks, ai: AiService(providers: [writer]), aiEnabled: () => on, clock: () => now);
      expect(service.assistantReady, isFalse);
      final id = await service.make(now);
      expect(writer.prompts, isEmpty);
      expect((await notes.loadNote(id))!.documentText, isNot(contains('The week in short')));
      on = true;
      expect(service.assistantReady, isTrue);
    });
  });
}
