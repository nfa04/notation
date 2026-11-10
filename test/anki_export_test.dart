import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/spaced_repetition.dart';
import 'package:notes/export/anki_export.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  final now = DateTime(2026, 11, 4, 12);

  Future<(Database, Directory)> open(List<AnkiCard> cards) async {
    final work = Directory.systemTemp.createTempSync('anki_test');
    final bytes = await ankiPackage(cards, workDirectory: work, now: now);
    final zip = ZipDecoder().decodeBytes(bytes);
    expect(zip.files.map((f) => f.name).toList()..sort(), ['collection.anki2', 'media']);
    expect(utf8.decode(zip.findFile('media')!.content), '{}');
    final out = Directory.systemTemp.createTempSync('anki_test_out');
    File('${out.path}/c.anki2').writeAsBytesSync(zip.findFile('collection.anki2')!.content);
    final db = await databaseFactoryFfi.openDatabase('${out.path}/c.anki2', options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    // nothing of the work folder is left
    expect(work.listSync(), isEmpty);
    work.deleteSync();
    return (db, out);
  }

  test('cards become notes and cards in decks, with their schedule', () async {
    final (db, out) = await open([
      const AnkiCard(id: 'a1', deck: 'Algorithms', front: 'What is \$O(n)\$?', back: 'Linear time.\nSecond line', source: 'Algorithms, p. 3', schedule: CardSchedule()),
      AnkiCard(
        id: 'a2',
        deck: 'Algorithms',
        front: 'Sum \$\$\\sum_{k=1}^n k\$\$',
        back: 'a < b & c',
        schedule: CardSchedule(interval: 6, ease: 2.35, reps: 3, lapses: 1, due: now.add(const Duration(days: 2))),
      ),
      const AnkiCard(id: 'b1', deck: 'Biology', front: 'Cell', back: 'Unit of life', schedule: CardSchedule()),
    ]);
    try {
      final notes = await db.query('notes', orderBy: 'id');
      expect(notes, hasLength(3));
      expect(notes[0]['guid'], 'a1');
      expect((notes[0]['flds'] as String).split('\x1f'), [r'What is \(O(n)\)?', 'Linear time.<br>Second line', 'Algorithms, p. 3']);
      expect(notes[0]['sfld'], r'What is \(O(n)\)?');
      expect(notes[0]['tags'], ' Algorithms ');
      expect((notes[1]['flds'] as String).split('\x1f').take(2), [r'Sum \[\sum_{k=1}^n k\]', 'a &lt; b &amp; c']);
      expect(notes.map((n) => n['id']).toSet(), hasLength(3));

      final cards = await db.query('cards', orderBy: 'id');
      expect(cards, hasLength(3));
      // new
      expect([cards[0]['type'], cards[0]['queue'], cards[0]['due'], cards[0]['ivl'], cards[0]['factor']], [0, 0, 1, 0, 0]);
      // learned: a review card, due in two days, with its ease
      expect([cards[1]['type'], cards[1]['queue'], cards[1]['ivl'], cards[1]['factor'], cards[1]['reps'], cards[1]['lapses']], [2, 2, 6, 2350, 3, 1]);
      final col = (await db.query('col')).single;
      final today = ((now.millisecondsSinceEpoch ~/ 1000 - (col['crt'] as int)) / 86400).floor();
      expect(cards[1]['due'], today + 2);
      expect(cards[2]['due'], 2);
      expect(cards.map((c) => c['nid']), notes.map((n) => n['id']));

      // the decks: the root and one for each note
      final decks = jsonDecode(col['decks'] as String) as Map<String, dynamic>;
      expect(decks.values.map((d) => d['name']).toSet(), {'Default', 'Notation', 'Notation::Algorithms', 'Notation::Biology'});
      final deckOf = {for (final d in decks.values) d['name']: d['id']};
      expect(cards[0]['did'], deckOf['Notation::Algorithms']);
      expect(cards[2]['did'], deckOf['Notation::Biology']);

      final models = jsonDecode(col['models'] as String) as Map<String, dynamic>;
      final model = models.values.single as Map<String, dynamic>;
      expect((model['flds'] as List).map((f) => f['name']), ['Front', 'Back', 'Source']);
      expect(notes.every((n) => '${n['mid']}' == models.keys.single), isTrue);
      expect(col['ver'], 11);
      expect(jsonDecode(col['dconf'] as String), isA<Map>());
    } finally {
      await db.close();
      out.deleteSync(recursive: true);
    }
  });

  test('an overdue card is due on the day of the import', () async {
    final (db, out) = await open([
      AnkiCard(id: 'x', deck: 'D', front: 'f', back: 'b', schedule: CardSchedule(interval: 10, reps: 4, due: now.subtract(const Duration(days: 9)))),
    ]);
    try {
      expect((await db.query('cards')).single['due'], 0);
    } finally {
      await db.close();
      out.deleteSync(recursive: true);
    }
  });

  test('a card that was forgotten is a review card again, not a new one', () async {
    final (db, out) = await open([
      AnkiCard(id: 'x', deck: 'D', front: 'f', back: 'b', schedule: CardSchedule(lapses: 1, ease: 2.3, due: now.add(const Duration(minutes: 10)))),
    ]);
    try {
      final c = (await db.query('cards')).single;
      expect([c['type'], c['ivl'], c['lapses']], [2, 1, 1]);
    } finally {
      await db.close();
      out.deleteSync(recursive: true);
    }
  });

  test('the same card has the same guid when it is exported again', () async {
    final a = await open([const AnkiCard(id: 'same', deck: 'D', front: 'f', back: 'b', schedule: CardSchedule())]);
    final b = await open([const AnkiCard(id: 'same', deck: 'D', front: 'f', back: 'b', schedule: CardSchedule())]);
    try {
      expect((await a.$1.query('notes')).single['guid'], (await b.$1.query('notes')).single['guid']);
      expect((await a.$1.query('col')).single['models'], (await b.$1.query('col')).single['models']);
    } finally {
      await a.$1.close();
      await b.$1.close();
      a.$2.deleteSync(recursive: true);
      b.$2.deleteSync(recursive: true);
    }
  });

  group('the text of a field', () {
    test('formulas', () {
      expect(ankiField(r'$x^2$ and $$y$$'), r'\(x^2\) and \[y\]');
      expect(ankiField(r'it costs $5 and $6'), r'it costs $5 and $6');
      expect(ankiField(r'a \$b\$'), r'a \$b\$');
      expect(ankiField(r'$a < b$'), r'\(a &lt; b\)');
    });

    test('markup and line breaks are kept as text', () {
      expect(ankiField('<b>x</b>\ny'), '&lt;b&gt;x&lt;/b&gt;<br>y');
    });
  });
}
