import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/screens/calendar_view.dart';
import 'package:notes/screens/dashboard_view.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/sync/caldav_remote.dart' show NewEvent;
import 'package:notes/sync/device_calendar_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A phone calendar with events that can be deleted.
class _Phone implements PhoneCalendarApi {
  final events_ = <PhoneEvent>[];
  final deleted = <String>[];

  @override
  Future<bool> requestAccess() async => true;
  @override
  Future<bool> hasAccess() async => true;
  @override
  Future<List<PhoneCalendar>> calendars() async => const [PhoneCalendar(id: 'p', name: 'Private')];
  @override
  Future<List<PhoneEvent>> events(DateTime from, DateTime to, List<String> ids) async => [...events_];
  @override
  Future<String> createEvent(String calendarId, NewEvent event) async => 'new';
  final updated = <String, NewEvent>{};
  @override
  Future<void> updateEvent(String eventId, NewEvent event) async => updated[eventId] = event;

  @override
  Future<void> deleteEvent(String eventId) async {
    deleted.add(eventId);
    events_.removeWhere((e) => e.id == eventId);
  }

  @override
  Future<String> createCalendar(String name, {String? color}) async => 'c';
}

void main() {
  setUpAll(AppDatabase.initFfi);

  group('untitled notes', () {
    test('a new note keeps an empty title, shown as "Untitled" in the language of the app', () async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      final repo = NoteRepository(db);
      final id = await repo.createNote();
      expect((await repo.noteInfo(id))!.title, '');
      expect(isUntitled(''), isTrue);
      expect(isUntitled('Untitled Note'), isTrue, reason: 'the English title older notes were given');
      expect(isUntitled('Lecture 3'), isFalse);
    });
  });

  group('calendar events', () {
    Future<_Phone> open(WidgetTester tester, List<PhoneEvent> events) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final phone = _Phone()..events_.addAll(events);
      late TaskRepository tasks;
      late DeviceCalendarService device;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        await db.delete('tasks');
        await db.delete('settings');
        tasks = TaskRepository(db);
        device = DeviceCalendarService(SettingsRepository(db), api: phone);
        await device.setSelected({'p'});
      });
      await tester.pumpWidget(MaterialApp(home: CalendarView(repository: tasks, device: device)));
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      return phone;
    }

    final today = DateTime.now();
    PhoneEvent event(String id, {bool repeats = false}) => PhoneEvent(
        title: 'Dentist $id',
        start: DateTime(today.year, today.month, today.day, 9),
        end: DateTime(today.year, today.month, today.day, 10),
        allDay: false,
        calendarId: 'p',
        repeats: repeats,
        id: id);

    testWidgets('an event made in a calendar can be opened and deleted, after a second question', (tester) async {
      final phone = await open(tester, [event('a')]);
      await tester.tap(find.byKey(const ValueKey('event-a')));
      await tester.pumpAndSettle();
      expect(find.text('09:00 - 10:00'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('event-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-delete-sure')));
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(phone.deleted, ['a']);
      expect(find.byKey(const ValueKey('event-a')), findsNothing);
    });

    testWidgets('a repeating event is not deleted from here: the calendar app does that', (tester) async {
      final phone = await open(tester, [event('r', repeats: true)]);
      await tester.tap(find.byKey(const ValueKey('event-r')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-delete')), findsNothing);
      expect(find.textContaining('This event repeats'), findsOneWidget);
      expect(phone.deleted, isEmpty);
    });
  });

  group('the dashboard greets a first visit', () {
    Future<void> show(WidgetTester tester, {required bool more}) async {
      late NoteRepository repo;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        await db.delete('notes');
        repo = NoteRepository(db);
        final welcome = await repo.createNote(title: 'Welcome to Notation');
        await repo.settings.set(welcomeNoteKey, welcome);
        if (more) await repo.createNote(title: 'My own');
      });
      await tester.pumpWidget(MaterialApp(home: DashboardView(repository: repo, onOpenNote: (_) {})));
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    testWidgets('with only the welcome note: "Welcome", not "Welcome back"', (tester) async {
      await show(tester, more: false);
      expect(find.text('Welcome'), findsOneWidget);
      expect(find.text('Welcome back'), findsNothing);
    });

    testWidgets('with notes of their own: "Welcome back"', (tester) async {
      await show(tester, more: true);
      expect(find.text('Welcome back'), findsOneWidget);
    });
  });

  group('the note says whether it is saved', () {
    testWidgets('"Saving..." after a change, "Saved" once it is written', (tester) async {
      tester.view.physicalSize = const Size(1800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late NoteRepository repo;
      late String id;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        repo = NoteRepository(db);
        id = await repo.createNote(title: 'Keep me');
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      Semantics label() => tester.widget<Semantics>(find.byKey(const ValueKey('save-state')));
      await tester.pump(const Duration(seconds: 1)); // (opening may ask for a save that finds nothing new)
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump();
      expect(label().properties.label, 'Saved');

      await tester.enterText(find.widgetWithText(TextField, 'Keep me'), 'Kept');
      await tester.pump(const Duration(milliseconds: 850)); // the timer: the write starts
      expect(label().properties.label, 'Saving...');

      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 900)); // the timer of the save (and of one that a change after it started)
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
        await tester.pump();
      }
      expect(label().properties.label, 'Saved');
      expect((await tester.runAsync(() => repo.noteInfo(id)))!.title, 'Kept');
    });
  });
}
