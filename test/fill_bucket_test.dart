import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/region_fill.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late NoteRepository repo;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings');
      repo = NoteRepository(db);
      id = await repo.createNote();
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
  }

  List<DrawingStroke> strokes() {
    final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
    return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
  }

  Offset onPage(WidgetTester tester, Offset p) => tester.getTopLeft(find.byKey(const ValueKey('page-0'))) + p;

  Future<void> drag(WidgetTester tester, Offset a, Offset b) async {
    final g = await tester.createGesture();
    await g.down(onPage(tester, a));
    for (var i = 1; i <= 12; i++) {
      await g.moveTo(onPage(tester, Offset.lerp(a, b, i / 12)!));
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Offset p) async {
    final g = await tester.createGesture();
    await g.down(onPage(tester, p));
    await g.up();
    await tester.pumpAndSettle();
  }

  Future<void> drawBox(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR); // (rectangle)
    await tester.pumpAndSettle();
    await drag(tester, const Offset(100, 100), const Offset(400, 300));
  }

  testWidgets('a touch inside a drawn shape fills it under the line, and it can be taken back', (tester) async {
    await open(tester);
    await drawBox(tester);
    expect(strokes(), hasLength(1));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3); // (red)
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();
    await tap(tester, const Offset(250, 200));
    final all = strokes();
    expect(all, hasLength(2));
    final fill = all.first;
    expect(isBucketFill(fill), isTrue, reason: 'it lies under the line');
    expect(fill.fill!.r, greaterThan(0.5));
    expect(pointInPolygon(const Offset(250, 200), fill.points), isTrue);
    expect(pointInPolygon(const Offset(50, 200), fill.points), isFalse);
    expect(all.last.fill, isNull);

    // filling the same area again in another color replaces the fill
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tap(tester, const Offset(250, 200));
    expect(strokes(), hasLength(2));
    expect(strokes().first.fill!.r, lessThan(0.5));

    await tester.ensureVisible(find.byKey(const ValueKey('undo-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('undo-button')));
    await tester.pumpAndSettle();
    expect(strokes().first.fill!.r, greaterThan(0.5), reason: 'the first fill is back');
    await tester.ensureVisible(find.byKey(const ValueKey('undo-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('undo-button')));
    await tester.pumpAndSettle();
    expect(strokes(), hasLength(1));
  });

  testWidgets('outside the shape the paper is filled round it, and a page with no lines says so', (tester) async {
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();
    await tap(tester, const Offset(250, 200));
    expect(find.byKey(const ValueKey('fill-bucket-message')), findsOneWidget);
    expect(strokes(), isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyG); // (off)
    await drawBox(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();
    await tap(tester, const Offset(50, 50));
    final fills = strokes().where(isBucketFill).toList();
    expect(fills, hasLength(1));
    expect(pointInPolygon(const Offset(50, 50), fills.single.points), isTrue);
    expect(pointInPolygon(const Offset(250, 200), fills.single.points), isFalse, reason: 'the inside of the box is left out');
  });

  testWidgets('the button and another tool switch the bucket off; the gap menu offers four sizes', (tester) async {
    await open(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('fill-bucket-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fill-bucket-button')));
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('fill-bucket-button'))).isSelected, isTrue);
    await tester.tap(find.byKey(const ValueKey('fill-gap')));
    await tester.pumpAndSettle();
    for (final gap in FillGap.values) {
      expect(find.byKey(ValueKey('fill-gap-${gap.name}')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('fill-gap-none')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE); // (the eraser)
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('fill-bucket-button'))).isSelected, isFalse);
    expect(find.byKey(const ValueKey('fill-gap')), findsNothing);
  });
}
