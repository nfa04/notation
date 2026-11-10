import 'package:flutter/painting.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/automations/todo_finder.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/events/event_bus.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  // a Wednesday
  final today = DateTime(2026, 3, 4);

  group('finding to-do lines', () {
    test('(the day the tests are written for)', () => expect(today.weekday, DateTime.wednesday));

    test('markers: words and empty boxes; ticked boxes and ordinary lines are not to-dos', () {
      final items = findTodos([
        'Lecture notes on heaps',
        'TODO: call the landlord',
        '☐ buy paper',
        '- [ ] send the form',
        '[ ] ',
        '- [x] already done',
        '☑ done too',
        'Aufgabe: Übung 3 lösen',
        'Action item - email the group',
        'todos are nice',
      ], today);
      expect(items.map((i) => i.summary), ['Call the landlord', 'Buy paper', 'Send the form', 'Übung 3 lösen', 'Email the group']);
      expect(items.every((i) => i.due == null), isTrue);
    });

    test('a day the line says: a date, today, tomorrow, a weekday, next week', () {
      DateTime? due(String line) => findTodos([line], today).single.due;
      expect(due('todo hand in the report 2026-03-20'), DateTime(2026, 3, 20));
      expect(due('☐ call Sam tomorrow'), DateTime(2026, 3, 5));
      expect(due('☐ call Sam heute'), DateTime(2026, 3, 4));
      expect(due('☐ call Sam morgen'), DateTime(2026, 3, 5));
      expect(due('☐ pay rent by Friday'), DateTime(2026, 3, 6));
      expect(due('☐ pay rent bis Montag'), DateTime(2026, 3, 9));
      expect(due('☐ pay rent by Wednesday'), DateTime(2026, 3, 11)); // never the day itself
      expect(due('☐ pay rent by fri'), DateTime(2026, 3, 6));
      expect(due('☐ plan the trip next week'), DateTime(2026, 3, 11));
    });

    test('the words that said when are not in the summary', () {
      expect(findTodos(['☐ call Sam tomorrow'], today).single.summary, 'Call Sam');
      expect(findTodos(['☐ pay rent by Friday'], today).single.summary, 'Pay rent');
      expect(findTodos(['todo: hand in the report on 2026-03-20'], today).single.summary, 'Hand in the report');
    });

    test('the item stays the same when the day it says is worked out on another day, and a repeat counts once', () {
      final a = findTodos(['☐ pay rent by Friday'], today).single;
      final b = findTodos(['☐ Pay rent by Friday'], DateTime(2026, 3, 9)).single;
      expect(a.key, b.key);
      expect(findTodos(['☐ pay rent', '- [ ] Pay rent'], today), hasLength(1));
    });

    test('a long line is cut, and a marker with next to nothing after it is not an item', () {
      expect(findTodos(['☐ ${'word ' * 60}'], today).single.summary.length, lessThanOrEqualTo(120));
      expect(findTodos(['todo', 'todo: x', '☐'], today), isEmpty);
    });
  });

  group('the automation', () {
    setUpAll(AppDatabase.initFfi);
    late NoteRepository notes;
    late TaskRepository tasks;
    setUp(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['settings', 'tasks', 'notes', 'folders', 'text_boxes', 'ink_text']) {
        await db.delete(t);
      }
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
    });

    Future<String> noteWith(String text) async {
      final id = await notes.createNote(title: 'Meeting');
      await notes.putTextBox(id, 0, TextBoxWidgetModel(id: 'b', position: Offset.zero, size: const Size(100, 0), initialText: text));
      return id;
    }

    test('every new to-do line of a closed note becomes a task, on its day, once', () async {
      final id = await noteWith('Notes\n☐ call Sam tomorrow\n- [ ] buy paper\nsomething else');
      final s = AutomationService(notes, tasks, now: () => today);
      await s.load();
      await s.add(const Automation(id: 't', event: AutomationEvent.todoFound, action: AutomationAction.addTask, params: {'title': '{summary}', 'due': 'inAWeek'}));
      await s.bus.emit(AppEvent('noteClosed', noteId: id, title: 'Meeting'));
      var list = await tasks.listTasks();
      expect(list.map((t) => t.title).toSet(), {'Call Sam', 'Buy paper'});
      expect(list.firstWhere((t) => t.title == 'Call Sam').dueDate, DateTime(2026, 3, 5));
      expect(list.firstWhere((t) => t.title == 'Buy paper').dueDate, DateTime(2026, 3, 11)); // the day of the rule: it says none
      // closing it again adds nothing
      await s.bus.emit(AppEvent('noteClosed', noteId: id, title: 'Meeting'));
      expect(await tasks.listTasks(), hasLength(2));
      // a line written since is picked up
      await notes.putTextBox(id, 0, TextBoxWidgetModel(id: 'c', position: Offset.zero, size: const Size(100, 0), initialText: '☐ renew the library card'));
      await s.bus.emit(AppEvent('noteClosed', noteId: id, title: 'Meeting'));
      list = await tasks.listTasks();
      expect(list, hasLength(3));
      s.dispose();
    });

    test('nothing is read when no rule asks for to-do lines', () async {
      final id = await noteWith('☐ call Sam');
      final s = AutomationService(notes, tasks, now: () => today);
      await s.load();
      expect(await s.scanTodos(id), isEmpty);
      expect(await tasks.listTasks(), isEmpty);
      s.dispose();
    });
  });
}
