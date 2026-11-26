import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../ai/flashcards.dart';
import '../ai/fsrs.dart';
import '../ai/spaced_repetition.dart';
import '../data/card_repository.dart';

/// [base] with the answers of [log] given in their order: where a card stands after them.
CardSchedule replaySchedule(CardSchedule base, Iterable<(int at, Recall recall)> log, Fsrs fsrs) {
  var s = base;
  for (final (at, recall) in log) {
    s = s.review(recall, DateTime.fromMillisecondsSinceEpoch(at), fsrs: fsrs);
  }
  return s;
}

/// The flashcards between devices, a deck (the cards of one source: a note, an Anki deck, the graph) at a time.
///
/// What is the same on two devices is told by a digest of each deck: its cards (texts, kind, media), where each one's history starts
/// (`base`, the schedule before its first logged answer) and every answer given (the log). A deck whose digest differs is sent whole, and
/// the two are merged: the cards of both, the answers of both. A card answered on both devices while they were apart counts both: its
/// schedule is worked out again from its start and all the answers, in the order they were given. Deleted cards are told by tombstones
/// ('card'), as notes are.
///
/// A device of an older version knows nothing of this: its manifest has no decks, and it is sent none.
class CardSync {
  final Database _db;

  /// The scheduler with the retention set now (the answers of a merged card are given again with it).
  final Future<Fsrs> Function() scheduler;

  CardSync(this._db, {required this.scheduler});

  Future<Map<String, List<Map<String, Object?>>>> _logs({String? source}) async {
    final rows = await _db.rawQuery(
      'SELECT l.card_id, l.at, l.recall FROM review_log l JOIN review_cards c ON c.id = l.card_id${source == null ? '' : ' WHERE c.source = ?'} ORDER BY l.card_id, l.at',
      [?source],
    );
    final out = <String, List<Map<String, Object?>>>{};
    for (final r in rows) {
      (out[r['card_id'] as String] ??= []).add(r);
    }
    return out;
  }

  /// The start of a card's history: what was kept when it was first answered, or (never answered here, or answered before the log was
  /// kept) where it stands now.
  static Map<String, Object?> _baseOf(Map<String, Object?> row, bool logged) {
    if (row['base'] is String) {
      try {
        return (jsonDecode(row['base'] as String) as Map).cast<String, Object?>();
      } on FormatException {
        // (a broken start: taken as where it stands)
      }
    }
    return _scheduleOf(row).toJson();
  }

  static CardSchedule _scheduleOf(Map<String, Object?> r) => CardSchedule(
        interval: (r['interval'] as num).toDouble(),
        ease: (r['ease'] as num).toDouble(),
        reps: r['reps'] as int,
        lapses: r['lapses'] as int,
        due: DateTime.fromMillisecondsSinceEpoch(r['due'] as int),
        stability: (r['stability'] as num?)?.toDouble(),
        difficulty: (r['difficulty'] as num?)?.toDouble(),
        lastReview: r['last_review'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['last_review'] as int),
      );

  /// A card of a deck as it travels.
  static Map<String, Object?> _cardJson(Map<String, Object?> r, List<Map<String, Object?>> log) => {
        'id': r['id'],
        'f': r['front'],
        'b': r['back'],
        'p': r['page'],
        'k': r['kind'],
        'm': r['media'],
        'c': r['created_at'],
        'base': _baseOf(r, log.isNotEmpty),
        'log': [for (final e in log) [e['at'], e['recall']]],
      };

  /// The deck of [source]: its cards with their history, in a fixed order.
  Future<List<Map<String, Object?>>> deck(String source) async {
    final logs = await _logs(source: source);
    return [
      for (final r in await _db.query('review_cards', where: 'source = ?', whereArgs: [source], orderBy: 'id')) _cardJson(r, logs[r['id']] ?? const []),
    ];
  }

  /// A digest of every deck: what two devices compare.
  Future<Map<String, String>> digests() async {
    final logs = await _logs();
    final bySource = <String, List<Map<String, Object?>>>{};
    for (final r in await _db.query('review_cards', orderBy: 'source, id')) {
      (bySource[r['source'] as String] ??= []).add(_cardJson(r, logs[r['id']] ?? const []));
    }
    return {for (final e in bySource.entries) e.key: sha1.convert(utf8.encode(jsonEncode(e.value))).toString().substring(0, 20)};
  }

  /// The ids of the card pictures here.
  Future<Set<String>> pictureIds() async => {for (final r in await _db.query('card_pictures', columns: ['id'])) r['id'] as String};

  /// The pictures the cards of [deck] show.
  static Set<String> picturesOf(List<Map<String, Object?>> deck) => {
        for (final c in deck)
          if (c['k'] == CardKind.region && c['m'] is String)
            if (_decode(c['m'] as String)?['picture'] case final String id) id,
      };

  static Map? _decode(String json) {
    try {
      final v = jsonDecode(json);
      return v is Map ? v : null;
    } on FormatException {
      return null;
    }
  }

  Future<({Uint8List png, int width, int height})?> picture(String id) async {
    final rows = await _db.query('card_pictures', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final r = rows.single;
    return (png: r['png'] as Uint8List, width: r['width'] as int, height: r['height'] as int);
  }

  /// Takes a picture from another device: only when its bytes are the ones its name says (what comes from elsewhere is not trusted).
  Future<bool> applyPicture(String id, Uint8List png, int width, int height) async {
    if (sha1.convert(png).toString() != id || width <= 0 || height <= 0 || width > 20000 || height > 20000) return false;
    await _db.insert('card_pictures', {'id': id, 'png': png, 'width': width, 'height': height}, conflictAlgorithm: ConflictAlgorithm.ignore);
    return true;
  }

  /// The cards deleted here: card id -> when.
  Future<Map<String, int>> _tombs() async => {
        for (final r in await _db.query('sync_tombstones', where: 'kind = ?', whereArgs: ['card'])) r['id'] as String: r['deleted_at'] as int,
      };

  /// Deletes the cards another device deleted (by their tombstones); the answer is how many were here.
  Future<int> applyDeletions(Map<String, int> tombs) async {
    var n = 0;
    await _db.transaction((txn) async {
      for (final MapEntry(key: id, value: at) in tombs.entries) {
        final gone = await txn.delete('review_cards', where: 'id = ?', whereArgs: [id]);
        await txn.delete('review_log', where: 'card_id = ?', whereArgs: [id]);
        await txn.insert('sync_tombstones', {'kind': 'card', 'id': id, 'deleted_at': at}, conflictAlgorithm: ConflictAlgorithm.ignore);
        n += gone;
      }
    });
    if (n > 0) cardsChangedElsewhere();
    return n;
  }

  static String _canon(Object? o) => jsonEncode(o);

  /// Merges a deck of [source] that came from another device into the one here; the answer is how many cards changed. What is sent is
  /// not trusted: a card that is not of the deck's shape is left out.
  Future<int> applyDeck(String source, List<Object?> theirs) async {
    final fsrs = await scheduler();
    final tombs = await _tombs();
    final mine = {for (final c in await deck(source)) c['id'] as String: c};
    var changed = 0;
    await _db.transaction((txn) async {
      for (final t in theirs) {
        if (t is! Map) continue;
        final id = t['id'], front = t['f'], back = t['b'], kind = t['k'], created = t['c'], base = t['base'], log = t['log'];
        if (id is! String || front is! String || back is! String || kind is! String || created is! int || base is! Map || log is! List) continue;
        if (tombs.containsKey(id)) continue; // (deleted here: it stays deleted)
        final theirLog = <(int, int)>{
          for (final e in log)
            if (e is List && e.length == 2 && e[0] is int && e[1] is int && (e[1] as int) >= 1 && (e[1] as int) <= 4) (e[0] as int, e[1] as int),
        };
        final here = mine[id];
        final myLog = <(int, int)>{for (final e in (here?['log'] as List?) ?? const []) ((e as List)[0] as int, e[1] as int)};
        final union = {...myLog, ...theirLog}.toList()..sort((x, y) => x.$1.compareTo(y.$1));
        // Both devices must come to the same card, or they would send it to each other at every sync: of two versions of its texts and
        // of two starts (the same card made on both, an Anki deck imported twice), the one that comes first as JSON is kept - on both.
        final media = t['m'] is String ? t['m'] as String : null;
        final theirContent = <String, Object?>{'f': front, 'b': back, 'k': kind, 'm': media, 'p': t['p'] is int ? t['p'] : null, 'c': created};
        final myContent = here == null ? null : <String, Object?>{'f': here['f'], 'b': here['b'], 'k': here['k'], 'm': here['m'], 'p': here['p'], 'c': here['c']};
        final content = myContent == null || _canon(theirContent).compareTo(_canon(myContent)) < 0 ? theirContent : myContent;
        final start = here == null || _canon(base).compareTo(_canon(here['base'])) < 0 ? base : here['base'] as Map;
        if (here != null && union.length == myLog.length && identical(content, myContent) && identical(start, here['base'])) continue;
        final s = replaySchedule(CardSchedule.fromJson(start), [for (final (at, r) in union) (at, Recall.values[r - 1])], fsrs);
        final row = {
          'front': content['f'],
          'back': content['b'],
          'page': content['p'],
          'kind': content['k'],
          'media': content['m'],
          'created_at': content['c'],
          'base': jsonEncode(start),
          'due': (s.due ?? DateTime.fromMillisecondsSinceEpoch(content['c'] as int)).millisecondsSinceEpoch,
          'interval': s.interval,
          'ease': s.ease,
          'reps': s.reps,
          'lapses': s.lapses,
          'stability': s.stability,
          'difficulty': s.difficulty,
          'last_review': s.lastReview?.millisecondsSinceEpoch,
        };
        if (here == null) {
          await txn.insert('review_cards', {'id': id, 'source': source, ...row}, conflictAlgorithm: ConflictAlgorithm.ignore);
        } else {
          await txn.update('review_cards', row, where: 'id = ?', whereArgs: [id]);
        }
        for (final (at, r) in theirLog.difference(myLog)) {
          await txn.insert('review_log', {'card_id': id, 'at': at, 'recall': r}, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        changed++;
      }
    });
    if (changed > 0) cardsChangedElsewhere();
    return changed;
  }
}
