import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/bookmark_repository.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/reminder_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/mcp/mcp_notes.dart';
import 'package:notes/mcp/mcp_protocol.dart';
import 'package:notes/models/page_format.dart';
import 'package:notes/reminders/notification_sink.dart';
import 'package:notes/reminders/reminder_service.dart';
import 'package:notes/sync/calendar_access.dart';
import 'package:notes/sync/caldav_remote.dart' show CalendarInfo, DayEvent, NewEvent;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

/// The tools that the assistant of the app has beyond reading and writing text, as an agent outside the app gets them: pages, text
/// boxes, pictures and drawing, PDFs, tracked changes, flashcards, tasks, reminders and the calendar. Here for notes that are not open
/// (an open note goes through its editor, which the same tools reach as `agentApi`).
void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  late NoteRepository repo;
  late BookmarkRepository bookmarks;
  late CardRepository cards;
  late McpProtocol protocol;
  late List<(CalendarInfo, NewEvent)> made;
  var calendars = <CalendarInfo>[];

  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath);
    for (final t in ['notes', 'folders', 'tasks', 'text_boxes', 'page_bookmarks', 'review_cards', 'reminders']) {
      await db.delete(t);
    }
    repo = NoteRepository(db);
    bookmarks = BookmarkRepository(db);
    cards = CardRepository(db);
    made = [];
    calendars = [const CalendarInfo('a', 'Home', null)];
    final tasks = TaskRepository(db);
    final notes = McpNotes(
      repository: repo,
      tasks: tasks,
      cards: cards,
      bookmarks: bookmarks,
      calendar: CalendarAccess(
        events: (from, to) async => [DayEvent(title: 'Exam', start: DateTime(2030, 5, 2, 9), end: DateTime(2030, 5, 2, 11), allDay: false, calendarName: 'Home')],
        writable: () async => calendars,
        create: (target, event) async => made.add((target, event)),
      ),
      reminders: ReminderService(reminders: ReminderRepository(db), tasks: tasks, sink: _Sink(), read: (k) async => null, write: (k, v) async {}),
    );
    protocol = McpProtocol(tools: () => notes.tools, canChange: () => true);
  });

  var next = 0;

  Future<(String, bool)> call(String name, [Map<String, Object?> args = const {}]) async {
    final r = await protocol.handle({'jsonrpc': '2.0', 'id': ++next, 'method': 'tools/call', 'params': {'name': name, 'arguments': args}});
    final result = (r!.body['result'] as Map);
    return (((result['content'] as List).single as Map)['text'] as String, result['isError'] == true);
  }

  Future<String> ok(String name, [Map<String, Object?> args = const {}]) async {
    final (text, failed) = await call(name, args);
    expect(failed, isFalse, reason: '$name: $text');
    return text;
  }

  Future<String> fails(String name, [Map<String, Object?> args = const {}]) async {
    final (text, failed) = await call(name, args);
    expect(failed, isTrue, reason: '$name should have failed, said: $text');
    return text;
  }

  Future<String> make(String title, [String text = '']) async {
    final reply = await ok('create_note', {'title': title, 'text': text});
    return RegExp(r'Its id is (\S+)\.').firstMatch(reply)!.group(1)!;
  }

  test('the tools are there, say what they are called here, and a PDF is only read from the note the call names', () async {
    final tools = {for (final t in McpNotes(repository: repo, tasks: TaskRepository(db), cards: cards).tools) t.name: t};
    for (final n in [
      'resolve_tracked_changes', 'read_pdf', 'search_pdf', 'add_flashcards', 'list_pages', 'add_page', 'delete_page', 'move_page', 'set_up_pages',
      'list_text_boxes', 'add_text_box', 'move_text_box', 'delete_text_box', 'list_images', 'move_image', 'delete_image', 'draw_shape', 'draw_strokes',
      'update_task', 'delete_task',
    ]) {
      expect(tools, contains(n));
    }
    // (what is not set up is not offered)
    expect(tools, isNot(contains('add_calendar_event')));
    expect(tools, isNot(contains('add_reminder')));
    expect(McpNotes(repository: repo, tasks: TaskRepository(db)).tools.map((t) => t.name), isNot(contains('add_flashcards')));
    // the descriptions send the model to tools that are here
    final format = tools['format_note_text']!.description + jsonEncode(tools['format_note_text']!.inputSchema);
    expect(format, contains('inspect_note_formatting'));
    expect(format, isNot(contains('note_inspect')));
    expect(tools['draw_shape']!.description, contains('list_pages'));
    expect(((tools['read_pdf']!.inputSchema['properties']) as Map).keys, ['note_id', 'from', 'to']);
    // what only looks is read only
    for (final n in ['read_pdf', 'search_pdf', 'list_pages', 'list_text_boxes', 'list_images']) {
      expect(tools[n]!.changes, isFalse, reason: n);
    }
    for (final n in ['add_page', 'draw_shape', 'add_text_box', 'resolve_tracked_changes']) {
      expect(tools[n]!.changes, isTrue, reason: n);
    }
  });

  test('pages, text boxes and drawing of a note that is not open, with its bookmarks following the pages', () async {
    final id = await make('Paper', '# Written\nsome text');
    expect(await ok('list_pages', {'note_id': id}), allOf(contains('Page 1 (written'), contains('Page 2 (notebook')));

    expect(await ok('add_text_box', {'note_id': id, 'text': 'on two', 'page': 2, 'x': 100, 'y': 50}), contains('has the id'));
    expect(await ok('list_text_boxes', {'note_id': id}), allOf(contains('page 2 at 100.0, 50.0'), contains('on two')));
    final boxId = RegExp(r'id (\S+):').firstMatch(await ok('list_text_boxes', {'note_id': id}))!.group(1)!;
    await ok('move_text_box', {'note_id': id, 'id': boxId, 'x': 10, 'page': 1});
    expect(await ok('list_text_boxes', {'note_id': id}), contains('page 1 at 10.0, 50.0'));
    await ok('move_text_box', {'note_id': id, 'id': boxId, 'page': 2});

    // the paper is drawn on
    expect(await ok('draw_shape', {'note_id': id, 'type': 'rectangle', 'x': 20, 'y': 20, 'width': 100, 'height': 60, 'page': 2}), contains('rectangle'));
    expect(await ok('draw_strokes', {'note_id': id, 'strokes': [{'points': [[0, 0], [50, 50]], 'color': '#ff0000'}]}), contains('1 lines'));
    expect(await ok('list_pages', {'note_id': id}), allOf(contains('Page 1 (written'), contains('1 strokes'), contains('Page 2'), contains('1 text boxes')));
    expect((await repo.loadNote(id))!.strokes[1], hasLength(1));

    // a page in between: the page, its things and its bookmark go one down
    await bookmarks.toggle(id, 1);
    expect(await ok('add_page', {'note_id': id, 'at': 2}), contains('page is page 2'));
    expect((await repo.loadNote(id))!.textBoxes.keys, [2]);
    expect([for (final b in await bookmarks.list(id)) b.page], [2]);
    await ok('move_page', {'note_id': id, 'page': 3, 'to': 2});
    expect((await repo.loadNote(id))!.textBoxes.keys, [1]);
    expect([for (final b in await bookmarks.list(id)) b.page], [1]);
    await ok('delete_page', {'note_id': id, 'page': 2});
    expect((await repo.loadNote(id))!.textBoxes, isEmpty);
    expect(await bookmarks.list(id), isEmpty);
    expect((await repo.loadNote(id))!.documentText, '# Written\nsome text');

    // what is not possible says why
    expect(await fails('delete_page', {'note_id': id, 'page': 1}), contains('written document'));
    expect(await fails('move_page', {'note_id': id, 'page': 1, 'to': 2}), contains('written document'));
    expect(await fails('add_page', {'note_id': id, 'at': 1}), contains('written document'));
    expect(await fails('delete_page', {'note_id': id, 'page': 9}), contains('There is no page 9'));
    expect(await fails('move_text_box', {'note_id': id, 'id': 'nope', 'x': 1}), contains('no text box'));
    expect(await fails('draw_strokes', {'note_id': id, 'strokes': [{'points': [[0, 0]]}]}), contains('two points'));
  });

  test('the paper of a note is set up, and a note without a PDF has none to read', () async {
    final id = await make('Setup', 'x');
    expect(await ok('set_up_pages', {'note_id': id, 'paper': 'a5', 'orientation': 'landscape', 'background': 'grid', 'margins': {'left': 10}}), allOf(contains('landscape'), contains('margins')));
    final note = (await repo.loadNote(id))!;
    expect(note.pageFormat, PageFormat.papers.firstWhere((f) => f.name == 'a5'));
    expect(note.landscape, isTrue);
    expect(note.marginLeft, closeTo(10 * PageFormat.a4Units / 210, 0.01));
    expect(await fails('set_up_pages', {'note_id': id, 'paper': 'huge'}), contains('"paper" has to be one of'));
    expect(await fails('set_up_pages', {'note_id': id}), contains('at least one'));
    expect(await fails('read_pdf', {'note_id': id}), contains('no PDF'));
    expect(await fails('search_pdf', {'note_id': id, 'query': 'x'}), contains('no PDF'));
  });

  test('tracked changes are accepted or rejected, and flashcards are kept for review', () async {
    final id = await make('Edit', 'Hello {++big ++}world {--now--}');
    expect(await ok('resolve_tracked_changes', {'note_id': id, 'accept': true}), contains('2 changes'));
    expect((await repo.loadNote(id))!.documentText, 'Hello big world ');
    expect(await fails('resolve_tracked_changes', {'note_id': id, 'accept': true}), contains('no tracked changes'));

    expect(await ok('add_flashcards', {'note_id': id, 'cards': [{'front': 'Q1', 'back': 'A1'}, {'front': 'Q2', 'back': 'A2'}]}), contains('2 new flashcards'));
    expect(await cards.count(source: id), 2);
    expect(await fails('add_flashcards', {'note_id': id, 'cards': [{'front': 'only'}]}), contains('"front" and a "back"'));
  });

  test('the locked and the missing are refused by every note tool', () async {
    expect(await fails('list_pages', {'note_id': 'nope'}), isNotEmpty);
    expect(await fails('draw_shape', {'note_id': 'nope', 'type': 'line', 'x': 0, 'y': 0, 'x2': 5, 'y2': 5}), isNotEmpty);
    expect(await fails('add_page', {'note_id': 'nope'}), isNotEmpty);
  });

  test('tasks are changed and deleted, reminders are set, listed and removed, the calendar is read and written', () async {
    final task = RegExp(r'Its id is (\S+)\.').firstMatch(await ok('add_task', {'title': 'Buy milk'}))!.group(1)!;
    await ok('update_task', {'id': task, 'title': 'Buy oat milk', 'due': '2030-01-02'});
    expect(await ok('list_tasks'), allOf(contains('Buy oat milk'), contains('2030-01-02')));
    await ok('update_task', {'id': task, 'due': ''});
    expect(await ok('list_tasks'), isNot(contains('2030-01-02')));
    expect(await fails('update_task', {'id': task}), contains('"title" or a "due"'));
    await ok('delete_task', {'id': task});
    expect(await fails('delete_task', {'id': task}), contains('no task'));

    final note = await make('About', 'x');
    expect(await ok('add_reminder', {'text': 'Look at it', 'at': '2099-01-01T09:30', 'repeat': 'weekly', 'note_id': note}), contains('reminder is set'));
    expect(await ok('add_reminder', {'text': 'Plain', 'at': '2099-02-02 10:00'}), contains('reminder is set'));
    final listed = await ok('list_reminders');
    expect(listed, allOf(contains('Look at it'), contains('2099-01-01T09:30, weekly'), contains('Plain')));
    expect((await ReminderRepository(db).all()).firstWhere((r) => r.title == 'Look at it').refId, note);
    expect(await fails('add_reminder', {'text': 'Late', 'at': '2001-01-01T09:30'}), contains('in the past'));
    expect(await fails('add_reminder', {'text': 'x', 'at': '2099-01-01T09:30', 'note_id': 'nope'}), isNotEmpty);
    final reminder = RegExp(r'id (\S+): "Plain"').firstMatch(listed)!.group(1)!;
    await ok('remove_reminder', {'id': reminder});
    expect(await ok('list_reminders'), isNot(contains('Plain')));
    expect(await fails('remove_reminder', {'id': reminder}), contains('no reminder'));

    expect(await ok('list_calendar_events', {'from': '2030-05-01', 'to': '2030-05-03'}), allOf(contains('2030-05-02T09:00 to 2030-05-02T11:00'), contains('"Exam" (Home)')));
    await ok('add_calendar_event', {'title': 'Dentist', 'start': '2030-06-01T14:00'});
    expect(made.single.$1.name, 'Home');
    expect(made.single.$2.title, 'Dentist');
    expect(made.single.$2.end, DateTime(2030, 6, 1, 15)); // (no end: an hour)
    expect(await fails('add_calendar_event', {'title': 'Bad', 'start': 'tomorrow'}), contains('times like'));
    expect(await fails('add_calendar_event', {'title': 'Bad', 'start': '2030-06-01T14:00', 'calendar': 'Work'}), contains('There is no calendar "Work"'));
    calendars = [];
    expect(await fails('add_calendar_event', {'title': 'Bad', 'start': '2030-06-01T14:00'}), contains('no calendar that events can be added to'));
  });
}
