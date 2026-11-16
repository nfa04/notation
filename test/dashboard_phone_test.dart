import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/dashboard_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  Future<NoteRepository> open(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      for (final n in await repo.listNotes()) {
        await repo.deleteNote(n.id);
      }
      for (var i = 0; i < 6; i++) {
        await repo.createNote(title: 'Note $i');
      }
    });
    await tester.pumpWidget(MaterialApp(home: DashboardView(repository: repo, onOpenNote: (_) {}, onJoinSession: () {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('on a phone the actions are in a menu, two cards sit side by side and one button is at the foot', (tester) async {
    await open(tester, const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('select-notes')), findsNothing, reason: 'it is in the menu');
    expect(find.byKey(const ValueKey('dashboard-more')), findsOneWidget);
    expect(find.byKey(const ValueKey('new-from-pdf')), findsNothing, reason: 'the small round buttons are in the menu too');
    expect(find.byType(FloatingActionButton), findsOneWidget);
    // the bar's buttons stay clear of the menu button the shell puts over the top left corner (56 px)
    expect(tester.getTopLeft(find.byKey(const ValueKey('dashboard-more'))).dx, greaterThan(56));
    final cards = find.byType(Card);
    expect(tester.getTopLeft(cards.at(0)).dy, tester.getTopLeft(cards.at(1)).dy, reason: 'two cards in a row');
    expect(tester.getSize(cards.at(0)).width, lessThan(200));

    await tester.tap(find.byKey(const ValueKey('dashboard-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu-select-notes')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-join-session')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-new-from-pdf')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('menu-select-notes')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dashboard-more')), findsNothing, reason: 'selecting notes has its own bar');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('on a wide screen the buttons are in the bar as before', (tester) async {
    await open(tester, const Size(1200, 900));
    expect(find.byKey(const ValueKey('dashboard-more')), findsNothing);
    expect(find.byKey(const ValueKey('select-notes')), findsOneWidget);
    expect(find.byKey(const ValueKey('join-session')), findsOneWidget);
    expect(find.byKey(const ValueKey('new-from-pdf')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
