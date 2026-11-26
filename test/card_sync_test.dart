import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/ai/fsrs.dart';
import 'package:notes/ai/spaced_repetition.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/devicesync/card_sync.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// One device: its database, its cards and its side of the card sync.
class _Device {
  final Database db;
  final CardRepository cards;
  final CardSync sync;
  _Device(this.db) : cards = CardRepository(db), sync = CardSync(db, scheduler: () async => Fsrs());

  static Future<_Device> open() async {
    // (each device its own database file)
    final dir = Directory.systemTemp.createTempSync('card_sync_');
    addTearDown(() => dir.deleteSync(recursive: true));
    return _Device(await AppDatabase.open(path: '${dir.path}/notes.db'));
  }

  /// Takes every deck of [other] that differs from its own, its pictures and its deletions, as a sync does.
  Future<void> takeFrom(_Device other) async {
    final mine = await sync.digests(), theirs = await other.sync.digests();
    await sync.applyDeletions({
      for (final r in await other.db.query('sync_tombstones', where: 'kind = ?', whereArgs: ['card'])) r['id'] as String: r['deleted_at'] as int,
    });
    final have = await sync.pictureIds();
    for (final MapEntry(key: source, value: digest) in theirs.entries) {
      if (mine[source] == digest) continue;
      final deck = await other.sync.deck(source);
      for (final id in CardSync.picturesOf(deck).difference(have)) {
        final p = (await other.sync.picture(id))!;
        await sync.applyPicture(id, p.png, p.width, p.height);
      }
      await sync.applyDeck(source, deck);
    }
  }
}

Future<void> _meet(_Device a, _Device b) async {
  await a.takeFrom(b);
  await b.takeFrom(a);
}

void main() {
  setUpAll(AppDatabase.initFfi);
  final t0 = DateTime(2026, 11, 26, 9);

  test('a schedule goes to JSON and back, and replaying its answers gives where the card stands', () {
    var s = const CardSchedule();
    final log = <(int, Recall)>[];
    for (final (i, r) in [Recall.good, Recall.good, Recall.again, Recall.good].indexed) {
      final at = t0.add(Duration(days: i * 3));
      s = s.review(r, at);
      log.add((at.millisecondsSinceEpoch, r));
    }
    final back = CardSchedule.fromJson(s.toJson());
    expect([back.interval, back.ease, back.reps, back.lapses, back.due, back.stability, back.difficulty, back.lastReview],
        [s.interval, s.ease, s.reps, s.lapses, s.due, s.stability, s.difficulty, s.lastReview]);
    final replayed = replaySchedule(const CardSchedule(), log, Fsrs());
    expect([replayed.stability, replayed.difficulty, replayed.due], [s.stability, s.difficulty, s.due]);
  });

  test('cards made on one device come to the other with their answers, and the two agree after', () async {
    final a = await _Device.open(), b = await _Device.open();
    await a.cards.addAll('n1', const [Flashcard('Q1', 'A1'), Flashcard('Q2', 'A2')], now: t0);
    final q1 = (await a.cards.all()).first;
    await a.cards.review(q1, Recall.good, now: t0);
    await _meet(a, b);
    final there = await b.cards.all(source: 'n1');
    expect(there.map((c) => c.card.front), unorderedEquals(['Q1', 'Q2']));
    final got = there.firstWhere((c) => c.id == q1.id).schedule;
    expect([got.reps, got.stability, got.due], [1, 2.3065, DateTime(2026, 11, 28)]);
    expect(await b.cards.log(q1.id), [(t0, Recall.good)]);
    expect(await a.sync.digests(), await b.sync.digests());
    await a.db.close();
    await b.db.close();
  });

  test('a card answered on both devices while they were apart counts both answers', () async {
    final a = await _Device.open(), b = await _Device.open();
    await a.cards.addAll('n1', const [Flashcard('Q', 'A')], now: t0);
    await _meet(a, b);
    // a: good on day 0; b (not knowing): again on day 1, good ten minutes later
    await a.cards.review((await a.cards.all()).single, Recall.good, now: t0);
    final day1 = t0.add(const Duration(days: 1));
    await b.cards.review((await b.cards.all()).single, Recall.again, now: day1);
    await b.cards.review((await b.cards.all()).single, Recall.good, now: day1.add(const Duration(minutes: 10)));
    await _meet(a, b);
    final sa = (await a.cards.all()).single.schedule, sb = (await b.cards.all()).single.schedule;
    final expected = replaySchedule(const CardSchedule(), [
      (t0.millisecondsSinceEpoch, Recall.good),
      (day1.millisecondsSinceEpoch, Recall.again),
      (day1.add(const Duration(minutes: 10)).millisecondsSinceEpoch, Recall.good),
    ], Fsrs());
    for (final s in [sa, sb]) {
      expect([s.stability, s.difficulty, s.due, s.lapses], [expected.stability, expected.difficulty, expected.due, 1]);
    }
    expect((await a.cards.log((await a.cards.all()).single.id)).length, 3);
    expect(await a.sync.digests(), await b.sync.digests());
    await a.db.close();
    await b.db.close();
  });

  test('cards reviewed before they were synced start from where they stood, the same on both', () async {
    final a = await _Device.open(), b = await _Device.open();
    // (an Anki card with its schedule, then answered once)
    final old = CardSchedule(interval: 20, ease: 2.2, reps: 5, due: t0);
    await a.cards.addScheduled('anki:Bio', [(const Flashcard('Q', 'A'), old)], now: t0.subtract(const Duration(days: 30)));
    await a.cards.review((await a.cards.all()).single, Recall.good, now: t0);
    final onA = (await a.cards.all()).single.schedule;
    await _meet(a, b);
    final onB = (await b.cards.all()).single.schedule;
    expect([onB.stability, onB.difficulty, onB.due, onB.reps], [onA.stability, onA.difficulty, onA.due, onA.reps]);
    expect(await a.sync.digests(), await b.sync.digests());
    await a.db.close();
    await b.db.close();
  });

  test('a deleted card is deleted on the other device and does not come back', () async {
    final a = await _Device.open(), b = await _Device.open();
    await a.cards.addAll('n1', const [Flashcard('Q1', 'A1'), Flashcard('Q2', 'A2')], now: t0);
    await _meet(a, b);
    await a.cards.remove(CardRepository.idOf('n1', 'Q1'));
    await _meet(a, b);
    expect((await b.cards.all()).map((c) => c.card.front), ['Q2']);
    await _meet(a, b);
    expect((await a.cards.all()).map((c) => c.card.front), ['Q2'], reason: 'b does not give it back');
    await a.db.close();
    await b.db.close();
  });

  test('the same card made on both devices becomes one, the same on both', () async {
    final a = await _Device.open(), b = await _Device.open();
    await a.cards.addAll('anki:Bio', const [Flashcard('Q', 'A short answer')], now: t0);
    await b.cards.addAll('anki:Bio', const [Flashcard('Q', 'A longer answer')], now: t0.add(const Duration(hours: 1)));
    await _meet(a, b);
    await _meet(a, b);
    expect((await a.cards.all()).single.card.back, (await b.cards.all()).single.card.back);
    expect(await a.sync.digests(), await b.sync.digests(), reason: 'nothing is sent again at the next sync');
    await a.db.close();
    await b.db.close();
  });

  test('pictures go along with their cards, and a picture whose bytes are not what its name says is refused', () async {
    final a = await _Device.open(), b = await _Device.open();
    final png = Uint8List.fromList(List.generate(64, (i) => i));
    final id = await a.cards.putPicture(png, width: 8, height: 8);
    await a.cards.addAll('n1', [const RegionCard(picture: '', width: 8, height: 8).card(answer: 'x').copyWithPicture(id)], now: t0);
    await _meet(a, b);
    expect(await b.cards.picture(id), png);
    expect(await b.sync.applyPicture(sha1.convert([1, 2, 3]).toString(), Uint8List.fromList([9, 9]), 8, 8), isFalse);
    await a.db.close();
    await b.db.close();
  });
}

extension on Flashcard {
  Flashcard copyWithPicture(String id) => Flashcard(front, back, kind: kind, media: {...?media, 'picture': id});
}
