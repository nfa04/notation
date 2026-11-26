import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../ai/flashcards.dart';
import '../ai/fsrs.dart';
import '../ai/spaced_repetition.dart';
import 'settings_repository.dart';
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

final _changedElsewhere = StreamController<void>.broadcast();

/// Says that cards were changed by something else than a [CardRepository] (a sync), so that what shows them looks again.
void cardsChangedElsewhere() => _changedElsewhere.add(null);

/// The cards kept for spaced repetition (table `review_cards`). Cards come from the assistant and the graph's study tools; what
/// is kept is the question, the answer and the schedule, so they can be asked again days later.
class CardRepository {
  /// The source of cards made from the facts of all notes.
  static const graphSource = 'graph';

  final Database _db;

  /// Where the retention the person chose is kept (synced to their other devices); null: always the default.
  final SettingsRepository? settings;

  CardRepository(this._db, {this.settings}) {
    _changedElsewhere.stream.listen((_) => _changed());
  }

  /// The setting of the retention, as a number such as "0.9".
  static const retentionKey = 'card_retention';
  static const minRetention = 0.7, maxRetention = 0.97;

  /// The scheduler as last read (see [scheduler]).
  Fsrs fsrs = Fsrs();

  /// The scheduler with the retention as it is set now (it may have come from another device since).
  Future<Fsrs> scheduler() async {
    final r = double.tryParse(await settings?.get(retentionKey) ?? '')?.clamp(minRetention, maxRetention).toDouble() ?? 0.9;
    if (r != fsrs.retention) fsrs = Fsrs(retention: r);
    return fsrs;
  }

  /// Keeps [retention], the chance of remembering a card at which it comes back: higher means more reviews and less forgotten.
  Future<void> setRetention(double retention) async {
    final r = retention.clamp(minRetention, maxRetention).toDouble();
    fsrs = Fsrs(retention: r);
    await settings?.set(retentionKey, r.toStringAsFixed(2));
  }

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
        card: Flashcard(r['front'] as String, r['back'] as String, page: r['page'] as int?, kind: (r['kind'] as String?) ?? CardKind.basic, media: _media(r['media'])),
        schedule: CardSchedule(
          interval: (r['interval'] as num).toDouble(),
          ease: (r['ease'] as num).toDouble(),
          reps: r['reps'] as int,
          lapses: r['lapses'] as int,
          due: DateTime.fromMillisecondsSinceEpoch(r['due'] as int),
          stability: (r['stability'] as num?)?.toDouble(),
          difficulty: (r['difficulty'] as num?)?.toDouble(),
          lastReview: r['last_review'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['last_review'] as int),
        ),
      );

  static Map<String, Object?>? _media(Object? json) {
    if (json is! String || json.isEmpty) return null;
    try {
      final m = jsonDecode(json);
      return m is Map ? m.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  /// The columns of [c] that say what the card is (its texts, kind and media), for a row of [source].
  static Map<String, Object?> _row(String source, Flashcard c) => {
        'id': idOf(source, c.identity),
        'source': source,
        'front': c.front.trim(),
        'back': c.back.trim(),
        'page': c.page,
        'kind': c.kind,
        'media': c.media == null ? null : jsonEncode(c.media),
      };

  /// Keeps [cards] for review, due now. A card of [source] with the same question is not added again (its schedule is kept).
  /// The answer is how many were new.
  Future<int> addAll(String source, Iterable<Flashcard> cards, {DateTime? now}) async {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    var added = 0;
    await _db.transaction((txn) async {
      for (final c in cards) {
        final n = await txn.insert(
          'review_cards',
          {..._row(source, c), 'due': at, 'created_at': at},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (n > 0) {
          added++;
          // (made again after it was deleted: no longer deleted for the other devices)
          await txn.delete('sync_tombstones', where: 'kind = ? AND id = ?', whereArgs: ['card', idOf(source, c.identity)]);
        }
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
            ..._row(source, c),
            'due': fresh ? at : (s.due ?? DateTime.fromMillisecondsSinceEpoch(at)).millisecondsSinceEpoch,
            'interval': s.interval,
            'ease': s.ease,
            'reps': s.reps,
            'lapses': s.lapses,
            'stability': s.stability,
            'difficulty': s.difficulty,
            'last_review': s.lastReview?.millisecondsSinceEpoch,
            'created_at': at,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (n > 0) {
          added++;
          // (made again after it was deleted: no longer deleted for the other devices)
          await txn.delete('sync_tombstones', where: 'kind = ? AND id = ?', whereArgs: ['card', idOf(source, c.identity)]);
        }
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
             SUM(CASE WHEN NOT (due = created_at AND reps = 0 AND lapses = 0) AND (lapses >= 2 OR (difficulty IS NOT NULL AND difficulty >= 7) OR (difficulty IS NULL AND ease <= 1.9)) THEN 1 ELSE 0 END) AS weak
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

  /// Books the answer to [card] (and keeps it in the log of answers); the answer is its new schedule.
  Future<CardSchedule> review(ReviewCard card, Recall recall, {DateTime? now}) async {
    final at = now ?? DateTime.now();
    final next = card.schedule.review(recall, at, fsrs: await scheduler());
    await _db.transaction((txn) async {
      // (the first answer that is logged keeps where the card stood before it: its history starts there)
      final logged = (await txn.query('review_log', columns: ['at'], where: 'card_id = ?', whereArgs: [card.id], limit: 1)).isNotEmpty;
      await txn.update(
        'review_cards',
        {
          if (!logged) 'base': jsonEncode(card.schedule.toJson()),
          'due': next.due!.millisecondsSinceEpoch,
          'interval': next.interval,
          'ease': next.ease,
          'reps': next.reps,
          'lapses': next.lapses,
          'stability': next.stability,
          'difficulty': next.difficulty,
          'last_review': at.millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [card.id],
      );
      await txn.insert('review_log', {'card_id': card.id, 'at': at.millisecondsSinceEpoch, 'recall': recall.grade}, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    _changed();
    return next;
  }

  /// Keeps the picture [png] ([width] x [height] pixels) of a card; the answer is its id (the same picture is kept once).
  Future<String> putPicture(Uint8List png, {required int width, required int height}) async {
    final id = sha1.convert(png).toString();
    await _db.insert('card_pictures', {'id': id, 'png': png, 'width': width, 'height': height}, conflictAlgorithm: ConflictAlgorithm.ignore);
    return id;
  }

  final _pictures = <String, Uint8List?>{};

  /// The picture [id] (null when it is not here: one that has not come from another device yet).
  Future<Uint8List?> picture(String id) async {
    if (_pictures.containsKey(id)) return _pictures[id];
    final rows = await _db.query('card_pictures', columns: ['png'], where: 'id = ?', whereArgs: [id]);
    final png = rows.isEmpty ? null : rows.single['png'] as Uint8List;
    if (png != null) {
      if (_pictures.length > 40) _pictures.remove(_pictures.keys.first);
      _pictures[id] = png;
    }
    return png;
  }

  /// Takes away the pictures no card shows any more.
  Future<void> _prunePictures() async {
    final used = <String>{
      for (final r in await _db.query('review_cards', columns: ['media'], where: 'kind = ?', whereArgs: [CardKind.region]))
        if (_media(r['media'])?['picture'] case final String id) id,
    };
    for (final r in await _db.query('card_pictures', columns: ['id'])) {
      final id = r['id'] as String;
      if (!used.contains(id)) {
        await _db.delete('card_pictures', where: 'id = ?', whereArgs: [id]);
        _pictures.remove(id);
      }
    }
  }

  /// Tells the other devices that these cards were deleted (see `CardSync`).
  Future<void> _tomb(List<String> ids) async {
    final at = DateTime.now().millisecondsSinceEpoch;
    final batch = _db.batch();
    for (final id in ids) {
      batch.insert('sync_tombstones', {'kind': 'card', 'id': id, 'deleted_at': at}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// The answers given to card [id], oldest first.
  Future<List<(DateTime, Recall)>> log(String id) async {
    final rows = await _db.query('review_log', where: 'card_id = ?', whereArgs: [id], orderBy: 'at');
    return [for (final r in rows) (DateTime.fromMillisecondsSinceEpoch(r['at'] as int), Recall.values[(r['recall'] as int) - 1])];
  }

  Future<void> remove(String id) async {
    await _db.delete('review_cards', where: 'id = ?', whereArgs: [id]);
    await _db.delete('review_log', where: 'card_id = ?', whereArgs: [id]);
    await _tomb([id]);
    await _prunePictures();
    _changed();
  }

  /// Forgets every card of [source] (a note that was deleted, say).
  Future<void> removeSource(String source) async {
    final ids = [for (final r in await _db.query('review_cards', columns: ['id'], where: 'source = ?', whereArgs: [source])) r['id'] as String];
    await _tomb(ids);
    await _db.delete('review_log', where: 'card_id IN (SELECT id FROM review_cards WHERE source = ?)', whereArgs: [source]);
    await _db.delete('review_cards', where: 'source = ?', whereArgs: [source]);
    await _prunePictures();
    _changed();
  }
}
