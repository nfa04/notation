import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/ai/spaced_repetition.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final t0 = DateTime(2026, 3, 1, 20, 30);

  group('CardSchedule', () {
    test('a new card is due right away', () {
      expect(const CardSchedule().isDue(t0), isTrue);
    });

    test('good answers space the reviews further and further apart', () {
      var s = const CardSchedule().review(Recall.good, t0);
      expect(s.interval, 1);
      expect(s.due, DateTime(2026, 3, 2));
      s = s.review(Recall.good, s.due!);
      expect(s.interval, 6);
      s = s.review(Recall.good, s.due!);
      expect(s.interval, 15); // 6 * 2.5
      s = s.review(Recall.good, s.due!);
      expect(s.interval, 38);
    });

    test('forgetting sends the card back to short steps and costs ease', () {
      var s = const CardSchedule().review(Recall.good, t0);
      s = s.review(Recall.good, s.due!);
      final lapsed = s.review(Recall.again, s.due!);
      expect(lapsed.interval, 0);
      expect(lapsed.reps, 0);
      expect(lapsed.lapses, 1);
      expect(lapsed.ease, closeTo(2.3, 1e-9));
      expect(lapsed.due!.difference(s.due!), const Duration(minutes: 10));
    });

    test('failing a card that was never learned is no lapse', () {
      final s = const CardSchedule().review(Recall.again, t0);
      expect(s.lapses, 0);
      expect(s.ease, CardSchedule.startingEase);
    });

    test('hard grows slower than good and easy faster; ease never goes under the minimum', () {
      var s = const CardSchedule(interval: 10, reps: 3);
      expect(s.review(Recall.hard, t0).interval, 12);
      expect(s.review(Recall.good, t0).interval, 25);
      expect(s.review(Recall.easy, t0).interval, 33); // 10 * 2.5 * 1.3 = 32.5
      for (var i = 0; i < 20; i++) {
        s = s.review(Recall.hard, t0);
      }
      expect(s.ease, CardSchedule.minimumEase);
    });

    test('the buttons say when the card comes back', () {
      const s = CardSchedule();
      expect(s.previewLabel(Recall.again, t0), '10 min');
      expect(s.previewLabel(Recall.good, t0), '1 d');
      expect(s.previewLabel(Recall.easy, t0), '4 d');
      expect(const CardSchedule(interval: 100, reps: 5).previewLabel(Recall.good, t0), '8 mo');
    });
  });

  group('CardRepository', () {
    late Database db;
    late CardRepository cards;

    setUpAll(AppDatabase.initFfi);
    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      cards = CardRepository(db);
    });
    tearDown(() => db.close());

    test('cards are due when added, once, and the same question is not added twice', () async {
      expect(await cards.addAll('n1', const [Flashcard('Q1', 'A1', page: 2), Flashcard('Q2', 'A2')], now: t0), 2);
      expect(await cards.addAll('n1', const [Flashcard('Q1', 'other', page: 2), Flashcard('Q3', 'A3')], now: t0), 1);
      expect(await cards.addAll('n2', const [Flashcard('Q1', 'A1')], now: t0), 1); // another note: another card
      expect(await cards.count(), 4);
      expect(await cards.dueCount(now: t0), 4);
      expect(await cards.dueCount(now: t0, source: 'n1'), 3);
      final due = await cards.due(now: t0, source: 'n1');
      expect(due.map((c) => c.card.front), ['Q1', 'Q2', 'Q3']);
      expect(due.first.card.page, 2);
      expect(due.first.card.back, 'A1'); // the first version is kept
    });

    test('a reviewed card leaves the due list until its day comes', () async {
      await cards.addAll('n1', const [Flashcard('Q1', 'A1'), Flashcard('Q2', 'A2')], now: t0);
      final first = (await cards.due(now: t0)).first;
      final next = await cards.review(first, Recall.good, now: t0);
      expect(next.due, DateTime(2026, 3, 2));
      expect((await cards.due(now: t0)).map((c) => c.card.front), ['Q2']);
      expect(await cards.dueCount(now: DateTime(2026, 3, 2)), 2);
      final again = (await cards.due(now: DateTime(2026, 3, 2))).firstWhere((c) => c.id == first.id);
      expect(again.schedule.reps, 1);
      expect(again.schedule.interval, 1);
    });

    test('cards can be removed one by one or by source', () async {
      await cards.addAll('n1', const [Flashcard('Q1', 'A1'), Flashcard('Q2', 'A2')], now: t0);
      await cards.addAll('n2', const [Flashcard('Q9', 'A9')], now: t0);
      await cards.remove(CardRepository.idOf('n1', 'Q1'));
      expect(await cards.count(source: 'n1'), 1);
      await cards.removeSource('n1');
      expect(await cards.count(), 1);
    });

    test('cards that come with a schedule keep it, and the same card is not added twice', () async {
      final due = DateTime(2026, 3, 10);
      final n = await cards.addScheduled('anki:Algorithms', [
        (const Flashcard('New', 'n'), const CardSchedule()),
        (const Flashcard('Old', 'o'), CardSchedule(interval: 12, ease: 2.1, reps: 4, lapses: 2, due: due)),
      ], now: t0);
      expect(n, 2);
      final all = await cards.all(source: 'anki:Algorithms');
      final old = all.firstWhere((c) => c.card.front == 'Old').schedule;
      expect([old.interval, old.ease, old.reps, old.lapses, old.due], [12, 2.1, 4, 2, due]);
      expect(await cards.dueCount(now: t0, source: 'anki:Algorithms'), 1, reason: 'only the new card is due');
      final stats = await cards.stats(source: 'anki:Algorithms', now: t0);
      expect([stats.unseen, stats.seen], [1, 1]);
      expect(await cards.addScheduled('anki:Algorithms', [(const Flashcard('Old', 'o'), const CardSchedule())], now: t0), 0);
    });
  });
}
