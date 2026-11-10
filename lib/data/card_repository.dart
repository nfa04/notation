import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../ai/flashcards.dart';
import '../ai/spaced_repetition.dart';
import '../review/study_plan.dart';

/// A flashcard kept for review, with its place in the schedule.
class ReviewCard {
  final String id;

  /// The note it came from, or [CardRepository.graphSource].
  final String source;
  final Flashcard card;
  final CardSchedule schedule;

  const ReviewCard({required this.id, required this.source, required this.card, required this.schedule});
}

/// The cards kept for spaced repetition (table `review_cards`). Cards come from the assistant and the graph's study tools; what
/// is kept is the question, the answer and the schedule, so they can be asked again days later.
class CardRepository {
  /// The source of cards made from the facts of all notes.
  static const graphSource = 'graph';

  final Database _db;

  CardRepository(this._db);

  final _changes = StreamController<void>.broadcast();

  /// Fires after cards were added, reviewed or removed.
  Stream<void> get changes => _changes.stream;
  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static String idOf(String source, String front) => sha1.convert('$source\n${front.trim()}'.codeUnits).toString();

  static ReviewCard _card(Map<String, Object?> r) => ReviewCard(
        id: r['id'] as String,
        source: r['source'] as String,
        card: Flashcard(r['front'] as String, r['back'] as String, page: r['page'] as int?),
        schedule: CardSchedule(
          interval: (r['interval'] as num).toDouble(),
          ease: (r['ease'] as num).toDouble(),
          reps: r['reps'] as int,
          lapses: r['lapses'] as int,
          due: DateTime.fromMillisecondsSinceEpoch(r['due'] as int),
        ),
      );

  /// Keeps [cards] for review, due now. A card of [source] with the same question is not added again (its schedule is kept).
  /// The answer is how many were new.
  Future<int> addAll(String source, Iterable<Flashcard> cards, {DateTime? now}) async {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    var added = 0;
    await _db.transaction((txn) async {
      for (final c in cards) {
        final id = idOf(source, c.front);
        final n = await txn.insert(
          'review_cards',
          {'id': id, 'source': source, 'front': c.front.trim(), 'back': c.back.trim(), 'page': c.page, 'due': at, 'created_at': at},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (n > 0) added++;
      }
    });
    if (added > 0) _changed();
    return added;
  }

  /// Keeps cards that come with a schedule of their own (from another program), as [addAll] does: one of [source] with the same
  /// question is not added again. The answer is how many were new.
  Future<int> addScheduled(String source, Iterable<(Flashcard, CardSchedule)> cards, {DateTime? now}) async {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    var added = 0;
    await _db.transaction((txn) async {
      for (final (c, s) in cards) {
        // (a card that was never answered is due now and has the mark of a new card: due = created_at)
        final fresh = s.reps == 0 && s.lapses == 0;
        final n = await txn.insert(
          'review_cards',
          {
            'id': idOf(source, c.front),
            'source': source,
            'front': c.front.trim(),
            'back': c.back.trim(),
            'page': c.page,
            'due': fresh ? at : (s.due ?? DateTime.fromMillisecondsSinceEpoch(at)).millisecondsSinceEpoch,
            'interval': s.interval,
            'ease': s.ease,
            'reps': s.reps,
            'lapses': s.lapses,
            'created_at': at,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (n > 0) added++;
      }
    });
    if (added > 0) _changed();
    return added;
  }

  /// The cards due at [now], the ones that have waited longest first. [source] limits them to one note's cards.
  Future<List<ReviewCard>> due({DateTime? now, String? source, int? limit}) async {
    final rows = await _db.query(
      'review_cards',
      where: source == null ? 'due <= ?' : 'due <= ? AND source = ?',
      whereArgs: [(now ?? DateTime.now()).millisecondsSinceEpoch, ?source],
      orderBy: 'due, created_at',
      limit: limit,
    );
    return rows.map(_card).toList();
  }

  /// Every card, or those of [source], in the order they were made.
  Future<List<ReviewCard>> all({String? source}) async {
    final rows = await _db.query('review_cards', where: source == null ? null : 'source = ?', whereArgs: [?source], orderBy: 'created_at, rowid');
    return rows.map(_card).toList();
  }

  Future<int> dueCount({DateTime? now, String? source}) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM review_cards WHERE due <= ?${source == null ? '' : ' AND source = ?'}',
      [(now ?? DateTime.now()).millisecondsSinceEpoch, ?source],
    );
    return rows.first['n'] as int;
  }

  Future<int> count({String? source}) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM review_cards${source == null ? '' : ' WHERE source = ?'}',
      [?source],
    );
    return rows.first['n'] as int;
  }

  /// How the cards of [source] (all of them: null) stand: those never answered, those answered, those due, and the weak ones (forgotten
  /// more than once, or hard to remember).
  Future<CardStats> stats({String? source, DateTime? now}) async {
    final rows = await _db.rawQuery('''
      SELECT SUM(CASE WHEN due = created_at AND reps = 0 AND lapses = 0 THEN 1 ELSE 0 END) AS unseen,
             SUM(CASE WHEN due = created_at AND reps = 0 AND lapses = 0 THEN 0 ELSE 1 END) AS seen,
             SUM(CASE WHEN due <= ? THEN 1 ELSE 0 END) AS due,
             SUM(CASE WHEN NOT (due = created_at AND reps = 0 AND lapses = 0) AND (lapses >= 2 OR ease <= 1.9) THEN 1 ELSE 0 END) AS weak
        FROM review_cards${source == null ? '' : ' WHERE source = ?'}
    ''', [(now ?? DateTime.now()).millisecondsSinceEpoch, ?source]);
    final r = rows.first;
    int n(String k) => (r[k] as num?)?.toInt() ?? 0;
    return CardStats(unseen: n('unseen'), seen: n('seen'), due: n('due'), weak: n('weak'));
  }

  /// How many cards each source has, the sources with the most first.
  Future<Map<String, int>> sourceCounts() async {
    final rows = await _db.rawQuery('SELECT source, COUNT(*) AS n FROM review_cards GROUP BY source ORDER BY n DESC');
    return {for (final r in rows) r['source'] as String: r['n'] as int};
  }

  /// Books the answer to [card]; the answer is its new schedule.
  Future<CardSchedule> review(ReviewCard card, Recall recall, {DateTime? now}) async {
    final next = card.schedule.review(recall, now ?? DateTime.now());
    await _db.update(
      'review_cards',
      {'due': next.due!.millisecondsSinceEpoch, 'interval': next.interval, 'ease': next.ease, 'reps': next.reps, 'lapses': next.lapses},
      where: 'id = ?',
      whereArgs: [card.id],
    );
    _changed();
    return next;
  }

  Future<void> remove(String id) async {
    await _db.delete('review_cards', where: 'id = ?', whereArgs: [id]);
    _changed();
  }

  /// Forgets every card of [source] (a note that was deleted, say).
  Future<void> removeSource(String source) async {
    await _db.delete('review_cards', where: 'source = ?', whereArgs: [source]);
    _changed();
  }
}
