import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/block_editor.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/page_format.dart';
import 'package:notes/screens/document_sheet.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/margin_ruler.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('a page is as wide as its paper: an A4 sheet is 800, A5 is narrower, A3 wider, and a page on its side is as wide as the sheet is high', () {
    double w(PageFormat f, {bool landscape = false}) => f.widthUnits(landscape: landscape);
    expect(w(PageFormat.a4), 800);
    expect(w(PageFormat.a5), closeTo(800 * 148 / 210, 0.01));
    expect(w(PageFormat.a3), closeTo(800 * 297 / 210, 0.01));
    expect(w(PageFormat.a5), lessThan(w(PageFormat.a4)));
    expect(w(PageFormat.a4), lessThan(w(PageFormat.a3)));
    expect(w(PageFormat.a4, landscape: true), closeTo(800 * 297 / 210, 0.01));
    expect(w(PageFormat.letter), closeTo(800 * 215.9 / 210, 0.01));
    // the height follows from the width and the shape of the paper, and the sizes differ in both
    final heights = {for (final f in PageFormat.values) f: f.widthUnits(landscape: false) * f.aspect(landscape: false)};
    expect(heights[PageFormat.a4], closeTo(800 * 297 / 210, 0.01));
    expect(heights[PageFormat.a5], closeTo(800 * 210 / 210, 0.01));
    expect(heights[PageFormat.a5], isNot(heights[PageFormat.a4]));
    expect({for (final f in PageFormat.values) f.widthUnits(landscape: false).round()}.length, greaterThanOrEqualTo(5), reason: 'the sizes differ in width');
  });

  testWidgets('the vertical ruler is as high as the page is on the screen, and a drag moves a margin by what it moved on the page', (tester) async {
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var top = 56.0, bottom = 56.0;
    // a page of 1000 units shown at half size: 500 px high
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            height: 500,
            child: StatefulBuilder(
              builder: (context, setState) => VerticalMarginRuler(
                pageHeight: 1000,
                top: top,
                bottom: bottom,
                onChanged: (t, b) => setState(() {
                  top = t;
                  bottom = b;
                }),
              ),
            ),
          ),
        ),
      ),
    ));
    expect(tester.getSize(find.byType(VerticalMarginRuler)).width, VerticalMarginRuler.width);
    // the handles are where the margins are on the page
    expect(tester.getCenter(find.byKey(const ValueKey('margin-top'))).dy, closeTo(56 / 2, 1));
    expect(tester.getCenter(find.byKey(const ValueKey('margin-bottom'))).dy, closeTo((1000 - 56) / 2, 1));

    final before = top;
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('margin-top'))));
    await gesture.moveBy(const Offset(0, 20)); // (the first move gets the drag going)
    await gesture.moveBy(const Offset(0, 50)); // 50 px on the screen = 100 on the page
    await gesture.up();
    await tester.pump();
    expect(top - before, closeTo(100, 25));
    expect(top, greaterThan(before + 75));

    // the bottom handle moves the other way round, and the limits hold: the text area keeps its height
    final bottomBefore = bottom;
    await tester.drag(find.byKey(const ValueKey('margin-bottom')), const Offset(0, -60));
    await tester.pump();
    expect(bottom, greaterThan(bottomBefore + 50));
    await tester.drag(find.byKey(const ValueKey('margin-bottom')), const Offset(0, -3000), warnIfMissed: false);
    await tester.pump();
    expect(1000 - top - bottom, greaterThanOrEqualTo(MarginRuler.minText - 0.01));
    await tester.drag(find.byKey(const ValueKey('margin-top')), const Offset(0, -3000), warnIfMissed: false);
    await tester.pump();
    expect(top, MarginRuler.minMargin);
  });

  testWidgets('in the editor, another paper size changes the page, and the vertical ruler is the height of the page', (tester) async {
    tester.view.physicalSize = const Size(1800, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = Directory.systemTemp.createTempSync('page_size_');
      repo = NoteRepository(await AppDatabase.open(path: '${dir.path}/n.db'));
      id = await repo.createNote(title: 'Paper');
    });
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 300));
    }

    await settle();
    await tester.tap(find.text('Document'));
    await settle();
    double sheetWidth() => tester.getSize(find.byType(DocumentSheet)).width;
    double sheetHeight() => tester.getSize(find.byType(DocumentSheet)).height;
    expect(find.byKey(const ValueKey('margin-top')), findsOneWidget);
    expect(find.byKey(const ValueKey('margin-bottom')), findsOneWidget);
    final a4 = (w: sheetWidth(), h: sheetHeight());
    expect(a4.w, closeTo(800, 1));

    await tester.tap(find.byTooltip('Page size'));
    await settle();
    await tester.pump(const Duration(seconds: 1)); // (the menu opens)
    await tester.tap(find.text('A5').last, warnIfMissed: false);
    await settle();
    expect(sheetWidth(), lessThan(a4.w - 100), reason: 'an A5 page is narrower than an A4 one');
    expect(sheetWidth(), closeTo(800 * 148 / 210, 1));
    expect(sheetHeight(), closeTo(800, 1));

    await tester.tap(find.byTooltip('Page size'));
    await settle();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('A3').last, warnIfMissed: false);
    await settle();
    expect(sheetWidth(), greaterThan(a4.w + 100), reason: 'an A3 page is wider');

    // the ruler is the page's own: as high as the page on the screen, starting where it starts, beside it, and its handle at the margin
    final sheetTop = tester.getTopLeft(find.byType(DocumentSheet)).dy;
    final scale = sheetWidth() / (800 * 297 / 210);
    final ruler = find.byType(VerticalMarginRuler);
    expect(tester.getTopLeft(ruler).dy, closeTo(sheetTop, 1));
    expect(tester.getSize(ruler).height, closeTo(sheetHeight(), 1));
    expect(tester.getTopRight(ruler).dx, lessThanOrEqualTo(tester.getTopLeft(find.byType(DocumentSheet)).dx + 0.5));
    expect(tester.getCenter(find.byKey(const ValueKey('margin-top'))).dy - sheetTop, closeTo(56 * scale, 2));
    expect(tester.getCenter(find.byKey(const ValueKey('margin-bottom'))).dy - sheetTop, closeTo(sheetHeight() - 56 * scale, 2));
  });

  testWidgets('every page has its margin rulers while the document is written', (tester) async {
    tester.view.physicalSize = const Size(1800, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = Directory.systemTemp.createTempSync('page_rulers_');
      repo = NoteRepository(await AppDatabase.open(path: '${dir.path}/n.db'));
      id = await repo.createNote(title: 'Rulers');
    });
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 300));
    }

    await settle();
    await tester.tap(find.text('Document'));
    await settle();
    // (once there is text, the notebook shows an empty page after the first)
    await tester.tap(find.byType(BlockEditor));
    await settle();
    tester.widget<BlockEditor>(find.byType(BlockEditor)).controller.value = const TextEditingValue(text: 'Some text', selection: TextSelection.collapsed(offset: 9));
    await settle();
    await tester.dragFrom(const Offset(1500, 600), const Offset(0, -700)); // (the next page comes into view)
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(MarginRuler), findsNWidgets(2));
    expect(find.byType(VerticalMarginRuler), findsNWidgets(2));
    // each ruler is with its own page: the second is below the first
    final tops = [for (final r in find.byType(MarginRuler).evaluate()) tester.getTopLeft(find.byWidget(r.widget)).dy]..sort();
    expect(tops[1], greaterThan(tops[0] + 800));
  });
}
