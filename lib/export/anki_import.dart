import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../ai/spaced_repetition.dart';
import '../data/safe_zip.dart';

/// A package that cannot be read, with the reason in words for the person.
class AnkiImportException implements Exception {
  final String message;
  const AnkiImportException(this.message);

  @override
  String toString() => message;
}

/// A card read from an Anki package: the deck it was in, the question and the answer as plain text (formulas as `$...$`), and where it
/// stood in Anki's schedule.
class ImportedCard {
  final String deck;
  final String front, back;
  final CardSchedule schedule;

  const ImportedCard({required this.deck, required this.front, required this.back, required this.schedule});
}

/// The text of an Anki field as plain text: line breaks kept, markup and sounds left out, pictures marked, `\(a\)` and `\[a\]` as the
/// `$a$` and `$$a$$` this app writes formulas with.
String ankiPlainText(String html) {
  var s = html;
  s = s.replaceAll(RegExp(r'\[sound:[^\]]*\]'), '');
  s = s.replaceAll(RegExp(r'<img\b[^>]*>', caseSensitive: false), '[image]');
  s = s.replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'</\s*(div|p|li|tr|h[1-6])\s*>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<[^>]*>'), '');
  s = s.replaceAllMapped(RegExp(r'\\\[(.+?)\\\]', dotAll: true), (m) => '\$\$${m[1]!.trim()}\$\$');
  s = s.replaceAllMapped(RegExp(r'\\\((.+?)\\\)', dotAll: true), (m) => '\$${m[1]!.trim()}\$');
  s = _unescape(s);
  return s.replaceAll(' ', ' ').split('\n').map((l) => l.trimRight()).join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

String _unescape(String s) => s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);'), (m) {
      final e = m[1]!;
      if (e.startsWith('#x')) return String.fromCharCode(int.parse(e.substring(2), radix: 16));
      if (e.startsWith('#')) return String.fromCharCode(int.parse(e.substring(1)));
      return switch (e) { 'amp' => '&', 'lt' => '<', 'gt' => '>', 'quot' => '"', 'apos' => "'", 'nbsp' => ' ', _ => m[0]! };
    });

/// A cloze text with the hidden part [number] (`{{c1::answer::hint}}`) hidden as `[...]` (or `[hint]`) in the question, and shown in
/// the answer; the other clozes are shown in both.
(String, String) clozeSides(String text, int number) {
  final cloze = RegExp(r'\{\{c(\d+)::(.*?)(?:::(.*?))?\}\}', dotAll: true);
  final front = text.replaceAllMapped(cloze, (m) => int.parse(m[1]!) == number ? '[${(m[3] ?? '').isEmpty ? '...' : m[3]}]' : m[2]!);
  final back = text.replaceAllMapped(cloze, (m) => m[2]!);
  return (front, back);
}

/// The cards of an Anki package (`.apkg`, as Anki exports it with "Support older Anki versions" ticked). Basic notes give a card
/// with the first field as the question and the second as the answer, cloze notes one card for each hidden part; the scheduling
/// (interval, ease, reps, lapses and when the card is due) is taken over. Pictures and sounds are not (they stay as `[image]`).
/// [workDirectory] holds the collection file for the moment it is read.
Future<List<ImportedCard>> readAnkiPackage(Uint8List bytes, {required Directory workDirectory, DateTime? now}) async {
  final Archive archive;
  try {
    archive = decodeZipLimited(bytes);
  } on ArchiveTooBigException {
    throw const AnkiImportException('This Anki package is too big to read.');
  } catch (_) {
    throw const AnkiImportException('This is not an Anki package.');
  }
  ArchiveFile? find(String name) {
    for (final f in archive) {
      if (f.name == name) return f;
    }
    return null;
  }

  // the newest format first; an old Anki leaves the readable one beside the compressed one
  final file = find('collection.anki21') ?? find('collection.anki2');
  if (file == null) {
    throw AnkiImportException(
      find('collection.anki21b') != null
          ? 'This package was exported in the newest Anki format. Export it again with "Support older Anki versions" ticked.'
          : 'This is not an Anki package.',
    );
  }
  final dir = await workDirectory.createTemp('anki_import');
  try {
    final path = '${dir.path}/collection.sqlite';
    await File(path).writeAsBytes(file.content as List<int>);
    final db = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    try {
      return await _cardsOf(db, now ?? DateTime.now());
    } finally {
      await db.close();
    }
  } on DatabaseException {
    throw const AnkiImportException('This is not an Anki package.');
  } on FormatException {
    // (a collection whose models or decks are no JSON, an empty `col` table, a column of another type: some other database)
    throw const AnkiImportException('This is not an Anki package.');
  } on StateError {
    throw const AnkiImportException('This is not an Anki package.');
  } on TypeError {
    throw const AnkiImportException('This is not an Anki package.');
  } finally {
    await dir.delete(recursive: true);
  }
}

Future<List<ImportedCard>> _cardsOf(Database db, DateTime now) async {
  final col = (await db.query('col')).first;
  final created = DateTime.fromMillisecondsSinceEpoch((col['crt'] as int) * 1000);
  final models = (jsonDecode(col['models'] as String) as Map).map((k, v) => MapEntry(k.toString(), v as Map));
  final decks = (jsonDecode(col['decks'] as String) as Map).map((k, v) => MapEntry(k.toString(), (v as Map)['name'].toString()));
  final notes = <int, Map<String, Object?>>{for (final n in await db.query('notes')) n['id'] as int: n};
  final out = <ImportedCard>[];
  for (final c in await db.query('cards', orderBy: 'nid, ord')) {
    final note = notes[c['nid'] as int];
    if (note == null) continue;
    final model = models['${note['mid']}'];
    final fields = (note['flds'] as String).split('\x1f').map(ankiPlainText).toList();
    if (fields.isEmpty) continue;
    final ord = c['ord'] as int;
    String front, back;
    if (model != null && model['type'] == 1) {
      // a cloze note: the text is the first field, the second may hold extra words for the answer
      final (f, b) = clozeSides((note['flds'] as String).split('\x1f').first, ord + 1);
      front = ankiPlainText(f);
      back = [ankiPlainText(b), if (fields.length > 1 && fields[1].isNotEmpty) fields[1]].join('\n\n');
    } else {
      // (a note with a card in the other direction, "Basic (and reversed)", gives its second card turned round)
      final turned = ord == 1 && fields.length > 1 && (model?['tmpls'] as List?)?.length == 2;
      front = fields[turned ? 1 : 0];
      back = fields.length > 1 ? fields[turned ? 0 : 1] : '';
    }
    if (front.trim().isEmpty) continue;
    final deckName = decks['${c['did']}'] ?? 'Default';
    out.add(ImportedCard(deck: deckName, front: front, back: back, schedule: _scheduleOf(c, created, now)));
  }
  return out;
}

CardSchedule _scheduleOf(Map<String, Object?> c, DateTime created, DateTime now) {
  final type = c['type'] as int;
  final reps = (c['reps'] as num?)?.toInt() ?? 0;
  final lapses = (c['lapses'] as num?)?.toInt() ?? 0;
  if (type == 0) return const CardSchedule(); // new
  final factor = (c['factor'] as num?)?.toInt() ?? 0;
  final ease = factor > 0 ? (factor / 1000).clamp(CardSchedule.minimumEase, 5.0).toDouble() : CardSchedule.startingEase;
  final interval = (c['ivl'] as num?)?.toDouble() ?? 0;
  final due = (c['due'] as num?)?.toInt() ?? 0;
  // a card in the review queue (or learning for days) is due on a day counted from the creation of the collection; one in the learning
  // steps of the day is due at a time in seconds; a suspended or buried one goes by its type
  final queue = (c['queue'] as num?)?.toInt() ?? type;
  final DateTime when = switch (queue) {
    2 || 3 => created.add(Duration(days: due)),
    1 => DateTime.fromMillisecondsSinceEpoch(due * 1000),
    _ => type == 2 ? created.add(Duration(days: due)) : now,
  };
  return CardSchedule(interval: interval < 0 ? 0 : interval, ease: ease, reps: reps, lapses: lapses, due: when);
}
