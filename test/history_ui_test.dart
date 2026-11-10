import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/history/note_history.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';

DrawingStroke line(String id, double y) =>
    DrawingStroke(id: id, color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(100.0 + i * 5, y + i)]);

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('the history has two tabs; a version can be previewed, compared with now, and restored', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late NoteHistory history;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('history_ui_');
      Directory('${dir.path}/support').createSync();
      final db = await AppDatabase.open(path: '${dir.path}/n.db');
      repo = NoteRepository(db);
      history = NoteHistory(db, repo, supportDirectory: () async => Directory('${dir.path}/support'));
      id = await repo.createNote(title: 'Plan');
      await repo.saveNote((await repo.loadNote(id))!..strokes = {0: [line('s1', 100)]});
      await history.snapshot(id); // an automatic one: just s1
      await repo.saveNote((await repo.loadNote(id))!
        ..title = 'Later'
        ..strokes[0]!.add(line('s2', 300)));
      await history.snapshot(id, manual: true, label: 'Exam');
      await repo.saveNote((await repo.loadNote(id))!..strokes[0]!.add(line('s3', 500))); // not in any version yet
    });
    addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));

    Future<void> settle() async {
      // (not pumpAndSettle: a spinner in the editor never settles)
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(seconds: 1));
    }

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo, history: history)));
    await settle();

    await tester.ensureVisible(find.byKey(const ValueKey('history-button')));
    await tester.tap(find.byKey(const ValueKey('history-button')));
    await settle();
    expect(find.text('While editing'), findsOneWidget, reason: 'the automatic tab is first');
    expect(find.text('Exam'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('history-manual')));
    await settle();
    expect(find.text('Exam'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('history-auto')));
    await settle();

    // beside the note, and it can be made wider by dragging its edge
    final panel = find.byKey(const ValueKey('history-panel'));
    expect(panel, findsOneWidget);
    final width = tester.getSize(panel).width;
    await tester.drag(find.byKey(const ValueKey('history-resize')), const Offset(-150, 0));
    await tester.pump();
    expect(tester.getSize(panel).width, closeTo(width + 150, 1));

    // the automatic version, in the panel, compared with the note now
    await tester.tap(find.text('While editing'));
    await settle();
    expect(find.byKey(const ValueKey('preview-page-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('preview-compare')));
    await settle();
    await tester.tap(find.text('The note now').last);
    await settle();
    expect(find.text('Added since: 2 [2 drawings]'), findsOneWidget);
    expect(find.text('Removed since: 0'), findsOneWidget);
    expect(find.byKey(const ValueKey('diff-fields')), findsOneWidget, reason: 'the title changed too');
    expect(find.byKey(const ValueKey('diff-ink-0')), findsOneWidget, reason: 'the drawings themselves, in colour');

    // restored: the note is as it was, and what it was just before is a version of its own
    await tester.tap(find.byKey(const ValueKey('preview-restore')));
    await settle();
    await tester.tap(find.byKey(const ValueKey('version-restore-ok')));
    await settle();
    for (var i = 0; i < 20 && find.byKey(const ValueKey('history-back')).evaluate().isNotEmpty; i++) {
      await settle(); // (the note is kept as a version first, which is zipped away from the screen)
    }
    expect(find.text('Restore this version?'), findsNothing);
    expect(find.text('Added since: 2 [2 drawings]'), findsNothing, reason: 'back to the list');
    expect(panel, findsOneWidget, reason: 'the panel stays open');

    late List<NoteVersion> versions;
    await tester.runAsync(() async {
      final saved = (await repo.loadNote(id))!;
      expect(saved.title, 'Plan');
      expect(saved.strokes[0]!.map((s) => s.id), ['s1']);
      versions = await history.list(id);
    });
    expect(versions.first.reason, VersionReason.restore, reason: 'the note just before the restore is kept');
    late List<String> before;
    await tester.runAsync(() async => before = [for (final s in (await history.read(versions.first)).note.strokes[0]!) s.id]);
    expect(before, ['s1', 's2', 's3']);
  });

  testWidgets('"Who added what" colours each person\'s drawings, and the comparison counts per person', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late NoteHistory history;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('history_authors_');
      Directory('${dir.path}/support').createSync();
      final db = await AppDatabase.open(path: '${dir.path}/n.db');
      repo = NoteRepository(db);
      history = NoteHistory(db, repo, supportDirectory: () async => Directory('${dir.path}/support'));
      id = await repo.createNote(title: 'Plan');
      DrawingStroke by(String id, double y, String? who) => DrawingStroke(id: id, color: Colors.black, width: 3, author: who, points: [for (var i = 0; i < 6; i++) Offset(100.0 + i * 5, y + i)]);
      await repo.saveNote((await repo.loadNote(id))!..strokes = {0: [by('s1', 100, 'Anna'), by('s2', 200, 'Ben')]});
      await history.snapshot(id, manual: true, label: 'Start');
      await repo.saveNote((await repo.loadNote(id))!..strokes[0]!.addAll([by('s3', 300, 'Ben'), by('s4', 400, 'Ben'), by('s5', 500, 'Anna')]));
    });
    addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(seconds: 1));
    }

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo, history: history)));
    await settle();
    await tester.ensureVisible(find.byKey(const ValueKey('history-button')));
    await tester.tap(find.byKey(const ValueKey('history-button')));
    await settle();
    await tester.tap(find.byKey(const ValueKey('history-manual')));
    await settle();
    await tester.tap(find.text('Start'));
    await settle();

    // compared with now: Ben added two, Anna one
    await tester.tap(find.byKey(const ValueKey('preview-compare')));
    await settle();
    await tester.tap(find.text('The note now').last);
    await settle();
    expect(find.text('Added since: 3 [3 drawings] (Ben 2, Anna 1)'), findsOneWidget);

    // who added what in this version: Anna 1, Ben 1
    await tester.tap(find.byKey(const ValueKey('preview-compare')));
    await settle();
    await tester.tap(find.text('Who added what').last);
    await settle();
    expect(find.byKey(const ValueKey('author-legend')), findsOneWidget);
    expect(find.text('Anna 1'), findsOneWidget);
    expect(find.text('Ben 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('author-ink-0')), findsOneWidget);
  });

  testWidgets('two people with the same name show up apart in the history, by the start of their id', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const ben1 = '2222222222222222', ben2 = '3333333333333333';

    late NoteRepository repo;
    late NoteHistory history;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('history_ids_');
      Directory('${dir.path}/support').createSync();
      final db = await AppDatabase.open(path: '${dir.path}/n.db');
      repo = NoteRepository(db);
      history = NoteHistory(db, repo, supportDirectory: () async => Directory('${dir.path}/support'));
      id = await repo.createNote(title: 'Plan');
      DrawingStroke by(String id, double y, String? who) => DrawingStroke(id: id, color: Colors.black, width: 3, author: who, points: [for (var i = 0; i < 6; i++) Offset(100.0 + i * 5, y + i)]);
      await repo.saveNote((await repo.loadNote(id))!..strokes = {0: [by('s1', 100, '$ben1:Ben'), by('s2', 200, '$ben2:Ben'), by('s3', 300, '$ben2:Ben'), by('s4', 400, 'Anna')]});
      await history.snapshot(id, manual: true, label: 'Now');
    });
    addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(seconds: 1));
    }

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo, history: history)));
    await settle();
    await tester.ensureVisible(find.byKey(const ValueKey('history-button')));
    await tester.tap(find.byKey(const ValueKey('history-button')));
    await settle();
    await tester.tap(find.byKey(const ValueKey('history-manual')));
    await settle();
    await tester.tap(find.text('Now'));
    await settle();
    await tester.tap(find.byKey(const ValueKey('preview-compare')));
    await settle();
    await tester.tap(find.text('Who added what').last);
    await settle();
    expect(find.text('Ben (#3333) 2'), findsOneWidget, reason: 'the more active one first');
    expect(find.text('Ben (#2222) 1'), findsOneWidget);
    expect(find.text('Anna 1'), findsOneWidget, reason: 'one Anna: no id after the name');
  });

  testWidgets('branches: a new branch takes the note, switching brings back what the other had; blame colours each drawing by the version it is from', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late NoteHistory history;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('branch_ui_');
      Directory('${dir.path}/support').createSync();
      final db = await AppDatabase.open(path: '${dir.path}/n.db');
      repo = NoteRepository(db);
      history = NoteHistory(db, repo, supportDirectory: () async => Directory('${dir.path}/support'));
      id = await repo.createNote(title: 'Plan');
      await repo.saveNote((await repo.loadNote(id))!..strokes = {0: [line('s1', 100)]});
      await history.snapshot(id);
      await repo.saveNote((await repo.loadNote(id))!..strokes[0]!.add(line('s2', 300)));
      await history.snapshot(id);
    });
    addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(seconds: 1));
    }

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo, history: history)));
    await settle();
    await tester.ensureVisible(find.byKey(const ValueKey('history-button')));
    await tester.tap(find.byKey(const ValueKey('history-button')));
    await settle();
    expect(find.byKey(const ValueKey('branch-bar')), findsOneWidget);

    // a branch from the note now
    await tester.tap(find.byKey(const ValueKey('branch-menu')));
    await settle();
    await tester.tap(find.text('New branch from the note now').last);
    await settle();
    await tester.enterText(find.byKey(const ValueKey('version-name')), 'idea');
    await tester.tap(find.byKey(const ValueKey('version-name-ok')));
    await settle();
    await tester.runAsync(() async => expect(await history.activeBranch(id), 'idea'));

    // blame of the newest version on the main branch: s1 is from before the oldest, s2 from the newer version
    await tester.tap(find.byKey(const ValueKey('branch-select')));
    await settle();
    await tester.tap(find.text('main').last);
    await settle();
    await tester.tap(find.text('While editing').first);
    await settle();
    for (var i = 0; i < 8 && find.byKey(const ValueKey('preview-compare')).evaluate().isEmpty; i++) {
      await settle();
    }
    await tester.tap(find.byKey(const ValueKey('preview-compare')));
    await settle();
    await tester.tap(find.text('Blame: when each thing came in').last);
    for (var i = 0; i < 5 && find.byKey(const ValueKey('blame-legend')).evaluate().isEmpty; i++) {
      await settle();
    }
    expect(find.byKey(const ValueKey('blame-legend')), findsOneWidget);
    expect(find.byKey(const ValueKey('blame-ink-0')), findsOneWidget);
    expect(find.text('Before the first kept version: 1'), findsOneWidget);
  });
}
