import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/history/note_history.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DrawingStroke line(String id, double y) => DrawingStroke(id: id, color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, y + i)]);

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory dir;
  late Database db;
  late NoteRepository notes;
  late NoteHistory history;
  late String id;
  var clock = DateTime(2026, 10, 19, 12);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('branches_');
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
    clock = clock.add(const Duration(minutes: 1));
  }

  Set<String> strokeIds(NoteData n) => {for (final l in n.strokes.values) for (final s in l) s.id};

  test('a new note is on the main branch; a branch takes the versions made after it, and switching keeps what was on the other', () async {
    expect(await history.activeBranch(id), 'main');
    final base = (await history.snapshot(id))!;
    expect(base.branch, 'main');

    final b = await history.createBranch(id, 'idea');
    expect(b.active, isTrue);
    expect(await history.activeBranch(id), 'idea');
    expect((await history.branches(id)).map((x) => (x.name, x.active)), [('main', false), ('idea', true)]);

    await change((n) => n.strokes[0] = [...n.strokes[0]!, line('on-idea', 60)]);
    final onIdea = (await history.snapshot(id))!;
    expect(onIdea.branch, 'idea');
    expect((await history.list(id, branch: 'main')).map((v) => v.id), [base.id]);
    expect((await history.list(id, branch: 'idea')).map((v) => v.id), [onIdea.id]);

    // back to main: the branch's head is kept first, the note is made what main is at
    await change((n) => n.strokes[0] = [...n.strokes[0]!, line('unsaved', 90)]);
    final main = await history.switchTo(id, 'main');
    expect(main!.id, base.id);
    expect(await history.activeBranch(id), 'main');
    final kept = await history.head(id, 'idea');
    expect(strokeIds((await history.read(kept!)).note), {'s1', 'on-idea', 'unsaved'}, reason: 'the work on the branch is kept when leaving it');
    expect((await history.read(main)).note.strokes[0]!.map((s) => s.id), ['s1']);
  });

  test('a branch with no version of its own is at the version it began from; names are checked', () async {
    final base = (await history.snapshot(id))!;
    await history.createBranch(id, 'try');
    expect((await history.head(id, 'try'))!.id, base.id);
    expect(() => history.createBranch(id, 'TRY'), throwsStateError);
    expect(() => history.createBranch(id, ' '), throwsStateError);
    expect(() => history.createBranch(id, 'main'), throwsStateError);
  });

  test('merging a branch: what only the branch changed comes in, what only the note changed stays, what both changed stays as the note has it', () async {
    await change((n) => n.strokes[0] = [line('s1', 10), line('both', 30), line('gone-on-branch', 50)]);
    await history.snapshot(id);
    await history.createBranch(id, 'idea');
    await change((n) {
      n.strokes[0] = [line('s1', 10), line('both', 99), line('new-on-branch', 70)]; // (changed 'both', dropped one, added one)
      n.title = 'Idea title';
    });
    await history.snapshot(id);
    await history.switchTo(id, 'main');
    // (switching only moves the versions; the editor makes the note what the branch was: here the test does)
    await change((n) {
      n.title = 'Plan';
      n.strokes[0] = [line('s1', 10), line('both', 40), line('gone-on-branch', 50), line('new-on-main', 80)];
    });

    final merge = await history.mergeChanges(id, 'idea', await note());
    expect(merge.conflicts, 1, reason: 'both changed "both"');
    final byKey = {for (final op in merge.changes) Replica.keyOf(op.kind, op.id): op.deleted};
    expect(byKey['stroke:new-on-branch'], false);
    expect(byKey['stroke:gone-on-branch'], true);
    expect(byKey.containsKey('stroke:both'), isFalse);
    expect(byKey.containsKey('stroke:new-on-main'), isFalse, reason: 'the branch never had it, and the note keeps it');
    expect(byKey['note:title'], false);

    // the next merge begins from where the branch was
    await history.completeMerge(id, 'idea', merge.head);
    expect((await history.branches(id)).firstWhere((b) => b.name == 'idea').base, merge.head.id);
  });

  test('the version a branch began from and the heads of branches are not thinned out', () async {
    await history.snapshot(id);
    await history.createBranch(id, 'idea');
    final base = (await history.branches(id)).last.base!;
    await change((n) => n.title = 'x');
    await history.snapshot(id);
    clock = clock.add(const Duration(days: 60));
    await change((n) => n.title = 'y');
    await history.snapshot(id);
    await history.prune(id);
    expect((await history.list(id)).any((v) => v.id == base), isTrue);
  });

  test('a branch can be deleted with its versions, but not the main one, the one the note is on, or one another began from', () async {
    await history.snapshot(id);
    await history.createBranch(id, 'a');
    await change((n) => n.title = 'on a');
    await history.snapshot(id);
    await history.createBranch(id, 'b'); // from a's head
    expect(() => history.deleteBranch(id, 'a'), throwsStateError); // b began from it
    expect(() => history.deleteBranch(id, 'b'), throwsStateError); // the note is on it
    expect(() => history.deleteBranch(id, 'main'), throwsStateError);
    await history.switchTo(id, 'main');
    await history.deleteBranch(id, 'b');
    expect((await history.branches(id)).map((b) => b.name), ['main', 'a']);
  });

  test('blame: each drawing is from the version it came in with, one that changed from where it changed, and the unsaved from after the last', () async {
    final v0 = (await history.snapshot(id))!; // s1
    await change((n) => n.strokes[0] = [...n.strokes[0]!, line('s2', 40)]);
    final v1 = (await history.snapshot(id))!; // s1 s2
    await change((n) => n.strokes[0] = [line('s1', 10), line('s2', 44), line('s3', 70)]); // s2 moved
    final v2 = (await history.snapshot(id))!;
    await change((n) => n.strokes[0] = [...n.strokes[0]!, line('s4', 100)]); // not in a version

    final blame = await history.blame(id, await note());
    expect(blame.versions.map((v) => v.id), [v0.id, v1.id, v2.id]);
    expect(blame.origin['stroke:s1'], -1, reason: 'it was there from the oldest version on');
    expect(blame.origin['stroke:s2'], 2, reason: 'it changed in v2');
    expect(blame.origin['stroke:s3'], 2);
    expect(blame.origin['stroke:s4'], 3, reason: 'in no version yet');
    expect(v1.id, isNot(v2.id));
  });

  test('blame of the written text goes by line: a line is from the version where it was written', () {
    final (lines, from) = NoteHistory.blameLines([
      'one\ntwo',
      'one\ntwo\nthree',
      'one\n2\nthree\nfour',
    ], 'one\n2\nthree\nfour\nfive');
    expect(lines, ['one', '2', 'three', 'four', 'five']);
    expect(from, [-1, 2, 1, 2, 3]);
  });

  test('blame goes through a branch: the versions it began from come first', () async {
    final v0 = (await history.snapshot(id))!;
    await history.createBranch(id, 'idea');
    await change((n) => n.strokes[0] = [...n.strokes[0]!, line('on-idea', 60)]);
    final v1 = (await history.snapshot(id))!;
    final blame = await history.blame(id, await note());
    expect(blame.versions.map((v) => v.id), [v0.id, v1.id]);
    expect(blame.origin['stroke:s1'], -1);
    expect(blame.origin['stroke:on-idea'], 1);
  });
}
