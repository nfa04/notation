import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/events/event_bus.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/tag_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/automations_view.dart';
import 'package:notes/style/platform_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_model.dart';

const _text = 'A binary heap keeps its largest item at the root. The swim function restores the heap property after an insertion by '
    'exchanging a node with its parent while it is larger.';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository notes;
  late TaskRepository tasks;
  late TagRepository tags;
  late FakeModel model;
  late Directory dir;

  setUp(() async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    for (final t in ['settings', 'tasks', 'notes', 'folders', 'text_boxes', 'note_tags']) {
      await db.delete(t);
    }
    notes = NoteRepository(db);
    tasks = TaskRepository(db);
    tags = TagRepository(db);
    model = FakeModel('Heaps keep the biggest item on top.');
    dir = await Directory.systemTemp.createTemp('chain');
  });
  tearDown(() => dir.delete(recursive: true));

  Future<AutomationService> service() async {
    final s = AutomationService(notes, tasks,
        ai: AiService(providers: [model]), tags: tags, noteFiles: NoteFileService(notes, supportDirectory: () async => dir));
    s.editorWait = const Duration(milliseconds: 100);
    await s.load();
    return s;
  }

  Future<String> noteWith(String text, {String title = 'Heaps'}) async {
    final id = await notes.createNote(title: title);
    await notes.putTextBox(id, 0, TextBoxWidgetModel(id: 'b', position: const Offset(40, 100), size: const Size(300, 60), initialText: text));
    return id;
  }

  Future<List<String>> boxes(String id) async => [for (final b in (await notes.loadNote(id))!.textBoxes[0] ?? const <TextBoxWidgetModel>[]) b.controller.text];

  test('a rule with steps is kept with them, and one without has none', () {
    const a = Automation(
      id: 'a',
      event: AutomationEvent.noteClosed,
      action: AutomationAction.summarizeToBox,
      then: [ChainStep(AutomationAction.addTag, {'tag': 'done'}), ChainStep(AutomationAction.saveNoteFile, {'dir': '/x'})],
    );
    final back = Automation.decodeAll(Automation.encodeAll([a, const Automation(id: 'b', event: AutomationEvent.noteClosed, action: AutomationAction.starNote)]));
    expect([for (final t in back.first.then) '${t.action.name} ${t.params}'], ['addTag {tag: done}', 'saveNoteFile {dir: /x}']);
    expect(back.last.then, isEmpty);
    expect(a.toJson().containsKey('then'), isTrue);
    expect(back.last.toJson().containsKey('then'), isFalse, reason: 'rules saved before steps existed look the same');
    expect(a.copyWith(enabled: false).then, hasLength(2));
    // what needs the open editor, and extensions, cannot be a step
    expect(chainable(AutomationAction.exportPdf), isFalse);
    expect(chainable(AutomationAction.extensionAction), isFalse);
    expect(chainable(AutomationAction.summarizeToBox), isTrue);
  });

  test('the steps run one after the other, each with what the one before said as {result}', () async {
    final id = await noteWith(_text);
    final s = await service();
    await s.add(const Automation(
      id: 'c',
      event: AutomationEvent.noteClosed,
      action: AutomationAction.summarizeToBox,
      then: [
        ChainStep(AutomationAction.addTask, {'title': 'Check: {result}', 'due': 'none'}),
        ChainStep(AutomationAction.addTag, {'tag': 'summarized'}),
        ChainStep(AutomationAction.saveNoteFile, {'dir': '/placeholder'}),
      ],
    ));
    final dest = '${dir.path}/out';
    Directory(dest).createSync();
    await s.update(s.all.single.copyWith(then: [...s.all.single.then.take(2), ChainStep(AutomationAction.saveNoteFile, {'dir': dest})]));
    final said = await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps');
    expect(said.single, 'Doing 4 steps in the background...');
    await s.assistantDone;

    expect(await boxes(id), [_text, '**Summary**\nHeaps keep the biggest item on top.']);
    expect((await tasks.listTasks()).single.title, 'Check: Added a text box to page 1');
    expect(await tags.tagsOf(id), ['summarized']);
    expect(Directory(dest).listSync().map((f) => f.path.split('/').last), [startsWith('Heaps')]);
    final run = s.runsOf('c').single;
    expect(run.result, startsWith('1. Added a text box to page 1 2. Added the task'));
    expect(run.result, contains('4. Saved as'));
    expect(s.runsOf('c'), hasLength(1), reason: 'one run, not one for each step');
    expect(s.all.single.lastResult, startsWith('"Heaps": 1. '));
    s.dispose();
  });

  test('a step that cannot do its work ends the chain, and what the earlier steps did stays', () async {
    final id = await noteWith('milk', title: 'Shopping');
    final s = await service();
    await s.add(const Automation(
      id: 'c',
      event: AutomationEvent.noteClosed,
      action: AutomationAction.addTag,
      params: {'tag': 'first'},
      then: [ChainStep(AutomationAction.summarizeToBox), ChainStep(AutomationAction.addTag, {'tag': 'never'})],
    ));
    await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Shopping');
    await s.assistantDone;
    expect(await tags.tagsOf(id), ['first']);
    final result = s.runsOf('c').single.result;
    expect(result, contains('2. Too little text to summarize'));
    expect(result, contains('The chain stops here.'));
    expect(result, isNot(contains('3.')));
    expect(model.prompts, isEmpty);
    s.dispose();
  });

  test('the whole chain can be taken back, the last step first', () async {
    final id = await noteWith(_text);
    final s = await service();
    await s.add(const Automation(
      id: 'c',
      event: AutomationEvent.noteClosed,
      action: AutomationAction.summarizeToBox,
      then: [ChainStep(AutomationAction.addTag, {'tag': 'x'}), ChainStep(AutomationAction.starNote)],
    ));
    await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps');
    await s.assistantDone;
    expect(s.runsOf('c').single.steps.map((u) => u.kind), ['box', 'tag', 'star']);
    await s.undo(s.runsOf('c').single);
    expect(await boxes(id), [_text]);
    expect(await tags.tagsOf(id), isEmpty);
    expect((await notes.listNotes()).single.favorite, isFalse);
    s.dispose();
  });

  test('a chain works for events that have no note, too, and a rule without steps runs as before', () async {
    final s = await service();
    await s.add(const Automation(
      id: 'c',
      event: AutomationEvent.taskCompleted,
      action: AutomationAction.addTask,
      params: {'title': 'Follow up on {title}'},
      then: [ChainStep(AutomationAction.addTask, {'title': 'Then: {result}'})],
    ));
    await s.bus.emit(const AppEvent('taskCompleted', title: 'Pay rent'));
    await s.assistantDone;
    expect((await tasks.listTasks()).map((t) => t.title), unorderedEquals(['Follow up on Pay rent', 'Then: Added the task "Follow up on Pay rent"']));
    s.dispose();
  });

  group('in the dialog', () {
    testWidgets('steps are added, listed and taken out; only what can follow another is offered', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
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

      // the first action is one that can have steps
      await tester.tap(find.byKey(const ValueKey('automation-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add a summary of the note as a text box (the assistant writes it)').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('automation-add-step')), findsOneWidget);

      // (the dialog of the rule is behind the one of the step: what is looked for is in the one in front)
      Finder top(String key) => find.descendant(of: find.byType(PlatformAlertDialog).last, matching: find.byKey(ValueKey(key)));

      await tester.tap(find.byKey(const ValueKey('automation-add-step')));
      await tester.pumpAndSettle();
      expect(find.text('A further step'), findsOneWidget);
      expect(top('automation-event'), findsNothing, reason: 'a step has no event of its own');
      await tester.tap(top('automation-action'));
      await tester.pumpAndSettle();
      expect(find.text('Export the note as a PDF'), findsNothing, reason: 'it needs the open editor');
      await tester.tap(find.text('Give the note a tag').last);
      await tester.pumpAndSettle();
      await tester.enterText(top('automation-field-tag'), 'done');
      await tester.pump();
      await tester.tap(top('automation-save'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('automation-step-0')), findsOneWidget);
      expect(find.text('Give the note a tag'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('automation-add-step')));
      await tester.pumpAndSettle();
      await tester.tap(top('automation-save')); // the first step the dialog offers, as it starts
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('automation-step-1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('automation-step-remove-1')));
      await tester.pump();
      expect(find.byKey(const ValueKey('automation-step-1')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('automation-save')));
      await tester.pumpAndSettle();
      expect(saved!.action, AutomationAction.summarizeToBox);
      expect(saved!.then.map((t) => (t.action, t.params['tag'])), [(AutomationAction.addTag, 'done')]);
    });

    testWidgets('an action that needs the editor has no steps, and a rule with steps shows them in the list', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(onPressed: () => showDialog<Automation>(context: context, builder: (_) => const AutomationDialog(folders: [])), child: const Text('open')),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // (the first action is the export of a PDF: it has no steps)
      expect(find.byKey(const ValueKey('automation-add-step')), findsNothing);
    });
  });
}
