import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/sync/caldav_remote.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:notes/sync/task_calendar_mirror.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'device_calendar_service_test.dart' show FakePhone;

void main() {
  setUpAll(AppDatabase.initFfi);

  late TaskRepository tasks;
  late FakePhone phone;
  late DeviceCalendarService device;
  late TaskCalendarMirror mirror;

  setUp(() async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    await db.delete('tasks');
    await db.delete('settings');
    await db.delete('task_events');
    final settings = SettingsRepository(db);
    tasks = TaskRepository(db);
    phone = FakePhone();
    device = DeviceCalendarService(settings, api: phone);
    await device.setSelected({'p'});
    mirror = TaskCalendarMirror(settings, tasks, device: device);
    await mirror.load();
  });

  test('tasks made by an automation go on the chosen calendar, and leave it when done', () async {
    final auto = await tasks.createTask('Hand in the report', dueDate: DateTime(2026, 11, 5), auto: true);
    await tasks.createTask('Typed in by hand', dueDate: DateTime(2026, 11, 6));
    await tasks.createTask('No day', auto: true);

    await mirror.setTarget('phone:p');
    expect(phone.created.values.map((e) => e.title), ['Hand in the report']);
    final event = phone.created.values.single;
    expect(event.allDay, isTrue);
    expect(event.start, DateTime(2026, 11, 5));
    expect(phone.created.keys.single, endsWith('@p'));

    await mirror.run();
    expect(phone.created, hasLength(1)); // nothing is put twice

    await tasks.updateTask(auto, title: 'Hand in the final report', dueDate: DateTime(2026, 11, 5));
    await mirror.run();
    expect(phone.created.values.map((e) => e.title), ['Hand in the final report']);

    await tasks.setDone(auto, true);
    await mirror.run();
    expect(phone.created, isEmpty);
  });

  test('all tasks can be put there, and none once the calendar is switched off', () async {
    await tasks.createTask('Typed in by hand', dueDate: DateTime(2026, 11, 6));
    await mirror.setTarget('phone:p');
    expect(phone.created, isEmpty);
    await mirror.setOnlyAuto(false);
    expect(phone.created, hasLength(1));
    await mirror.setTarget(null);
    expect(phone.created, isEmpty);
    expect(await tasks.taskEvents(), isEmpty);
  });

  test('events the server answered with are kept, and come back the same', () async {
    final e = DayEvent(title: 'Exam', start: DateTime(2026, 11, 9, 10), end: DateTime(2026, 11, 9, 12), allDay: false, calendarName: 'Uni', color: '#ff0000', repeats: true, calendarKey: '/cal/uni/', uid: 'u1');
    final back = DayEvent.fromJson(e.toJson());
    expect((back.title, back.start, back.end, back.allDay, back.calendarName, back.color, back.repeats, back.calendarKey, back.uid), (e.title, e.start, e.end, e.allDay, e.calendarName, e.color, e.repeats, e.calendarKey, e.uid));
    expect(await tasks.cachedEvents('s', 'r'), isNull);
    await tasks.cacheEvents('s', 'r', '[]');
    expect((await tasks.cachedEvents('s', 'r'))!.payload, '[]');
    await tasks.clearEventCache();
    expect(await tasks.cachedEvents('s', 'r'), isNull);
  });
}
