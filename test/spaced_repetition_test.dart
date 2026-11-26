import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/ai/spaced_repetition.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final t0 = DateTime(2026, 3, 1, 20, 30);

  group('CardSchedule', () {
    test('a new card is due right away', () {
      expect(const CardSchedule().isDue(t0), isTrue);
    });

    test('good answers space the reviews further and further apart', () {
      var s = const CardSchedule().review(Recall.good, t0);
      expect(s.interval, 2);
      expect(s.due, DateTime(2026, 3, 3));
      final gaps = <double>[s.interval];
      for (var i = 0; i < 4; i++) {
        s = s.review(Recall.good, s.due!.add(const Duration(hours: 12)));
        gaps.add(s.interval);
      }
      for (var i = 1; i < gaps.length; i++) {
        expect(gaps[i], greaterThan(gaps[i - 1]), reason: '$gaps');
      }
    });

    test('forgetting sends the card back to short steps and makes it harder', () {
      var s = const CardSchedule().review(Recall.good, t0);
      s = s.review(Recall.good, s.due!.add(const Duration(hours: 12)));
      final lapsed = s.review(Recall.again, s.due!);
      expect(lapsed.interval, 0);
      expect(lapsed.reps, 0);
      expect(lapsed.lapses, 1);
      expect(lapsed.difficulty, greaterThan(s.difficulty!));
      expect(lapsed.stability, lessThan(s.stability!));
      expect(lapsed.due!.difference(s.due!), const Duration(minutes: 10));
    });

    test('failing a card that was never learned is no lapse', () {
      final s = const CardSchedule().review(Recall.again, t0);
      expect(s.lapses, 0);
      expect(s.reps, 0);
    });

    test('hard grows slower than good and easy faster; difficulty stays within 1 and 10', () {
      final s = CardSchedule(interval: 10, reps: 3, stability: 10, difficulty: 5, lastReview: t0.subtract(const Duration(days: 10)));
      final hard = s.review(Recall.hard, t0).interval, good = s.review(Recall.good, t0).interval, easy = s.review(Recall.easy, t0).interval;
      expect(hard, lessThan(good));
      expect(easy, greaterThan(good));
      var h = s;
      for (var i = 0; i < 30; i++) {
        h = h.review(Recall.hard, t0.add(Duration(days: i * 2)));
      }
      expect(h.difficulty, lessThanOrEqualTo(10));
      expect(h.weak, isTrue);
    });

    test('the buttons say when the card comes back', () {
      const s = CardSchedule();
      expect(s.previewLabel(Recall.again, t0), '10 min');
      expect(s.previewLabel(Recall.hard, t0), '15 min');
      expect(s.previewLabel(Recall.good, t0), '2 d');
      expect(s.previewLabel(Recall.easy, t0), '8 d');
      final known = CardSchedule(interval: 100, reps: 5, stability: 100, difficulty: 5, lastReview: t0.subtract(const Duration(days: 100)));
      expect(known.previewLabel(Recall.good, t0), endsWith('mo'));
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
      expect(next.due, DateTime(2026, 3, 3));
      expect((await cards.due(now: t0)).map((c) => c.card.front), ['Q2']);
      expect(await cards.dueCount(now: DateTime(2026, 3, 3)), 2);
      final again = (await cards.due(now: DateTime(2026, 3, 3))).firstWhere((c) => c.id == first.id);
      expect(again.schedule.reps, 1);
      expect(again.schedule.interval, 2);
      expect(again.schedule.stability, closeTo(2.3065, 1e-9));
      expect(again.schedule.lastReview, t0);
      expect(await cards.log(first.id), [(t0, Recall.good)]);
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

  group('the cards of a database from before FSRS (version 61)', () {
    late Directory dir;
    setUpAll(AppDatabase.initFfi);
    setUp(() async => dir = await Directory.systemTemp.createTemp('fsrs_db_'));
    tearDown(() => dir.delete(recursive: true));

    test('keep their schedule, and their next answer takes them over to FSRS and is logged', () async {
      final path = '${dir.path}/n.db';
      final old = await databaseFactory.openDatabase(path, options: OpenDatabaseOptions(version: 61, onCreate: (d, _) async {
        await d.execute('''
          CREATE TABLE review_cards (id TEXT PRIMARY KEY, source TEXT NOT NULL, front TEXT NOT NULL, back TEXT NOT NULL, page INTEGER,
            due INTEGER NOT NULL, interval REAL NOT NULL DEFAULT 0, ease REAL NOT NULL DEFAULT 2.5, reps INTEGER NOT NULL DEFAULT 0,
            lapses INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)''');
        await d.insert('review_cards', {'id': 'c1', 'source': 'n1', 'front': 'Q', 'back': 'A', 'due': t0.millisecondsSinceEpoch, 'interval': 10, 'ease': 2.5, 'reps': 3, 'created_at': 0});
      }));
      await old.close();
      final db = await AppDatabase.open(path: path);
      final cards = CardRepository(db);
      final card = (await cards.due(now: t0)).single;
      expect([card.schedule.interval, card.schedule.reps, card.schedule.stability, card.schedule.difficulty], [10, 3, null, null]);
      final next = await cards.review(card, Recall.good, now: t0);
      expect(next.stability, isNotNull);
      expect(next.interval, greaterThan(10));
      final again = (await cards.all()).single.schedule;
      expect([again.stability, again.difficulty, again.lastReview], [next.stability, next.difficulty, t0]);
      expect(await cards.log('c1'), [(t0, Recall.good)]);
      await cards.remove('c1');
      expect(await cards.log('c1'), isEmpty, reason: 'the log goes with the card');
      await db.close();
    });
  });

  group('the retention', () {
    late Database db;
    setUpAll(AppDatabase.initFfi);
    setUp(() async => db = await AppDatabase.open(path: inMemoryDatabasePath));
    tearDown(() => db.close());

    test('is kept in the settings, read again before an answer, and higher retention brings a card back sooner', () async {
      final settings = SettingsRepository(db);
      final cards = CardRepository(db, settings: settings);
      expect((await cards.scheduler()).retention, 0.9);
      await cards.setRetention(0.99);
      expect(await settings.get(CardRepository.retentionKey), '0.97', reason: 'kept within its bounds');
      await settings.set(CardRepository.retentionKey, '0.8'); // (as if from another device)
      final known = CardSchedule(interval: 20, reps: 4, stability: 20, difficulty: 5, lastReview: t0.subtract(const Duration(days: 20)));
      await cards.addScheduled('n1', [(const Flashcard('Q', 'A'), known)], now: t0);
      final low = await cards.review((await cards.all()).single, Recall.good, now: t0);
      expect(cards.fsrs.retention, 0.8);
      expect(low.interval, greaterThan(known.review(Recall.good, t0).interval));
    });
  });
}
