import '../data/task_repository.dart';
import '../l10n/language.dart';

/// A to-do as the server has it.
class RemoteTodo {
  final String uid;
  final String href;
  final String? etag;
  final String title;
  final DateTime? dueDate;
  final bool done;

  /// The server library's own object, handed back for updates and deletes.
  final Object? handle;

  const RemoteTodo({
    required this.uid,
    required this.href,
    required this.etag,
    required this.title,
    required this.dueDate,
    required this.done,
    this.handle,
  });
}

/// The fields this app edits.
class TodoFields {
  final String title;
  final DateTime? dueDate;
  final bool done;

  const TodoFields(this.title, this.dueDate, this.done);
}

/// What the sync needs from a CalDAV calendar. The real one wraps the caldav
/// package ([CalDavRemoteTodos]); tests use a fake.
abstract class RemoteTodos {
  Future<List<RemoteTodo>> list();
  Future<RemoteTodo> create(String uid, TodoFields fields);
  Future<RemoteTodo> update(RemoteTodo existing, TodoFields fields);
  Future<void> delete(RemoteTodo existing);
}

/// What a sync of tasks with the server did.
class SyncReport {
  int uploaded = 0;
  int downloaded = 0;
  int removed = 0;

  /// Titles of tasks changed both here and on the server: the server's
  /// version was kept.
  final List<String> conflicts = [];
  final List<String> errors = [];

  bool get hasProblems => errors.isNotEmpty;

  @override
  String toString() => tr('{up} uploaded, {down} downloaded, {removed} removed', {'up': uploaded, 'down': downloaded, 'removed': removed}) +
      (conflicts.isEmpty ? '' : tr(', {n} conflicts', {'n': conflicts.length})) +
      (errors.isEmpty ? '' : tr(', {n} errors', {'n': errors.length}));
}

TodoFields _fields(Task t) => TodoFields(t.title, t.dueDate, t.done);

bool _same(RemoteTodo r, Task t) => r.title == t.title && r.dueDate == t.dueDate && r.done == t.done;

/// Two-way sync of the local tasks with one server calendar.
///
/// Per task: new here -> uploaded; changed here only -> uploaded; changed on
/// the server only -> downloaded; changed in both -> the server's version
/// wins (and is reported); deleted on one side -> deleted on the other, except
/// that a task edited here but deleted on the server is uploaded again, so
/// that no work is lost.
///
/// One failing task does not stop the others; it is reported in
/// [SyncReport.errors] and retried next time.
Future<SyncReport> syncTasks(TaskRepository local, RemoteTodos remote) async {
  final report = SyncReport();
  final remoteByUid = {for (final r in await remote.list()) r.uid: r};
  final handled = <String>{};

  Future<void> take(RemoteTodo r) => local.applyRemote(
        id: r.uid,
        title: r.title,
        dueDate: r.dueDate,
        done: r.done,
        href: r.href,
        etag: r.etag,
      );

  Future<void> upload(SyncTask t) async {
    final created = await remote.create(t.id, _fields(t));
    await local.markSynced(t.id, href: created.href, etag: created.etag);
    report.uploaded++;
  }

  for (final t in await local.listForSync()) {
    final r = remoteByUid[t.id];
    if (r != null) handled.add(t.id);
    try {
      if (t.deleted) {
        if (r != null) {
          await remote.delete(r);
          report.removed++;
        }
        await local.purge(t.id);
      } else if (t.remoteHref == null) {
        if (r != null) {
          await take(r); // the same uid is already there: it is the same task
          report.downloaded++;
        } else {
          await upload(t);
        }
      } else if (r == null) {
        if (t.dirty) {
          await upload(t);
        } else {
          await local.purge(t.id); // deleted on the server
          report.removed++;
        }
      } else {
        // without an etag from the server, compare the content instead
        final changedRemotely = r.etag != null ? r.etag != t.remoteEtag : !_same(r, t);
        if (changedRemotely) {
          if (t.dirty && !_same(r, t)) report.conflicts.add(t.title);
          await take(r);
          report.downloaded++;
        } else if (t.dirty) {
          final updated = await remote.update(r, _fields(t));
          await local.markSynced(t.id, href: updated.href, etag: updated.etag);
          report.uploaded++;
        }
      }
    } catch (e) {
      report.errors.add('${t.title}: $e');
    }
  }

  for (final r in remoteByUid.values) {
    if (handled.contains(r.uid)) continue;
    try {
      await take(r);
      report.downloaded++;
    } catch (e) {
      report.errors.add('${r.title}: $e');
    }
  }
  return report;
}
