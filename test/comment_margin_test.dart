
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/pdf_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late String id;

  Future<NoteData> reload() async => (await repo.loadNote(id))!;

  Future<void> open(WidgetTester tester, Size window) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.highlights[0] = [
        PdfHighlight(rect: const Rect.fromLTRB(100, 300, 300, 330), color: Colors.blue.withValues(alpha: 0.3), commentBox: 'c1'),
        PdfHighlight(rect: const Rect.fromLTRB(100, 340, 250, 365), color: Colors.blue.withValues(alpha: 0.3), commentBox: 'c2'),
      ];
      note.textBoxes[0] = [
        TextBoxWidgetModel(id: 'c1', position: const Offset(320, 280), initialText: 'Comment: the first remark'),
        TextBoxWidgetModel(id: 'c2', position: const Offset(320, 340), initialText: 'Comment: the second remark, which is a good deal longer than the first one and wraps over several lines in a narrow card'),
        TextBoxWidgetModel(id: 'plain', position: const Offset(100, 600), initialText: 'an ordinary box'),
      ];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  testWidgets('with room, a comment is a card next to the page, level with its text, not a box on it', (tester) async {
    await open(tester, const Size(1600, 1000));
    final page = tester.getRect(find.byKey(const ValueKey('page-0')));
    final first = find.byKey(const ValueKey('comment-card-c1'));
    final second = find.byKey(const ValueKey('comment-card-c2'));
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    // right of the page, not over it
    expect(tester.getRect(first).left, greaterThan(page.right));
    expect(tester.getRect(second).left, greaterThan(page.right));
    // the first one is level with the text it marks (page units are 1:1 here)
    expect(tester.getRect(first).top, closeTo(page.top + 300, 2));
    // the second wants to be at 340 but the first is in the way: it is pushed below it, not on top
    expect(tester.getRect(second).top, greaterThanOrEqualTo(tester.getRect(first).bottom));
    // the comment text is in its card once, and no box with it lies on the page
    expect(find.text('Comment: the first remark'), findsOneWidget);
    expect(find.descendant(of: first, matching: find.text('Comment: the first remark')), findsOneWidget);
    // an ordinary box stays where it is
    expect(find.textContaining('an ordinary box'), findsOneWidget);
    final plain = tester.getRect(find.textContaining('an ordinary box'));
    expect(plain.right, lessThan(page.right));
  });

  testWidgets('the card can be written in, and removing it removes the marks too', (tester) async {
    await open(tester, const Size(1600, 1000));
    await tester.enterText(find.byKey(const ValueKey('comment-text-c1')), 'Comment: changed');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // the autosave
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    var saved = (await tester.runAsync(reload))!;
    expect(saved.textBoxes[0]!.firstWhere((b) => b.id == 'c1').controller.text, 'Comment: changed');

    await tester.tap(find.byKey(const ValueKey('comment-delete-c1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('comment-card-c1')), findsNothing);
    expect(find.byKey(const ValueKey('comment-card-c2')), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    saved = (await tester.runAsync(reload))!;
    expect(saved.textBoxes[0]!.map((b) => b.id), ['c2', 'plain']);
    expect(saved.highlights[0]!.map((h) => h.commentBox), ['c2']); // the marks of that comment went with it
  });

  testWidgets('a tablet held upright keeps room on the right of the page for the bubbles', (tester) async {
    await open(tester, const Size(600, 1000));
    final page = tester.getRect(find.byKey(const ValueKey('page-0')));
    final card = tester.getRect(find.byKey(const ValueKey('comment-card-c1')));
    expect(card.left, greaterThanOrEqualTo(page.right));
    expect(card.right, lessThanOrEqualTo(600));
    expect(page.width, greaterThan(350)); // still a readable page
    await tester.tap(find.byKey(const ValueKey('comment-text-c1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('comment-card-c1')), findsOneWidget);
  });

  testWidgets('on a phone there is no room beside the page: the comment stays a box on it', (tester) async {
    await open(tester, const Size(400, 1000));
    expect(find.byKey(const ValueKey('comment-card-c1')), findsNothing);
    expect(find.textContaining('the first remark'), findsOneWidget); // still shown: on the page
  });

  testWidgets('a window of ordinary width shrinks the page to make room for the bubbles', (tester) async {
    await open(tester, const Size(1000, 1000));
    final page = tester.getRect(find.byKey(const ValueKey('page-0')));
    final card = tester.getRect(find.byKey(const ValueKey('comment-card-c1')));
    expect(card.left, greaterThanOrEqualTo(page.right));
    expect(card.right, lessThanOrEqualTo(1000));
  });

  testWidgets('clicking into a card keeps it and lets it be written in', (tester) async {
    await open(tester, const Size(1600, 1000));
    await tester.tap(find.byKey(const ValueKey('comment-text-c1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('comment-card-c1')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('comment-text-c1')), 'Comment: typed');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('comment-card-c1')), findsOneWidget);
    expect(find.text('Comment: typed'), findsOneWidget);
  });
}
