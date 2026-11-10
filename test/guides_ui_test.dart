import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/guides.dart';
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
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
    });
    await tester.runAsync(() => repo.settings.set('draw_bar_more', '1')); // (the rarely used tools are folded away by default)
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

  Offset pageOrigin(WidgetTester tester) => tester.getTopLeft(find.byKey(const ValueKey('page-0')));

  Future<void> choose(WidgetTester tester, String item) async {
    await tester.ensureVisible(find.byKey(const ValueKey('guides-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('guides-picker')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(ValueKey(item))); // (the menu is longer than the screen)
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(item)));
    await tester.pumpAndSettle();
  }

  Future<void> draw(WidgetTester tester, List<Offset> path) async {
    final origin = pageOrigin(tester);
    final g = await tester.createGesture();
    await g.down(origin + path.first);
    for (final p in path.skip(1)) {
      await g.moveTo(origin + p);
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  Future<void> pull(WidgetTester tester, String key, Offset by) async {
    final g = await tester.startGesture(tester.getCenter(find.byKey(ValueKey(key))));
    for (var i = 1; i <= 10; i++) {
      await g.moveBy(by / 10);
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  Offset onPage(WidgetTester tester, String key) => tester.getCenter(find.byKey(ValueKey(key))) - pageOrigin(tester);

  /// A hand that wobbles about the line from [a] to [b].
  List<Offset> shaky(Offset a, Offset b, {double wobble = 5, int n = 16}) {
    final d = b - a;
    final normal = Offset(-d.dy, d.dx) / d.distance;
    return [for (var i = 0; i <= n; i++) a + d * (i / n) + normal * ((i.isEven ? 1 : -1) * wobble * (i == 0 ? 0 : 1))];
  }

  double offLine(Offset p, Offset a, Offset b) {
    final d = b - a;
    return ((p - a).dx * d.dy - (p - a).dy * d.dx).abs() / d.distance;
  }

  Future<void> settleSave(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
  }

  testWidgets('an overlay is laid over the page and taken away again, and is not part of the page', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('guides-layer')), findsNothing);
    await choose(tester, 'guide-overlay-thirds');
    expect(find.byKey(const ValueKey('guides-layer')), findsOneWidget);
    await draw(tester, [const Offset(100, 100), const Offset(300, 120)]);
    expect(strokes().length, 1, reason: 'drawing over it is just drawing');
    await choose(tester, 'guide-overlay-none');
    expect(find.byKey(const ValueKey('guides-layer')), findsNothing);
    await settleSave(tester);
  });

  testWidgets('a ruler is laid on the page, and a line drawn along its edge is straight along it, however the hand wobbles', (tester) async {
    await open(tester);
    await choose(tester, 'guide-aid-ruler');
    final pivot = onPage(tester, 'aid-pivot'), end = onPage(tester, 'aid-turn');
    expect(end.dx - pivot.dx, closeTo(420, 1), reason: 'a ruler of 420 units, along the page');
    final topEdgeY = pivot.dy - DrawingAid.rulerWidth / 2;

    await draw(tester, shaky(Offset(pivot.dx + 40, topEdgeY + 5), Offset(pivot.dx + 380, topEdgeY - 3), wobble: 6));
    final s = strokes().single;
    expect(s.points.length, greaterThanOrEqualTo(2));
    for (final p in s.points) {
      expect(p.dy, closeTo(topEdgeY, 0.01), reason: 'on the edge');
      expect(p.dx, inInclusiveRange(pivot.dx - 0.01, end.dx + 0.01));
    }
    // it goes on to the end of the ruler and no further
    await draw(tester, [Offset(pivot.dx + 100, topEdgeY + 4), Offset(pivot.dx + 900, topEdgeY + 6)]);
    expect(strokes().last.points.last.dx, closeTo(end.dx, 0.01));

    // away from the ruler the hand is free
    await draw(tester, shaky(const Offset(300, 700), const Offset(600, 760), wobble: 8));
    final free = strokes().last;
    expect(free.points.any((p) => offLine(p, free.points.first, free.points.last) > 3), isTrue);
    await settleSave(tester);
  });

  testWidgets('the ruler is moved by its pivot and turned and made longer by its end, and then lines follow it where it is', (tester) async {
    await open(tester);
    await choose(tester, 'guide-aid-ruler');
    final before = onPage(tester, 'aid-pivot');
    await pull(tester, 'aid-pivot', const Offset(60, 200));
    final pivot = onPage(tester, 'aid-pivot');
    expect((pivot - before).dx, closeTo(60, 24), reason: 'it follows the hand but for the first step');
    expect((pivot - before).dy, closeTo(200, 24));

    await pull(tester, 'aid-turn', const Offset(-120, 160));
    final end = onPage(tester, 'aid-turn');
    final along = end - pivot;
    expect(along.dy, greaterThan(100), reason: 'turned downwards');
    final unit = along / along.distance;
    final normal = Offset(-unit.dy, unit.dx);
    // a line along its upper edge (the one on the side of minus the normal), a little way in from the end
    final a = pivot + unit * 60 - normal * (DrawingAid.rulerWidth / 2), b = pivot + unit * 200 - normal * (DrawingAid.rulerWidth / 2);
    await draw(tester, shaky(a + normal * 6, b - normal * 5, wobble: 5));
    final s = strokes().single;
    for (final p in s.points) {
      expect(offLine(p, a, b), lessThan(0.05), reason: 'on the slanted edge');
    }
    expect((s.points.last - s.points.first).dy, greaterThan(40), reason: 'it is a slanted line');
    await settleSave(tester);
  });

  testWidgets('a set square follows all three of its sides, and the ruler is gone when "None" is chosen', (tester) async {
    await open(tester);
    await choose(tester, 'guide-aid-squareFortyFive');
    final pivot = onPage(tester, 'aid-pivot'), end = onPage(tester, 'aid-turn');
    // the hypotenuse runs from the end of the base to the end of the upright side
    final top = Offset(pivot.dx, pivot.dy + (end.dx - pivot.dx));
    final mid = Offset.lerp(end, top, 0.5)!;
    await draw(tester, shaky(Offset.lerp(end, top, 0.25)! + const Offset(4, 3), Offset.lerp(end, top, 0.75)! + const Offset(-3, 4), wobble: 4));
    final s = strokes().single;
    for (final p in s.points) {
      expect(offLine(p, end, top), lessThan(0.05), reason: 'on the hypotenuse');
    }
    expect(mid, isNot(Offset.zero));
    // the upright side
    await draw(tester, shaky(Offset(pivot.dx + 3, pivot.dy + 40), Offset(pivot.dx - 2, pivot.dy + 200), wobble: 3));
    for (final p in strokes().last.points) {
      expect(p.dx, closeTo(pivot.dx, 0.05), reason: 'on the upright side');
    }
    await choose(tester, 'guide-aid-none');
    expect(find.byKey(const ValueKey('aid-pivot')), findsNothing);
    await settleSave(tester);
  });

  testWidgets('"lines follow the guides" can be switched off, and then the ruler is only to be looked at', (tester) async {
    await open(tester);
    await choose(tester, 'guide-aid-ruler');
    final pivot = onPage(tester, 'aid-pivot');
    final top = pivot.dy - DrawingAid.rulerWidth / 2;
    await choose(tester, 'guide-snap');
    await draw(tester, shaky(Offset(pivot.dx + 40, top + 4), Offset(pivot.dx + 380, top - 3), wobble: 6));
    final ys = {for (final p in strokes().single.points) p.dy.round()};
    expect(ys.length, greaterThan(1), reason: 'not straight');
    await choose(tester, 'guide-snap');
    await draw(tester, shaky(Offset(pivot.dx + 40, top + 4), Offset(pivot.dx + 380, top - 3), wobble: 6));
    expect({for (final p in strokes().last.points) p.dy.round()}.length, 1, reason: 'on again');
    await settleSave(tester);
  });

  testWidgets('perspective: a line drawn towards a vanishing point goes exactly to it, the vertical stays vertical, another way is free; the points can be moved', (tester) async {
    await open(tester);
    await choose(tester, 'guide-perspective-1');
    final vp = onPage(tester, 'vanishing-0');
    final start = Offset(vp.dx - 180, vp.dy + 400);
    // up the page, towards the vanishing point, with a shaky hand
    final target = start + (vp - start) * 0.7;
    await draw(tester, shaky(start, target, wobble: 3));
    final toward = strokes().single;
    for (final p in toward.points) {
      expect(offLine(p, toward.points.first, toward.points.last), lessThan(0.001), reason: 'the line is straight');
    }
    final way = toward.points.last - toward.points.first, wanted = vp - start;
    final off = math.acos(((way.dx * wanted.dx + way.dy * wanted.dy) / (way.distance * wanted.distance)).clamp(-1.0, 1.0)) * 180 / math.pi;
    expect(off, lessThan(0.3), reason: 'and it points at the vanishing point (the hand was up to 3 units off it)');

    // straight up and down
    await draw(tester, shaky(Offset(600, 700), Offset(603, 900), wobble: 3));
    for (final p in strokes().last.points) {
      expect(p.dx, closeTo(600, 0.05));
    }

    // a quarter of the way between the two: free
    final free = shaky(Offset(200, 900), Offset(300, 1000), wobble: 0);
    await draw(tester, free);
    expect(strokes().last.points.last.dx, closeTo(300, 1.5));
    expect(strokes().last.points.last.dy, closeTo(1000, 1.5));

    // the vanishing point is pulled elsewhere
    await pull(tester, 'vanishing-0', const Offset(-200, 100));
    final moved = onPage(tester, 'vanishing-0');
    expect(moved.dx, closeTo(vp.dx - 200, 24));
    expect(moved.dy, closeTo(vp.dy + 100, 24));
    await settleSave(tester);
  });

  testWidgets('with two and three vanishing points there are two and three handles, and none without', (tester) async {
    await open(tester);
    await choose(tester, 'guide-perspective-2');
    expect(find.byKey(const ValueKey('vanishing-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('vanishing-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('vanishing-2')), findsNothing);
    await choose(tester, 'guide-perspective-3');
    expect(find.byKey(const ValueKey('vanishing-2')), findsOneWidget);
    await choose(tester, 'guide-perspective-0');
    expect(find.byKey(const ValueKey('vanishing-0')), findsNothing);
    expect(find.byKey(const ValueKey('guides-layer')), findsNothing);
  });

  testWidgets('the ruler and symmetry work together: the line along the ruler is mirrored too', (tester) async {
    await open(tester);
    await choose(tester, 'guide-aid-ruler');
    final pivot = onPage(tester, 'aid-pivot');
    await tester.ensureVisible(find.byKey(const ValueKey('symmetry-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('symmetry-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('symmetry-leftRight')));
    await tester.pumpAndSettle();
    final top = pivot.dy - DrawingAid.rulerWidth / 2;
    await draw(tester, shaky(Offset(pivot.dx + 40, top + 4), Offset(pivot.dx + 300, top - 4), wobble: 5));
    final drawn = strokes();
    expect(drawn.length, 2);
    for (final s in drawn) {
      expect({for (final p in s.points) p.dy.round()}.length, 1, reason: 'both are straight');
    }
    expect(drawn[0].points.first.dx + drawn[1].points.first.dx, closeTo(800, 1.5));
    await settleSave(tester);
  });

  testWidgets('with the tool off there is no button, no overlay and no handle', (tester) async {
    final store = <String, String>{};
    final features = FeatureSettings((k) async => store[k], (k, v) async => store[k] = v);
    await features.apply({...FeaturePresets.everything}..remove(Feature.guides));
    await open(tester, features: features);
    expect(find.byKey(const ValueKey('guides-picker')), findsNothing);
    expect(find.byKey(const ValueKey('guides-layer')), findsNothing);
  });
}
