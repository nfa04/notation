import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/note_delta.dart';
import 'package:notes/collab/replica.dart' show ElementKind;
import 'package:notes/data/app_database.dart';
import 'package:notes/data/database_schema.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/history/note_history.dart';
import 'package:notes/history/version_diff.dart';
import 'package:notes/models/authorship.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/models/pdf_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DrawingStroke line(String id, double y, {String? author}) =>
    DrawingStroke(id: id, color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, y + i)], author: author);

/// A note with something from three people (and something from nobody).
void fill(NoteData n, {required String picture}) {
  n.strokes[0] = [line('s1', 10, author: 'Anna'), line('s2', 40, author: 'Ben'), line('s3', 70)];
  n.textBoxes[0] = [TextBoxWidgetModel(id: 'b1', position: const Offset(20, 100), initialText: 'Hi', author: 'Cleo')];
  n.images[1] = [ImageItem(id: 'i1', path: picture, position: const Offset(5, 5), size: const Size(40, 30), author: 'Anna')];
  n.highlights[1] = [PdfHighlight(id: 'h1', rect: const Rect.fromLTWH(10, 10, 50, 12), color: Colors.yellow, author: 'Ben')];
}

Map<String, String?> authorsOf(NoteData n) => {
      for (final l in n.strokes.values) for (final s in l) 'stroke:${s.id}': s.author,
      for (final l in n.textBoxes.values) for (final b in l) 'box:${b.id}': b.author,
      for (final l in n.images.values) for (final m in l) 'image:${m.id}': m.author,
      for (final l in n.highlights.values) for (final h in l) 'mark:${h.id}': h.author,
    };

const expected = {
  'stroke:s1': 'Anna',
  'stroke:s2': 'Ben',
  'stroke:s3': null,
  'box:b1': 'Cleo',
  'image:i1': 'Anna',
  'mark:h1': 'Ben',
};

void main() {
  setUpAll(AppDatabase.initFfi);
  tearDown(() {
    Authorship.set(null);
    Authorship.setId(null);
  });

  late Directory dir;
  late File picture;
  late Database db;
  late NoteRepository repo;
  late String id;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('authors_');
    Directory('${dir.path}/support').createSync();
    picture = File('${dir.path}/p.png')..writeAsBytesSync(Uint8List.fromList(List.generate(200, (i) => i % 256)));
    db = await AppDatabase.open(path: '${dir.path}/n.db');
    repo = NoteRepository(db);
    id = await repo.createNote(title: 'Plan');
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  group('in the database', () {
    test('who made a stroke, box, picture and highlight is saved and read back', () async {
      final n = (await repo.loadNote(id))!;
      fill(n, picture: picture.path);
      await repo.saveNote(n);
      expect(authorsOf((await repo.loadNote(id))!), expected);
    });

    test('putTextBox keeps the author too', () async {
      await repo.putTextBox(id, 0, TextBoxWidgetModel(id: 'hw-0-1', position: Offset.zero, author: 'Dana'));
      expect(authorsOf((await repo.loadNote(id))!), {'box:hw-0-1': 'Dana'});
    });

    test('a stroke keeps its author when it is changed and saved again', () async {
      final n = (await repo.loadNote(id))!;
      n.strokes[0] = [line('s1', 10, author: 'Anna')];
      await repo.saveNote(n);
      final again = (await repo.loadNote(id))!;
      again.strokes[0]!.single.points.add(const Offset(99, 99));
      await repo.saveNote(again);
      expect(authorsOf((await repo.loadNote(id))!), {'stroke:s1': 'Anna'});
    });

    test('a database from before authors gets the columns, and what was in it has no author', () async {
      await db.close();
      // a database as version 16 had it: the same tables without the author columns
      final old = '${dir.path}/old.db';
      final legacy = await databaseFactory.openDatabase(old,
          options: OpenDatabaseOptions(
              version: 16,
              onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
              onCreate: (d, _) async {
                for (final sql in createStatements) {
                  final lines = sql.split('\n').where((l) => !RegExp(r'^\s*(author\s+TEXT|favorite\s+INTEGER|fill\s+INTEGER|dash\s+INTEGER|pressure\s+BLOB|lock_mode\s+INTEGER|auto\s+INTEGER|changed_at\s+INTEGER)').hasMatch(l)).join('\n');
                  await d.execute(lines.replaceAllMapped(RegExp(r',(\s*(?:--[^\n]*)?\n\s*\))'), (m) => m.group(1)!));
                }
              }));
      expect((await legacy.rawQuery('PRAGMA table_info(strokes)')).map((c) => c['name']), isNot(contains('author')));
      await legacy.insert('notes', {'id': 'n', 'created_at': 1, 'updated_at': 1});
      await legacy.insert('strokes', {'uid': 'old', 'note_id': 'n', 'page_index': 0, 'color': 0xFF000000, 'width': 3.0, 'points': Uint8List(32)});
      await legacy.insert('text_boxes', {'id': 'b', 'note_id': 'n', 'page_index': 0, 'x': 0, 'y': 0, 'width': 260, 'height': 0});
      await legacy.close();

      final upgraded = await AppDatabase.open(path: old);
      for (final table in ['strokes', 'text_boxes', 'highlights', 'images']) {
        expect((await upgraded.rawQuery('PRAGMA table_info($table)')).map((c) => c['name']), contains('author'), reason: table);
      }
      final upgradedRepo = NoteRepository(upgraded);
      final note = (await upgradedRepo.loadNote('n'))!;
      expect(authorsOf(note), {'stroke:old': null, 'box:b': null}, reason: 'what was there is kept, without an author');
      note.textBoxes[0]!.single.author = 'Anna';
      await upgradedRepo.saveNote(note);
      expect(authorsOf((await upgradedRepo.loadNote('n'))!), {'stroke:old': null, 'box:b': 'Anna'});
      await upgraded.close();
      db = await AppDatabase.open(path: '${dir.path}/n.db'); // (for the tear-down)
    });
  });

  group('in the note file', () {
    test('every author is in the file and comes back, and a note without authors has no author fields', () async {
      final n = NoteData(id: 'x', title: 'T');
      fill(n, picture: picture.path);
      final bytes = encodeNoteFile(NoteFileParts(n, images: {'i1': picture.readAsBytesSync()}, imageExtensions: const {'i1': 'png'}));
      final parsed = decodeNoteFile(bytes);
      expect(authorsOf(parsed.note), expected);

      final bare = NoteData(id: 'y');
      bare.strokes[0] = [line('s1', 10)];
      bare.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: Offset.zero)];
      final text = String.fromCharCodes(encodeNoteFile(NoteFileParts(bare)));
      expect(text.contains('"author"'), isFalse);
      expect(text.contains('"authors"'), isFalse);
      expect(authorsOf(decodeNoteFile(encodeNoteFile(NoteFileParts(bare))).note), {'stroke:s1': null, 'box:b': null});
    });

    test('a file written before authors existed (no author fields) opens, and a file with an unknown stroke number does not break', () async {
      final n = NoteData(id: 'x');
      n.strokes[0] = [line('s1', 10, author: 'Anna')];
      final parsed = decodeNoteFile(encodeNoteFile(NoteFileParts(n)));
      expect(parsed.note.strokes[0]!.single.author, 'Anna');
      // the number of a name that is not in the list is ignored
      final entries = noteFileEntries(NoteFileParts(n));
      final manifest = String.fromCharCodes(entries.first.$2).replaceAll('"Anna"', '"Anna"').replaceAll(RegExp(r'"by": \{\s*"s1": 0'), '"by": {"s1": 7');
      final broken = zipNoteFile([(entries.first.$1, Uint8List.fromList(manifest.codeUnits), true), ...entries.skip(1)]);
      expect(decodeNoteFile(broken).note.strokes[0]!.single.author, isNull);
    });

    test('opening a file as a note and exporting a note both keep the authors', () async {
      final n = NoteData(id: 'x', title: 'T');
      fill(n, picture: picture.path);
      final files = NoteFileService(repo, supportDirectory: () async => Directory('${dir.path}/support'));
      final imported = await files.importBytes(encodeNoteFile(NoteFileParts(n, images: {'i1': picture.readAsBytesSync()}, imageExtensions: const {'i1': 'png'})));
      expect(authorsOf((await repo.loadNote(imported.noteId))!), expected);

      final out = decodeNoteFile((await files.exportBytes(imported.noteId))!);
      expect(authorsOf(out.note), expected);
    });
  });

  group('in changes between devices', () {
    test('what is sent about a thing says who made it, and the same for a change found by comparing', () async {
      final n = NoteData(id: 'x');
      fill(n, picture: picture.path);
      final ops = NoteDelta.changesSince(n, const {});
      expect({for (final op in ops) if (op.kind != ElementKind.note) '${op.kind.name}:${op.id}': op.data['a']}, expected, reason: 'no author, no field');
    });
  });

  group('in the history', () {
    test('a version keeps who made what', () async {
      final n = (await repo.loadNote(id))!;
      fill(n, picture: picture.path);
      await repo.saveNote(n);
      final history = NoteHistory(db, repo, supportDirectory: () async => Directory('${dir.path}/support'));
      final v = (await history.snapshot(id))!;
      await repo.saveNote((await repo.loadNote(id))!..strokes = {});
      expect(authorsOf((await history.read(v)).note), expected);
      history.dispose();
    });

    test('the comparison says who added, removed and changed what', () async {
      final older = NoteData(id: 'x');
      fill(older, picture: picture.path);
      final newer = NoteData(id: 'x');
      fill(newer, picture: picture.path);
      newer.strokes[0] = [line('s1', 10, author: 'Anna'), line('s3', 70), line('s4', 120, author: 'Ben'), line('s5', 150, author: 'Ben')]; // s2 gone
      newer.strokes[0]![1].points.add(const Offset(50, 50)); // s3 changed (no author)
      newer.textBoxes[0]!.single.position = const Offset(60, 100); // b1 moved: Cleo's
      final diff = VersionDiff.between(older, newer);
      expect(diff.byAuthor(ChangeKind.added), {'Ben': 2});
      expect(diff.byAuthor(ChangeKind.removed), {'Ben': 1});
      expect(diff.byAuthor(ChangeKind.changed), {null: 1, 'Cleo': 1});
    });

    test('who is in a note, with how much each did, and a colour each', () {
      final n = NoteData(id: 'x');
      fill(n, picture: picture.path);
      final authors = NoteAuthors.of(n);
      expect([for (final p in authors.people) (p.name, p.count)], [('Anna', 2), ('Ben', 2), ('Cleo', 1)]);
      expect(authors.unknown, 1);
      final names = [for (final p in authors.people) p.name];
      final colors = {for (final name in names) NoteAuthors.colorOf(name, names)};
      expect(colors.length, 3, reason: 'three people, three colours');
      expect(NoteAuthors.colorOf(null, names), isNot(isIn(colors)));
    });
  });

  group('in the editor', () {
    testWidgets('what the person adds gets their name: a text box, a drawing', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Authorship.set('  Noel ');
      Authorship.setId('0123456789abcdef');
      expect(Authorship.name, 'Noel');
      expect(Authorship.current, '0123456789abcdef:Noel');
      late NoteRepository r;
      late String nid;
      await tester.runAsync(() async {
        final d = await AppDatabase.open(path: inMemoryDatabasePath);
        r = NoteRepository(d);
        nid = await r.createNote();
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(nid), noteId: nid, repository: r)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();

      // a drawing
      await tester.ensureVisible(find.text('Draw'));
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
      final g = await tester.startGesture(origin + const Offset(200, 200), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
      for (var i = 1; i <= 8; i++) {
        await g.moveTo(origin + Offset(200 + i * 20, 200 + i * 5));
        await tester.pump();
      }
      await g.up();
      await tester.pump();

      // a text box (three clicks)
      for (var i = 0; i < 3; i++) {
        final c = await tester.startGesture(origin + const Offset(300, 500), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
        await c.up();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump(const Duration(milliseconds: 80));
      }
      await tester.pumpAndSettle();

      Authorship.set('Somebody else'); // (the name changing later does not change who made what)
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
      await tester.pump(const Duration(milliseconds: 1000));
      late NoteData saved;
      await tester.runAsync(() async => saved = (await r.loadNote(nid))!);
      expect(saved.strokes[0], isNotEmpty);
      expect(saved.textBoxes[0], isNotEmpty);
      expect(authorsOf(saved).values.toSet(), {'0123456789abcdef:Noel'}, reason: 'the name and the id of the person');
      expect(Author.parse(saved.textBoxes[0]!.first.author)!.name, 'Noel');
    });
  });
}
