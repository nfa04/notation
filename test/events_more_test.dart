import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/audio/wav.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/audio_repository.dart';
import 'package:notes/data/note_activity.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/events/event_bus.dart';
import 'package:notes/events/event_sources.dart';
import 'package:notes/markdown/mention.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/pdf_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  late NoteRepository notes;
  late TaskRepository tasks;
  late Directory dir;
  late AudioRepository audio;

  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath);
    for (final t in ['settings', 'tasks', 'notes', 'folders', 'text_boxes', 'highlights', 'note_audio']) {
      await db.delete(t);
    }
    notes = NoteRepository(db);
    tasks = TaskRepository(db);
    dir = await Directory.systemTemp.createTemp('events_more_');
    audio = AudioRepository(db, root: () async => dir);
  });
  tearDown(() => dir.delete(recursive: true));

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

  group('what a save adds to a note', () {
    test('a page that gets something, a highlight and a link are reported; a plain save is not', () async {
      final target = await notes.createNote(title: 'Linear algebra');
      final id = await notes.createNote(title: 'Plan');
      final seen = <NoteActivity>[];
      notes.activity.listen(seen.add);

      var note = (await notes.loadNote(id))!;
      await notes.saveNote(note);
      await settle();
      expect(seen, isEmpty, reason: 'nothing was added');

      note.textBoxes[2] = [TextBoxWidgetModel(id: 'b', position: Offset.zero, size: const Size(100, 0), initialText: 'see ${noteLink(target, 'Linear algebra')}')];
      note.highlights[0] = [PdfHighlight(rect: const Rect.fromLTWH(0, 0, 10, 10), color: const Color(0xFFFFFF00))];
      await notes.saveNote(note);
      await settle();
      expect(seen, hasLength(1));
      expect(seen.single.pagesAdded, 2, reason: 'a note has one page to begin with, and now three');
      expect(seen.single.pages, 3);
      expect(seen.single.highlightsAdded, 1);
      expect(seen.single.newLinks, {target});

      await notes.saveNote(note); // the same again
      await settle();
      expect(seen, hasLength(1));
      note = (await notes.loadNote(id))!;
      note.highlights[0]!.add(PdfHighlight(rect: const Rect.fromLTWH(20, 0, 10, 10), color: const Color(0xFFFFFF00)));
      await notes.saveNote(note);
      await settle();
      expect(seen.last.highlightsAdded, 1);
      expect(seen.last.pagesAdded, 0);
    });

    test('a note that was not loaded since the app started adds nothing at its first save', () async {
      final id = await notes.createNote(title: 'x');
      final other = NoteRepository(db); // another run of the app
      final seen = <NoteActivity>[];
      other.activity.listen(seen.add);
      final note = NoteData(id: id, title: 'x')..highlights[0] = [PdfHighlight(rect: const Rect.fromLTWH(0, 0, 1, 1), color: const Color(0xFFFFFF00))];
      await other.saveNote(note);
      await settle();
      expect(seen, isEmpty);
    });

    test('a PDF that is put into a note is one event, not as many as it has pages', () async {
      final id = await notes.createNote(title: 'paper');
      final seen = <NoteActivity>[];
      notes.activity.listen(seen.add);
      final note = (await notes.loadNote(id))!
        ..pdfName = 'paper.pdf'
        ..pdfPath = '/x/paper.pdf'
        ..pdfPageCount = 30;
      await notes.saveNote(note);
      await settle();
      expect(seen.single.pdfAdded, 'paper.pdf');
      expect(seen.single.pagesAdded, 0);
    });
  });

  group('announced on the bus', () {
    test('page, highlight, link and PDF events carry the note and what the texts can use', () async {
      final bus = EventBus();
      for (final e in AutomationEvent.values) {
        bus.register(EventType(e.name, e.label, hasNote: e.hasNote));
      }
      final heard = <AppEvent>[];
      bus.listen(heard.add);
      final source = ActivitySource(notes, bus, tasks: tasks, audio: audio)..start();
      final target = await notes.createNote(title: 'Graphs');
      final id = await notes.createNote(title: 'Plan');
      final note = (await notes.loadNote(id))!
        ..pdfName = 'slides.pdf'
        ..pdfPath = '/x/slides.pdf'
        ..pdfPageCount = 4;
      note.highlights[1] = [PdfHighlight(rect: const Rect.fromLTWH(0, 0, 1, 1), color: const Color(0xFFFFFF00))];
      note.textBoxes[1] = [TextBoxWidgetModel(id: 'b', position: Offset.zero, size: const Size(10, 0), initialText: noteLink(target, 'Graphs'))];
      await notes.saveNote(note);
      await settle();
      expect(heard.map((e) => e.type), unorderedEquals(['pdfImported', 'highlightAdded', 'noteLinked']));
      final linked = heard.firstWhere((e) => e.type == 'noteLinked');
      expect(linked.noteId, id);
      expect(linked.title, 'Plan');
      expect((linked.data['vars'] as Map)['target'], 'Graphs');
      expect((heard.firstWhere((e) => e.type == 'pdfImported').data['vars'] as Map)['pdf'], 'slides.pdf');
      source.dispose();
    });

    test('a task that is ticked off, and a recording that is kept; not a sound a note file brought, nor a note read aloud', () async {
      final bus = EventBus();
      for (final e in AutomationEvent.values) {
        bus.register(EventType(e.name, e.label, hasNote: e.hasNote));
      }
      final heard = <AppEvent>[];
      bus.listen(heard.add);
      final source = ActivitySource(notes, bus, tasks: tasks, audio: audio)..start();
      final id = await notes.createNote(title: 'Meeting');
      final task = await tasks.createTask('Pay rent', dueDate: DateTime(2026, 3, 5));
      await tasks.setDone(task, true);
      await tasks.setDone(task, true); // already done
      final wav = wavFromMuLaw(Uint8List.fromList(List.filled(8000 * 90, 0xFF)), 8000);
      await audio.add(id, wav, title: 'Standup');
      await audio.add(id, wav, title: 'imported', id: 'fixed');
      await audio.add(id, wav, title: 'read aloud', kind: AudioKind.speech);
      await settle();
      final done = heard.singleWhere((e) => e.type == 'taskCompleted');
      expect(done.title, 'Pay rent');
      expect((done.data['vars'] as Map)['due'], '2026-03-05');
      final recorded = heard.singleWhere((e) => e.type == 'audioRecorded');
      expect(recorded.noteId, id);
      expect((recorded.data['vars'] as Map)['minutes'], '2'); // a minute and a half
      source.dispose();
    });

    test('a rule for a completed task makes a follow-up task from what the event says', () async {
      final s = AutomationService(notes, tasks);
      await s.load();
      ActivitySource(notes, s.bus, tasks: tasks).start();
      await s.add(const Automation(
          id: 'f', event: AutomationEvent.taskCompleted, action: AutomationAction.addTask, params: {'title': 'Send receipt for {title} (was due {due})'}));
      final task = await tasks.createTask('Pay rent', dueDate: DateTime(2026, 3, 5));
      await tasks.setDone(task, true);
      await settle();
      expect((await tasks.listTasks()).map((t) => t.title), contains('Send receipt for Pay rent (was due 2026-03-05)'));
      s.dispose();
    });
  });

  group('a calendar event about to start', () {
    test('each event once, only inside the lead time, never an all-day one', () async {
      var now = DateTime(2026, 3, 5, 9, 0);
      var asked = 0;
      final s = AutomationService(notes, tasks, now: () => now, upcomingEvents: (from, to) async {
        asked++;
        return [
          UpcomingEvent('Standup', DateTime(2026, 3, 5, 9, 8), uid: 'a'),
          UpcomingEvent('Lunch', DateTime(2026, 3, 5, 12, 0), uid: 'b'),
          UpcomingEvent('Holiday', DateTime(2026, 3, 5, 0, 0), allDay: true, uid: 'c'),
        ];
      });
      await s.load();
      await s.add(const Automation(
          id: 'c', event: AutomationEvent.calendarEventStarting, action: AutomationAction.addTask, params: {'title': 'Prepare for {title} at {start}', 'minutes': '10'}));
      expect(await s.checkEventsStarting(), 1);
      expect((await tasks.listTasks()).single.title, 'Prepare for Standup at 09:08');
      expect(await s.checkEventsStarting(), 0, reason: 'once');
      now = DateTime(2026, 3, 5, 11, 55);
      expect(await s.checkEventsStarting(), 1, reason: 'lunch is five minutes away');
      expect(await s.checkEventsStarting(), 0);
      expect(asked, 2, reason: 'the calendars are asked every ten minutes at most: here once at 9:00 and again at 11:55');
      expect(s.all.single.lastResult, contains('Lunch'));
      s.dispose();
    });

    test('a calendar that cannot be read does not break anything and is tried again', () async {
      var fail = true;
      final s = AutomationService(notes, tasks, now: () => DateTime(2026, 3, 5, 9, 0), upcomingEvents: (from, to) async {
        if (fail) throw StateError('offline');
        return [UpcomingEvent('Standup', DateTime(2026, 3, 5, 9, 5), uid: 'a')];
      });
      await s.load();
      await s.add(const Automation(id: 'c', event: AutomationEvent.calendarEventStarting, action: AutomationAction.addTask, params: {'title': '{title}'}));
      expect(await s.checkEventsStarting(), 0);
      fail = false;
      expect(await s.checkEventsStarting(), 1);
      s.dispose();
    });

    test('with no rule for it the calendars are not asked', () async {
      var asked = 0;
      final s = AutomationService(notes, tasks, upcomingEvents: (a, b) async {
        asked++;
        return [];
      });
      await s.load();
      expect(await s.checkEventsStarting(), 0);
      expect(asked, 0);
      s.dispose();
    });
  });

  test('every event has a label, a note flag that fits it and placeholders that are written as {name}', () {
    final ids = AutomationEvent.values.map((e) => e.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
    for (final e in AutomationEvent.values) {
      expect(e.label, isNotEmpty);
      for (final (name, what) in e.placeholders) {
        expect(name, matches(RegExp(r'^\{\w+\}$')));
        expect(what, isNotEmpty);
      }
    }
    expect(AutomationEvent.pageAdded.hasNote, isTrue);
    expect(AutomationEvent.taskCompleted.hasNote, isFalse);
    expect(AutomationEvent.calendarEventStarting.hasNote, isFalse);
  });
}
