import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late NoteRepository repo;
  late String id;

  Future<void> open(WidgetTester tester, {FeatureSettings? features}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, features: features)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
  }

  List<DrawingStroke> strokes() {
    final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
    return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
  }

  Future<void> choose(WidgetTester tester, String picker, String item) async {
    await tester.ensureVisible(find.byKey(ValueKey(picker)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(picker)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(item)));
    await tester.pumpAndSettle();
  }

  Future<void> drag(WidgetTester tester, List<Offset> path) async {
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    final g = await tester.createGesture();
    await g.down(origin + path.first);
    for (final p in path.skip(1)) {
      await g.moveTo(origin + p);
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  /// Pulls the symmetry handle by [by], in small steps as a hand does.
  Future<void> pull(WidgetTester tester, Offset by) async {
    final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('symmetry-handle'))));
    for (var i = 1; i <= 10; i++) {
      await g.moveBy(by / 10);
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  List<Offset> line(Offset a, Offset b, [int n = 12]) => [for (var i = 0; i <= n; i++) Offset.lerp(a, b, i / n)!];

  testWidgets('the new brushes are in the brush menu, draw with their own width', (tester) async {
    await open(tester);
    await choose(tester, 'brush-picker', 'brush-watercolour');
    await drag(tester, line(const Offset(100, 100), const Offset(400, 160)));
    expect(strokes().single.brush, 'watercolour');
    expect(strokes().single.width, closeTo(3 * 4, 1e-9), reason: 'the width chosen (3), four times as thick');
    await choose(tester, 'brush-picker', 'brush-pencil');
    await drag(tester, line(const Offset(100, 300), const Offset(400, 360)));
    expect(strokes().last.brush, 'pencil');
  });

  testWidgets('with the tool off the pen and the roller are the only brushes (so the button is still there for those two)', (tester) async {
    final store = <String, String>{};
    final features = FeatureSettings((k) async => store[k], (k, v) async => store[k] = v);
    await features.apply({...FeaturePresets.everything}..removeAll([Feature.brushes, Feature.symmetry, Feature.stabiliser, Feature.layers, Feature.pictureEdit, Feature.guides, Feature.arrange, Feature.stamps, Feature.flipbook, Feature.ideas, Feature.exportImages, Feature.pathText, Feature.alignLines, Feature.colorPicker, Feature.fillBucket, Feature.freeTransform]));
    await open(tester, features: features);
    await tester.ensureVisible(find.byKey(const ValueKey('brush-picker')));
    await tester.tap(find.byKey(const ValueKey('brush-picker')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brush-roller')), findsOneWidget);
    expect(find.byKey(const ValueKey('brush-pencil')), findsNothing);
    expect(find.byKey(const ValueKey('symmetry-picker')), findsNothing);
    expect(find.byKey(const ValueKey('stabiliser-picker')), findsNothing);
    expect(find.byKey(const ValueKey('layers-button')), findsNothing);
  });

  testWidgets('a mirror draws the line again on the other side of the middle of the page, and one undo takes both back', (tester) async {
    await open(tester);
    final size = tester.getSize(find.byKey(const ValueKey('page-0')));
    await choose(tester, 'symmetry-picker', 'symmetry-leftRight');
    expect(find.byKey(const ValueKey('symmetry-guide')), findsOneWidget);
    await drag(tester, line(const Offset(100, 100), const Offset(250, 220)));
    final drawn = strokes();
    expect(drawn.length, 2);
    final a = drawn[0], b = drawn[1];
    expect(a.id, isNot(b.id));
    expect(a.points.length, b.points.length);
    for (var i = 0; i < a.points.length; i++) {
      expect(b.points[i].dx, closeTo(size.width - a.points[i].dx, 1e-6));
      expect(b.points[i].dy, closeTo(a.points[i].dy, 1e-6));
    }
    expect(b.color, a.color);
    expect(b.width, a.width);

    await tester.drag(find.byKey(const ValueKey('symmetry-picker')), const Offset(0, 900)); // (the drawing bar back to its top)
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('undo-button')));
    await tester.pumpAndSettle();
    expect(strokes(), isEmpty);
    await tester.tap(find.byKey(const ValueKey('redo-button')));
    await tester.pumpAndSettle();
    expect(strokes().length, 2);
  });

  testWidgets('around the centre with six turns makes six lines of the same length, and turning symmetry off draws one again', (tester) async {
    await open(tester);
    await choose(tester, 'symmetry-picker', 'symmetry-radial');
    await choose(tester, 'symmetry-picker', 'symmetry-turns-6');
    await drag(tester, line(const Offset(300, 200), const Offset(380, 300)));
    expect(strokes().length, 6);
    double length(DrawingStroke s) {
      var d = 0.0;
      for (var i = 1; i < s.points.length; i++) {
        d += (s.points[i] - s.points[i - 1]).distance;
      }
      return d;
    }

    for (final s in strokes()) {
      expect(length(s), closeTo(length(strokes().first), 0.5));
    }
    await choose(tester, 'symmetry-picker', 'symmetry-off');
    await drag(tester, line(const Offset(100, 500), const Offset(300, 520)));
    expect(strokes().length, 7);
    expect(find.byKey(const ValueKey('symmetry-guide')), findsNothing);
  });

  testWidgets('a tap does not leave a stray mirror image behind', (tester) async {
    await open(tester);
    await choose(tester, 'symmetry-picker', 'symmetry-both');
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await tester.tapAt(origin + const Offset(200, 200));
    await tester.pumpAndSettle();
    expect(strokes().length, lessThanOrEqualTo(1), reason: 'at most the dot a tap with a finger or pen writes, never its three images');
  });

  testWidgets('the stabiliser keeps a shaky line smoother than the pen and ends it where the pen was lifted', (tester) async {
    await open(tester);
    await choose(tester, 'stabiliser-picker', 'stabiliser-Strong');
    // a line along the page with a wobble of 6 up and down
    final path = [for (var i = 0; i <= 40; i++) Offset(100 + i * 8.0, 300 + (i.isEven ? 6 : -6))];
    await drag(tester, path);
    final s = strokes().single;
    final ys = [for (final p in s.points) p.dy];
    final spread = ys.reduce((a, b) => a > b ? a : b) - ys.reduce((a, b) => a < b ? a : b);
    expect(spread, lessThan(8), reason: 'the pen wobbled 12 up and down');
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    expect((s.points.last - path.last).distance, lessThan(8), reason: 'it ends at the pen');
    expect(s.points.first.dx, closeTo(path.first.dx, 1e-6));
    expect(origin, isNotNull);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500))); // (the save the drawing started)
    await tester.pumpAndSettle();
  });

  testWidgets('the centre of the symmetry is pulled by its handle, drawn about where it was put, and brought back to the middle by the menu or a double tap', (tester) async {
    await open(tester);
    final size = tester.getSize(find.byKey(const ValueKey('page-0')));
    await choose(tester, 'symmetry-picker', 'symmetry-leftRight');
    expect(find.byKey(const ValueKey('symmetry-handle')), findsOneWidget);

    final left = tester.getTopLeft(find.byKey(const ValueKey('page-0'))).dx;
    await pull(tester, const Offset(120, 0));
    final centreX = tester.getCenter(find.byKey(const ValueKey('symmetry-handle'))).dx - left; // (where it is now)
    expect(centreX, closeTo(size.width / 2 + 120, 16), reason: 'it followed the hand, but for the first step that tells a drag from a tap');
    await drag(tester, line(const Offset(100, 300), const Offset(220, 380)));
    var drawn = strokes();
    expect(drawn.length, 2);
    for (var i = 0; i < drawn[0].points.length; i++) {
      expect(drawn[1].points[i].dx, closeTo(2 * centreX - drawn[0].points[i].dx, 1.5), reason: 'mirrored about the new centre');
      expect(drawn[1].points[i].dy, closeTo(drawn[0].points[i].dy, 1e-6));
    }

    // back to the middle from the menu
    await tester.ensureVisible(find.byKey(const ValueKey('symmetry-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('symmetry-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('symmetry-centre')));
    await tester.pumpAndSettle();
    await drag(tester, line(const Offset(100, 500), const Offset(220, 560)));
    drawn = strokes();
    expect(drawn.length, 4);
    expect(drawn[3].points.first.dx, closeTo(size.width - drawn[2].points.first.dx, 1.5), reason: 'about the middle again');

    // a double tap on the handle does the same
    await pull(tester, const Offset(-80, 60));
    final moved = tester.getCenter(find.byKey(const ValueKey('symmetry-handle')));
    expect(moved.dx, lessThan(tester.getTopLeft(find.byKey(const ValueKey('page-0'))).dx + size.width / 2 - 40));
    await tester.tap(find.byKey(const ValueKey('symmetry-handle')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('symmetry-handle')));
    await tester.pumpAndSettle();
    final back = tester.getCenter(find.byKey(const ValueKey('symmetry-handle')));
    expect(back.dx - tester.getTopLeft(find.byKey(const ValueKey('page-0'))).dx, closeTo(size.width / 2, 1.5));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the handle is there only while symmetry is on', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('symmetry-handle')), findsNothing);
    await choose(tester, 'symmetry-picker', 'symmetry-radial');
    expect(find.byKey(const ValueKey('symmetry-handle')), findsOneWidget);
    await choose(tester, 'symmetry-picker', 'symmetry-off');
    expect(find.byKey(const ValueKey('symmetry-handle')), findsNothing);
  });
}
