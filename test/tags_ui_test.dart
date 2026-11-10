import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/tag_repository.dart';
import 'package:notes/screens/folder_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('tag a note from its menu, browse by tag, rename and merge in the manager', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late TagRepository tags;
    late String a, b;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      tags = TagRepository(db);
      a = await repo.createNote(title: 'Algebra');
      b = await repo.createNote(title: 'Biology');
    });
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(MaterialApp(home: FolderView(repository: repo, tags: tags, onOpenNote: (_) {})));
    await settle();
    expect(find.text('Give a note a tag from its menu to find it here.'), findsOneWidget);

    await tester.tap(find.widgetWithText(ListTile, 'All notes'));
    await settle();
    // the menu of Algebra (the list shows the newest first, find it by its menu key)
    await tester.tap(find.descendant(of: find.widgetWithText(ListTile, 'Algebra'), matching: find.byTooltip('Note actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('tags-menu-$a')));
    await settle(); // the dialog reads the tags first
    await tester.enterText(find.byKey(const ValueKey('tag-field')), 'School/Maths');
    await tester.tap(find.byKey(const ValueKey('tags-save')));
    await settle();

    final stored = await tester.runAsync(() => tags.tagsOf(a));
    expect(stored, ['school/maths']);
    // the tree shows school (1) with maths under it once it is opened
    expect(find.byKey(const ValueKey('tag-row-school')), findsOneWidget);
    expect(find.byKey(const ValueKey('tag-row-school/maths')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tag-toggle-school')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tag-row-school/maths')), findsOneWidget);
    expect(find.textContaining('#school/maths'), findsOneWidget); // on the note's line

    // choosing the parent tag lists the note, and only it
    await tester.tap(find.byKey(const ValueKey('tag-row-school')));
    await settle();
    expect(find.widgetWithText(ListTile, 'Algebra'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Biology'), findsNothing);

    // a second note, with a tag that will be merged
    await tester.runAsync(() => tags.setTags(b, ['uni']));
    await tester.tap(find.byKey(const ValueKey('manage-tags')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('rename-tag-uni')));
    await settle();
    await tester.enterText(find.byKey(const ValueKey('tag-rename-field')), 'School');
    await tester.tap(find.byKey(const ValueKey('tag-rename-ok')));
    await settle();
    final all = await tester.runAsync(() => tags.all());
    expect(all, {a: {'school/maths'}, b: {'school'}});

    // delete the tag again
    await tester.tap(find.byKey(const ValueKey('delete-tag-school')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tag-delete-ok')));
    await settle();
    expect(await tester.runAsync(() => tags.all()), isEmpty);
  });
}
