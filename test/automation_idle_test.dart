import 'package:flutter/painting.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/events/event_bus.dart';
import 'package:notes/events/event_sources.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _OpenEditor implements NoteEditorHandle, TitleSetter {
  String title;
  _OpenEditor(this.title);
  @override
  Future<void> get ready async {}
  @override
  Future<void> saveNow() async {}
  @override
  String get noteTitle => title;
  @override
  Future<String?> exportPdfTo(String path) async => null;
  @override
  Future<List<String>> pdfTextLines() async => const [];
  @override
  void setNoteTitle(String t) => title = t;
}

void main() {
  setUpAll(AppDatabase.initFfi);
  late NoteRepository notes;
  late TaskRepository tasks;

  setUp(() async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    for (final t in ['settings', 'tasks', 'notes', 'folders', 'text_boxes']) {
      await db.delete(t);
    }
    notes = NoteRepository(db);
    tasks = TaskRepository(db);
  });

  Future<String> noteWith(String text, {String title = 'Untitled Note'}) async {
    final id = await notes.createNote(title: title);
    await notes.putTextBox(id, 0, TextBoxWidgetModel(id: 'b', position: Offset.zero, size: const Size(100, 0), initialText: text));
    return id;
  }

  group('a note left alone', () {
    test('announced once, a pause after the last save; every new save starts the wait again', () async {
      final bus = EventBus()..register(const EventType('notePaused', 'x', hasNote: true));
      final heard = <String>[];
      bus.listen((e) => heard.add('${e.type}:${e.title}'));
      final id = await notes.createNote(title: 'Plan');
      final source = IdleSource(notes, bus, pause: const Duration(milliseconds: 120))..start();
      final note = (await notes.loadNote(id))!;
      await notes.saveNote(note);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      await notes.saveNote(note); // again before the pause was over
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(heard, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(heard, ['notePaused:Plan']);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(heard, hasLength(1));
      source.dispose();
    });
  });

  group('naming a note', () {
    test('the first line becomes the title of a note without one, in the database', () async {
      final id = await noteWith('Heap sort and priority queues\nthe swim function restores the heap property');
      final s = AutomationService(notes, tasks);
      await s.load();
      await s.add(const Automation(id: 't', event: AutomationEvent.notePaused, action: AutomationAction.titleNote));
      await s.bus.emit(AppEvent('notePaused', noteId: id));
      await s.assistantDone;
      expect((await notes.noteInfo(id))!.title, 'Heap sort and priority queues');
      expect(s.all.single.lastResult, contains('Named it'));
      s.dispose();
    });

    test('the language model writes the title when there is one', () async {
      final id = await noteWith('We talked about the new budget and who pays for the trip in April, and what is left over.');
      final s = AutomationService(notes, tasks, smartTitle: (text) async => 'Budget talk');
      await s.load();
      await s.add(const Automation(id: 't', event: AutomationEvent.noteClosed, action: AutomationAction.titleNote));
      await s.run(AutomationEvent.noteClosed, noteId: id, title: 'Untitled Note');
      await s.assistantDone;
      expect((await notes.noteInfo(id))!.title, 'Budget talk');
      s.dispose();
    });

    test('a note that has a title is never changed, and one with too little text is left alone', () async {
      final titled = await noteWith('Something long enough to be a title of its own, really', title: 'Mine');
      final tiny = await noteWith('milk');
      final s = AutomationService(notes, tasks);
      await s.load();
      await s.add(const Automation(id: 't', event: AutomationEvent.notePaused, action: AutomationAction.titleNote));
      for (final id in [titled, tiny]) {
        await s.bus.emit(AppEvent('notePaused', noteId: id));
        await s.assistantDone;
      }
      expect((await notes.noteInfo(titled))!.title, 'Mine');
      expect((await notes.noteInfo(tiny))!.title, 'Untitled Note');
      s.dispose();
    });

    test('a note that is open is named through its editor, so that the editor does not write the old title back', () async {
      final id = await noteWith('Chemistry lab report\nmeasured the pH of three samples');
      final editor = _OpenEditor('');
      final s = AutomationService(notes, tasks);
      s.openEditor = (n) => n == id ? editor : null;
      await s.load();
      await s.add(const Automation(id: 't', event: AutomationEvent.notePaused, action: AutomationAction.titleNote));
      await s.bus.emit(AppEvent('notePaused', noteId: id));
      await s.assistantDone;
      expect(editor.title, 'Chemistry lab report');
      expect((await notes.noteInfo(id))!.title, 'Untitled Note'); // the editor saves its own title a moment later
      s.dispose();
    });

    test('a long first line is cut at a word, a very long word is no title', () {
      expect(AutomationService.firstLineTitle('word ' * 30), endsWith('…'));
      expect(AutomationService.firstLineTitle('word ' * 30)!.length, lessThanOrEqualTo(61));
      expect(AutomationService.firstLineTitle('x' * 90), isNull);
      expect(AutomationService.firstLineTitle('## Lecture 4: Graphs.\nmore'), 'Lecture 4: Graphs');
      expect(AutomationService.firstLineTitle('\n  \n'), isNull);
    });

    test('naming and filing work after a pause or a closing, and filing after a pause too', () {
      expect(AutomationAction.titleNote.worksAfter(AutomationEvent.notePaused), isTrue);
      expect(AutomationAction.titleNote.worksAfter(AutomationEvent.noteClosed), isTrue);
      expect(AutomationAction.titleNote.worksAfter(AutomationEvent.noteCreated), isFalse);
      expect(AutomationAction.sortIntoFolder.worksAfter(AutomationEvent.notePaused), isTrue);
    });
  });
}
