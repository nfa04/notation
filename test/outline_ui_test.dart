import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/bookmark_repository.dart';
import 'package:notes/data/link_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/markdown/mention.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('the outline lists headings, bookmarks follow their pages, and other notes that link here are listed', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late BookmarkRepository bookmarks;
    late LinkRepository links;
    late String id, other;
    String? opened;
    int? openedPage;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      bookmarks = BookmarkRepository(db);
      links = LinkRepository(db);
      id = await repo.createNote(title: 'Thermodynamics');
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'h1', position: const Offset(50, 50), initialText: '# Laws\nof thermodynamics')];
      note.textBoxes[1] = [TextBoxWidgetModel(id: 'h2', position: const Offset(50, 50), initialText: '## Entropy')];
      await repo.saveNote(note);
      other = await repo.createNote(title: 'Exam plan');
      final plan = (await repo.loadNote(other))!;
      plan.textBoxes[2] = [TextBoxWidgetModel(id: 'l', position: const Offset(50, 50), initialText: 'Revise ${noteLink(id, 'Thermodynamics')} first')];
      await repo.saveNote(plan);
    });
    await tester.pumpWidget(MaterialApp(
      home: FixedPageNoteEditor(
        noteId: id,
        repository: repo,
        bookmarks: bookmarks,
        links: links,
        onOpenNoteAt: (note, page) {
          opened = note;
          openedPage = page;
        },
      ),
    ));
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    await settle();
    await tester.tap(find.byKey(const ValueKey('outline-button')));
    await settle();

    // contents
    Finder entry(int i, String title) => find.descendant(of: find.byKey(ValueKey('outline-entry-$i')), matching: find.text(title));
    expect(entry(0, 'Laws'), findsOneWidget);
    expect(entry(1, 'Entropy'), findsOneWidget);
    expect(find.byKey(const ValueKey('outline-entry-2')), findsNothing);

    expect(find.byKey(const ValueKey('outline-panel')), findsOneWidget, reason: 'beside the note, not a sheet over it');

    // bookmark the page in view
    await tester.tap(find.byKey(const ValueKey('outline-tab-bookmarks')));
    await tester.pumpAndSettle();
    expect(find.textContaining('No bookmarks yet'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bookmark-this-page')));
    await settle();
    expect(find.byKey(const ValueKey('bookmark-0')), findsOneWidget);
    expect(await tester.runAsync(() => bookmarks.list(id)), [const PageBookmark(0, '')]);

    // name it
    await tester.tap(find.byKey(const ValueKey('bookmark-name-0')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('bookmark-name-field')), 'Start');
    await tester.tap(find.byKey(const ValueKey('bookmark-name-ok')));
    await settle();
    expect(find.descendant(of: find.byKey(const ValueKey('bookmark-0')), matching: find.text('Start')), findsOneWidget);

    // the links tab
    await tester.tap(find.byKey(const ValueKey('outline-tab-links')));
    // (a spinner never settles, so the tab is slid in by hand, then the search is given real time)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(find.descendant(of: find.byKey(const ValueKey('backlink-0')), matching: find.text('Exam plan')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('backlink-0')), matching: find.textContaining('Revise Thermodynamics first')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('backlink-0')));
    await settle();
    expect(opened, other);
    expect(openedPage, 2);

    // a page inserted before moves the bookmark along; taking that back moves it home
    await tester.tap(find.byKey(const ValueKey('pages-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Insert a blank page before'));
    await settle();
    expect(await tester.runAsync(() => bookmarks.list(id)), [const PageBookmark(1, 'Start')]);
    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await settle();
    expect(await tester.runAsync(() => bookmarks.list(id)), [const PageBookmark(0, 'Start')]);

    // choosing a line takes the reader there and leaves the panel open
    await tester.tap(find.byKey(const ValueKey('outline-tab-contents')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('outline-entry-1')));
    await settle();
    expect(find.byKey(const ValueKey('outline-panel')), findsOneWidget);
  });
}
