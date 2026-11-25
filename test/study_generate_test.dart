import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/graph/study.dart';
import 'package:notes/review/study_generate.dart';
import 'package:notes/review/study_material.dart';
import 'package:notes/review/study_planner.dart';
import 'package:notes/review/study_practice.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_study_calendar.dart';
import 'support/fake_model.dart';

void main() {
  group('how much is made', () {
    test('a part with hardly any words gets nothing; more words mean more points and cards', () {
      expect(materialBudget(words: 30, learnMinutes: 10, reviewMinutes: 5, minutesAvailable: 600), (points: 0, cards: 0));
      final small = materialBudget(words: 300, learnMinutes: 20, reviewMinutes: 8, minutesAvailable: 90);
      final big = materialBudget(words: 1500, learnMinutes: 20, reviewMinutes: 8, minutesAvailable: 90);
      expect(big.points, greaterThan(small.points));
      expect(big.cards, greaterThan(small.cards));
    });

    test('little time means a short summary and a few cards, a lot of time means more of both', () {
      final tight = materialBudget(words: 1200, learnMinutes: 40, reviewMinutes: 15, minutesAvailable: 30);
      final normal = materialBudget(words: 1200, learnMinutes: 40, reviewMinutes: 15, minutesAvailable: 90);
      final plenty = materialBudget(words: 1200, learnMinutes: 40, reviewMinutes: 15, minutesAvailable: 400);
      expect(tight.cards, lessThanOrEqualTo(4));
      expect(tight.points, lessThan(normal.points));
      expect(plenty.points, greaterThan(normal.points));
      expect(plenty.cards, greaterThan(normal.cards));
    });

    test('the cards are no more than can be gone over three times in the time after the first going-through', () {
      // 100 minutes available, 80 for learning: 20 spare minutes = 1200 s = 20 cards x 3 times at 20 s
      final b = materialBudget(words: 3000, learnMinutes: 80, reviewMinutes: 20, minutesAvailable: 100);
      expect(b.cards, 20);
      expect(materialBudget(words: 3000, learnMinutes: 80, reviewMinutes: 20, minutesAvailable: 0).cards, 3, reason: 'a few at least');
    });

    test('the time to the exam is shared by the parts in proportion to their learning time, without the days off', () {
      // Monday 1 June to Friday 5 June: Monday-Thursday are study days, Wednesday is off: 3 days of 120 minutes
      final s = shareMinutes(today: DateTime(2026, 6, 1, 9), exam: DateTime(2026, 6, 5), daysOff: {3}, perDay: 180, windowMinutes: 120, weights: {'a': 30, 'b': 90});
      expect(s, {'a': 90, 'b': 270});
      expect(shareMinutes(today: DateTime(2026, 6, 5), exam: DateTime(2026, 6, 5), daysOff: {}, perDay: 60, windowMinutes: 60, weights: {'a': 1}), {'a': 0}, reason: 'no day left');
    });
  });

  group('what the model wrote', () {
    test('the points of a summary are the bulleted or numbered lines, a line that goes on joins its point, introductions are left out', () {
      const reply = 'Here is the summary:\n- The cell is the unit of life.\n* Membranes are made of **lipids**\n  and proteins.\n3. Mitochondria make ATP.\n';
      expect(parseSummaryPoints(reply), ['The cell is the unit of life.', 'Membranes are made of lipids and proteins.', 'Mitochondria make ATP.']);
      expect(parseSummaryPoints(reply, max: 2).length, 2);
    });

    test('a reply without bullets gives its sentences', () {
      expect(parseSummaryPoints('The cell is the unit of life. Mitochondria make the energy of the cell.'), ['The cell is the unit of life.', 'Mitochondria make the energy of the cell.']);
      expect(parseSummaryPoints(''), isEmpty);
    });

    test('the request names how many points and asks for the language of the text', () {
      final p = summaryPrompt('Text', 7);
      expect(p.system, contains('exactly 7 points'));
      expect(p.system, contains('language of the text'));
    });
  });

  group('the text of a part of a document', () {
    const doc = 'Before the headings there is some introduction.\n# One\nfirst text\n# Two\nsecond text\n';
    test('a part is what is under its heading; anything else of a document with headings is its start', () {
      expect(textOfSection(doc, 'Two').trim(), 'second text');
      expect(textOfSection(doc, 'One').trim(), 'first text');
      expect(textOfSection(doc, 'Notes').trim(), 'Before the headings there is some introduction.');
    });

    test('the even parts of a text without headings', () {
      final text = [for (var i = 0; i < 90; i++) 'w$i'].join(' ');
      expect(textOfSection(text, 'Notes (2/3)').split(' ').first, 'w30');
      expect(textOfSection(text, 'Notes (3/3)').split(' ').last, 'w89');
      expect(textOfSection(text, 'Notes'), text);
    });
  });

  test('what was made is kept in the plan as it is written, and a part that has none is not in it', () {
    final e = StudyPlanEntry(
      id: 'p',
      name: 'x',
      exam: DateTime(2026, 6, 12),
      units: const [StudyUnit(id: 'u', noteId: 'n', title: 'U', minutes: 10)],
      material: const {'u': UnitMaterial(points: ['One.', 'Two.'], cards: 5)},
    );
    final back = StudyPlanEntry.fromJson(e.toJson())!;
    expect(back.material['u'], const UnitMaterial(points: ['One.', 'Two.'], cards: 5));
    expect(StudyPlanEntry.fromJson(e.copyWith(material: const {}).toJson())!.material, isEmpty);
    expect(UnitMaterial.fromJson({'p': <String>[], 'c': 0}), isNull);
  });

  group('making it for a plan', () {
    setUpAll(AppDatabase.initFfi);
    late Database db;
    late CardRepository cards;
    late StudyPlanner planner;
    late FakeModel model;
    late _Facts facts;
    final now = DateTime(2026, 6, 1, 8);
    final long = List.filled(260, 'cells').join(' ');
    final texts = <int, String>{for (var p = 0; p < 12; p++) p: 'Page ${p + 1} of the notes. $long'};

    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['settings', 'tasks', 'review_cards']) {
        await db.delete(t);
      }
      cards = CardRepository(db);
      model = FakeModel()
        ..respond = (p) => p.system.contains('flashcards')
            ? 'Q: What is a cell?\nA: The unit of life.\nPage: 2\n\nQ: What makes ATP?\nA: Mitochondria.\nPage: 99\n\nQ: What is a membrane?\nA: A barrier.'
            : '- A cell is the unit of life.\n- Mitochondria make ATP.\n- A membrane is a barrier of lipids.';
      planner = StudyPlanner(SettingsRepository(db), cards, TaskRepository(db), calendar: FakeStudyCalendar(), now: () => now);
      await planner.load();
      planner.maker = StudyMaterialMaker(pageTexts: (_) async => texts, documentText: (_) async => '', model: () => model, enabled: () => true);
      facts = _Facts();
      planner.facts = facts;
    });
    tearDown(() => planner.dispose());

    StudyPlanEntry draft() => planner.draft(name: 'Bio', exam: DateTime(2026, 6, 12)).copyWith(
          units: const [
            StudyUnit(id: 'n#0', noteId: 'n', title: 'Cells', fromPage: 0, toPage: 5, minutes: 30),
            StudyUnit(id: 'n#1', noteId: 'n', title: 'Blank', fromPage: 20, toPage: 22, minutes: 12),
          ],
        );

    test('a part with text gets a summary and cards (the card page is kept when it is in the part, else the first page of the part); a part with no text is skipped', () async {
      final r = await planner.makeMaterial(draft());
      expect(r.units, 1);
      expect(r.skipped, 1);
      final m = r.entry.material['n#0']!;
      expect(m.points.length, 3);
      expect(m.cards, 3);
      expect(r.entry.material.containsKey('n#1'), isFalse);
      final kept = await cards.all(source: 'n');
      expect({for (final c in kept) c.card.front: c.card.page}, {'What is a cell?': 1, 'What makes ATP?': 0, 'What is a membrane?': 0});
      expect(r.cards, 3);
      final passages = model.prompts.first.user;
      expect(passages, contains('[Page 1]'));
      expect(passages, contains('[Page 6]'));
      expect(passages, isNot(contains('[Page 7]')));
    });

    test('what has a summary already is not made again, unless asked', () async {
      final first = await planner.makeMaterial(draft());
      final asked = model.prompts.length;
      // (only the part without text is left: nothing can be made of it, and the model is not asked)
      await expectLater(planner.makeMaterial(first.entry), throwsA(predicate((e) => '$e'.contains('too little text'))));
      expect(model.prompts.length, asked);
      final done = await planner.makeMaterial(first.entry.copyWith(units: [first.entry.units.first]));
      expect((done.units, done.skipped), (0, 0), reason: 'nothing left to make');
      expect(model.prompts.length, asked);
      final again = await planner.makeMaterial(first.entry, again: true);
      expect(again.units, 1);
      expect(again.cards, 0, reason: 'the same cards are not kept twice');
      expect((await cards.all(source: 'n')).length, 3);
    });

    test('less time to the exam gives fewer cards (the request says how many)', () async {
      Future<int> cardsAsked(DateTime exam) async {
        model.prompts.clear();
        await planner.makeMaterial(draft().copyWith(exam: exam, units: const [StudyUnit(id: 'n#0', noteId: 'n', title: 'Cells', fromPage: 0, toPage: 5, minutes: 200)]));
        return int.parse(RegExp(r'Make (\d+) flashcards').firstMatch(model.prompts.firstWhere((p) => p.system.contains('flashcards')).user)!.group(1)!);
      }

      final near = await cardsAsked(DateTime(2026, 6, 2)), far = await cardsAsked(DateTime(2026, 6, 20));
      expect(near, lessThan(far));
      expect(near, lessThanOrEqualTo(4));
    });

    test('a summary with enough points makes a quiz possible, and the points are its facts; without a model nothing is made', () async {
      final r = await planner.makeMaterial(draft());
      final u = r.entry.units.first;
      final f = await planner.factsOf(u, material: r.entry.material[u.id]);
      expect(f.map((x) => x.sentence), ['A cell is the unit of life.', 'Mitochondria make ATP.', 'A membrane is a barrier of lipids.']);
      expect(f.first.title, 'Cells');
      facts.ready = false;
      expect(await planner.factsOf(u, material: r.entry.material[u.id]), isEmpty);
      final p = await planner.propose(r.entry.copyWith(cardSources: () => const {}));
      expect(p.sessions, isNotEmpty);
      model.current = ProviderStateForTest.notReady;
      expect(planner.canMakeMaterial, isFalse);
      await expectLater(planner.makeMaterial(draft()), throwsA(isA<StateError>()));
    });

    test('stopped part of the way, what was made is kept and nothing more is asked', () async {
      final cancel = AiCancel();
      model.respond = (p) {
        cancel.cancel();
        return '- One.\n- Two.\n- Three.';
      };
      final r = await planner.makeMaterial(draft(), cancel: cancel);
      expect(r.entry.material, isEmpty, reason: 'cancelled while the first answer came');
      expect(model.prompts.length, 1);
    });

    test('when nothing has been read of any part, it is said why', () async {
      planner.maker = StudyMaterialMaker(pageTexts: (_) async => const {}, documentText: (_) async => '', model: () => model, enabled: () => true);
      await expectLater(planner.makeMaterial(draft()), throwsA(predicate((e) => '$e'.contains('too little text'))));
      expect(model.prompts, isEmpty);
    });
  });
}

class _Facts implements StudyFactSource {
  bool ready = true;

  @override
  bool get canQuiz => ready;

  @override
  Future<List<FactSpot>> facts() async => const [];

  @override
  Future<void> quiz(BuildContext context, String title, List<StudyFact> facts, {CardRepository? cards}) async {}
}
