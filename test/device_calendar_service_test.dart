import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/sync/caldav_remote.dart' show NewEvent;
import 'package:notes/sync/device_calendar_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakePhone implements PhoneCalendarApi {
  bool allowed = true;
  int eventCalls = 0;
  List<String> lastIds = [];
  final events_ = <PhoneEvent>[];

  @override
  Future<bool> requestAccess() async => allowed;
  @override
  Future<bool> hasAccess() async => allowed;
  @override
  Future<List<PhoneCalendar>> calendars() async => const [
        PhoneCalendar(id: 'p', name: 'Private', account: 'me@gmail.com', color: '#ff0000'),
        PhoneCalendar(id: 'w', name: 'Work'),
      ];
  @override
  Future<List<PhoneEvent>> events(DateTime from, DateTime to, List<String> ids) async {
    eventCalls++;
    lastIds = ids;
    return events_;
  }

  final created = <String, NewEvent>{};
  @override
  Future<String> createEvent(String calendarId, NewEvent event) async {
    final id = 'e${created.length + 1}@$calendarId';
    created[id] = event;
    return id;
  }

  @override
  Future<void> deleteEvent(String eventId) async => created.remove(eventId);
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late SettingsRepository settings;
  late FakePhone phone;
  late DeviceCalendarService service;
  setUp(() async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    await db.delete('settings');
    settings = SettingsRepository(db);
    phone = FakePhone();
    service = DeviceCalendarService(settings, api: phone);
  });

  final from = DateTime(2026, 11, 1), to = DateTime(2026, 12, 13);

  test('nothing is read until calendars are selected', () async {
    phone.events_.add(PhoneEvent(
        title: 'x', start: DateTime(2026, 11, 5, 10), end: DateTime(2026, 11, 5, 11), allDay: false, calendarId: 'p'));
    expect(await service.events(from, to), isEmpty);
    expect(phone.eventCalls, 0);
  });

  test('selection is saved and used, results are cached until it changes', () async {
    phone.events_.add(PhoneEvent(
        title: 'Dentist', start: DateTime(2026, 11, 5, 10), end: DateTime(2026, 11, 5, 11), allDay: false, calendarId: 'p'));
    expect((await service.requestCalendars())!.map((c) => c.name), ['Private', 'Work']);
    await service.setSelected({'p'});

    final events = await service.events(from, to);
    expect(phone.lastIds, ['p']);
    expect((events.single.title, events.single.calendarName, events.single.color), ('Dentist', 'Private', '#ff0000'));
    await service.events(from, to);
    expect(phone.eventCalls, 1);

    await service.setSelected({'p', 'w'});
    await service.events(from, to);
    expect(phone.eventCalls, 2);

    // a new service (app restart) remembers the choice
    final restarted = DeviceCalendarService(settings, api: phone);
    await restarted.load();
    expect(restarted.selected, {'p', 'w'});
  });

  test('all-day events: the plugin end is exclusive, the view wants the last day', () async {
    phone.events_.addAll([
      PhoneEvent(title: 'one day', start: DateTime(2026, 11, 5), end: DateTime(2026, 11, 6), allDay: true, calendarId: 'p'),
      PhoneEvent(title: 'trip', start: DateTime(2026, 11, 10), end: DateTime(2026, 11, 13), allDay: true, calendarId: 'p'),
    ]);
    await service.setSelected({'p'});
    final events = await service.events(from, to);

    final oneDay = events.firstWhere((e) => e.title == 'one day');
    expect(oneDay.end, isNull);
    expect(oneDay.occursOn(DateTime(2026, 11, 5)), isTrue);
    expect(oneDay.occursOn(DateTime(2026, 11, 6)), isFalse);

    final trip = events.firstWhere((e) => e.title == 'trip');
    expect(trip.end, DateTime(2026, 11, 12));
    expect([for (var d = 9; d <= 13; d++) trip.occursOn(DateTime(2026, 11, d))], [false, true, true, true, false]);
  });

  test('a refused permission gives no events instead of an error', () async {
    await service.setSelected({'p'});
    phone.allowed = false;
    expect(await service.events(from, to), isEmpty);
    expect(await service.requestCalendars(), isNull);
  });

  test('platforms without a calendar database do nothing', () async {
    final none = DeviceCalendarService(settings);
    expect(none.isSupported, isFalse);
    expect(await none.requestCalendars(), isNull);
    expect(await none.events(from, to), isEmpty);
  });
}
