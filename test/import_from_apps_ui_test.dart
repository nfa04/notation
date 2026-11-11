import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/dashboard_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('the dashboard offers to bring notes from Obsidian, Notion and GoodNotes', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    await tester.runAsync(() async => repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath)));
    await tester.pumpWidget(MaterialApp(home: DashboardView(repository: repo, onOpenNote: (_) {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('import-from-apps')));
    await tester.pumpAndSettle();
    for (final key in ['import-obsidian-folder', 'import-obsidian-zip', 'import-notion', 'import-goodnotes']) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    expect(find.textContaining('Export as PDF'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('import-notion')), findsNothing);
  });
}
