import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/screens/calendar_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('add a task for the selected day, complete it, delete it', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late TaskRepository repo;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('tasks');
      repo = TaskRepository(db);
    });
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(MaterialApp(home: CalendarView(repository: repo)));
    await settle();
    expect(find.text('Nothing planned.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Read chapter 3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle();
    // once as a chip in today's cell, once in the side panel
    expect(find.text('Read chapter 3'), findsNWidgets(2));
    var tasks = (await tester.runAsync(() => repo.listTasks()))!;
    expect(tasks.single.dueDate, dayOf(DateTime.now()));

    await tester.tap(find.byType(Checkbox));
    await settle();
    tasks = (await tester.runAsync(() => repo.listTasks()))!;
    expect(tasks.single.done, isTrue);

    await tester.tap(find.byTooltip('Delete'));
    await settle();
    expect(find.text('Read chapter 3'), findsNothing);
    expect(await tester.runAsync(() => repo.listTasks()), isEmpty);
  });
}
