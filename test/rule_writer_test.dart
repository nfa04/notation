import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/automations/rule_writer.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/events/event_sources.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/rule_writer_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_model.dart';

const folders = [
  FolderEntry(id: 'f-physics', parentId: null, name: 'Physics', noteCount: 0),
  FolderEntry(id: 'f-archive', parentId: null, name: 'Archive', noteCount: 0),
];

var _n = 0;
String newId() => 'r${_n++}';

void main() {
  setUpAll(AppDatabase.initFfi);

  group('reading what the assistant wrote', () {
    test('a rule: the event, the action, its settings, the folder it is limited to; it comes switched off', () {
      final d = parseRules('event=noteClosed action=addTag tag="school/maths" in="Physics" contains="lecture, exercise"', folders: folders, newId: newId);
      expect(d.rejected, isEmpty);
      final r = d.rules.single.rule;
      expect((r.event, r.action, r.folderId, r.contains, r.enabled), (AutomationEvent.noteClosed, AutomationAction.addTag, 'f-physics', 'lecture, exercise', false));
      expect(r.params['tag'], 'school/maths');
      expect(d.rules.single.notes, isEmpty);
    });

    test('bullets, back ticks and other lines around it do not matter; at most three rules', () {
      final d = parseRules('''
Here you go:
1. `event=noteClosed action=starNote`
- event=noteClosed action=starNote
event=noteClosed action=starNote
event=noteClosed action=starNote
''', folders: folders, newId: newId);
      expect(d.rules, hasLength(3));
      expect(parseRules('none', folders: folders, newId: newId).rules, isEmpty);
    });

    test('an event or an action that is not there, and an action that cannot follow the event, are left out and told', () {
      final d = parseRules('''
event=wakeUp action=starNote
event=noteClosed action=makeCoffee
event=taskCompleted action=addTag tag=x
event=noteClosed action=extensionAction extension=a/b
''', folders: folders, newId: newId);
      expect(d.rules, isEmpty);
      expect(d.rejected, hasLength(4));
      expect(d.rejected[0], contains('no event "wakeUp"'));
      expect(d.rejected[1], contains('no action "makeCoffee"'));
      expect(d.rejected[2], contains('cannot follow'));
      expect(d.rejected[3], contains('no action'));
    });

    test('a setting of a choice that is not one is replaced by the start one, and said; a folder that is not there is said', () {
      final d = parseRules('event=noteClosed action=appendToNote where=elsewhere text="- {title}" folder=Nowhere', folders: folders, newId: newId);
      final r = d.rules.single;
      expect(r.rule.params['where'], 'this');
      expect(r.notes.single, contains('"elsewhere" is not a choice'));

      final mover = parseRules('event=noteStale action=moveToFolder folder=Archive weeks=8', folders: folders, newId: newId).rules.single.rule;
      expect(mover.params, {'folder': 'f-archive', 'weeks': '8'});
      final lost = parseRules('event=noteStale action=moveToFolder folder=Basement', folders: folders, newId: newId).rules.single;
      expect(lost.rule.params.containsKey('folder'), isFalse);
      expect(lost.notes.single, contains('no folder "Basement"'));
    });

    test('what has to be chosen on this device is left open and said: a folder for files, a template, a text that is needed', () {
      final pdf = parseRules('event=noteClosed action=exportPdf', folders: folders, newId: newId).rules.single;
      expect(pdf.notes, ['Choose the folder on this device']);
      final tpl = parseRules('event=calendarEventStarting action=createNoteFromTemplate', folders: folders, newId: newId).rules.single;
      expect(tpl.notes, contains('Choose the template'));
      expect(tpl.rule.params['minutes'], '10');
      final tag = parseRules('event=noteClosed action=addTag', folders: folders, newId: newId).rules.single;
      expect(tag.rule.params['tag'], 'todo', reason: 'the start value of the dialog');
    });

    test('numbers are kept in their range, and the tasks it makes have a title', () {
      final stale = parseRules('event=noteStale action=addTask weeks=100000', folders: folders, newId: newId).rules.single.rule;
      expect(stale.params['weeks'], '520');
      expect(stale.params['title'], '{title}');
      expect(stale.params['due'], 'none');
      final cards = parseRules('event=noteClosed action=makeFlashcards count=99', folders: folders, newId: newId).rules.single.rule;
      expect(cards.params['count'], '30');
    });

    test('a scope is dropped for an event that is not about a note', () {
      final r = parseRules('event=taskCompleted action=addTask title="Well done" in="Physics" contains=x', folders: folders, newId: newId).rules.single.rule;
      expect((r.folderId, r.contains), (null, null));
    });

    test('a rule in a sentence', () {
      final d = parseRules('event=noteStale action=addTag tag="old" weeks=8 in="Physics"', folders: folders, newId: newId).rules.single.rule;
      expect(describeRule(d, folderName: (id) => 'Physics'), 'When a note has not been opened for a while: give the note a tag (old), after 8 weeks, for notes in Physics');
    });
  });

  test('the assistant is told every event and every action that can be written, and what each takes', () {
    final p = rulePrompt('tag my notes');
    for (final e in AutomationEvent.values) {
      expect(p.system, contains('- ${e.id}:'), reason: e.id);
    }
    for (final a in writableActions) {
      expect(p.system, contains('- ${a.name}:'), reason: a.name);
    }
    expect(p.system, isNot(contains('- extensionAction:')));
    expect(p.system, contains('tag=<'));
    expect(p.system, contains('(only after: calendarEventStarting)'), reason: 'meetingNote needs the event that is coming up');
    expect(p.user, 'tag my notes');
  });

  group('what a rule would touch', () {
    late NoteRepository notes;
    late TaskRepository tasks;
    final now = DateTime(2026, 5, 4, 10);

    setUp(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['settings', 'tasks', 'notes', 'folders', 'text_boxes']) {
        await db.delete(t);
      }
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
    });

    test('notes in the folder with the words, those that are stale, to-do lines, done tasks, events in the next day', () async {
      final f = await notes.createFolder('Physics');
      final a = await notes.createNote(title: 'Physics lecture 1', folderId: f);
      await notes.createNote(title: 'Physics lecture 2', folderId: f);
      await notes.createNote(title: 'Groceries');
      await notes.markOpened(a, at: DateTime(2026, 3, 1));
      final s = AutomationService(notes, tasks,
          now: () => now, upcomingEvents: (from, to) async => [UpcomingEvent('Standup', DateTime(2026, 5, 4, 10, 5)), UpcomingEvent('Holiday', DateTime(2026, 5, 4), allDay: true)]);
      await s.load();

      var p = await s.preview(Automation(id: '1', event: AutomationEvent.noteClosed, action: AutomationAction.starNote, folderId: f, contains: 'lecture'));
      expect(p.headline, 'It is for 2 notes you have now');
      p = await s.preview(Automation(id: '2', event: AutomationEvent.noteStale, action: AutomationAction.starNote, params: const {'weeks': '4'}));
      expect(p.headline, '1 note has not been opened for 4 weeks');
      expect(p.examples, ['Physics lecture 1']);

      await notes.putTextBox(a, 0, TextBoxWidgetModel(id: 'b', position: Offset.zero, size: const Size(100, 0), initialText: '☐ buy paper\n- [ ] send the form\nsomething else'));
      p = await s.preview(const Automation(id: '3', event: AutomationEvent.todoFound, action: AutomationAction.addTask));
      expect(p.headline, '2 to-do lines are in your notes now');
      expect(p.examples.single, 'Physics lecture 1 (2)');

      final t = await tasks.createTask('Pay rent');
      await tasks.setDone(t, true);
      p = await s.preview(const Automation(id: '4', event: AutomationEvent.taskCompleted, action: AutomationAction.addTask));
      expect(p.headline, '1 task is done now');
      expect(p.examples, ['Pay rent']);

      p = await s.preview(const Automation(id: '5', event: AutomationEvent.calendarEventStarting, action: AutomationAction.addTask, params: {'minutes': '10'}));
      expect(p.headline, startsWith('1 event in the next day'));
      expect(p.examples, ['Standup'], reason: 'an all-day event is left out');
      p = await s.preview(const Automation(id: '6', event: AutomationEvent.appStarted, action: AutomationAction.addTask));
      expect(p.headline, 'It runs every time the app starts.');
      s.dispose();
    });

    test('rules are written only while the assistant is ready', () async {
      final model = FakeModel('event=noteClosed action=starNote');
      final s = AutomationService(notes, tasks, ai: AiService(providers: [model]));
      await s.load();
      expect(s.canWriteRules, isTrue);
      expect((await s.writeRules('star my notes')).rules, hasLength(1));
      model.current = ProviderStateForTest.notReady;
      await expectLater(s.writeRules('x'), throwsA(isA<StateError>()));
      s.dispose();
    });
  });

  group('the dialog', () {
    late NoteRepository notes;
    late TaskRepository tasks;
    late FakeModel model;
    late AutomationService service;

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        for (final t in ['settings', 'tasks', 'notes', 'folders']) {
          await db.delete(t);
        }
        notes = NoteRepository(db);
        tasks = TaskRepository(db);
        model = FakeModel('event=noteClosed action=addTag tag="lecture" in="Physics"\nevent=noteClosed action=moveToFolder folder=Basement');
        service = AutomationService(notes, tasks, ai: AiService(providers: [model]));
        await service.load();
        await notes.createFolder('Physics');
      });
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) => TextButton(onPressed: () => showRuleWriter(context, service: service, folders: folders), child: const Text('open'))),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> real(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
      }
    }

    testWidgets('a request becomes rules to look at, with what they would touch; added switched off or on, once', (tester) async {
      await open(tester);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('rule-write'))).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('rule-request')), 'tag my physics notes when I close them');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('rule-write')));
      await real(tester);

      expect(model.prompts.single.user, 'tag my physics notes when I close them');
      expect(find.textContaining('When a note is closed (leaving the canvas): give the note a tag (lecture)'), findsOneWidget);
      expect(find.textContaining('It is for 0 notes you have now'), findsNWidgets(2));
      expect(find.textContaining('There is no folder "Basement"'), findsOneWidget);

      final ids = [for (final e in find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('rule-draft-')).evaluate()) '${(e.widget.key as ValueKey).value}'.substring('rule-draft-'.length)];
      expect(ids, hasLength(2));
      // the one that has something left to choose cannot be switched on from here
      expect(tester.widget<FilledButton>(find.byKey(ValueKey('rule-add-on-${ids[1]}'))).onPressed, isNull);

      await tester.ensureVisible(find.byKey(ValueKey('rule-add-on-${ids[0]}')));
      await tester.tap(find.byKey(ValueKey('rule-add-on-${ids[0]}')));
      await real(tester);
      await tester.ensureVisible(find.byKey(ValueKey('rule-add-off-${ids[1]}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('rule-add-off-${ids[1]}')));
      await real(tester);
      expect(service.all.map((a) => (a.action, a.enabled)), [(AutomationAction.addTag, true), (AutomationAction.moveToFolder, false)]);
      expect(find.byKey(ValueKey('rule-added-${ids[0]}')), findsOneWidget);
      expect(find.byKey(ValueKey('rule-add-on-${ids[0]}')), findsNothing, reason: 'added once');
      await tester.pumpWidget(const SizedBox());
      service.dispose();
    });

    testWidgets('an answer with no rule in it is said, and an assistant that fails is explained', (tester) async {
      await open(tester);
      model.answer = 'none';
      model.respond = null;
      await tester.enterText(find.byKey(const ValueKey('rule-request')), 'make me a sandwich');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('rule-write')));
      await real(tester);
      expect(find.byKey(const ValueKey('rule-none')), findsOneWidget);

      model.current = ProviderStateForTest.notReady;
      await tester.tap(find.byKey(const ValueKey('rule-write')));
      await real(tester);
      expect(find.byKey(const ValueKey('rule-problem')), findsOneWidget);
      expect(find.textContaining('not ready'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      service.dispose();
    });
  });
}
