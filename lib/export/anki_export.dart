import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../ai/spaced_repetition.dart';
import '../data/card_repository.dart';

/// The review cards as an Anki package (`.apkg`) that Anki, AnkiDroid and AnkiMobile import by opening the file. One note type
/// (Front, Back, Source), one deck for each note the cards are from (below one deck, [rootDeck]), the formulas as Anki writes them
/// (`\( ... \)` and `\[ ... \]`), and the schedule: cards that were learned come as review cards with their interval and ease, cards
/// never answered as new ones. Every card keeps the same id when it is exported again, so a second import updates the first.
///
/// The package is the format of Anki's collection file as it was up to version 2.1.x (`collection.anki2`), which every version imports.

/// One card for the package: [deck] is the name of the deck (of the note it is from).
class AnkiCard {
  final String id;
  final String deck;
  final String front, back;

  /// What the card is from, shown small under the answer: the note and the page.
  final String source;
  final CardSchedule schedule;

  const AnkiCard({required this.id, required this.deck, required this.front, required this.back, this.source = '', required this.schedule});

  /// [review] with the deck named [deck] and a [source] line (the page is one-based there).
  factory AnkiCard.of(ReviewCard review, {required String deck}) => AnkiCard(
        id: review.id,
        deck: deck,
        front: review.card.front,
        back: review.card.back,
        source: [deck, if (review.card.page != null) 'p. ${review.card.page! + 1}'].join(', '),
        schedule: review.schedule,
      );
}

/// The id of the note type: always the same, so that Anki keeps one type however often a package is imported.
const _modelId = 1730000000001;
const _rootDeckDefault = 'Notation';

String _html(String s) => const HtmlEscape(HtmlEscapeMode.element).convert(s).replaceAll('\n', '<br>');

/// [text] as the HTML of an Anki field: escaped, line breaks kept, `$a$` and `$$a$$` as the maths Anki shows.
String ankiField(String text) {
  var s = _html(text.trim());
  s = s.replaceAllMapped(RegExp(r'\$\$(.+?)\$\$'), (m) => '\\[${m[1]}\\]');
  // (a dollar sign opens maths when no space follows it and closes it when none comes before it: `costs $5 and $6` is no formula)
  s = s.replaceAllMapped(RegExp(r'(?<![\\$])\$(?![\s$])([^$]*?[^\s$])\$(?![\d$])'), (m) => '\\(${m[1]}\\)');
  return s;
}

/// What Anki checks a note's first field by: the first eight hex digits of the SHA-1 of its text without markup, as a number.
int _checksum(String field) => int.parse(sha1.convert(utf8.encode(field.replaceAll(RegExp(r'<[^>]*>'), ''))).toString().substring(0, 8), radix: 16);

int _idOf(String name) => int.parse(sha1.convert(utf8.encode(name)).toString().substring(0, 11), radix: 16);

const _schema = [
  '''CREATE TABLE col (id integer primary key, crt integer not null, mod integer not null, scm integer not null, ver integer not null,
     dty integer not null, usn integer not null, ls integer not null, conf text not null, models text not null, decks text not null,
     dconf text not null, tags text not null)''',
  '''CREATE TABLE notes (id integer primary key, guid text not null, mid integer not null, mod integer not null, usn integer not null,
     tags text not null, flds text not null, sfld integer not null, csum integer not null, flags integer not null, data text not null)''',
  '''CREATE TABLE cards (id integer primary key, nid integer not null, did integer not null, ord integer not null, mod integer not null,
     usn integer not null, type integer not null, queue integer not null, due integer not null, ivl integer not null,
     factor integer not null, reps integer not null, lapses integer not null, left integer not null, odue integer not null,
     odid integer not null, flags integer not null, data text not null)''',
  '''CREATE TABLE revlog (id integer primary key, cid integer not null, usn integer not null, ease integer not null, ivl integer not null,
     lastIvl integer not null, factor integer not null, time integer not null, type integer not null)''',
  'CREATE TABLE graves (usn integer not null, type integer not null, oid integer not null)',
  'CREATE INDEX ix_notes_usn on notes (usn)',
  'CREATE INDEX ix_cards_usn on cards (usn)',
  'CREATE INDEX ix_revlog_usn on revlog (usn)',
  'CREATE INDEX ix_cards_nid on cards (nid)',
  'CREATE INDEX ix_cards_sched on cards (did, queue, due)',
  'CREATE INDEX ix_revlog_cid on revlog (cid)',
  'CREATE INDEX ix_notes_csum on notes (csum)',
];

const _css = '.card { font-family: arial; font-size: 20px; text-align: center; color: black; background-color: white; }\n'
    '.source { font-size: 12px; color: gray; margin-top: 1.5em; }';

Map<String, Object?> _model(int deckId, int now) => {
      'css': _css,
      'did': deckId,
      'flds': [
        for (final (i, name) in const ['Front', 'Back', 'Source'].indexed)
          {'font': 'Arial', 'media': <Object?>[], 'name': name, 'ord': i, 'rtl': false, 'size': 20, 'sticky': false},
      ],
      'id': _modelId,
      'latexPost': r'\end{document}',
      'latexPre': '\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8]{inputenc}\n\\usepackage{amssymb,amsmath}\n'
          '\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n',
      'mod': now,
      'name': 'Notation: Front and Back',
      'req': [
        [0, 'all', [0]],
      ],
      'sortf': 0,
      'tags': <Object?>[],
      'tmpls': [
        {
          'afmt': '{{FrontSide}}\n\n<hr id=answer>\n\n{{Back}}\n{{#Source}}<div class="source">{{Source}}</div>{{/Source}}',
          'bafmt': '',
          'bqfmt': '',
          'did': null,
          'name': 'Card 1',
          'ord': 0,
          'qfmt': '{{Front}}',
        },
      ],
      'type': 0,
      'usn': -1,
      'vers': <Object?>[],
    };

Map<String, Object?> _deck(int id, String name, int now) => {
      'collapsed': false,
      'conf': 1,
      'desc': '',
      'dyn': 0,
      'extendedReview': false,
      'id': id,
      'lrnToday': [0, 0],
      'mod': now,
      'name': name,
      'newToday': [0, 0],
      'revToday': [0, 0],
      'timeToday': [0, 0],
      'usn': -1,
    };

const _deckConfiguration = {
  '1': {
    'autoplay': true,
    'id': 1,
    'lapse': {'delays': [10], 'leechAction': 0, 'leechFails': 8, 'minInt': 1, 'mult': 0},
    'maxTaken': 60,
    'mod': 0,
    'name': 'Default',
    'new': {'bury': true, 'delays': [1, 10], 'initialFactor': 2500, 'ints': [1, 4, 7], 'order': 1, 'perDay': 20, 'separate': true},
    'replayq': true,
    'rev': {'bury': true, 'ease4': 1.3, 'fuzz': 0.05, 'ivlFct': 1, 'maxIvl': 36500, 'minInt': 1, 'perDay': 100},
    'timer': 0,
    'usn': 0,
  },
};

/// A tag for [deck]: no spaces (Anki separates tags by them), no `::`.
String _tag(String deck) => deck.replaceAll(RegExp(r'[\s:]+'), '_');

/// The package for [cards], built in [workDirectory] (a folder for a file that is deleted again). [now] is when it is made; the cards
/// that were due before are due on the day of the import.
Future<Uint8List> ankiPackage(List<AnkiCard> cards, {required Directory workDirectory, DateTime? now, String rootDeck = _rootDeckDefault}) async {
  final at = now ?? DateTime.now();
  final nowSeconds = at.millisecondsSinceEpoch ~/ 1000;
  // Anki counts days from the collection's creation, which it puts at four in the morning (when its day turns over): the last four
  // o'clock there was
  final day = at.hour < 4 ? at.subtract(const Duration(days: 1)) : at;
  final created = DateTime(day.year, day.month, day.day, 4).millisecondsSinceEpoch ~/ 1000;
  final today = ((nowSeconds - created) / 86400).floor();

  final deckNames = {for (final c in cards) c.deck};
  final deckIds = {for (final name in deckNames) name: _idOf('$rootDeck::$name')};
  final rootId = _idOf(rootDeck);
  final decks = <String, Object?>{
    '1': _deck(1, 'Default', nowSeconds),
    '$rootId': _deck(rootId, rootDeck, nowSeconds),
    for (final e in deckIds.entries) '${e.value}': _deck(e.value, '$rootDeck::${e.key.replaceAll('::', ':')}', nowSeconds),
  };

  final dir = await workDirectory.createTemp('anki_export');
  final file = '${dir.path}/collection.anki2';
  try {
    final db = await databaseFactoryFfi.openDatabase(file, options: OpenDatabaseOptions(singleInstance: false));
    try {
      await db.transaction((txn) async {
        for (final statement in _schema) {
          await txn.execute(statement);
        }
        await txn.insert('col', {
          'id': 1,
          'crt': created,
          'mod': nowSeconds * 1000,
          'scm': nowSeconds * 1000,
          'ver': 11,
          'dty': 0,
          'usn': 0,
          'ls': 0,
          'conf': jsonEncode({
            'activeDecks': [1],
            'addToCur': true,
            'collapseTime': 1200,
            'curDeck': 1,
            'curModel': '$_modelId',
            'dueCounts': true,
            'estTimes': true,
            'newBury': true,
            'newSpread': 0,
            'nextPos': cards.length + 1,
            'sortBackwards': false,
            'sortType': 'noteFld',
            'timeLim': 0,
          }),
          'models': jsonEncode({'$_modelId': _model(deckIds.values.firstOrNull ?? 1, nowSeconds)}),
          'decks': jsonEncode(decks),
          'dconf': jsonEncode(_deckConfiguration),
          'tags': '{}',
        });
        var next = at.millisecondsSinceEpoch;
        var position = 0;
        for (final c in cards) {
          final front = ankiField(c.front), back = ankiField(c.back), source = _html(c.source);
          final noteId = next++, cardId = next++;
          await txn.insert('notes', {
            'id': noteId,
            'guid': c.id,
            'mid': _modelId,
            'mod': nowSeconds,
            'usn': -1,
            'tags': ' ${_tag(c.deck)} ',
            'flds': [front, back, source].join('\x1f'),
            'sfld': front.replaceAll(RegExp(r'<[^>]*>'), ''),
            'csum': _checksum(front),
            'flags': 0,
            'data': '',
          });
          final s = c.schedule;
          // a card that was answered at least once (or forgotten) is a review card; the others are new
          final learned = s.reps > 0 || s.lapses > 0;
          final dueDay = s.due == null ? today : ((s.due!.millisecondsSinceEpoch ~/ 1000 - created) / 86400).floor();
          await txn.insert('cards', {
            'id': cardId,
            'nid': noteId,
            'did': deckIds[c.deck]!,
            'ord': 0,
            'mod': nowSeconds,
            'usn': -1,
            'type': learned ? 2 : 0,
            'queue': learned ? 2 : 0,
            'due': learned ? (dueDay < 0 ? 0 : dueDay) : ++position,
            'ivl': learned ? (s.interval < 1 ? 1 : s.interval.round()) : 0,
            'factor': learned ? (s.ease * 1000).round() : 0,
            'reps': s.reps,
            'lapses': s.lapses,
            'left': 0,
            'odue': 0,
            'odid': 0,
            'flags': 0,
            'data': '',
          });
        }
      });
    } finally {
      await db.close();
    }
    final archive = Archive()
      ..add(ArchiveFile.bytes('collection.anki2', await File(file).readAsBytes()))
      ..add(ArchiveFile.bytes('media', utf8.encode('{}')));
    return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
  } finally {
    await dir.delete(recursive: true);
  }
}
