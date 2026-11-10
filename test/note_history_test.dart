import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/note_delta.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/history/note_history.dart';
import 'package:notes/history/version_diff.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/screens/history_panel.dart' show madeByAssistant, versionTitle;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DrawingStroke line(String id, double y) =>
    DrawingStroke(id: id, color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, y + i)]);

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory dir;
  late Database db;
  late NoteRepository notes;
  late NoteHistory history;
  late String id;
  var clock = DateTime(2026, 10, 19, 12);

  Directory blobs() => Directory('${dir.path}/support/versions/blobs');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('history_');
    Directory('${dir.path}/support').createSync();
    db = await AppDatabase.open(path: '${dir.path}/n.db');
    notes = NoteRepository(db);
    clock = DateTime(2026, 10, 19, 12);
    history = NoteHistory(db, notes, supportDirectory: () async => Directory('${dir.path}/support'), now: () => clock);
    id = await notes.createNote(title: 'Plan');
    await notes.saveNote((await notes.loadNote(id))!..strokes = {0: [line('s1', 10)]});
  });
  tearDown(() async {
    history.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<NoteData> note() async => (await notes.loadNote(id))!;
  Future<void> change(void Function(NoteData n) f) async {
    final n = await note();
    f(n);
    await notes.saveNote(n);
  }

  test('a version holds the note as it was: drawings, text boxes, pictures, title', () async {
    final picture = File('${dir.path}/pic.png')..writeAsBytesSync(Uint8List.fromList(List.generate(300, (i) => i % 256)));
    await change((n) {
      n.textBoxes[0] = [TextBoxWidgetModel(id: 'b1', position: const Offset(40, 60), initialText: 'Hello')];
      n.images[1] = [ImageItem(id: 'i1', path: picture.path, position: const Offset(5, 5), size: const Size(50, 40))];
    });
    final v = (await history.snapshot(id))!;
    await change((n) {
      n.title = 'Changed';
      n.strokes[0] = [];
    });

    final back = await history.read(v);
    expect(back.note.title, 'Plan');
    expect(back.note.strokes[0]!.single.id, 's1');
    expect(back.note.textBoxes[0]!.single.controller.text, 'Hello');
    expect(back.images['i1']!.bytes, picture.readAsBytesSync());
    expect(v.manual, isFalse);
    expect(v.reason, VersionReason.edit);
  });

  test('what the assistant did is told apart: a version before it, one after it, each saying what', () async {
    final before = (await history.snapshot(id, reason: VersionReason.assistantBefore, label: 'Replace "a"'))!;
    await change((n) => n.title = 'Retitled by the assistant');
    final after = (await history.snapshot(id, reason: VersionReason.assistant, label: 'Replace "a"'))!;
    final all = await history.list(id);
    expect(all.map((v) => v.reason), [VersionReason.assistant, VersionReason.assistantBefore]);
    expect(all.every((v) => !v.manual && v.label == 'Replace "a"'), isTrue);
    expect(versionTitle(before), 'Before the assistant: Replace "a"');
    expect(versionTitle(after), 'Made by the assistant: Replace "a"');
    expect(all.every(madeByAssistant), isTrue);
    expect(madeByAssistant((await history.snapshot(id, reason: VersionReason.edit, manual: true, label: 'mine'))!), isFalse);
    expect((await history.read(before)).note.title, 'Plan');
    expect((await history.read(after)).note.title, 'Retitled by the assistant');
  });

  test('the app makes no version when nothing changed; a version the person saves is always made', () async {
    final a = await history.snapshot(id);
    final b = await history.snapshot(id, reason: VersionReason.merge);
    expect(b!.id, a!.id, reason: 'the same note: the version there is');
    final c = await history.snapshot(id, manual: true, label: 'Exam');
    expect(c!.id, isNot(a.id));
    expect(c.manual, isTrue);
    expect(c.label, 'Exam');
    expect((await history.list(id)).length, 2);

    await change((n) => n.strokes[0]!.add(line('s2', 40)));
    final d = await history.snapshot(id);
    expect(d!.id, isNot(c.id));
    expect((await history.list(id)).map((v) => v.id), [d.id, c.id, a.id], reason: 'newest first');
  });

  test('pictures and the PDF are kept once, however many versions there are, and go when no version needs them', () async {
    final picture = File('${dir.path}/pic.png')..writeAsBytesSync(Uint8List.fromList(List.generate(500, (i) => i % 7)));
    final pdfBytes = Uint8List.fromList(List.generate(4000, (i) => i % 251));
    final pdf = File('${dir.path}/doc.pdf')..writeAsBytesSync(pdfBytes);
    await change((n) {
      n.images[0] = [ImageItem(id: 'i1', path: picture.path, position: Offset.zero, size: const Size(20, 20))];
      n
        ..pdfName = 'doc.pdf'
        ..pdfPath = pdf.path
        ..pdfSha256 = sha256.convert(pdfBytes).toString()
        ..pdfPageCount = 1;
    });
    final versions = <NoteVersion>[];
    for (var i = 0; i < 3; i++) {
      await change((n) => n.strokes[0]!.add(line('x$i', 20.0 * i)));
      versions.add((await history.snapshot(id))!);
    }
    expect(blobs().listSync().whereType<File>().length, 2, reason: 'one picture, one PDF');
    for (final v in versions) {
      expect(v.size, lessThan(pdfBytes.length), reason: 'a version does not carry the PDF');
    }
    expect((await history.read(versions.first)).pdf, pdfBytes);

    await history.delete(versions[0]);
    await history.delete(versions[1]);
    expect(blobs().listSync().whereType<File>().length, 2, reason: 'one version still needs them');
    await history.delete(versions[2]);
    expect(blobs().listSync().whereType<File>(), isEmpty);
  });

  test('restoring gives the changes that make the note what it was, deletions and the title included', () async {
    final v = (await history.snapshot(id))!;
    await change((n) {
      n.title = 'Later';
      n.strokes[0] = [line('s9', 90)];
    });
    final now = await note();
    final changes = await history.restoreChanges(v, now);
    final raw = Replica('restore');
    for (final op in changes) {
      raw.apply(now, op,
          makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
          saveImage: (_, _, _) => throw StateError('no pictures here'),
          onNoteField: (f, d) => Replica.applyNoteField(now, f, d));
    }
    expect(now.title, 'Plan');
    expect(now.strokes[0]!.map((s) => s.id), ['s1']);
    expect(NoteDelta.digests(now), NoteDelta.digests((await history.read(v)).note));
  });

  test('versions the app made are thinned out as they get older; the ones the person saved stay', () async {
    final start = clock;
    // one every 20 minutes for 40 days, oldest first
    for (var i = 40 * 24 * 3; i >= 0; i--) {
      clock = start.subtract(Duration(minutes: 20 * i));
      await change((n) => n.strokes[0] = [line('s$i', 10)]);
      await history.snapshot(id);
      if (i == 40 * 24 * 3) await history.snapshot(id, manual: true, label: 'Very old');
    }
    final all = await history.list(id);
    final auto = [for (final v in all) if (!v.manual) v];
    final day = [for (final v in auto) if (clock.difference(v.at) < const Duration(days: 1)) v];
    final week = [for (final v in auto) if (clock.difference(v.at) >= const Duration(days: 1) && clock.difference(v.at) < const Duration(days: 7)) v];
    final month = [for (final v in auto) if (clock.difference(v.at) >= const Duration(days: 7)) v];
    expect(day.length, 72, reason: 'all of the last day');
    expect(week.length, inInclusiveRange(6 * 24 - 1, 6 * 24 + 1), reason: 'one an hour');
    expect(month.length, inInclusiveRange(22, 24), reason: 'one a day, up to 30 days');
    expect(auto.every((v) => clock.difference(v.at) < const Duration(days: 31)), isTrue);
    expect(all.where((v) => v.manual).single.label, 'Very old');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('saving a note makes a version a little later, and not more often than every so often', () async {
    history.dispose();
    history = NoteHistory(db, notes,
        supportDirectory: () async => Directory('${dir.path}/support'), settle: const Duration(milliseconds: 30), every: const Duration(milliseconds: 400))
      ..start();
    await change((n) => n.strokes[0]!.add(line('s2', 30)));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect((await history.list(id)).length, 1);
    await change((n) => n.strokes[0]!.add(line('s3', 50)));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((await history.list(id)).length, 1, reason: 'too soon after the last one');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final versions = await history.list(id);
    expect(versions.length, 2);
    expect((await history.read(versions.first)).note.strokes[0]!.length, 3, reason: 'the note as it was when the version was made');
  });

  test('two saves at once make one version, not two', () async {
    history.dispose();
    history = NoteHistory(db, notes,
        supportDirectory: () async => Directory('${dir.path}/support'), settle: const Duration(milliseconds: 30), every: const Duration(milliseconds: 400))
      ..start();
    final n = (await notes.loadNote(id))!..strokes[0]!.add(line('s2', 30));
    // (the second save is done before the history has looked up the last version for the first)
    await Future.wait([notes.saveNote(n), notes.saveNote(n)]);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect((await history.list(id)).length, 1);
  });

  test('files of versions whose note was deleted for good are cleaned up', () async {
    await history.snapshot(id);
    final folder = Directory('${dir.path}/support/versions').listSync().whereType<Directory>().where((d) => !d.path.endsWith('blobs')).single;
    expect(folder.listSync(), hasLength(1));
    await db.delete('notes', where: 'id = ?', whereArgs: [id]); // (rows of its versions go with it)
    await history.cleanUp();
    expect(folder.listSync(), isEmpty);
  });

  test('the comparison finds what was added, removed and changed, where it is, and which fields changed', () async {
    final older = await note();
    final newer = await note();
    newer.title = 'New title';
    newer.strokes[0] = [line('s1', 30), line('s5', 200)]; // s1 moved, s5 new
    newer.strokes[2] = [line('s6', 10)];
    final added = await note();
    added.strokes[0] = [];
    final diff = VersionDiff.between(older, newer);
    expect(diff.count(ChangeKind.added), 2);
    expect(diff.count(ChangeKind.changed), 1);
    expect(diff.count(ChangeKind.removed), 0);
    expect(diff.fields, {'title'});
    expect(diff.onPage(2).single.id, 's6');
    final moved = diff.elements.firstWhere((e) => e.id == 's1');
    expect(moved.rect.top, lessThanOrEqualTo(10), reason: 'covers where it was and where it is');
    expect(moved.rect.bottom, greaterThanOrEqualTo(35));

    // the strokes themselves, as they were and as they are, to draw in colour
    expect((moved.older as DrawingStroke).points.first.dy, 10);
    expect((moved.newer as DrawingStroke).points.first.dy, 30);
    expect(diff.elements.firstWhere((e) => e.id == 's5').newer, isA<DrawingStroke>());

    // moved to another page: gone from the one, new on the other
    final elsewhere = await note();
    elsewhere.strokes[0] = [];
    elsewhere.strokes[3] = [line('s1', 10)];
    final across = VersionDiff.between(older, elsewhere);
    expect({for (final e in across.elements) (e.change, e.page)}, {(ChangeKind.removed, 0), (ChangeKind.added, 3)});

    final removed = VersionDiff.between(older, added);
    expect(removed.elements.single.change, ChangeKind.removed);
    expect(VersionDiff.between(older, older).isEmpty, isTrue);
  });
}
