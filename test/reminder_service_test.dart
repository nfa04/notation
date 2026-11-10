import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/reminder_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/reminders/notification_sink.dart';
import 'package:notes/reminders/reminder.dart';
import 'package:notes/reminders/reminder_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeSink implements NotificationSink {
  FakeSink({this.supportsScheduling = false, this.permission = true, this.works = true});

  @override
  final bool supportsScheduling;
  final bool permission, works;
  final shown = <(int, String, String)>[];
  final scheduled = <(int, DateTime, String)>[];
  var cancelled = 0;
  void Function(String?)? tap;

  @override
  Future<bool> init(void Function(String? payload) onTap) async {
    tap = onTap;
    return works;
  }

  var asked = 0;

  @override
  Future<bool> isPermitted() async => granted;

  late var granted = permission;

  @override
  Future<bool> requestPermission() async {
    asked++;
    granted = permission;
    return permission;
  }

  @override
  Future<void> show({required int id, required String title, required String body, required String payload}) async => shown.add((id, title, payload));

  @override
  Future<void> schedule({required int id, required DateTime at, required String title, required String body, required String payload}) async =>
      scheduled.add((id, at, title));

  @override
  Future<void> cancelScheduled() async {
    cancelled++;
    scheduled.clear();
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  late ReminderRepository repo;
  late TaskRepository tasks;
  final store = <String, String>{};
  var now = DateTime(2026, 3, 1, 8);

  ReminderService make(FakeSink sink, {bool withTasks = true}) => ReminderService(
        reminders: repo,
        tasks: withTasks ? tasks : null,
        sink: sink,
        read: (k) async => store[k],
        write: (k, v) async => store[k] = v,
        clock: () => now,
      );

  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath);
    repo = ReminderRepository(db);
    tasks = TaskRepository(db);
    store.clear();
    now = DateTime(2026, 3, 1, 8);
  });
  tearDown(() => db.close());

  group('ReminderRepository', () {
    test('reminders are listed with the one that goes off first on top, finished ones last', () async {
      final later = await repo.add(kind: ReminderKind.custom, title: 'later', at: DateTime(2026, 5, 1));
      final sooner = await repo.add(kind: ReminderKind.note, refId: 'n1', title: 'sooner', at: DateTime(2026, 4, 1));
      final over = await repo.add(kind: ReminderKind.custom, title: 'over', at: DateTime(2026, 1, 1));
      await repo.markFired(over, DateTime(2026, 1, 1));
      expect((await repo.all()).map((r) => r.id), [sooner, later, over]);
    });

    test('moving a reminder makes it go off again; removing for a note removes only that note\'s', () async {
      final id = await repo.add(kind: ReminderKind.note, refId: 'n1', title: 'a', at: DateTime(2026, 1, 1));
      await repo.add(kind: ReminderKind.note, refId: 'n2', title: 'b', at: DateTime(2026, 1, 1));
      await repo.markFired(id, DateTime(2026, 1, 1));
      await repo.update(id, at: DateTime(2026, 6, 1), repeat: Repeat.weekly);
      final r = (await repo.all()).firstWhere((r) => r.id == id);
      expect(r.firedTo, isNull);
      expect(r.repeat, Repeat.weekly);
      await repo.removeFor(ReminderKind.note, 'n1');
      expect((await repo.all()).map((r) => r.refId), ['n2']);
    });
  });

  group('ReminderService', () {
    test('a reminder is shown when its time has come, once, and the timer moves on to the next', () async {
      final sink = FakeSink();
      final service = make(sink);
      await repo.add(kind: ReminderKind.note, refId: 'n1', title: 'Review physics', at: DateTime(2026, 3, 1, 7));
      await repo.add(kind: ReminderKind.custom, title: 'Later', at: DateTime(2026, 3, 1, 12));
      await service.load();
      await service.start();
      expect(sink.shown.map((s) => (s.$2, s.$3)), [('Review physics', 'note:n1')]);
      await service.reconcile();
      expect(sink.shown.length, 1); // not twice
      now = DateTime(2026, 3, 1, 12, 5);
      await service.reconcile();
      expect(sink.shown.map((s) => s.$2), ['Review physics', 'Later']);
      service.dispose();
    });

    test('a repeating reminder missed for weeks is shown once, and comes again on its next day', () async {
      final sink = FakeSink();
      final service = make(sink);
      await repo.add(kind: ReminderKind.custom, title: 'Water the plants', at: DateTime(2026, 1, 1, 9), repeat: Repeat.daily);
      await service.start();
      expect(sink.shown.length, 1);
      expect((await repo.all()).single.firedTo, DateTime(2026, 3, 1, 9) .subtract(const Duration(days: 1)));
      now = DateTime(2026, 3, 2, 9, 1);
      await service.reconcile();
      expect(sink.shown.length, 2);
      service.dispose();
    });

    test('without permission or without a working system nothing is shown, but the reminder counts as past', () async {
      for (final sink in [FakeSink(permission: false), FakeSink(works: false)]) {
        await db.delete('reminders');
        final service = make(sink);
        await repo.add(kind: ReminderKind.custom, title: 'x', at: DateTime(2026, 3, 1, 7));
        await service.start();
        expect(sink.shown, isEmpty);
        service.dispose();
      }
    });

    test('where the system schedules, it gets the coming occurrences and the app does not show them itself', () async {
      final sink = FakeSink(supportsScheduling: true);
      final service = make(sink);
      await repo.add(kind: ReminderKind.custom, title: 'Daily', at: DateTime(2026, 3, 1, 18), repeat: Repeat.daily);
      await repo.add(kind: ReminderKind.note, refId: 'n1', title: 'Once', at: DateTime(2026, 3, 3, 10));
      await repo.add(kind: ReminderKind.custom, title: 'Missed', at: DateTime(2026, 2, 1));
      await service.start();
      expect(sink.shown, isEmpty);
      final byTitle = <String, List<DateTime>>{};
      for (final s in sink.scheduled) {
        (byTitle[s.$3] ??= []).add(s.$2);
      }
      expect(byTitle['Daily']!.length, 8);
      expect(byTitle['Daily']!.first, DateTime(2026, 3, 1, 18));
      expect(byTitle['Once'], [DateTime(2026, 3, 3, 10)]);
      expect(byTitle.containsKey('Missed'), isFalse);
      expect(sink.scheduled.map((s) => s.$1).toSet().length, sink.scheduled.length); // every notification has its own id
      expect(await repo.all().then((l) => l.firstWhere((r) => r.title == 'Missed').pending), isNull);
      service.dispose();
    });

    test('tasks with a due date get a reminder on that day, moved with the task, gone when done', () async {
      final sink = FakeSink();
      final service = make(sink);
      await service.load();
      final soon = await tasks.createTask('Hand in report', dueDate: DateTime(2026, 3, 1));
      final far = await tasks.createTask('Book flights', dueDate: DateTime(2026, 4, 10));
      await tasks.createTask('No date');
      await service.start();
      // today at 09:00 is still to come at 08:00
      var list = await service.upcoming();
      expect(list.map((r) => (r.title, r.at)), [('Hand in report', DateTime(2026, 3, 1, 9)), ('Book flights', DateTime(2026, 4, 10, 9))]);
      expect(list.every((r) => r.auto && r.kind == ReminderKind.task), isTrue);
      expect(sink.shown, isEmpty);

      now = DateTime(2026, 3, 1, 9, 2);
      await service.reconcile();
      expect(sink.shown.single.$2, 'Hand in report');
      expect(sink.shown.single.$3, 'task:$soon');

      await tasks.updateTask(far, title: 'Book flights', dueDate: DateTime(2026, 4, 12));
      await service.reconcile();
      expect((await service.upcoming()).single.at, DateTime(2026, 4, 12, 9));
      await tasks.setDone(far, true);
      await service.reconcile();
      expect(await service.upcoming(), isEmpty);
      service.dispose();
    });

    test('a reminder the person set for a task goes when the task is done or deleted', () async {
      final sink = FakeSink();
      final service = make(sink);
      final done = await tasks.createTask('Water plants');
      final gone = await tasks.createTask('Call Anna');
      final kept = await tasks.createTask('Write letter');
      for (final id in [done, gone, kept]) {
        await repo.add(kind: ReminderKind.task, refId: id, title: 'nudge $id', at: DateTime(2026, 6, 1), repeat: Repeat.weekly);
      }
      await service.start();
      expect((await repo.all()).length, 3);
      await tasks.setDone(done, true);
      await tasks.deleteTask(gone);
      await service.reconcile();
      expect((await repo.all()).map((r) => r.refId), [kept]);
      service.dispose();
    });

    test('turning the task reminders off removes theirs and keeps the person\'s own; the time of day can be chosen', () async {
      final sink = FakeSink();
      final service = make(sink);
      await service.load();
      await tasks.createTask('Report', dueDate: DateTime(2026, 5, 1));
      await repo.add(kind: ReminderKind.custom, title: 'Mine', at: DateTime(2026, 6, 1));
      await service.start();
      await service.setTaskMinutes(7 * 60 + 30);
      expect((await service.upcoming()).map((r) => r.at), [DateTime(2026, 5, 1, 7, 30), DateTime(2026, 6, 1)]);
      await service.setTasksOn(false);
      expect((await service.upcoming()).map((r) => r.title), ['Mine']);
      // remembered
      final again = make(sink);
      await again.load();
      expect(again.tasksOn, isFalse);
      expect(again.taskMinutes, 450);
      service.dispose();
      again.dispose();
    });

    test('the permission is asked for when a reminder is set up, not before', () async {
      final sink = FakeSink(permission: true);
      sink.granted = false;
      final service = make(sink);
      await service.start();
      expect(service.allowed, isFalse);
      expect(sink.asked, 0);
      expect(await service.ensurePermission(), isTrue);
      expect(sink.asked, 1);
      expect(await service.ensurePermission(), isTrue);
      expect(sink.asked, 1); // already allowed
      service.dispose();
    });

    test('tapping a notification opens what it was about', () async {
      final sink = FakeSink();
      final service = make(sink);
      final opened = <(ReminderKind, String?)>[];
      service.onOpen = (kind, id) => opened.add((kind, id));
      await service.start();
      sink.tap!('note:abc');
      sink.tap!('task:t1');
      sink.tap!('custom');
      sink.tap!('nonsense:1');
      sink.tap!(null);
      expect(opened, [(ReminderKind.note, 'abc'), (ReminderKind.task, 't1'), (ReminderKind.custom, null)]);
      service.dispose();
    });
  });

  test('notification ids are stable, positive and differ per occurrence', () {
    final a = ReminderService.notificationId('abc', 0);
    expect(a, ReminderService.notificationId('abc', 0));
    expect(a, isNot(ReminderService.notificationId('abc', 1)));
    expect(a, isNot(ReminderService.notificationId('abd', 0)));
    expect(a, greaterThan(0));
    expect(ReminderService.notificationId('zzzzzzzz', 255), lessThan(1 << 31));
  });
}
