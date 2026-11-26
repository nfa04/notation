import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/event_repository.dart';
import 'package:notes/data/reminder_repository.dart';
import 'package:notes/reminders/notification_sink.dart';
import 'package:notes/reminders/reminder.dart';
import 'package:notes/reminders/reminder_service.dart';
import 'package:notes/sync/local_events.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Sink implements NotificationSink {
  final shown = <String>[];
  @override
  bool get supportsScheduling => false;
  @override
  Future<bool> init(void Function(String? payload) onTap) async => true;
  @override
  Future<bool> isPermitted() async => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> show({required int id, required String title, required String body, required String payload}) async => shown.add(title);
  @override
  Future<void> schedule({required int id, required DateTime at, required String title, required String body, required String payload}) async {}
  @override
  Future<void> cancelScheduled() async {}
}

LocalEvent _weekly({List<int> alarms = const [], List<DateTime> skip = const []}) => LocalEvent(
      id: 'w1',
      calendarId: EventRepository.defaultCalendarId,
      title: 'Study group',
      start: DateTime(2026, 11, 2, 18), // a Monday
      end: DateTime(2026, 11, 2, 19, 30),
      rrule: 'FREQ=WEEKLY;BYDAY=MO',
      alarms: alarms,
      exdates: skip,
      location: 'Library',
      attendees: const ['ann@example.org'],
    );

void main() {
  setUpAll(AppDatabase.initFfi);

  test('a repeating event shows on every occurrence in the range, without a skipped one', () {
    final shown = expandLocalEvent(_weekly(skip: [DateTime(2026, 11, 16, 18)]), DateTime(2026, 11, 1), DateTime(2026, 12, 1), calendarName: 'Mine', key: 'local:x');
    expect([for (final e in shown) e.start.day], [2, 9, 23, 30]);
    expect(shown.first.end, DateTime(2026, 11, 2, 19, 30));
    expect(shown.first.repeats, isTrue);
    expect(shown.first.location, 'Library');
    expect(shown.first.attendees, ['ann@example.org']);
    expect(shown.first.uid, 'w1');
    expect(shown.first.rrule, 'FREQ=WEEKLY;BYDAY=MO');
  });

  test('an all-day event of several days shows from its first to its last day, with its end the last day', () {
    final trip = LocalEvent(id: 't', calendarId: 'c', title: 'Trip', start: DateTime(2026, 12, 5), end: DateTime(2026, 12, 8), allDay: true);
    final shown = expandLocalEvent(trip, DateTime(2026, 12, 1), DateTime(2026, 12, 31), calendarName: 'Mine', key: 'local:c').single;
    expect(shown.allDay, isTrue);
    expect(shown.start, DateTime(2026, 12, 5));
    expect(shown.end, DateTime(2026, 12, 7));
    expect(shown.notes, '', reason: 'known to be empty, so the dialog offers the field');
  });

  group('alarms', () {
    late Database db;
    late EventRepository events;
    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('local_events');
      await db.delete('local_calendars');
      await db.delete('reminders');
      events = EventRepository(db);
      await events.calendars();
    });
    tearDown(() => db.close());

    test('each alarm of each coming occurrence is a moment, before the start by its minutes', () async {
      await events.createEvent(_weekly(alarms: const [10, 1440]));
      final alarms = await localEventAlarms(events, DateTime(2026, 11, 1), DateTime(2026, 11, 20));
      alarms.sort((a, b) => a.at.compareTo(b.at));
      expect([for (final a in alarms) a.at], [
        DateTime(2026, 11, 1, 18), // a day before the 2nd
        DateTime(2026, 11, 2, 17, 50),
        DateTime(2026, 11, 8, 18),
        DateTime(2026, 11, 9, 17, 50),
        DateTime(2026, 11, 15, 18),
        DateTime(2026, 11, 16, 17, 50),
      ]);
      expect(alarms.every((a) => a.title == 'Study group'), isTrue);
      expect({for (final a in alarms) a.key}.length, alarms.length);
    });

    test('the reminder service makes a reminder per alarm, announces it, and drops it when the alarm or the event goes', () async {
      final id = await events.createEvent(_weekly(alarms: const [10]));
      var now = DateTime(2026, 11, 2, 17, 45);
      final sink = _Sink();
      final store = <String, String>{};
      final service = ReminderService(reminders: ReminderRepository(db), sink: sink, read: (k) async => store[k], write: (k, v) async => store[k] = v, clock: () => now)
        ..eventAlarms = ((from, to) => localEventAlarms(events, from, to));
      await service.load();
      await service.start();
      final all = await ReminderRepository(db).all();
      expect(all.where((r) => r.kind == ReminderKind.event).length, greaterThan(1));
      expect(sink.shown, isEmpty);
      now = DateTime(2026, 11, 2, 17, 55);
      await service.reconcile();
      expect(sink.shown, ['Study group'], reason: 'the 17:50 alarm, announced once it is past');
      await service.reconcile();
      expect(sink.shown.length, 1);

      // the alarm is taken out: the reminders go
      await events.updateEvent((await events.event(id))!.copyWith(alarms: const []));
      await service.reconcile();
      expect((await ReminderRepository(db).all()).where((r) => r.kind == ReminderKind.event), isEmpty);

      await events.updateEvent((await events.event(id))!.copyWith(alarms: const [30]));
      await service.reconcile();
      expect((await ReminderRepository(db).all()).where((r) => r.kind == ReminderKind.event), isNotEmpty);
      await events.deleteEvent(id);
      await service.reconcile();
      expect((await ReminderRepository(db).all()).where((r) => r.kind == ReminderKind.event), isEmpty);
      service.dispose();
    });
  });
}
