import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/spaced_repetition.dart';
import 'package:notes/export/anki_export.dart';
import 'package:notes/export/anki_import.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  final now = DateTime(2026, 11, 4, 12);
  late Directory work;

  setUp(() => work = Directory.systemTemp.createTempSync('anki_import_test'));
  tearDown(() => work.deleteSync(recursive: true));

  Future<List<ImportedCard>> roundTrip(List<AnkiCard> cards) async {
    final bytes = await ankiPackage(cards, workDirectory: work, now: now);
    return readAnkiPackage(bytes, workDirectory: work, now: now);
  }

  group('what Anki writes becomes plain text', () {
    test('markup, line breaks, formulas, entities, pictures and sounds', () {
      expect(ankiPlainText('What is \\(O(n)\\)?<br>Second &amp; third'), 'What is \$O(n)\$?\nSecond & third');
      expect(ankiPlainText('<div>one</div><div>two</div>'), 'one\ntwo');
      expect(ankiPlainText('Sum \\[\\sum_{k=1}^n k\\]'), r'Sum $$\sum_{k=1}^n k$$');
      expect(ankiPlainText('a &lt; b &#8211; c<img src="x.png">[sound:y.mp3]'), 'a < b – c[image]');
      expect(ankiPlainText('<b>bold</b>&nbsp;text'), 'bold text');
    });

    test('a cloze hides one part and shows the others', () {
      const text = 'The {{c1::stack}} is {{c2::LIFO::order}}.';
      expect(clozeSides(text, 1), ('The [...] is LIFO.', 'The stack is LIFO.'));
      expect(clozeSides(text, 2), ('The stack is [order].', 'The stack is LIFO.'));
    });
  });

  group('a package made by the export', () {
    test('comes back with its decks, texts and schedule', () async {
      final read = await roundTrip([
        const AnkiCard(id: 'a1', deck: 'Algorithms', front: 'What is \$O(n)\$?', back: 'Linear time.\nSecond line', source: 'Algorithms, p. 3', schedule: CardSchedule()),
        AnkiCard(id: 'a2', deck: 'Algorithms', front: 'a < b & c', back: r'$$\sum_k k$$', schedule: CardSchedule(interval: 6, ease: 2.35, reps: 3, lapses: 1, due: DateTime(2026, 11, 6, 4))),
        const AnkiCard(id: 'b1', deck: 'Biology', front: 'Cell', back: 'Unit of life', schedule: CardSchedule()),
      ]);
      expect(read, hasLength(3));
      expect(read.map((c) => c.deck).toList(), ['Notation::Algorithms', 'Notation::Algorithms', 'Notation::Biology']);
      expect(read[0].front, r'What is $O(n)$?');
      expect(read[0].back, 'Linear time.\nSecond line');
      expect(read[0].schedule.reps, 0);
      expect(read[0].schedule.due, isNull);
      expect(read[1].front, 'a < b & c');
      expect(read[1].back, r'$$\sum_k k$$');
      final s = read[1].schedule;
      expect([s.interval, s.ease, s.reps, s.lapses], [6, 2.35, 3, 1]);
      expect(s.due!.difference(DateTime(2026, 11, 6, 4)).inHours.abs(), lessThan(24), reason: 'the same day, however the clock of the collection is counted');
      expect(read[2].back, 'Unit of life');
    });

    test('a package in the newest format says what to do; a file that is no package says so', () async {
      final bytes = ZipEncoder().encode(Archive()..add(ArchiveFile.bytes('collection.anki21b', [1, 2, 3])));
      await expectLater(readAnkiPackage(Uint8List.fromList(bytes), workDirectory: work), throwsA(isA<AnkiImportException>().having((e) => e.message, 'message', contains('Support older Anki versions'))));
      await expectLater(readAnkiPackage(Uint8List.fromList(utf8.encode('hello')), workDirectory: work), throwsA(isA<AnkiImportException>()));
      final junk = ZipEncoder().encode(Archive()..add(ArchiveFile.bytes('collection.anki2', utf8.encode('not a database'))));
      await expectLater(readAnkiPackage(Uint8List.fromList(junk), workDirectory: work), throwsA(isA<AnkiImportException>()));
      expect(work.listSync(), isEmpty, reason: 'nothing is left of the work folder');
    });

    test('a package with a flood of files is turned away as too big, before it takes the memory', () async {
      final flood = Archive();
      for (var i = 0; i < 10001; i++) {
        flood.addFile(ArchiveFile.bytes('media$i', const [1]));
      }
      final bytes = Uint8List.fromList(ZipEncoder().encode(flood));
      await expectLater(
        readAnkiPackage(bytes, workDirectory: work, now: now),
        throwsA(isA<AnkiImportException>().having((e) => e.message, 'message', contains('too big'))),
      );
    });

    test('a zip without a collection, and bytes that are no zip at all, are no packages', () async {
      final other = Archive()..addFile(ArchiveFile.bytes('readme.txt', utf8.encode('hello')));
      final zip = Uint8List.fromList(ZipEncoder().encode(other));
      for (final bytes in [zip, Uint8List(0), Uint8List.fromList(List.filled(100, 7))]) {
        await expectLater(
          readAnkiPackage(bytes, workDirectory: work, now: now),
          throwsA(isA<AnkiImportException>().having((e) => e.message, 'message', 'This is not an Anki package.')),
        );
      }
    });

    test('a collection file that is no database is no package, and leaves no work file behind', () async {
      final bad = Archive()..addFile(ArchiveFile.bytes('collection.anki2', utf8.encode('this is not sqlite')));
      final bytes = Uint8List.fromList(ZipEncoder().encode(bad));
      await expectLater(readAnkiPackage(bytes, workDirectory: work, now: now), throwsA(isA<AnkiImportException>()));
      expect(work.listSync(), isEmpty);
    });

    test('a database that is no Anki collection (empty col table, models that are no JSON, other column types) is no package', () async {
      Future<Uint8List> package(Future<void> Function(Database db) fill) async {
        final path = '${work.path}/make.sqlite';
        final db = await databaseFactoryFfi.openDatabase(path);
        await fill(db);
        await db.close();
        final zip = Archive()..addFile(ArchiveFile.bytes('collection.anki2', File(path).readAsBytesSync()));
        File(path).deleteSync();
        return Uint8List.fromList(ZipEncoder().encode(zip));
      }

      final cases = <String, Future<void> Function(Database)>{
        'an empty col table': (db) => db.execute('CREATE TABLE col (crt INTEGER, models TEXT, decks TEXT)'),
        'models that are no JSON': (db) async {
          await db.execute('CREATE TABLE col (crt INTEGER, models TEXT, decks TEXT)');
          await db.insert('col', {'crt': 1, 'models': 'not json', 'decks': '{}'});
        },
        'a creation date that is text': (db) async {
          await db.execute('CREATE TABLE col (crt TEXT, models TEXT, decks TEXT)');
          await db.insert('col', {'crt': 'yesterday', 'models': '{}', 'decks': '{}'});
        },
        'models that are a list': (db) async {
          await db.execute('CREATE TABLE col (crt INTEGER, models TEXT, decks TEXT)');
          await db.insert('col', {'crt': 1, 'models': '[]', 'decks': '{}'});
        },
      };
      for (final c in cases.entries) {
        await expectLater(
          readAnkiPackage(await package(c.value), workDirectory: work, now: now),
          throwsA(isA<AnkiImportException>()),
          reason: c.key,
        );
      }
      expect(work.listSync(), isEmpty);
    });

    test('cloze notes give a card for each hidden part, and reversed notes a second card turned round', () async {
      final bytes = await ankiPackage([
        const AnkiCard(id: 'c', deck: 'D', front: 'x', back: 'y', schedule: CardSchedule()),
      ], workDirectory: work, now: now);
      // turn the one note into a cloze note with two cards, then into a reversed one with two cards
      final zip = ZipDecoder().decodeBytes(bytes);
      final path = '${work.path}/edit.sqlite';
      File(path).writeAsBytesSync(zip.findFile('collection.anki2')!.content);
      final db = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
      final col = (await db.query('col')).single;
      final models = jsonDecode(col['models'] as String) as Map<String, dynamic>;
      final id = models.keys.single;
      Future<Uint8List> pack(int type, String fields, {int templates = 1}) async {
        (models[id] as Map<String, dynamic>)['type'] = type;
        (models[id] as Map<String, dynamic>)['tmpls'] = List.filled(templates, {});
        await db.update('col', {'models': jsonEncode(models)});
        await db.update('notes', {'flds': fields});
        final card = (await db.query('cards')).single;
        await db.delete('cards');
        for (var ord = 0; ord < (type == 1 || templates == 2 ? 2 : 1); ord++) {
          await db.insert('cards', {...card, 'id': (card['id'] as int) + ord, 'ord': ord});
        }
        await db.close();
        return Uint8List.fromList(ZipEncoder().encode(Archive()..add(ArchiveFile.bytes('collection.anki2', File(path).readAsBytesSync()))));
      }

      final cloze = await readAnkiPackage(await pack(1, 'The {{c1::stack}} is {{c2::LIFO}}.\x1fExtra\x1f'), workDirectory: work, now: now);
      expect(cloze.map((c) => c.front).toList(), ['The [...] is LIFO.', 'The stack is [...].']);
      expect(cloze[0].back, 'The stack is LIFO.\n\nExtra');

      final db2 = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
      // (the same file again, now as a reversed note)
      (models[id] as Map<String, dynamic>)['type'] = 0;
      (models[id] as Map<String, dynamic>)['tmpls'] = [{}, {}];
      await db2.update('col', {'models': jsonEncode(models)});
      await db2.update('notes', {'flds': 'Front\x1fBack\x1f'});
      await db2.close();
      final reversed = await readAnkiPackage(Uint8List.fromList(ZipEncoder().encode(Archive()..add(ArchiveFile.bytes('collection.anki2', File(path).readAsBytesSync())))), workDirectory: work, now: now);
      expect(reversed.map((c) => (c.front, c.back)).toList(), [('Front', 'Back'), ('Back', 'Front')]);
    });
  });
}
