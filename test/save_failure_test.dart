import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A repository whose saves fail while [failures] is above nothing.
class _FailingRepository extends NoteRepository {
  _FailingRepository(super.db);

  int failures = 0;
  int tried = 0;

  @override
  Future<void> saveNote(NoteData n) async {
    tried++;
    if (failures > 0) {
      failures--;
      throw StateError('no room left on the device');
    }
    return super.saveNote(n);
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late _FailingRepository repo;
  late String id;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      repo = _FailingRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  Future<void> rest(WidgetTester tester, Duration d) async {
    await tester.pump(d);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
  }

  Future<String> titleInDatabase(WidgetTester tester) async => (await tester.runAsync(() async => (await repo.loadNote(id))!.title))!;

  testWidgets('a save that fails is told to the person once, tried again by itself, and the person is told when it went through', (tester) async {
    await open(tester);
    repo.failures = 2;
    final tried = repo.tried;
    await tester.enterText(find.byType(TextField).first, 'Lecture notes');
    await rest(tester, const Duration(milliseconds: 900));
    expect(repo.tried, tried + 1);
    expect(find.textContaining('could not be saved'), findsOneWidget);
    expect(find.textContaining('no room left on the device'), findsOneWidget);
    expect(find.text('Try now'), findsOneWidget);
    expect(await titleInDatabase(tester), isNot('Lecture notes'));

    // nothing is changed meanwhile: it tries again by itself, after 3 seconds (this one fails too), and after 10 more
    await rest(tester, const Duration(seconds: 3));
    expect(repo.tried, tried + 2);
    expect(find.textContaining('could not be saved'), findsOneWidget, reason: 'told once, not at every try');
    await rest(tester, const Duration(seconds: 10));
    expect(repo.tried, tried + 3);
    expect(await titleInDatabase(tester), 'Lecture notes');
    await tester.pump(const Duration(seconds: 1)); // (the old message leaves, the new one comes)
    expect(find.textContaining('could not be saved'), findsNothing);
    expect(find.text('The note is saved again'), findsOneWidget);

    // and it is done: no more tries
    await rest(tester, const Duration(seconds: 60));
    expect(repo.tried, tried + 3);
  });

  testWidgets('"Try now" saves at once', (tester) async {
    await open(tester);
    repo.failures = 1;
    await tester.enterText(find.byType(TextField).first, 'Exam');
    await rest(tester, const Duration(milliseconds: 900));
    expect(find.text('Try now'), findsOneWidget);
    // (the snack bar lies over the toolbar of the editor in a test: the button is pressed, not hit)
    tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed();
    await rest(tester, const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    expect(await titleInDatabase(tester), 'Exam');
    expect(find.text('The note is saved again'), findsOneWidget);
  });

  testWidgets('a save that goes through says nothing', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField).first, 'Plain');
    await rest(tester, const Duration(milliseconds: 900));
    expect(await titleInDatabase(tester), 'Plain');
    expect(find.byType(SnackBar), findsNothing);
  });
}
