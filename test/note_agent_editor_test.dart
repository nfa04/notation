
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/reminder_repository.dart';
import 'package:notes/data/tag_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/history/note_history.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/models/page_background.dart';
import 'package:notes/models/page_format.dart';
import 'package:notes/reminders/reminder.dart';
import 'package:notes/sync/caldav_remote.dart';
import 'package:notes/sync/calendar_access.dart';
import 'package:notes/reminders/reminder_service.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'reminder_service_test.dart' show FakeSink;
import 'support/fake_model.dart';

Future<List<int>> _png() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 40, 20), Paint()..color = Colors.red);
  final image = await recorder.endRecording().toImage(40, 20);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// Notes the versions the assistant has kept made, without making them.
class _Versions extends NoteHistory {
  _Versions(super.db, super.notes);
  final kept = <String>[];

  @override
  Future<NoteVersion?> snapshot(String noteId, {VersionReason reason = VersionReason.edit, bool manual = false, String? label, String? who}) async {
    kept.add('${reason.name}: $label');
    return null;
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('the assistant works on the open note: it asks, then formats, reworded and retitled; the note\'s undo takes it back', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late _Versions versions;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      versions = _Versions(db, repo);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.title = 'Physics';
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: 'Entropy never decreases in an isolated system.')];
      await repo.saveNote(note);
    });
    final replies = <String>[
      '<tool>{"name":"note.format","args":{"target":"Entropy","bold":true}}</tool>',
      '<tool>{"name":"note.replaceText","args":{"find":"isolated","replacement":"closed"}}</tool>',
      '<tool>{"name":"note.setTitle","args":{"title":"Thermodynamics"}}</tool>',
      'Done: bold word, closed system, new title.',
    ];
    final model = FakeModel()..respond = (_) => replies.removeAt(0);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, history: versions, ai: AiService(providers: [model]))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(of: find.byKey(const ValueKey('assistant-mode')), matching: find.text('Agent')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'Bold Entropy, say closed instead of isolated, retitle');
    await tester.tap(find.byKey(const ValueKey('assistant-send')));

    Future<void> until(Finder f) async {
      for (var i = 0; i < 60 && f.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      expect(f, findsOneWidget);
    }

    List<String> texts() => tester.widgetList<EditableText>(find.byType(EditableText)).map((e) => e.controller.text).toList();

    // (the box is not on screen in the test view: what is in it is read from what the note saved)
    Future<String> box() async {
      await tester.pump(const Duration(seconds: 2)); // (the note is saved a moment after a change)
      return tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return (await repo.loadNote(id))!.textBoxes[0]!.single.controller.text;
        }).then((v) => v!);
    }

    await until(find.byKey(const ValueKey('agent-allow-chat')));
    expect(await box(), 'Entropy never decreases in an isolated system.', reason: 'nothing changed before the person said yes');
    // (what the first change would do is on the card: the line as it is, and as it would be)
    expect(find.textContaining('+ **Entropy** never decreases in an isolated system.'), findsOneWidget);
    expect(find.textContaining('- Entropy never decreases in an isolated system.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agent-allow-chat')));
    await tester.pump();
    await until(find.text('Done: bold word, closed system, new title.'));
    await tester.pumpAndSettle();

    expect(await box(), '**Entropy** never decreases in an closed system.');
    expect(texts(), contains('Thermodynamics'));
    expect(find.byKey(const ValueKey('agent-allow')), findsNothing, reason: 'allowed for the whole chat: not asked again');
    // (a version of the note before each change, and one after it, each saying what it was)
    expect(versions.kept, [
      'assistantBefore: Format "Entropy": bold',
      'assistant: Format "Entropy": bold',
      'assistantBefore: Replace "isolated"',
      'assistant: Replace "isolated"',
      'assistantBefore: Change the title to "Thermodynamics"',
      'assistant: Change the title to "Thermodynamics"',
    ]);

    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pumpAndSettle();
    expect(await box(), 'Entropy never decreases in an isolated system.');
    expect(texts(), contains('Physics'));
  });

  testWidgets('the choice between Ask and Agent is kept for the next note', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      await repo.settings.set('assistant_agent_mode', '1');
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, ai: AiService(providers: [FakeModel('x')]))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    final mode = tester.widget<SegmentedButton<bool>>(find.byKey(const ValueKey('assistant-mode')));
    expect(mode.selected, {true}, reason: 'it was Agent last time');

    await tester.tap(find.descendant(of: find.byKey(const ValueKey('assistant-mode')), matching: find.text('Ask')));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => repo.settings.get('assistant_agent_mode')), '0');
  });

  testWidgets('the assistant works across notes: finds and reads another, makes a note in a folder, files this one, looks at the formatting, adds after a line', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late TagRepository tags;
    late String id, folder;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      tags = TagRepository(db);
      folder = await repo.createFolder('School');
      final other = await repo.createNote(title: 'Foxes');
      await repo.saveNote((await repo.loadNote(other))!..documentText = 'The quick brown fox jumps over the lazy dog.');
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.title = 'Physics';
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: 'Entropy never decreases in an isolated system.')];
      await repo.saveNote(note);
    });
    String call(String name, String args) => '<tool>{"name":"$name","args":$args}</tool>';
    final replies = <String>[
      call('notes.search', '{"query":"fox"}'),
      call('notes.create', '{"title":"Fox facts","text":"# Fox facts\\n\\nFoxes are canids.","folder":"School"}'),
      call('note.addTags', '{"tags":["animals","Exam"]}'),
      call('note.moveToFolder', '{"folder":"School"}'),
      call('note.inspect', '{}'),
      call('note.insertText', '{"text":"Added line","after":"Entropy"}'),
      call('notes.read', '{"id":"nowhere"}'),
      'All done.',
    ];
    final model = FakeModel()..respond = (_) => replies.removeAt(0);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, tags: tags, ai: AiService(providers: [model]))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('assistant-mode')), matching: find.text('Agent')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'Make a note about foxes and file this one');
    await tester.tap(find.byKey(const ValueKey('assistant-send')));

    // each kind of permission is asked once: other notes, filing, and this note's text
    for (var asked = 0; asked < 3; asked++) {
      final button = find.byKey(const ValueKey('agent-allow-chat'));
      for (var i = 0; i < 80 && button.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      expect(button, findsOneWidget, reason: 'question ${asked + 1}');
      await tester.tap(button);
      await tester.pump();
    }
    final done = find.text('All done.');
    for (var i = 0; i < 80 && done.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(done, findsOneWidget);
    await tester.pump(const Duration(seconds: 2));

    await tester.runAsync(() async {
      final notes = await repo.listNotes();
      final made = notes.singleWhere((n) => n.title == 'Fox facts');
      expect(made.folderId, folder);
      expect((await repo.loadNote(made.id))!.documentText, '# Fox facts\n\nFoxes are canids.');
      expect(notes.singleWhere((n) => n.id == id).folderId, folder, reason: 'this note was filed too');
      expect(await tags.tagsOf(id), ['animals', 'exam']);
    });
    String results() => [for (final p in model.prompts) ...[p.user, for (final t in p.history) t.text]].join('\n');
    expect(results(), contains('"Foxes"'), reason: 'the search result went back to the model');
    expect(results(), contains('1| Entropy never decreases'), reason: 'so did the formatting of the note');
    expect(results(), contains('There is no such note'), reason: 'and the failure of the last read');
    await tester.pump(const Duration(seconds: 2));
    final box = await tester.runAsync(() async => (await repo.loadNote(id))!.textBoxes[0]!.single.controller.text);
    expect(box, 'Entropy never decreases in an isolated system.\nAdded line');
  });

  testWidgets('the assistant moves and deletes pages, and ticks off a task; a version is kept for the pages and undo brings them back', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late TaskRepository tasks;
    late _Versions versions;
    late String id, taskId;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      tasks = TaskRepository(db);
      versions = _Versions(db, repo);
      taskId = await tasks.createTask('Buy milk');
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      for (final (i, word) in ['alpha', 'beta', 'gamma'].indexed) {
        note.textBoxes[i] = [TextBoxWidgetModel(id: 'b$i', position: const Offset(100, 100), initialText: word)];
      }
      await repo.saveNote(note);
    });
    String call(String name, String args) => '<tool>{"name":"$name","args":$args}</tool>';
    final replies = <String>[
      call('pages.list', '{}'),
      call('pages.move', '{"page":3,"to":1}'),
      call('pages.delete', '{"page":2}'),
      call('pages.delete', '{"page":40}'),
      call('tasks.list', '{"done":false}'),
      call('tasks.complete', '{"id":"$taskId"}'),
      'Tidied.',
    ];
    final model = FakeModel()..respond = (_) => replies.removeAt(0);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, history: versions, tasks: tasks, ai: AiService(providers: [model]))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('assistant-mode')), matching: find.text('Agent')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'Put gamma first, drop alpha, and tick off the milk');
    await tester.tap(find.byKey(const ValueKey('assistant-send')));

    // (asked once for the pages and once for the tasks)
    for (var asked = 0; asked < 2; asked++) {
      final button = find.byKey(const ValueKey('agent-allow-chat'));
      for (var i = 0; i < 80 && button.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      expect(button, findsOneWidget, reason: 'question ${asked + 1}');
      await tester.tap(button);
      await tester.pump();
    }
    final done = find.text('Tidied.');
    for (var i = 0; i < 80 && done.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(done, findsOneWidget);

    Future<List<String>> pages() async {
      await tester.pump(const Duration(seconds: 2));
      return (await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final boxes = (await repo.loadNote(id))!.textBoxes;
        return [for (final k in boxes.keys.toList()..sort()) '$k:${boxes[k]!.map((b) => b.controller.text).join('+')}'];
      }))!;
    }

    expect(await pages(), ['0:gamma', '1:beta']);
    final open = await tester.runAsync(() async => (await tasks.listTasks()).where((t) => !t.done).length);
    expect(open, 0, reason: 'the milk is ticked off');
    expect(versions.kept, [
      'assistantBefore: Move page 3 to page 1',
      'assistant: Move page 3 to page 1',
      'assistantBefore: Delete page 2 with everything on it',
      'assistant: Delete page 2 with everything on it',
      // (a page that is not there is found out only when it is tried: the version before is asked for, and History drops it as the
      // note is the same as in the version before that)
      'assistantBefore: Delete page 40 with everything on it',
    ]);
    String results() => [for (final p in model.prompts) ...[p.user, for (final t in p.history) t.text]].join('\n');
    expect(results(), contains('Page 3 (notebook, 800 x 1131): 0 strokes, 1 text boxes, 0 pictures'));
    expect(results(), contains('There is no page 40'));
    expect(results(), contains('"Buy milk"'));

    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pumpAndSettle();
    expect(await pages(), ['0:gamma', '1:alpha', '2:beta']);
    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pumpAndSettle();
    expect(await pages(), ['0:alpha', '1:beta', '2:gamma']);
  });

  testWidgets('the assistant keeps the library: makes and renames folders, lists, files and tags other notes, trashes and restores one, never the open one', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late TagRepository tags;
    late String id, other, locked;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      tags = TagRepository(db);
      other = await repo.createNote(title: 'Foxes');
      locked = await repo.createNote(title: 'Secret');
      await db.update('notes', {'lock_mode': 1}, where: 'id = ?', whereArgs: [locked]);
      id = await repo.createNote(title: 'Physics');
    });
    String call(String name, String args) => '<tool>{"name":"$name","args":$args}</tool>';
    final replies = <String>[
      [
        call('folders.create', '{"name":"Animals"}'),
        call('folders.create', '{"name":"Wild","parent":"Animals"}'),
        call('folders.rename', '{"name":"Wild","newName":"Wild life"}'),
        call('notes.move', '{"id":"$other","folder":"Wild life"}'),
        call('notes.tag', '{"id":"$other","tags":["fur"]}'),
      ].join('\n'),
      [
        call('notes.list', '{"folder":"Wild life"}'),
        call('folders.list', '{}'),
        call('notes.move', '{"id":"$locked","folder":"Animals"}'),
        call('notes.trash', '{"id":"$id"}'),
        call('notes.trash', '{"id":"$other"}'),
      ].join('\n'),
      [call('notes.restore', '{"id":"$other"}'), call('folders.create', '{"name":"animals"}')].join('\n'),
      'Filed.',
    ];
    final model = FakeModel()..respond = (_) => replies.removeAt(0);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, tags: tags, ai: AiService(providers: [model]))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('assistant-mode')), matching: find.text('Agent')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'Sort my animal notes');
    await tester.tap(find.byKey(const ValueKey('assistant-send')));

    // (managing, reading and the trash are asked about in turn: the answer is given whenever a question is there)
    final done = find.text('Filed.');
    var asked = 0;
    for (var i = 0; i < 200 && done.evaluate().isEmpty; i++) {
      final button = find.byKey(const ValueKey('agent-allow-chat'));
      if (button.evaluate().isNotEmpty) {
        asked++;
        await tester.ensureVisible(button);
        await tester.pump();
        await tester.tap(button);
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(asked, greaterThanOrEqualTo(3));
    expect(done, findsOneWidget);

    await tester.runAsync(() async {
      final folders = await repo.listFolders();
      expect(folders.map((f) => f.name), containsAll(['Animals', 'Wild life']), reason: 'the database is shared with the other tests of the file');
      final wild = folders.singleWhere((f) => f.name == 'Wild life');
      expect(wild.parentId, folders.singleWhere((f) => f.name == 'Animals').id);
      final notes = await repo.listNotes();
      expect(notes.singleWhere((n) => n.id == other).folderId, wild.id);
      expect(notes.singleWhere((n) => n.id == locked).folderId, isNull, reason: 'a locked note is left alone');
      expect(notes.any((n) => n.id == id), isTrue, reason: 'the open note is not trashed');
      expect(await tags.tagsOf(other), ['fur']);
      expect(await repo.listTrash(), isEmpty, reason: 'trashed and brought back');
    });
    String results() => [for (final p in model.prompts) ...[p.user, for (final t in p.history) t.text]].join('\n');
    expect(results(), contains('"Foxes" in "Wild life"'));
    expect(results(), contains('"Wild life" in "Animals": 1 notes'));
    expect(results(), contains('locked'));
    expect(results(), contains('the note that is open'));
    expect(results(), contains('There is a folder "animals" already'));
  });

  testWidgets('the assistant sets and removes reminders and keeps flashcards of the note', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late ReminderRepository reminders;
    late CardRepository cards;
    late ReminderService service;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      reminders = ReminderRepository(db);
      cards = CardRepository(db);
      await db.delete('reminders');
      service = ReminderService(reminders: reminders, sink: FakeSink(), read: (_) async => null, write: (_, _) async {});
      id = await repo.createNote(title: 'Cells');
    });
    addTearDown(service.dispose);
    String call(String name, String args) => '<tool>{"name":"$name","args":$args}</tool>';
    final year = DateTime.now().year + 1;
    final replies = <String>[
      [
        call('reminders.add', '{"text":"Revise cells","at":"$year-03-04T09:30","aboutNote":true}'),
        call('reminders.add', '{"text":"Too late","at":"2001-01-01T09:00"}'),
        call('reminders.add', '{"text":"Weekly look","at":"$year-03-05 08:00","repeat":"weekly"}'),
        call('reminders.list', '{}'),
        call('cards.add', '{"cards":[{"front":"What is the powerhouse?","back":"The mitochondrion"},{"front":"What is the powerhouse?","back":"again"}]}'),
      ].join('\n'),
      'Done.',
    ];
    final model = FakeModel()..respond = (_) => replies.removeAt(0);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, reminders: service, cards: cards, ai: AiService(providers: [model]))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('assistant-mode')), matching: find.text('Agent')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'Remind me and make cards');
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    final done = find.text('Done.');
    for (var i = 0; i < 200 && done.evaluate().isEmpty; i++) {
      final button = find.byKey(const ValueKey('agent-allow-chat'));
      if (button.evaluate().isNotEmpty) {
        await tester.ensureVisible(button);
        await tester.pump();
        await tester.tap(button);
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(done, findsOneWidget);
    await tester.runAsync(() async {
      final all = await reminders.all();
      expect(all.map((r) => r.title), unorderedEquals(['Revise cells', 'Weekly look']), reason: 'a time in the past is refused');
      final note = all.singleWhere((r) => r.title == 'Revise cells');
      expect((note.kind, note.refId, note.at), (ReminderKind.note, id, DateTime(year, 3, 4, 9, 30)));
      expect(all.singleWhere((r) => r.title == 'Weekly look').repeat, Repeat.weekly);
      final kept = await cards.due(source: id);
      expect(kept.map((c) => c.card.back), ['The mitochondrion'], reason: 'the same question is kept once');
    });
    String results() => [for (final p in model.prompts) ...[p.user, for (final t in p.history) t.text]].join('\n');
    expect(results(), contains('is in the past'));
    expect(results(), contains('"Revise cells" at $year-03-04T09:30'));
    expect(results(), contains('1 new flashcards'));
  });

  testWidgets('the assistant reads the calendar and adds events to a calendar that takes them', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote(title: 'Plans');
    });
    final written = <String>[];
    final calendar = CalendarAccess(
      events: (from, to) async => [
        DayEvent(title: 'Dentist', start: DateTime(2026, 12, 24, 9), end: DateTime(2026, 12, 24, 10), allDay: false, calendarName: 'Home'),
        DayEvent(title: 'Holiday', start: DateTime(2026, 12, 25), allDay: true, calendarName: 'Home'),
      ],
      writable: () async => const [CalendarInfo('a', 'Home', null), CalendarInfo('b', 'Work', null)],
      create: (target, event) async => written.add('${target.name}|${event.title}|${event.start.toIso8601String()}|${event.end?.toIso8601String()}|${event.allDay}'),
    );
    String call(String name, String args) => '<tool>{"name":"$name","args":$args}</tool>';
    final replies = <String>[
      [
        call('calendar.events', '{"from":"2026-12-24","to":"2026-12-26"}'),
        call('calendar.addEvent', '{"title":"Lunch","start":"2026-12-24T12:00"}'),
        call('calendar.addEvent', '{"title":"Standup","start":"2026-12-28T09:00","end":"2026-12-28T09:15","calendar":"work"}'),
        call('calendar.addEvent', '{"title":"Trip","start":"2026-12-29","end":"2026-12-31","allDay":true,"calendar":"Play"}'),
      ].join('\n'),
      'Done.',
    ];
    final model = FakeModel()..respond = (_) => replies.removeAt(0);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, calendar: calendar, ai: AiService(providers: [model]))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('assistant-mode')), matching: find.text('Agent')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'Plan my week');
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    final done = find.text('Done.');
    for (var i = 0; i < 200 && done.evaluate().isEmpty; i++) {
      final button = find.byKey(const ValueKey('agent-allow-chat'));
      if (button.evaluate().isNotEmpty) {
        await tester.ensureVisible(button);
        await tester.pump();
        await tester.tap(button);
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(done, findsOneWidget);
    expect(written, [
      'Home|Lunch|2026-12-24T12:00:00.000|2026-12-24T13:00:00.000|false',
      'Work|Standup|2026-12-28T09:00:00.000|2026-12-28T09:15:00.000|false',
    ], reason: 'the first calendar by default, one by name in any case, and no event in a calendar that is not there');
    String results() => [for (final p in model.prompts) ...[p.user, for (final t in p.history) t.text]].join('\n');
    expect(results(), contains('2026-12-24T09:00 to 2026-12-24T10:00: "Dentist" (Home)'));
    expect(results(), contains('2026-12-25: "Holiday" (Home)'));
    expect(results(), contains('There is no calendar "Play". The calendars are: Home, Work.'));
  });

  testWidgets('the assistant places and moves text boxes and pictures, draws shapes and sets up the paper', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late _Versions versions;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      versions = _Versions(db, repo);
      final dir = await Directory.systemTemp.createTemp('agent_');
      final pic = '${dir.path}/p.png';
      await File(pic).writeAsBytes(await _png());
      id = await repo.createNote(title: 'Layout');
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: 'Old box')];
      note.textBoxes[1] = [TextBoxWidgetModel(id: 'gone', position: const Offset(10, 10), initialText: 'Delete me')];
      note.images[0] = [ImageItem(id: 'p', path: pic, position: const Offset(50, 50), size: const Size(200, 100))];
      await repo.saveNote(note);
    });
    String call(String name, String args) => '<tool>{"name":"$name","args":$args}</tool>';
    final replies = <String>[
      [
        call('textBoxes.list', '{}'),
        call('images.list', '{}'),
        call('textBoxes.add', '{"text":"New box","page":2,"x":50,"y":60,"width":300}'),
        call('textBoxes.move', '{"id":"b","page":2,"x":120}'),
        call('textBoxes.delete', '{"id":"gone"}'),
      ].join('\n'),
      [
        call('images.move', '{"id":"p","x":10,"y":20,"width":400}'),
        call('draw.shape', '{"type":"rectangle","x":10,"y":300,"width":200,"height":80,"fill":"#ffeb3b","color":"#d32f2f"}'),
        call('draw.shape', '{"type":"arrow","x":10,"y":400,"x2":210,"y2":400,"page":1}'),
        call('draw.shape', '{"type":"blob","x":1,"y":1}'),
        call('draw.strokes', '{"strokes":[{"points":[[0,0],[10,10],[20,0]],"width":3}],"page":3}'),
      ].join('\n'),
      call('pages.setup', '{"paper":"a5","orientation":"landscape","background":"grid","margins":{"left":25,"top":20}}'),
      'Laid out.',
    ];
    final model = FakeModel()..respond = (_) => replies.removeAt(0);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, history: versions, ai: AiService(providers: [model]))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('assistant-mode')), matching: find.text('Agent')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'Rearrange the layout');
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    // (with so many cards the last answer is far down the list, which does not build what is out of sight: the script being used up is the end)
    for (var i = 0; i < 300 && replies.isNotEmpty; i++) {
      final button = find.byKey(const ValueKey('agent-allow-chat'));
      if (button.evaluate().isNotEmpty) {
        await tester.ensureVisible(button);
        await tester.pump();
        await tester.tap(button);
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(replies, isEmpty);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final note = (await repo.loadNote(id))!;
      final boxes = {for (final e in note.textBoxes.entries) for (final b in e.value) b.id: (e.key, b.position, b.size.width, b.controller.text)};
      expect(boxes['b'], (1, const Offset(120, 100), 260.0, 'Old box'), reason: 'moved to page 2, and only x changed');
      expect(boxes.containsKey('gone'), isFalse);
      final added = boxes.values.singleWhere((b) => b.$4 == 'New box');
      expect((added.$1, added.$2, added.$3), (1, const Offset(50, 60), 300.0));
      final picture = note.images.values.expand((l) => l).single;
      expect((picture.position, picture.size), (const Offset(10, 20), const Size(400, 200)), reason: 'the height follows the width');
      expect(note.strokes[0]!.first.fill, const Color(0xFFFFEB3B));
      expect(note.strokes[0]!.first.points.length, 5);
      expect(note.strokes[0]!.first.color, const Color(0xFFD32F2F));
      expect(note.strokes[0]!.length, 2, reason: 'the arrow went to page 1 too');
      expect(note.strokes[2]!.single.width, 3, reason: 'a free line on page 3');
      expect((note.pageFormat, note.landscape, note.background), (PageFormat.a5, true, PageBackground.grid));
      expect(note.marginLeft, closeTo(25 * 800 / 210, 0.01));
      expect(note.marginTop, closeTo(20 * 800 / 210, 0.01));
    });
    String results() => [for (final p in model.prompts) ...[p.user, for (final t in p.history) t.text]].join('\n');
    expect(results(), contains('id b: page 1 at 100.0, 100.0, 260.0 wide: "Old box"'));
    expect(results(), contains('id p: page 1 at 50.0, 50.0, 200.0 x 100.0'));
    expect(results(), contains('"type" has to be one of: rectangle'));
    expect(versions.kept.where((k) => k.startsWith('assistantBefore')).length, 8, reason: 'a version before each of the eight changes (the shape that is not one failed before asking)');
  });

  // needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

  testWidgets('the assistant reads the text of the PDF that is open, by page, and searches it', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('agent_pdf_');
      final doc = pw.Document();
      for (final text in ['Cells are the unit of life', 'The mitochondrion makes energy', 'Photosynthesis happens in plants']) {
        doc.addPage(pw.Page(build: (_) => pw.Text(text, style: const pw.TextStyle(fontSize: 24))));
      }
      final file = File('${dir.path}/bio.pdf')..writeAsBytesSync(await doc.save());
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote(title: 'Biology paper');
      final note = (await repo.loadNote(id))!;
      note.pdfName = 'bio.pdf';
      note.pdfPath = file.path;
      note.pdfPageCount = 3;
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));
    String call(String name, String args) => '<tool>{"name":"$name","args":$args}</tool>';
    final replies = <String>[
      [call('pdf.search', '{"query":"mitochondrion energy"}'), call('pdf.read', '{"from":2,"to":3}'), call('pdf.read', '{"from":9}')].join('\n'),
      'The second page is about energy.',
    ];
    final model = FakeModel()..respond = (_) => replies.removeAt(0);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, ai: AiService(providers: [model]))));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final button = find.byKey(const ValueKey('assistant-button'));
    await tester.ensureVisible(button);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300)); // (the panel slides in, from when the frame is done)
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('assistant-mode')), matching: find.text('Agent')));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'What does the paper say about energy?');
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    for (var i = 0; i < 100 && replies.isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(replies, isEmpty);
    expect(find.byKey(const ValueKey('agent-allow')), findsNothing, reason: 'the PDF that is open is read without asking');
    String results() => [for (final p in model.prompts) ...[p.user, for (final t in p.history) t.text]].join('\n');
    expect(results(), contains('page 2: ... The mitochondrion makes energy'));
    expect(results(), contains('The PDF has 3 pages.'));
    expect(results(), contains('Page 2:\nThe mitochondrion makes energy'));
    expect(results(), contains('Page 3:\nPhotosynthesis happens in plants'));
    expect(results(), isNot(contains('Page 1:\nCells')), reason: 'only the pages asked for');
    expect(results(), contains('There is no page 9: the PDF has 3 pages'));
  });

  testWidgets('the PDF of another note is read from what the app has read of it, after asking; a note without one is told so', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id, other, plain;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote(title: 'Summary');
      other = await repo.createNote(title: 'Lecture slides');
      plain = await repo.createNote(title: 'Shopping');
      await db.update('notes', {'pdf_path': '/nowhere/slides.pdf', 'pdf_name': 'slides.pdf'}, where: 'id = ?', whereArgs: [other]);
      await repo.text.savePdfText(other, ['Slide one: osmosis', '', 'Slide three: diffusion is passive']);
    });
    String call(String name, String args) => '<tool>{"name":"$name","args":$args}</tool>';
    final replies = <String>[
      [
        call('pdf.search', '{"query":"diffusion","id":"$other"}'),
        call('pdf.read', '{"id":"$other"}'),
        call('pdf.read', '{"id":"$plain"}'),
        call('pdf.read', '{}'),
      ].join('\n'),
      'Read.',
    ];
    final model = FakeModel()..respond = (_) => replies.removeAt(0);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, ai: AiService(providers: [model]))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('assistant-mode')), matching: find.text('Agent')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'Summarise my slides');
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    var asked = 0;
    for (var i = 0; i < 200 && replies.isNotEmpty; i++) {
      final allow = find.byKey(const ValueKey('agent-allow-chat'));
      if (allow.evaluate().isNotEmpty) {
        asked++;
        await tester.ensureVisible(allow);
        await tester.pump();
        await tester.tap(allow);
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    expect(replies, isEmpty);
    expect(asked, greaterThanOrEqualTo(1), reason: 'another note is looked into only after asking');
    String results() => [for (final p in model.prompts) ...[p.user, for (final t in p.history) t.text]].join('\n');
    expect(results(), contains('page 3: ... Slide three: diffusion is passive'));
    expect(results(), contains('Page 1:\nSlide one: osmosis'));
    expect(results(), contains('Page 2:\n(no text on this page'));
    expect(results(), contains('There is no PDF to read in that note'));
    expect(results(), contains('This note has no PDF.'));
  });
}
