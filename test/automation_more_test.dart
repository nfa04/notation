
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/screens/automations_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DrawingStroke stroke(double y, {Color color = Colors.black}) =>
    DrawingStroke(color: color, width: 3, points: [for (var i = 0; i < 10; i++) Offset(100.0 + i * 5, y + i)]);

void main() {
  setUpAll(AppDatabase.initFfi);

  group('names', () {
    test('any word, in any case, in the title or the file name', () {
      expect(nameMatches('Physics', ['Physics 101', null]), isTrue);
      expect(nameMatches('physics, chemistry', ['Intro to CHEMISTRY']), isTrue);
      expect(nameMatches('Physics', ['Chemistry', 'lecture1.pdf']), isFalse);
      expect(nameMatches('lecture', ['Untitled', 'Lecture-03.pdf']), isTrue);
      expect(nameMatches(' ; ,', ['x']), isTrue); // nothing to match: every note fits
      expect(nameMatches(null, ['x']), isTrue);
      expect(nameMatches('x', []), isFalse);
    });
  });

  late NoteRepository notes;
  late TaskRepository tasks;
  var now = DateTime(2026, 3, 1);

  setUp(() async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    await db.delete('settings', where: "key LIKE 'automations%'");
    await db.delete('tasks');
    await db.delete('notes');
    await db.delete('folders');
    notes = NoteRepository(db);
    tasks = TaskRepository(db);
    now = DateTime(2026, 3, 1);
  });

  group('filing by name', () {
    test('only the notes whose title or PDF name fit are moved', () async {
      final physics = await notes.createFolder('Physics');
      final a = await notes.createNote(title: 'Physics 101 notes');
      final b = await notes.createNote(title: 'Groceries');
      final c = await notes.createNote(title: 'Untitled');
      final noteC = (await notes.loadNote(c))!..pdfName = 'physics-ex3.pdf'..pdfPath = '/x/p.pdf'..pdfPageCount = 1;
      await notes.saveNote(noteC);
      final s = AutomationService(notes, tasks, now: () => now);
      await s.load();
      await s.add(Automation(
          id: 'f',
          event: AutomationEvent.noteClosed,
          action: AutomationAction.moveToFolder,
          contains: 'physics',
          params: {'folder': physics}));
      for (final id in [a, b, c]) {
        await s.run(AutomationEvent.noteClosed, noteId: id, title: (await notes.noteInfo(id))!.title);
      }
      expect((await notes.noteInfo(a))!.folderId, physics);
      expect((await notes.noteInfo(b))!.folderId, isNull);
      expect((await notes.noteInfo(c))!.folderId, physics); // by its PDF's name
      s.dispose();
    });
  });

  group('notes not opened for a while', () {
    test('a note is acted on once after N weeks, and again only after it was opened and went stale again', () async {
      final old = await notes.createNote(title: 'Old course');
      final s = AutomationService(notes, tasks, now: () => now);
      await s.load();
      await s.add(const Automation(
          id: 's',
          event: AutomationEvent.noteStale,
          action: AutomationAction.addTask,
          params: {'weeks': '4', 'title': 'Revisit {title}'}));

      expect(await s.checkStale(), 0); // just made
      expect(s.all.single.lastResult, startsWith('Checked'));

      now = DateTime.now().add(const Duration(days: 29)); // 4 weeks and a day after the note was made
      expect(await s.checkStale(), 1);
      expect((await tasks.listTasks()).single.title, 'Revisit Old course');
      expect(s.all.single.lastResult, contains('1 note unopened for 4 weeks'));
      expect(await s.checkStale(), 0); // not again, nothing changed

      // opened a week later: fresh again; stale once more after another four weeks
      await notes.markOpened(old, at: now.add(const Duration(days: 7)));
      now = now.add(const Duration(days: 20));
      expect(await s.checkStale(), 0);
      now = now.add(const Duration(days: 20));
      expect(await s.checkStale(), 1);
      expect((await tasks.listTasks()).length, 2);
      s.dispose();
    });

    test('it can be limited by folder and name, and moves a note to an archive', () async {
      final archive = await notes.createFolder('Archive');
      final inFolder = await notes.createFolder('Courses');
      final keep = await notes.createNote(title: 'Taxes', folderId: inFolder);
      final move = await notes.createNote(title: 'Old lecture', folderId: inFolder);
      final other = await notes.createNote(title: 'Old lecture elsewhere');
      now = DateTime.now().add(const Duration(days: 100));
      final s = AutomationService(notes, tasks, now: () => now);
      await s.load();
      await s.add(Automation(
          id: 's',
          event: AutomationEvent.noteStale,
          action: AutomationAction.moveToFolder,
          folderId: inFolder,
          contains: 'lecture',
          params: {'weeks': '8', 'folder': archive}));
      expect(await s.checkStale(), 1);
      expect((await notes.noteInfo(move))!.folderId, archive);
      expect((await notes.noteInfo(keep))!.folderId, inFolder);
      expect((await notes.noteInfo(other))!.folderId, isNull);
      s.dispose();
    });

    test('opening a note is remembered, and trashed notes are left alone', () async {
      final id = await notes.createNote(title: 'N');
      expect((await notes.staleNotes(DateTime.now().add(const Duration(days: 1)))).map((n) => n.id), contains(id));
      await notes.markOpened(id, at: DateTime.now().add(const Duration(days: 5)));
      expect((await notes.staleNotes(DateTime.now().add(const Duration(days: 1)))).map((n) => n.id), isNot(contains(id)));
    });
  });

  group('converting handwriting', () {
    late List<List<DrawingStroke>> read;
    Future<AutomationService> make({bool ready = true, String text = 'meeting at noon'}) async {
      read = [];
      final s = AutomationService(
        notes,
        tasks,
        now: () => now,
        readInk: (strokes) async {
          read.add(strokes);
          return text;
        },
        inkReady: () => ready,
      );
      await s.load();
      await s.add(const Automation(id: 'h', event: AutomationEvent.noteClosed, action: AutomationAction.convertHandwriting));
      return s;
    }

    Future<String> noteWithInk() async {
      final id = await notes.createNote(title: 'Lecture');
      final note = (await notes.loadNote(id))!;
      note.strokes[0] = [stroke(100), stroke(130), stroke(160, color: Colors.yellow.withValues(alpha: 0.35))];
      note.strokes[2] = [stroke(300)];
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'mine', position: const Offset(10, 10), initialText: 'my own text')];
      await notes.saveNote(note);
      return id;
    }

    test('each page with pen writing gets a box under it, without the highlighter, and nothing else changes', () async {
      final s = await make();
      final id = await noteWithInk();
      final out = await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Lecture');
      expect(out.single, contains('background')); // it does not make navigation wait
      await s.conversionsDone;
      final back = (await notes.loadNote(id))!;
      final box = back.textBoxes[0]!.firstWhere((b) => b.id.startsWith('hw-0-'));
      expect(box.controller.text, 'meeting at noon');
      expect(box.position.dy, closeTo(130 + 9 + 16 + 30, 40)); // under the lowest pen stroke
      expect(back.textBoxes[0]!.any((b) => b.id == 'mine'), isTrue);
      expect(back.textBoxes[2]!.single.id, startsWith('hw-2-'));
      expect(read.map((r) => r.length), [2, 1]); // the highlighter was not read
      expect(s.all.single.lastResult, 'Read the handwriting of 2 pages');
      s.dispose();
    });

    test('a page is read again only when its writing changed, and then the box is replaced', () async {
      final s = await make();
      final id = await noteWithInk();
      await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Lecture');
      await s.conversionsDone;
      expect(read.length, 2);
      // the note has not changed since: closing it again runs nothing at all
      expect(await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Lecture'), isEmpty);
      await s.conversionsDone;
      expect(read.length, 2); // nothing new

      final note = (await notes.loadNote(id))!;
      note.strokes[0] = [...note.strokes[0]!, stroke(400)];
      await notes.saveNote(note);
      // (saving the whole note, as the editor does, drops the generated boxes of the old state)
      await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Lecture');
      await s.conversionsDone;
      final boxes = (await notes.loadNote(id))!.textBoxes[0]!.where((b) => b.id.startsWith('hw-0-')).toList();
      expect(boxes.length, 1);
      s.dispose();
    });

    test('without the model it says so', () async {
      final s = await make(ready: false);
      final id = await noteWithInk();
      final out = await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Lecture');
      expect(out.single, contains('not installed'));
      expect(read, isEmpty);
      s.dispose();
    });

    test('a failing reader is reported and does not stop the next note', () async {
      final s = AutomationService(notes, tasks, now: () => now, readInk: (_) async => throw StateError('no tflite'), inkReady: () => true);
      await s.load();
      await s.add(const Automation(id: 'h', event: AutomationEvent.noteClosed, action: AutomationAction.convertHandwriting));
      final id = await noteWithInk();
      await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Lecture');
      await s.conversionsDone;
      expect(s.all.single.lastResult, contains('Could not read the handwriting'));
      s.dispose();
    });

    test('the fingerprint depends on the ink only', () {
      expect(inkFingerprint([stroke(10)]), inkFingerprint([stroke(10)]));
      expect(inkFingerprint([stroke(10)]), isNot(inkFingerprint([stroke(11)])));
      expect(inkFingerprint([stroke(10)]), isNot(inkFingerprint([stroke(10, color: Colors.red)])));
    });

    test('only offered after a note is opened or closed', () {
      expect(AutomationAction.convertHandwriting.worksAfter(AutomationEvent.noteClosed), isTrue);
      expect(AutomationAction.convertHandwriting.worksAfter(AutomationEvent.noteOpened), isTrue);
      expect(AutomationAction.convertHandwriting.worksAfter(AutomationEvent.appStarted), isFalse);
      expect(AutomationAction.convertHandwriting.worksAfter(AutomationEvent.noteStale), isFalse);
    });
  });

  test('the new fields survive being saved', () {
    const a = Automation(
        id: '1',
        event: AutomationEvent.noteStale,
        action: AutomationAction.moveToFolder,
        contains: 'Physics, Lecture',
        params: {'weeks': '6', 'folder': 'f'});
    final back = Automation.decodeAll(Automation.encodeAll([a])).single;
    expect((back.event, back.action, back.contains, back.params['weeks']), (a.event, a.action, a.contains, '6'));
  });

  testWidgets('the dialog takes the weeks and the name, and handwriting needs nothing more', (tester) async {
    // (the list of events is long: it all has to be on the screen to be found)
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Automation? saved;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => saved = await showDialog<Automation>(
            context: context,
            builder: (_) => const AutomationDialog(folders: [FolderEntry(id: 'f', parentId: null, name: 'Archive', noteCount: 0)]),
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('automation-weeks')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('automation-event')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A note has not been opened for a while').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('automation-weeks')), findsOneWidget);
    expect(find.byKey(const ValueKey('automation-contains')), findsOneWidget);
    // the export needs a note that is open: after "not opened" it is not offered, the task is chosen
    expect(find.text('Add a task to the calendar'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('automation-weeks')), '0');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('automation-save'))).onPressed, isNull); // at least a week
    await tester.enterText(find.byKey(const ValueKey('automation-weeks')), '6');
    await tester.enterText(find.byKey(const ValueKey('automation-contains')), 'Physics, Lecture');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('automation-save')));
    await tester.pumpAndSettle();
    expect(saved!.event, AutomationEvent.noteStale);
    expect(saved!.action, AutomationAction.addTask);
    expect(saved!.params['weeks'], '6');
    expect(saved!.contains, 'Physics, Lecture');
  });
}
