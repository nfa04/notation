import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/automations/meeting.dart';
import 'package:notes/automations/todo_finder.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/events/event_sources.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_model.dart';

NoteSummary summary(String id, String title, DateTime at, {int lock = 0}) =>
    NoteSummary(id: id, title: title, updatedAt: at, isPdf: false, folderId: null, lockMode: lock);

void main() {
  group('the previous meeting', () {
    final notes = [
      summary('a', 'Standup 2026-03-02', DateTime(2026, 3, 2)),
      summary('b', 'standup 2026-03-04', DateTime(2026, 3, 4)),
      summary('c', 'Standup 2026-03-05', DateTime(2026, 3, 5)),
      summary('d', 'Standup secret', DateTime(2026, 3, 9), lock: 1),
      summary('e', 'Groceries', DateTime(2026, 3, 8)),
    ];

    test('the note of that name that was changed last, not the one being made, not a locked one, in any case', () {
      expect(previousMeetingNote(notes, 'Standup', exceptId: 'c')!.id, 'b');
      expect(previousMeetingNote(notes, 'STANDUP', exceptId: 'x')!.id, 'c');
      expect(previousMeetingNote(notes, 'Review', exceptId: 'x'), isNull);
      expect(previousMeetingNote(notes, 'ab', exceptId: 'x'), isNull, reason: 'too short a name to go by');
    });

    test('the text: the meeting, what is open (as written, at most twelve) and room for notes', () {
      final text = meetingNoteText(title: 'Standup', day: '2026-03-06', start: '09:15', previous: 'Standup 2026-03-05', open: ['pay rent by Friday', 'call Sam']);
      expect(text, startsWith('**Standup**  ·  2026-03-06 09:15'));
      expect(text, contains('**Still open from last time** (Standup 2026-03-05)\n☐ pay rent by Friday\n☐ call Sam'));
      expect(text, endsWith('**Notes**\n'));
      final many = meetingNoteText(title: 'x', day: 'd', start: '', open: [for (var i = 0; i < 15; i++) 'item $i']);
      expect(many, contains('item 11'));
      expect(many, isNot(contains('item 12')));
      expect(many, contains('… and 3 more'));
      expect(meetingNoteText(title: 'x', day: 'd', start: ''), isNot(contains('Still open')));
    });

    test('a to-do line without its marker, as it was written; a ticked one and a plain line have none', () {
      expect(todoText('- [ ] pay rent by Friday'), 'pay rent by Friday');
      expect(todoText('TODO: call Sam'), 'call Sam');
      expect(todoText('- [x] done'), isNull);
      expect(todoText('just a line'), isNull);
    });
  });

  group('a meeting from start to end', () {
    setUpAll(AppDatabase.initFfi);
    late NoteRepository notes;
    late TaskRepository tasks;
    late FakeModel model;
    var now = DateTime(2026, 3, 6, 9, 5);
    final start = DateTime(2026, 3, 6, 9, 15), end = DateTime(2026, 3, 6, 9, 45);

    setUp(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['settings', 'tasks', 'notes', 'folders', 'text_boxes']) {
        await db.delete(t);
      }
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
      model = FakeModel('Planned the sprint.');
      now = DateTime(2026, 3, 6, 9, 5);
    });

    Future<AutomationService> service() async {
      final s = AutomationService(notes, tasks,
          now: () => now,
          ai: AiService(providers: [model]),
          upcomingEvents: (from, to) async => [UpcomingEvent('Standup', start, end: end, uid: 'u1'), UpcomingEvent('Lunch', DateTime(2026, 3, 6, 12), end: DateTime(2026, 3, 6, 13), uid: 'u2')]);
      s.editorWait = const Duration(milliseconds: 100);
      await s.load();
      return s;
    }

    Future<List<String>> boxes(String id) async => [for (final b in (await notes.loadNote(id))!.textBoxes[0] ?? const <TextBoxWidgetModel>[]) b.controller.text];

    Future<String> lastMeeting() async {
      final id = await notes.createNote(title: 'Standup 2026-03-05');
      await notes.putTextBox(id, 0, TextBoxWidgetModel(id: 'b', position: Offset.zero, size: const Size(300, 80), initialText: '☐ pay rent by Friday\n- [x] call Sam\n- [ ] send the form'));
      return id;
    }

    test('ten minutes before: a note with what was left open last time; then, when it is over, the rules reach that note', () async {
      await lastMeeting();
      final s = await service();
      await s.add(const Automation(
          id: 'm', event: AutomationEvent.calendarEventStarting, action: AutomationAction.meetingNote, params: {'title': '{title} {day}', 'carry': 'yes', 'minutes': '10'}));
      await s.add(const Automation(id: 'e', event: AutomationEvent.calendarEventEnded, action: AutomationAction.summarizeToBox));

      expect(await s.checkEventsStarting(), 1);
      final made = (await notes.listNotes()).firstWhere((n) => n.title == 'Standup 2026-03-06');
      final text = (await boxes(made.id)).single;
      expect(text, contains('**Standup**  ·  2026-03-06 09:15'));
      expect(text, contains('☐ pay rent by Friday'));
      expect(text, contains('☐ send the form'));
      expect(text, isNot(contains('call Sam')), reason: 'that one was ticked');
      expect(s.all.first.lastResult, contains('2 open lines'));

      // the meeting is over
      await notes.putTextBox(made.id, 0, TextBoxWidgetModel(id: 'mine', position: const Offset(40, 300), size: const Size(300, 60), initialText: 'We planned the sprint, moved the demo to Thursday and agreed who reviews the release notes.'));
      now = DateTime(2026, 3, 6, 9, 50);
      expect(await s.checkEventsStarting(), 1);
      await s.assistantDone;
      expect(await boxes(made.id), contains('**Summary**\nPlanned the sprint.'));
      expect(await s.checkEventsStarting(), 0, reason: 'once');
      s.dispose();
    });

    test('a meeting that got no note is not acted on when it ends, nor is one that ended long ago', () async {
      final s = await service();
      await s.add(const Automation(id: 'e', event: AutomationEvent.calendarEventEnded, action: AutomationAction.starNote));
      now = DateTime(2026, 3, 6, 9, 50);
      expect(await s.checkEventsStarting(), 0, reason: 'there is no note of that meeting');
      s.dispose();

      final s2 = await service();
      await s2.add(const Automation(id: 'm', event: AutomationEvent.calendarEventStarting, action: AutomationAction.meetingNote, params: {'title': '{title}', 'minutes': '30'}));
      await s2.add(const Automation(id: 'e', event: AutomationEvent.calendarEventEnded, action: AutomationAction.starNote));
      now = DateTime(2026, 3, 6, 9, 0);
      expect(await s2.checkEventsStarting(), 1);
      now = DateTime(2026, 3, 6, 11, 0); // two hours after it ended, and a new fetch
      expect(await s2.checkEventsStarting(), 0);
      expect((await notes.listNotes()).where((n) => n.favorite), isEmpty);
      s2.dispose();
    });

    test('the first meeting of a series has nothing to carry, and "no" carries nothing', () async {
      final s = await service();
      await s.add(const Automation(id: 'm', event: AutomationEvent.calendarEventStarting, action: AutomationAction.meetingNote, params: {'title': 'Fresh', 'minutes': '30'}));
      await s.checkEventsStarting();
      final id = (await notes.listNotes()).firstWhere((n) => n.title == 'Fresh').id;
      expect((await boxes(id)).single, isNot(contains('Still open')));
      s.dispose();

      await lastMeeting();
      final s2 = await service();
      await s2.add(const Automation(id: 'm2', event: AutomationEvent.calendarEventStarting, action: AutomationAction.meetingNote, params: {'title': 'No carry', 'carry': 'no', 'minutes': '30'}));
      await s2.checkEventsStarting();
      final other = (await notes.listNotes()).firstWhere((n) => n.title == 'No carry').id;
      expect((await boxes(other)).single, isNot(contains('Still open')));
      s2.dispose();
    });

    test('what the rules fit', () {
      expect(AutomationAction.meetingNote.worksAfter(AutomationEvent.calendarEventStarting), isTrue);
      expect(AutomationAction.meetingNote.worksAfter(AutomationEvent.noteClosed), isFalse);
      expect(AutomationAction.summarizeToBox.worksAfter(AutomationEvent.calendarEventEnded), isTrue);
      expect(AutomationEvent.calendarEventEnded.hasNote, isTrue);
    });
  });
}
