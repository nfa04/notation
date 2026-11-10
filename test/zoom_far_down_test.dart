import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/block_editor.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/margin_ruler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Zooming far down a long note: the page stays under the fingers, on every frame, and nothing scrolls.
void main() {
  setUpAll(AppDatabase.initFfi);

  String paragraphs(int count) => [
        for (var i = 1; i <= count; i++) 'Paragraph $i. ${List.filled(5 + i % 4, 'Alexander the Great of Macedon conquered the Persian Empire.').join(' ')}',
      ].join('\n\n');

  Future<void> open(WidgetTester tester, {String? text, int lastPage = 0}) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      if (text != null) note.documentText = text;
      if (lastPage > 0) {
        note.strokes[lastPage] = [
          DrawingStroke(color: const Color(0xFF000000), width: 3, points: const [Offset(100, 100), Offset(200, 100)]),
        ];
      }
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  ScrollPosition pages(WidgetTester tester) => tester.state<ScrollableState>(find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first).position;

  /// Which page is at [point] and how far down it, in units of the page; a page is about 1131 of them.
  ({int page, double y}) under(WidgetTester tester, Offset point) {
    final found = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('page-'));
    expect(found, findsWidgets);
    for (final e in found.evaluate()) {
      final box = e.renderObject! as RenderBox;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.top <= point.dy && point.dy < rect.bottom) {
        final name = (e.widget.key! as ValueKey<String>).value;
        return (page: int.parse(name.substring(5)), y: (point.dy - rect.top) * 800 / rect.width);
      }
    }
    fail('no page is at $point');
  }

  /// Two fingers around [middle] move [each] apart per step: after each frame the same place of the same page is between them.
  Future<void> pinch(WidgetTester tester, Offset middle, double each, {int steps = 12, required String reason, void Function(String)? everyFrame}) async {
    final wanted = under(tester, middle);
    const start = 120.0;
    final a = await tester.startGesture(middle - const Offset(start, 0), pointer: 1);
    final b = await tester.startGesture(middle + const Offset(start, 0), pointer: 2);
    await tester.pump();
    for (var i = 1; i <= steps; i++) {
      await a.moveTo(middle - Offset(start + i * each, 0));
      await b.moveTo(middle + Offset(start + i * each, 0));
      await tester.pump();
      final now = under(tester, middle);
      expect(now.page, wanted.page, reason: '$reason, frame $i: the page under the fingers');
      expect(now.y, closeTo(wanted.y, 2), reason: '$reason, frame $i: the place on it');
      everyFrame?.call('$reason, frame $i');
    }
    await a.up();
    await b.up();
    await tester.pump();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      everyFrame?.call('$reason, after it, frame $i');
    }
    final end = under(tester, middle);
    expect(end.page, wanted.page, reason: '$reason, at the end: the page');
    expect(end.y, closeTo(wanted.y, 2), reason: '$reason, at the end: the place');
  }

  Future<void> goDown(WidgetTester tester, double to) async {
    pages(tester).jumpTo(to);
    await tester.pump();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  const middle = Offset(600, 450);

  testWidgets('deep in a document that is read', (tester) async {
    await open(tester, text: paragraphs(1200));
    await goDown(tester, 40000);
    await pinch(tester, middle, -6, reason: 'smaller');
    await pinch(tester, middle, 6, reason: 'bigger');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('deep in a document that is written', (tester) async {
    await open(tester, text: paragraphs(600));
    await tester.tap(find.text('Document'));
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final state = tester.state<BlockEditorState>(find.byType(BlockEditor));
    for (var i = 0; i < 2000 && !state.allMeasured; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900))); // (just opened, it does not go to the caret)
    await goDown(tester, 20000);
    void linesOnScreen(String reason) {
      final middleOfScreen = find
          .descendant(of: find.byType(BlockEditor), matching: find.byType(RichText))
          .evaluate()
          .map((e) => (e.renderObject! as RenderBox).localToGlobal(Offset.zero) & (e.renderObject! as RenderBox).size)
          .where((r) => r.width > 100 && r.bottom > 200 && r.top < 700);
      expect(middleOfScreen, isNotEmpty, reason: '$reason: the lines on screen are built');
    }

    linesOnScreen('before');
    await pinch(tester, middle, -6, reason: 'smaller', everyFrame: linesOnScreen);
    await pinch(tester, middle, 6, reason: 'bigger', everyFrame: linesOnScreen);
    // (a slow tablet: a long way between two frames, so that all of what is built has to change)
    await pinch(tester, middle, -50, steps: 2, reason: 'a lot smaller at once', everyFrame: linesOnScreen);
    await pinch(tester, middle, 100, steps: 2, reason: 'a lot bigger at once', everyFrame: linesOnScreen);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('far down a notebook of many pages', (tester) async {
    await open(tester, lastPage: 80);
    await goDown(tester, 40000);
    await pinch(tester, middle, -6, reason: 'smaller');
    await pinch(tester, middle, 6, reason: 'bigger');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('with the end of the note on screen: going smaller stops at the end, going bigger keeps the place, and nothing bounces', (tester) async {
    await open(tester, lastPage: 40);
    await goDown(tester, pages(tester).maxScrollExtent);
    final position = pages(tester);
    await pinch(tester, middle, 6, reason: 'bigger', steps: 8);
    await tester.pump(const Duration(milliseconds: 500));
    expect(position.pixels, lessThanOrEqualTo(position.maxScrollExtent));

    final a = await tester.startGesture(middle - const Offset(300, 0), pointer: 1);
    final b = await tester.startGesture(middle + const Offset(300, 0), pointer: 2);
    await tester.pump();
    for (var i = 1; i <= 10; i++) {
      await a.moveTo(middle - Offset(300 - i * 25.0, 0));
      await b.moveTo(middle + Offset(300 - i * 25.0, 0));
      await tester.pump();
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.01), reason: 'frame $i: at the end, and no further');
    }
    await a.up();
    await b.up();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  group('the list is told how tall the pages are, and that is how tall they are', () {
    /// Page [index] ends where the next begins, at any zoom.
    Future<void> check(WidgetTester tester, int index, {required double ruler, required String reason}) async {
      final page = find.byKey(ValueKey('page-$index'), skipOffstage: false), next = find.byKey(ValueKey('page-${index + 1}'), skipOffstage: false);
      expect(page, findsOneWidget, reason: reason);
      expect(next, findsOneWidget, reason: reason);
      expect(tester.getRect(next).top - tester.getRect(page).bottom, closeTo(ruler, 0.5), reason: reason);
    }

    Future<void> endOfDocument(WidgetTester tester) async {
      await goDown(tester, 0);
      final position = pages(tester);
      await goDown(tester, position.maxScrollExtent);
      await goDown(tester, position.maxScrollExtent);
    }

    testWidgets('pages of a notebook', (tester) async {
      await open(tester, lastPage: 6);
      await goDown(tester, 800);
      await check(tester, 1, ruler: 0, reason: 'at the normal size');
      await pinch(tester, middle, 6, reason: 'bigger', steps: 6);
      await check(tester, 1, ruler: 0, reason: 'bigger');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a long document and the page after it, read and written', (tester) async {
      await open(tester, text: paragraphs(200), lastPage: 1);
      await endOfDocument(tester);
      await check(tester, 0, ruler: 0, reason: 'read');
      await goDown(tester, 0);
      await tester.tap(find.text('Document'));
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final state = tester.state<BlockEditorState>(find.byType(BlockEditor));
      for (var i = 0; i < 2000 && !state.allMeasured; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump();
      await endOfDocument(tester);
      await check(tester, 0, ruler: MarginRuler.height, reason: 'written');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a short document and the page after it', (tester) async {
      await open(tester, text: '# Short', lastPage: 2);
      await check(tester, 0, ruler: 0, reason: 'read');
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
