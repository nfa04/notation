import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/pdf_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DrawingStroke line(double y, {Color color = Colors.black, int points = 10}) =>
    DrawingStroke(color: color, width: 3, points: [for (var i = 0; i < points; i++) Offset(10.0 + i * 5, y + i)]);

void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  late NoteRepository repo;
  late String id;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('incremental_');
    db = await AppDatabase.open(path: '${dir.path}/n.db');
    repo = NoteRepository(db);
    id = await repo.createNote();
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<List<int>> rows() async => [for (final r in await db.query('strokes', columns: ['id'], where: 'note_id = ?', whereArgs: [id], orderBy: 'id')) r['id'] as int];

  Future<List<double>> firstYs(NoteData n, int page) async => [for (final s in n.strokes[page] ?? const <DrawingStroke>[]) s.points.first.dy];

  test('the database is in write-ahead mode, which makes small writes cheap', () async {
    // (a file, as an in-memory database has no log)
    final mode = await db.rawQuery('PRAGMA journal_mode');
    expect(mode.single.values.single.toString().toLowerCase(), 'wal');
    expect((await db.rawQuery('PRAGMA synchronous')).single.values.single, 1); // NORMAL
  });

  test('a save after one new stroke leaves the other rows as they were', () async {
    final n = (await repo.loadNote(id))!;
    n.strokes[0] = [line(10), line(50), line(90)];
    await repo.saveNote(n);
    final before = await rows();
    expect(before.length, 3);

    n.strokes[0]!.add(line(130));
    await repo.saveNote(n);
    final after = await rows();
    expect(after.sublist(0, 3), before); // the same rows, not written again
    expect(after.length, 4);

    final back = (await repo.loadNote(id))!;
    expect(await firstYs(back, 0), [10, 50, 90, 130]);
  });

  test('a stroke that was moved or straightened is updated in its row', () async {
    final n = (await repo.loadNote(id))!;
    n.strokes[0] = [line(10), line(50), line(90, points: 40)];
    await repo.saveNote(n);
    final before = await rows();

    final s = n.strokes[0]![1];
    for (var i = 0; i < s.points.length; i++) {
      s.points[i] += const Offset(7, 100); // moved, as the lasso does
    }
    final last = n.strokes[0]![2];
    last.points.removeRange(2, last.points.length); // cut down to a line, as straightening does
    await repo.saveNote(n);
    expect(await rows(), before);

    final back = (await repo.loadNote(id))!;
    expect(back.strokes[0]![1].points.first, const Offset(17, 150));
    expect(back.strokes[0]![2].points.length, 2);
    expect(back.strokes[0]![0].points.first, const Offset(10, 10)); // untouched
  });

  test('an erased stroke is deleted', () async {
    final n = (await repo.loadNote(id))!;
    n.strokes[0] = [line(10), line(50), line(90)];
    await repo.saveNote(n);
    n.strokes[0]!.removeAt(1);
    await repo.saveNote(n);
    expect((await rows()).length, 2);
    expect(await firstYs((await repo.loadNote(id))!, 0), [10, 90]);
  });

  test('an erase that is taken back keeps the stroke where it was in the drawing order', () async {
    final n = (await repo.loadNote(id))!;
    n.strokes[0] = [line(10), line(50), line(90)];
    await repo.saveNote(n);
    final erased = n.strokes[0]!.removeAt(1);
    await repo.saveNote(n);
    n.strokes[0]!.insert(1, erased); // undo
    await repo.saveNote(n);
    expect(await firstYs((await repo.loadNote(id))!, 0), [10, 50, 90]);
    expect((await rows()).length, 3);
  });

  test('a stroke moved to another page is on that page, on top', () async {
    final n = (await repo.loadNote(id))!;
    n.strokes[0] = [line(10), line(50)];
    n.strokes[1] = [line(200)];
    await repo.saveNote(n);
    final moved = n.strokes[0]!.removeAt(0);
    n.strokes[1]!.add(moved);
    await repo.saveNote(n);
    final back = (await repo.loadNote(id))!;
    expect(await firstYs(back, 0), [50]);
    expect(await firstYs(back, 1), [200, 10]);
  });

  test('a note built again from scratch replaces what was stored', () async {
    final n = (await repo.loadNote(id))!;
    n.strokes[0] = [line(10), line(50)];
    await repo.saveNote(n);
    final fresh = NoteData(id: id, strokes: {0: [line(300)]});
    await repo.saveNote(fresh);
    expect(await firstYs((await repo.loadNote(id))!, 0), [300]);
    expect((await rows()).length, 1);
  });

  test('what is saved is what the stroke was when the save began, and the next save notices the change', () async {
    final n = (await repo.loadNote(id))!;
    n.strokes[0] = [line(10)];
    final saving = repo.saveNote(n);
    n.strokes[0]![0].points.add(const Offset(500, 500)); // drawn on while the save is under way
    await saving;
    await repo.saveNote(n);
    expect((await repo.loadNote(id))!.strokes[0]!.single.points.last, const Offset(500, 500));
  });

  test('strokes loaded from the database are not written again until they change', () async {
    final n = (await repo.loadNote(id))!;
    n.strokes[0] = [for (var i = 0; i < 20; i++) line(10.0 + i * 20)];
    await repo.saveNote(n);
    final loaded = (await repo.loadNote(id))!; // a new run of the app
    final before = await rows();
    loaded.strokes[0]!.add(line(999));
    await repo.saveNote(loaded);
    final after = await rows();
    expect(after.sublist(0, 20), before);
    expect(after.length, 21);
  });

  test('a stroke has a stamp that moves with every kind of change', () {
    final s = line(10, points: 100);
    final stamp = s.stamp;
    expect(line(10, points: 100).stamp, stamp);
    s.points[0] += const Offset(1, 0);
    expect(s.stamp, isNot(stamp));
    final t = line(10, points: 100)..points.add(const Offset(1, 1));
    expect(t.stamp, isNot(stamp));
    final moved = line(10, points: 100);
    for (var i = 0; i < moved.points.length; i++) {
      moved.points[i] += const Offset(0, 3);
    }
    expect(moved.stamp, isNot(stamp));
  });

  test('strokes and highlights keep their ids through saving and loading', () async {
    final n = (await repo.loadNote(id))!;
    final a = line(10), b = line(50);
    n.strokes[0] = [a, b];
    n.highlights[0] = [PdfHighlight(rect: const Rect.fromLTWH(1, 2, 3, 4), color: Colors.yellow)];
    await repo.saveNote(n);
    final back = (await repo.loadNote(id))!;
    expect(back.strokes[0]!.map((s) => s.id), [a.id, b.id]);
    expect(back.highlights[0]!.single.id, n.highlights[0]!.single.id);
    expect(a.id, isNot(b.id));
  });

  test('a stroke from before ids existed gets one, and keeps it', () async {
    final n = (await repo.loadNote(id))!;
    n.strokes[0] = [line(10)];
    await repo.saveNote(n);
    await db.execute('UPDATE strokes SET uid = NULL');
    final old = (await repo.loadNote(id))!;
    final given = old.strokes[0]!.single.id;
    await repo.saveNote(old); // the id is written now
    expect((await repo.loadNote(id))!.strokes[0]!.single.id, given);
  });
}
