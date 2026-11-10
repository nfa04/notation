import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/sync/task_sync.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// An in-memory CalDAV calendar that numbers its etags like a server.
class FakeRemote implements RemoteTodos {
  final Map<String, RemoteTodo> todos = {};
  int _version = 0;
  bool failOnCreate = false;
  bool sendsEtags = true;

  RemoteTodo _store(String uid, TodoFields f) {
    final etag = sendsEtags ? '"${++_version}"' : null;
    return todos[uid] = RemoteTodo(
        uid: uid, href: '/cal/$uid.ics', etag: etag, title: f.title, dueDate: f.dueDate, done: f.done);
  }

  /// Another client edits the task.
  void editElsewhere(String uid, {String? title, bool? done}) {
    final t = todos[uid]!;
    _store(uid, TodoFields(title ?? t.title, t.dueDate, done ?? t.done));
  }

  @override
  Future<List<RemoteTodo>> list() async => todos.values.toList();

  @override
  Future<RemoteTodo> create(String uid, TodoFields fields) async {
    if (failOnCreate) throw StateError('server unavailable');
    return _store(uid, fields);
  }

  @override
  Future<RemoteTodo> update(RemoteTodo existing, TodoFields fields) async => _store(existing.uid, fields);

  @override
  Future<void> delete(RemoteTodo existing) async => todos.remove(existing.uid);
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late TaskRepository local;
  late FakeRemote remote;
  setUp(() async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    await db.delete('tasks');
    local = TaskRepository(db);
    remote = FakeRemote();
  });

  Future<List<String>> titles() async => (await local.listTasks()).map((t) => t.title).toList()..sort();

  test('new tasks go up, remote tasks come down', () async {
    await local.createTask('local one', dueDate: DateTime(2026, 11, 3));
    remote.todos['r1'] = const RemoteTodo(
        uid: 'r1', href: '/cal/r1.ics', etag: '"x"', title: 'remote one', dueDate: null, done: true);

    final report = await syncTasks(local, remote);
    expect((report.uploaded, report.downloaded), (1, 1));
    expect(await titles(), ['local one', 'remote one']);
    expect(remote.todos.values.map((t) => t.title), containsAll(['local one', 'remote one']));
    expect(remote.todos.values.firstWhere((t) => t.title == 'local one').dueDate, DateTime(2026, 11, 3));
    expect((await local.listTasks()).firstWhere((t) => t.title == 'remote one').done, isTrue);

    // a second run changes nothing
    final again = await syncTasks(local, remote);
    expect(again.toString(), '0 uploaded, 0 downloaded, 0 removed');
  });

  test('edits travel in both directions', () async {
    final id = await local.createTask('plan');
    await syncTasks(local, remote);

    await local.setDone(id, true);
    expect((await syncTasks(local, remote)).uploaded, 1);
    expect(remote.todos[id]!.done, isTrue);

    remote.editElsewhere(id, title: 'plan v2');
    expect((await syncTasks(local, remote)).downloaded, 1);
    expect(await titles(), ['plan v2']);
  });

  test('deletions travel in both directions', () async {
    final a = await local.createTask('a');
    final b = await local.createTask('b');
    await syncTasks(local, remote);

    await local.deleteTask(a); // tombstone until synced
    expect(await titles(), ['b']);
    expect((await local.listForSync()).length, 2);
    await syncTasks(local, remote);
    expect(remote.todos.keys, [b]);
    expect((await local.listForSync()).length, 1);

    remote.todos.remove(b); // deleted elsewhere
    final report = await syncTasks(local, remote);
    expect(report.removed, 1);
    expect(await titles(), isEmpty);
  });

  test('a task never uploaded is removed outright', () async {
    final id = await local.createTask('oops');
    await local.deleteTask(id);
    expect(await local.listForSync(), isEmpty);
  });

  test('changed in both places: the server wins and it is reported', () async {
    final id = await local.createTask('shared');
    await syncTasks(local, remote);

    await local.updateTask(id, title: 'mine');
    remote.editElsewhere(id, title: 'theirs');
    final report = await syncTasks(local, remote);
    expect(report.conflicts, ['mine']);
    expect(await titles(), ['theirs']);
  });

  test('edited here but deleted on the server: uploaded again', () async {
    final id = await local.createTask('keep me');
    await syncTasks(local, remote);
    remote.todos.remove(id);
    await local.updateTask(id, title: 'keep me, edited');

    await syncTasks(local, remote);
    expect(remote.todos[id]!.title, 'keep me, edited');
    expect(await titles(), ['keep me, edited']);
  });

  test('a server without etags is compared by content', () async {
    remote.sendsEtags = false;
    final id = await local.createTask('no etags');
    await syncTasks(local, remote);
    expect((await syncTasks(local, remote)).toString(), '0 uploaded, 0 downloaded, 0 removed');

    remote.editElsewhere(id, title: 'changed');
    await syncTasks(local, remote);
    expect(await titles(), ['changed']);
  });

  test('one failing task does not stop the rest and is retried', () async {
    await local.createTask('one');
    remote.failOnCreate = true;
    final failed = await syncTasks(local, remote);
    expect(failed.errors, hasLength(1));
    expect(await titles(), ['one']); // still there, still pending

    remote.failOnCreate = false;
    expect((await syncTasks(local, remote)).uploaded, 1);
  });

  test('detaching from the server makes every task upload again', () async {
    await local.createTask('x');
    await syncTasks(local, remote);
    await local.detachFromServer();
    final fresh = FakeRemote();
    expect((await syncTasks(local, fresh)).uploaded, 1);
  });
}
