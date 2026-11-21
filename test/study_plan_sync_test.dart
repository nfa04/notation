import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/devicesync/sync_library.dart' show syncedSetting;
import 'package:notes/review/study_calendar.dart';
import 'package:notes/review/study_material.dart';
import 'package:notes/review/study_planner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_study_calendar.dart';

/// One device: its own database (settings, to-dos, cards), calendars and planner.
class _Device {
  final Database db;
  final SettingsRepository settings;
  final TaskRepository tasks;
  final FakeStudyCalendar calendar;
  final StudyPlanner planner;

  _Device._(this.db, this.settings, this.tasks, this.calendar, this.planner);

  static Future<_Device> open(String path, FakeStudyCalendar calendar, DateTime Function() now) async {
    final db = await AppDatabase.open(path: path);
    final settings = SettingsRepository(db);
    final tasks = TaskRepository(db);
    final planner = StudyPlanner(settings, CardRepository(db), tasks, calendar: calendar, readNote: (id) async => _shape(id), now: now);
    await planner.load();
    return _Device._(db, settings, tasks, calendar, planner);
  }

  StudyPlanEntry get plan => planner.plans.single;

  /// The to-dos of study sessions here that are still to do, by id.
  Future<Map<String, Task>> openTasks() async => {for (final t in await tasks.listTasks()) if (!t.done) t.id: t};

  Future<void> close() async {
    planner.dispose();
    await db.close();
  }
}

final _words = List.filled(1200, 'word').join(' ');

NoteShape _shape(String id) => NoteShape(
      noteId: id,
      title: 'Biology',
      pdfPages: 40,
      pdfOutline: const [(title: 'Cells', level: 1, page: 0), (title: 'Genetics', level: 1, page: 10), (title: 'Evolution', level: 1, page: 25)],
      documentText: '# Summary\n$_words',
    );

/// What a sync does with the plans: the newer value of each plan's key replaces the other device's, which then takes it.
Future<void> _send(_Device from, _Device to) async {
  final values = await from.settings.allWhere(syncedSetting);
  for (final e in values.entries) {
    if (!e.key.startsWith(StudyPlanner.planPrefix)) continue;
    final there = (await to.settings.allWhere((k) => k == e.key))[e.key];
    if (there != null && (there.value == e.value.value || there.changedAt > e.value.changedAt)) continue;
    await to.settings.setFromSync(e.key, e.value.value, e.value.changedAt);
    await to.planner.takeSynced(e.key.substring(StudyPlanner.planPrefix.length));
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);
  late Directory dir;
  late FakeStudyCalendar server;
  late _Device a, b;
  var now = DateTime(2026, 6, 1, 8);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('study_sync');
    now = DateTime(2026, 6, 1, 8);
    server = FakeStudyCalendar();
    a = await _Device.open('${dir.path}/a.db', server, () => now);
    b = await _Device.open('${dir.path}/b.db', server, () => now);
  });
  tearDown(() async {
    await a.close();
    await b.close();
    await dir.delete(recursive: true);
  });

  Future<StudyPlanEntry> approve(_Device d, StudyPlanEntry e) async => d.planner.approve(await d.planner.propose(e));

  Future<StudyPlanEntry> biology(_Device d, CalendarTarget target) async =>
      d.planner.draft(name: 'Biology', exam: DateTime(2026, 6, 12)).copyWith(units: await d.planner.unitsOf('n1'), cardSources: () => const {}, target: target);

  test('each plan syncs under its own key; what is only this device\'s does not', () {
    expect(syncedSetting('${StudyPlanner.planPrefix}123'), isTrue);
    for (final k in ['study_plans', 'study_session_running', 'study_tasks_here', 'study_device']) {
      expect(syncedSetting(k), isFalse, reason: k);
    }
  });

  test('a plan made on one device is on the other: the same to-dos there, and its events are not written twice', () async {
    await approve(a, await biology(a, const CalendarTarget.calendar('srv/study')));
    final written = server.written.length;
    expect(written, a.plan.sessions.length);
    await _send(a, b);
    expect(b.plan.toJson(), a.plan.toJson());
    // the to-dos are made there under the same ids (one to-do on a server the to-dos sync with)
    final mine = await a.openTasks(), theirs = await b.openTasks();
    expect(theirs.keys.toSet(), mine.keys.toSet());
    expect([for (final id in mine.keys) theirs[id]!.title], [for (final t in mine.values) t.title]);
    await b.planner.refresh(lookAtCalendar: true);
    expect(server.written.length, written, reason: 'the events are there already');
    expect(b.planner.attentionOf(b.plan.id).any, isFalse);
    expect(b.planner.writesCalendarOf(b.plan), isTrue, reason: 'a server calendar is reached from both');
  });

  test('what is done on either device counts on both, also when both happen at the same time', () async {
    await approve(a, await biology(a, const CalendarTarget.calendar('srv/study')));
    await _send(a, b);
    final first = a.plan.sessions[0], second = a.plan.sessions[1];
    // the first session's to-do is ticked off on b, and the second session is studied on a, before either has heard of the other
    await b.tasks.setDone(first.taskId!, true);
    await b.planner.refresh();
    expect(b.plan.sessions[0].credited, isTrue);
    await a.planner.begin(a.plan.id, second.key);
    await a.planner.finish(a.plan.id, second.key, SessionReport(spent: second.session.minutes, done: {for (var i = 0; i < second.session.items.length; i++) i}));
    // (a's version is newer: b's is not taken; b puts a's together with its own and sends that back)
    await _send(b, a);
    expect(a.plan.sessions[0].credited, isFalse);
    await _send(a, b);
    expect([b.plan.sessions[0].credited, b.plan.sessions[1].credited], [true, true], reason: 'b\'s tick and a\'s report');
    await _send(b, a);
    expect([a.plan.sessions[0].credited, a.plan.sessions[1].credited], [true, true]);
    expect(a.plan.sessions[1].report, isNotNull);
    expect((await a.tasks.listTasks()).firstWhere((t) => t.id == first.taskId).done, isTrue, reason: 'ticked off here too');
    expect(b.plan.toJson(), a.plan.toJson());
    expect((await b.tasks.listTasks()).firstWhere((t) => t.id == second.taskId).done, isTrue);
    final learned = a.plan.progress.values.fold<double>(0, (n, p) => n + p.learned);
    expect(learned, greaterThan(0));
    // nothing more to send: the two agree
    final kept = await a.settings.get('${StudyPlanner.planPrefix}${a.plan.id}');
    await _send(b, a);
    expect(await a.settings.get('${StudyPlanner.planPrefix}${a.plan.id}'), kept);
  });

  test('a phone calendar is only written and read on its phone; a plan changed on another device is put there by the phone', () async {
    final phoneB = FakeStudyCalendar();
    await b.close();
    b = await _Device.open('${dir.path}/b2.db', phoneB, () => now);
    await approve(a, await biology(a, const CalendarTarget.makeAt(CalendarPlace.phone)));
    expect(a.plan.target.key, 'phone:study');
    expect(a.plan.calendarDevice, isNotNull);
    await _send(a, b);
    expect(b.planner.writesCalendarOf(b.plan), isFalse);
    // b's own calendars do not have these events: that must not read as "deleted in the calendar app"
    await b.planner.refresh(lookAtCalendar: true);
    expect(b.plan.sessions.any((s) => s.gone), isFalse);
    // the hours are changed on b and the new plan approved there: nothing is written to b's calendars
    final old = {for (final s in a.plan.sessions) s.eventId!};
    final changed = await approve(b, b.plan.copyWith(windowStart: 17 * 60, windowEnd: 21 * 60));
    expect(phoneB.written, isEmpty);
    expect(changed.calendarDevice, a.plan.calendarDevice, reason: 'the calendar is still the one on a');
    final moved = [for (final s in changed.sessions) if (s.eventId == null) s];
    expect(moved, isNotEmpty);
    expect({for (final x in changed.strays) x.id}, containsAll(old.where((id) => !changed.sessions.any((s) => s.eventId == id))));
    // on a, the events of the old sessions go and those of the new ones are written
    await _send(b, a);
    await a.planner.refresh(lookAtCalendar: true);
    expect(a.plan.strays, isEmpty);
    expect(a.plan.sessions.where((s) => s.session.start.isAfter(now)).every((s) => s.eventId != null), isTrue);
    expect(server.written.keys.toSet(), {for (final s in a.plan.sessions) s.eventId!});
    expect(server.written.values.every((w) => w.$1 == 'phone:study'), isTrue);
    // and each device has a to-do for each session, nothing else
    final ids = {for (final s in a.plan.sessions) s.taskId!};
    expect((await a.openTasks()).keys.toSet(), ids);
    await _send(a, b);
    expect((await b.openTasks()).keys.toSet(), ids);
    expect(b.plan.sessions.every((s) => s.eventId != null), isTrue);
  });

  test('a plan deleted on one device is deleted on the other, with its to-dos, and its events by the phone they are on', () async {
    final phoneB = FakeStudyCalendar();
    await b.close();
    b = await _Device.open('${dir.path}/b2.db', phoneB, () => now);
    await approve(a, await biology(a, const CalendarTarget.makeAt(CalendarPlace.phone)));
    await _send(a, b);
    expect(await b.openTasks(), isNotEmpty);
    await b.planner.remove(b.plan.id);
    expect(await b.openTasks(), isEmpty);
    await _send(b, a);
    expect(a.planner.plans, isEmpty);
    expect(await a.openTasks(), isEmpty);
    await a.planner.refresh(lookAtCalendar: true);
    expect(server.written, isEmpty);
    // the plan stays deleted after a restart
    await a.close();
    a = await _Device.open('${dir.path}/a.db', server, () => now);
    expect(a.planner.plans, isEmpty);
  });

  test('approved on both devices at once: one approval stays, and the events and to-dos of the other go', () async {
    await approve(a, await biology(a, const CalendarTarget.calendar('srv/study')));
    await _send(a, b);
    await approve(a, a.plan.copyWith(windowStart: 17 * 60, windowEnd: 21 * 60));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await approve(b, b.plan.copyWith(windowStart: 14 * 60, windowEnd: 18 * 60));
    await _send(b, a);
    await a.planner.refresh(lookAtCalendar: true);
    await _send(a, b);
    await b.planner.refresh(lookAtCalendar: true);
    expect(a.plan.toJson(), b.plan.toJson());
    expect(a.plan.windowStart, 14 * 60, reason: 'b approved last');
    expect(server.written.keys.toSet(), {for (final s in a.plan.sessions) if (s.eventId != null) s.eventId!}, reason: 'no event of a\'s approval is left');
    final ids = {for (final s in a.plan.sessions) s.taskId!};
    expect((await a.openTasks()).keys.toSet(), ids);
    expect((await b.openTasks()).keys.toSet(), ids);
  });

  test('plans kept before plans synced get a key each; their to-dos count as made here', () async {
    await approve(a, await biology(a, const CalendarTarget.makeAt(CalendarPlace.phone)));
    final id = a.plan.id;
    final json = (a.plan.toJson()..remove('calDevice'));
    await a.close();
    final db = await AppDatabase.open(path: '${dir.path}/a.db');
    await db.delete('settings', where: 'key LIKE ?', whereArgs: ['study_%']);
    await SettingsRepository(db).set('study_plans', jsonEncode([json]));
    await db.close();
    a = await _Device.open('${dir.path}/a.db', server, () => now);
    expect(a.plan.id, id);
    expect(await a.settings.get('study_plans'), isNull);
    expect(await a.settings.get('${StudyPlanner.planPrefix}$id'), isNotNull);
    expect(a.plan.calendarDevice, isNotNull, reason: 'its phone calendar is this device\'s');
    expect(a.planner.writesCalendarOf(a.plan), isTrue);
    // a to-do deleted here is not made again: the plan says it was dropped
    final gone = a.plan.sessions.first.taskId!;
    await a.tasks.deleteTask(gone);
    await a.planner.refresh();
    expect((await a.openTasks()).containsKey(gone), isFalse);
    expect(a.planner.attentionOf(id).dropped, 1);
  });
}
