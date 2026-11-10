import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/task_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late TaskRepository repo;
  setUp(() async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    await db.delete('tasks'); // the in-memory database is shared between tests
    repo = TaskRepository(db);
  });

  test('create, order, complete, edit, delete', () async {
    final undated = await repo.createTask('undated');
    final later = await repo.createTask('later', dueDate: DateTime(2026, 11, 2));
    final sooner = await repo.createTask('sooner', dueDate: DateTime(2026, 10, 30));

    expect((await repo.listTasks()).map((t) => t.id), [sooner, later, undated]);
    expect((await repo.listTasks()).first.dueDate, DateTime(2026, 10, 30));

    await repo.setDone(sooner, true);
    // finished tasks move to the end
    expect((await repo.listTasks()).map((t) => t.id), [later, undated, sooner]);
    expect((await repo.listTasks()).last.done, isTrue);
    await repo.setDone(sooner, false);
    expect((await repo.listTasks()).first.done, isFalse);

    await repo.updateTask(undated, title: 'renamed', dueDate: DateTime(2026, 1, 5));
    final t = (await repo.listTasks()).firstWhere((t) => t.id == undated);
    expect([t.title, t.dueDate], ['renamed', DateTime(2026, 1, 5)]);
    await repo.updateTask(undated, title: 'renamed');
    expect((await repo.listTasks()).firstWhere((t) => t.id == undated).dueDate, isNull);

    await repo.deleteTask(later);
    expect((await repo.listTasks()).length, 2);
  });

  test('month grid starts on a Monday and covers the month', () {
    final grid = monthGrid(DateTime(2026, 10, 18));
    expect(grid, hasLength(42));
    expect(grid.first, DateTime(2026, 9, 28)); // 1 Oct 2026 is a Thursday
    expect(grid.first.weekday, DateTime.monday);
    expect(grid.contains(DateTime(2026, 10, 31)), isTrue);
    // a month starting on a Monday begins its own grid
    expect(monthGrid(DateTime(2026, 6, 1)).first, DateTime(2026, 6, 1));
  });
}
