import 'dart:io';
import 'dart:ui' show Offset, Size;

import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/reminder_repository.dart';
import 'package:notes/data/tag_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/events/event_bus.dart';
import 'package:notes/events/event_sources.dart' show eventVars;
import 'package:notes/export/image_export.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/reminders/notification_sink.dart';
import 'package:notes/reminders/reminder.dart';
import 'package:notes/reminders/reminder_service.dart';
import 'package:notes/templates/templates.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_model.dart';

class _Sink implements NotificationSink {
  @override
  bool get supportsScheduling => false;
  @override
  Future<bool> init(void Function(String? payload) onTap) async => true;
  @override
  Future<bool> isPermitted() async => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> show({required int id, required String title, required String body, required String payload}) async {}
  @override
  Future<void> schedule({required int id, required DateTime at, required String title, required String body, required String payload}) async {}
  @override
  Future<void> cancelScheduled() async {}
}

class _Editor implements NoteEditorHandle, ImageExporter {
  final calls = <(String, ImagePreset)>[];
  @override
  Future<void> get ready async {}
  @override
  Future<void> saveNow() async {}
  @override
  String get noteTitle => 'x';
  @override
  Future<String?> exportPdfTo(String path) async => null;
  @override
  Future<List<String>> pdfTextLines() async => const [];
  @override
  Future<String> exportImagesInto(String dir, ImagePreset preset) async {
    calls.add((dir, preset));
    return 'Saved 2 pictures in $dir';
  }
}

const _text = 'A binary heap keeps its largest item at the root. The swim function restores the heap property after an insertion by '
    'exchanging a node with its parent while it is larger.';

void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  late NoteRepository notes;
  late TaskRepository tasks;
  late TagRepository tags;
  late FakeModel model;
  late Directory dir;
  var now = DateTime(2026, 3, 5, 10, 30);

  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath);
    for (final t in ['settings', 'tasks', 'notes', 'folders', 'text_boxes', 'note_tags', 'reminders', 'templates']) {
      await db.delete(t);
    }
    notes = NoteRepository(db);
    tasks = TaskRepository(db);
    tags = TagRepository(db);
    model = FakeModel('Heaps keep the biggest item on top.');
    dir = await Directory.systemTemp.createTemp('actions');
    now = DateTime(2026, 3, 5, 10, 30);
  });
  tearDown(() => dir.delete(recursive: true));

  Future<String> noteWith(String text, {String title = 'Heaps'}) async {
    final id = await notes.createNote(title: title);
    await notes.putTextBox(id, 0, TextBoxWidgetModel(id: 'b', position: const Offset(40, 100), size: const Size(300, 60), initialText: text));
    return id;
  }

  Future<AutomationService> service({ReminderService? reminders, TemplateService? templates}) async {
    final s = AutomationService(notes, tasks,
        now: () => now, ai: AiService(providers: [model]), tags: tags, reminders: reminders, templates: templates);
    s.editorWait = const Duration(milliseconds: 300);
    await s.load();
    return s;
  }

  Future<List<String>> boxes(String id) async => [for (final b in (await notes.loadNote(id))!.textBoxes[0] ?? const <TextBoxWidgetModel>[]) b.controller.text];

  group('adding text', () {
    test('a text box under the rest of the page, with what the event says in it', () async {
      final id = await noteWith(_text);
      final s = await service();
      await s.add(const Automation(id: 'a', event: AutomationEvent.noteClosed, action: AutomationAction.appendToNote, params: {'text': 'Closed "{title}" on {date}'}));
      await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps');
      await s.assistantDone;
      expect(await boxes(id), [_text, 'Closed "Heaps" on 2026-03-05']);
      final added = (await notes.loadNote(id))!.textBoxes[0]!.last;
      expect(added.position.dy, greaterThan(160), reason: 'under the box that was there');
      s.dispose();
    });

    test('a daily note is made once and added to every time', () async {
      final folder = await notes.createFolder('Journal');
      final s = await service();
      await s.add(Automation(
          id: 'a',
          event: AutomationEvent.taskCompleted,
          action: AutomationAction.appendToNote,
          params: {'where': 'daily', 'title': 'Daily {date}', 'folder': folder, 'text': 'Done: {title}'}));
      for (final t in ['Pay rent', 'Call Sam']) {
        await s.bus.emit(AppEvent('taskCompleted', title: t));
        await s.assistantDone;
      }
      final daily = (await notes.listNotes()).where((n) => n.title == 'Daily 2026-03-05').toList();
      expect(daily, hasLength(1));
      expect(daily.single.folderId, folder);
      expect(await boxes(daily.single.id), ['Done: Pay rent', 'Done: Call Sam']);
      s.dispose();
    });

    test('a note that stays open in an editor is not written to behind its back', () async {
      final id = await noteWith(_text);
      final s = await service();
      s.openEditor = (n) => n == id ? _Editor() : null;
      await s.add(const Automation(id: 'a', event: AutomationEvent.noteClosed, action: AutomationAction.appendToNote, params: {'text': 'x'}));
      await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps');
      await s.assistantDone;
      expect(await boxes(id), [_text]);
      expect(s.all.single.lastResult, contains('stayed open'));
      s.dispose();
    });

    test('it waits for the editor that is being closed, then writes', () async {
      final id = await noteWith(_text);
      final s = await service();
      var open = true;
      s.openEditor = (n) => open && n == id ? _Editor() : null;
      Future<void>.delayed(const Duration(milliseconds: 100), () => open = false);
      await s.add(const Automation(id: 'a', event: AutomationEvent.noteClosed, action: AutomationAction.appendToNote, params: {'text': 'later'}));
      await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps');
      await s.assistantDone;
      expect(await boxes(id), [_text, 'later']);
      s.dispose();
    });
  });

  group('tags and stars', () {
    test('a tag is put on the note, a star too', () async {
      final id = await noteWith(_text);
      final s = await service();
      await s.add(const Automation(id: 't', event: AutomationEvent.noteClosed, action: AutomationAction.addTag, params: {'tag': 'school/maths'}));
      await s.add(const Automation(id: 'f', event: AutomationEvent.noteClosed, action: AutomationAction.starNote));
      await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps');
      expect(await tags.tagsOf(id), ['school/maths']);
      expect((await notes.listNotes()).single.favorite, isTrue);
      s.dispose();
    });

    test('no tag, no change', () async {
      final id = await noteWith(_text);
      final s = await service();
      await s.add(const Automation(id: 't', event: AutomationEvent.noteClosed, action: AutomationAction.addTag, params: {'tag': ' '}));
      await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps');
      expect(await tags.tagsOf(id), isEmpty);
      s.dispose();
    });
  });

  group('the assistant writes into the note', () {
    test('a summary is a box that a later run replaces, not one more', () async {
      final id = await noteWith(_text);
      final s = await service();
      await s.add(const Automation(id: 's', event: AutomationEvent.noteClosed, action: AutomationAction.summarizeToBox));
      await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps');
      await s.assistantDone;
      model.answer = 'Another summary.';
      await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps'); // (unchanged since: skipped, as it should)
      await s.assistantDone;
      expect(await boxes(id), [_text, '**Summary**\nHeaps keep the biggest item on top.']);
      expect(model.prompts.single.user, contains('swim function'));
      expect(model.prompts.single.user, isNot(contains('Heaps\n')), reason: 'the title is not part of what is summarized');
      s.dispose();
    });

    test('an outline is a box of its own; the model is told to use only the notes', () async {
      final id = await noteWith(_text);
      model.answer = '- Heaps\n  - the largest item is at the root';
      final s = await service();
      await s.add(const Automation(id: 'o', event: AutomationEvent.noteClosed, action: AutomationAction.outlineToBox));
      await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps');
      await s.assistantDone;
      expect(await boxes(id), [_text, '**Outline**\n- Heaps\n  - the largest item is at the root']);
      expect(model.prompts.single.system, contains('only what is in the notes'));
      s.dispose();
    });

    test('a translation says the language, keeps the original and is a box of its own', () async {
      final id = await noteWith(_text);
      model.answer = 'Ein binärer Heap hält sein größtes Element an der Wurzel.';
      final s = await service();
      await s.add(const Automation(id: 't', event: AutomationEvent.noteStale, action: AutomationAction.translateToBox, params: {'language': 'de'}));
      await s.run(AutomationEvent.noteStale, noteId: id, title: 'Heaps');
      await s.assistantDone;
      expect(await boxes(id), [_text, '**German**\nEin binärer Heap hält sein größtes Element an der Wurzel.']);
      s.dispose();
    });

    test('without a ready assistant it says so at once, and a note with hardly any text is left alone', () async {
      final id = await noteWith(_text);
      final tiny = await noteWith('milk', title: 'Shopping');
      final s = await service();
      await s.add(const Automation(id: 's', event: AutomationEvent.noteClosed, action: AutomationAction.summarizeToBox));
      await s.run(AutomationEvent.noteClosed, noteId: tiny, title: 'Shopping');
      await s.assistantDone;
      expect(s.all.single.lastResult, contains('Too little text'));
      expect(model.prompts, isEmpty);
      model.current = ProviderStateForTest.notReady;
      final results = await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps');
      expect(results.single, contains('not ready'));
      s.dispose();
    });
  });

  group('notes from templates and reminders', () {
    test('a note from a template of the app is named after the event; a template that is gone is said so', () async {
      final templates = TemplateService(notes, NoteFileService(notes, supportDirectory: () async => dir), now: () => now);
      final s = await service(templates: templates);
      final lecture = templates.builtIn.first.id;
      await s.add(Automation(
          id: 'm', event: AutomationEvent.calendarEventStarting, action: AutomationAction.createNoteFromTemplate, params: {'template': lecture, 'title': 'Notes: {title} {start}'}));
      await s.bus.emit(AppEvent('calendarEventStarting', title: 'Algebra', data: eventVars({'start': '10:15'})));
      expect((await notes.listNotes()).map((n) => n.title), ['Notes: Algebra 10:15']);
      await s.update(s.all.single.copyWith(params: {'template': 'nope', 'title': 'x'}));
      await s.bus.emit(AppEvent('calendarEventStarting', title: 'Algebra'));
      expect(s.all.single.lastResult, contains('not there any more'));
      s.dispose();
    });

    test('a reminder for the note, at the time the rule says', () async {
      final id = await noteWith(_text);
      final reminders = ReminderService(reminders: ReminderRepository(db), sink: _Sink(), read: (k) async => null, write: (k, v) async {}, clock: () => now);
      final s = await service(reminders: reminders);
      await s.add(const Automation(id: 'r', event: AutomationEvent.noteStale, action: AutomationAction.setReminder, params: {'when': 'tomorrow', 'text': 'Look at {title} again'}));
      await s.run(AutomationEvent.noteStale, noteId: id, title: 'Heaps');
      final made = (await reminders.reminders.all()).single;
      expect(made.kind, ReminderKind.note);
      expect(made.refId, id);
      expect(made.title, 'Look at Heaps again');
      expect(made.at, DateTime(2026, 3, 6, 9));
      await s.update(s.all.single.copyWith(params: {'when': 'thisEvening', 'text': 'x'}));
      await s.run(AutomationEvent.noteStale, noteId: id, title: 'Heaps');
      expect((await reminders.reminders.all()).map((r) => r.at), contains(DateTime(2026, 3, 5, 18)));
      s.dispose();
    });

    test('a reminder for an event that is not about a note is a plain one', () async {
      final reminders = ReminderService(reminders: ReminderRepository(db), sink: _Sink(), read: (k) async => null, write: (k, v) async {}, clock: () => now);
      final s = await service(reminders: reminders);
      await s.add(const Automation(id: 'r', event: AutomationEvent.taskCompleted, action: AutomationAction.setReminder, params: {'when': 'inAnHour'}));
      await s.bus.emit(AppEvent('taskCompleted', title: 'Pay rent'));
      final made = (await reminders.reminders.all()).single;
      expect(made.kind, ReminderKind.custom);
      expect(made.at, DateTime(2026, 3, 5, 11, 30));
      expect(made.title, 'Pay rent');
      s.dispose();
    });
  });

  group('pictures of the pages', () {
    test('the open editor is asked for them, in the size the rule says, into the folder', () async {
      final id = await noteWith(_text);
      final editor = _Editor();
      final s = await service();
      await s.add(Automation(id: 'p', event: AutomationEvent.noteClosed, action: AutomationAction.exportImages, params: {'dir': '${dir.path}/pics', 'preset': 'slide'}));
      final results = await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Heaps', editor: editor);
      expect(editor.calls.single, ('${dir.path}/pics', ImagePreset.slide));
      expect(results.single, contains('Saved 2 pictures'));
      expect(Directory('${dir.path}/pics').existsSync(), isTrue);
      s.dispose();
    });

    test('without a folder or an editor that can do it, it says so', () async {
      final id = await noteWith(_text);
      final s = await service();
      await s.add(const Automation(id: 'p', event: AutomationEvent.noteStale, action: AutomationAction.exportImages, params: {}));
      expect((await s.run(AutomationEvent.noteStale, noteId: id, title: 'Heaps', editor: _Editor())).single, contains('No folder'));
      await s.update(s.all.single.copyWith(params: {'dir': dir.path}));
      expect((await s.run(AutomationEvent.noteStale, noteId: id, title: 'Heaps')).single, contains('not open'));
      s.dispose();
    });
  });

  group('what fits what', () {
    test('writing into a note needs a note; pictures need the editor; the rest can follow any event', () {
      expect(AutomationAction.addTag.worksAfter(AutomationEvent.taskCompleted), isFalse);
      expect(AutomationAction.addTag.worksAfter(AutomationEvent.pdfImported), isTrue);
      expect(AutomationAction.exportImages.worksAfter(AutomationEvent.noteClosed), isTrue);
      expect(AutomationAction.exportImages.worksAfter(AutomationEvent.noteStale), isFalse);
      expect(AutomationAction.appendToNote.worksAfter(AutomationEvent.appStarted), isTrue);
      expect(AutomationAction.createNoteFromTemplate.worksAfter(AutomationEvent.calendarEventStarting), isTrue);
      expect(AutomationAction.setReminder.worksAfter(AutomationEvent.taskCompleted), isTrue);
    });

    test('the settings of an action: every choice has a label, a field that depends on another names one that exists', () {
      for (final action in AutomationAction.values) {
        final keys = action.fields.map((f) => f.key).toSet();
        expect(keys.length, action.fields.length, reason: '${action.name} has a key twice');
        for (final f in action.fields) {
          if (f.kind == FieldKind.choice) {
            expect(f.choices, isNotEmpty);
            expect(f.choices.keys, contains(f.initial), reason: '${action.name}.${f.key} starts on something that is not a choice');
          }
          if (f.when != null) expect(keys, contains(f.when!.$1));
        }
      }
      expect(Colors.black, isNotNull);
    });
  });
}
