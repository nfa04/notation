import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/models/guides.dart';

void main() {
  const page = Size(800, 1131);

  group('the overlays', () {
    test('thirds and the golden ratio are on the right fractions of the page', () {
      final thirds = GuideOverlay.thirds.lines(page);
      expect(thirds.length, 4);
      expect({for (final (a, b) in thirds) if (a.dx == b.dx) a.dx.roundToDouble()}, {267.0, 533.0});
      expect({for (final (a, b) in thirds) if (a.dy == b.dy) a.dy.roundToDouble()}, {377.0, 754.0});
      final golden = GuideOverlay.golden.lines(page);
      final xs = [for (final (a, b) in golden) if (a.dx == b.dx) a.dx]..sort();
      expect(xs[0] / 800, closeTo(0.382, 0.001));
      expect(xs[1] / 800, closeTo(0.618, 0.001));
      expect(xs[1] / xs[0], closeTo(GuideOverlay.phi, 0.001), reason: 'the two parts are in the golden ratio');
    });

    test('centre lines, diagonals, and a grid of centimetres', () {
      final centre = GuideOverlay.centre.lines(page);
      expect([for (final (a, b) in centre) a.dx == b.dx ? a.dx : a.dy], [400, 565.5]);
      final diag = GuideOverlay.diagonals.lines(page);
      expect(diag.length, 2);
      expect(diag.first, (Offset.zero, const Offset(800, 1131)));
      final grid = GuideOverlay.grid.lines(page);
      final vertical = [for (final (a, b) in grid) if (a.dx == b.dx) a.dx]..sort();
      expect(vertical[1] - vertical[0], closeTo(GuideOverlay.centimetre, 1e-9));
      expect(GuideOverlay.centimetre, closeTo(800 / 21, 1e-9), reason: 'an A4 sheet is 21 cm across');
      expect(vertical.length, 20);
      expect(GuideOverlay.none.lines(page), isEmpty);
    });
  });

  group('perspective', () {
    test('one, two and three vanishing points start where a drawing would have them', () {
      expect(defaultVanishingPoints(0), isEmpty);
      expect(defaultVanishingPoints(1).length, 1);
      expect(defaultVanishingPoints(2).map((p) => p.dy).toSet().length, 1, reason: 'two points are on one horizon');
      expect(defaultVanishingPoints(3).length, 3);
      expect(defaultVanishingPoints(3).last.dy, greaterThan(0.8), reason: 'the third is for looking up or down');
    });

    test('spokes go out of every point, and the horizon goes through one or two of them', () {
      final points = [const Offset(100, 200), const Offset(700, 200)];
      final lines = perspectiveLines(points, page, spokes: 12);
      expect(lines.length, 12 * 2 + 1);
      expect(lines.where((l) => l.$1 == points[0]).length, 12);
      expect(lines.last, (const Offset(0, 200), const Offset(800, 200)));
      expect(perspectiveLines([const Offset(1, 1), const Offset(2, 2), const Offset(3, 3)], page, spokes: 4).length, 12, reason: 'no horizon with three');
    });

    test('from a point the directions are those to the vanishing points and the vertical, and with one the horizontal', () {
      const start = Offset(300, 600);
      final one = perspectiveDirections(start, [const Offset(300, 100)]);
      expect(one, containsAll([const Offset(0, -1), const Offset(0, 1), const Offset(1, 0)]));
      final two = perspectiveDirections(start, [const Offset(0, 200), const Offset(800, 200)]);
      expect(two.length, 3);
      for (final d in two) {
        expect(d.distance, closeTo(1, 1e-9));
      }
      expect(two.last, const Offset(0, 1));
      final three = perspectiveDirections(start, [const Offset(0, 200), const Offset(800, 200), const Offset(400, 1100)]);
      expect(three.length, 3, reason: 'with three points nothing is parallel');
      expect(perspectiveDirections(start, const []), isEmpty);
    });
  });

  group('edges', () {
    test('the nearest point of an edge, and its ends', () {
      const e = SnapEdge(Offset(0, 0), Offset(100, 0));
      expect(e.nearest(const Offset(40, 30)), const Offset(40, 0));
      expect(e.nearest(const Offset(-20, 5)), Offset.zero);
      expect(e.nearest(const Offset(250, -5)), const Offset(100, 0));
      expect(e.distanceTo(const Offset(40, 30)), 30);
      expect(e.direction, const Offset(1, 0));
      expect(const SnapEdge(Offset(5, 5), Offset(5, 5)).nearest(const Offset(9, 9)), const Offset(5, 5), reason: 'an edge of no length does not break');
    });
  });

  group('rulers and set squares', () {
    test('a ruler lies along its angle, with two long edges the width apart, as long as it is', () {
      const r = DrawingAid(AidKind.ruler, 0, Offset(100, 100), length: 400);
      final e = r.edges;
      expect(e.length, 2);
      expect(e[0].a, const Offset(100, 100 - DrawingAid.rulerWidth / 2));
      expect(e[0].b, const Offset(500, 100 - DrawingAid.rulerWidth / 2));
      expect(e[1].a.dy - e[0].a.dy, DrawingAid.rulerWidth);
      expect(r.handle, const Offset(500, 100));
      final turned = r.copyWith(angle: math.pi / 2); // a quarter turn clockwise: along the page downwards
      expect(turned.handle.dx, closeTo(100, 1e-9));
      expect(turned.handle.dy, closeTo(500, 1e-9));
      expect(turned.edges[0].length, closeTo(400, 1e-9));
    });

    test('a set square has three edges and the angles it is for', () {
      double angleBetween(SnapEdge a, SnapEdge b) {
        final cos = (a.direction.dx * b.direction.dx + a.direction.dy * b.direction.dy).abs();
        return math.acos(cos.clamp(0.0, 1.0)) * 180 / math.pi;
      }

      for (final turn in [0.0, 0.7, 2.0]) {
        final s45 = const DrawingAid(AidKind.squareFortyFive, 0, Offset(200, 200), length: 300).copyWith(angle: turn).edges;
        expect(s45.length, 3);
        expect(s45[0].length, closeTo(300, 1e-6));
        expect(s45[2].length, closeTo(300, 1e-6), reason: 'two equal sides');
        expect(angleBetween(s45[0], s45[2]), closeTo(90, 1e-6), reason: 'with a right angle between them');
        expect(angleBetween(s45[0], s45[1]), closeTo(45, 1e-6));

        final s30 = const DrawingAid(AidKind.squareThirty, 0, Offset(200, 200), length: 300).copyWith(angle: turn).edges;
        expect(angleBetween(s30[0], s30[2]), closeTo(90, 1e-6));
        expect(angleBetween(s30[0], s30[1]), closeTo(30, 1e-6), reason: 'the long side and the hypotenuse make 30 degrees');
        expect(s30[1].length, closeTo(300 / math.cos(math.pi / 6), 1e-6));
      }
    });

    test('its length stays within what can be used, and it can be put on another page', () {
      const r = DrawingAid(AidKind.ruler, 0, Offset.zero);
      expect(r.copyWith(length: 5).length, DrawingAid.minLength);
      expect(r.copyWith(length: 99999).length, DrawingAid.maxLength);
      expect(r.copyWith(page: 3).page, 3);
      expect(r.copyWith(origin: const Offset(9, 9)).origin, const Offset(9, 9));
    });
  });

  group('following the guides', () {
    const ruler = DrawingAid(AidKind.ruler, 0, Offset(100, 300), length: 400);

    test('a line started along the edge of the ruler is straight along it, wherever the pen wobbles, and ends where the ruler does', () {
      final top = ruler.edges[0].a.dy; // 272
      final s = GuideSnapper(Offset(150, top + 6), edges: ruler.edges);
      expect(s.active, isTrue);
      expect(s.following, isTrue);
      for (final (x, y) in [(160.0, top + 9), (250.0, top - 7), (400.0, top + 12)]) {
        final r = s.apply(Offset(x, y));
        expect(r.point.dy, top, reason: 'on the edge');
        expect(r.point.dx, x);
        expect(r.restart, isFalse);
      }
      expect(s.apply(const Offset(900, 300)).point, Offset(500, top), reason: 'not beyond the end of the ruler');
      expect(s.apply(const Offset(0, 300)).point, Offset(100, top));
    });

    test('far from the edges (and with no directions) the pen is free', () {
      final s = GuideSnapper(const Offset(150, 100), edges: ruler.edges);
      expect(s.active, isFalse);
      expect(s.apply(const Offset(200, 130)).point, const Offset(200, 130));
    });

    test('the nearest edge is the one that is followed, and the other side of the ruler is another edge', () {
      final bottom = ruler.edges[1].a.dy; // 328
      final s = GuideSnapper(Offset(150, bottom - 3), edges: ruler.edges);
      expect(s.apply(const Offset(300, 340)).point.dy, bottom);
    });

    test('a slanted set square makes slanted lines', () {
      final square = const DrawingAid(AidKind.squareFortyFive, 0, Offset(100, 100), length: 300);
      final hypotenuse = square.edges[1];
      final mid = hypotenuse.a + (hypotenuse.b - hypotenuse.a) * 0.3;
      final s = GuideSnapper(mid + const Offset(3, 3), edges: [hypotenuse]);
      final end = hypotenuse.a + (hypotenuse.b - hypotenuse.a) * 0.7;
      final r = s.apply(end + const Offset(5, -4));
      expect(hypotenuse.distanceTo(r.point), lessThan(1e-9));
    });

    test('going the way of a perspective direction locks the line to it, and the part drawn before is to be made again', () {
      const start = Offset(300, 600);
      final dirs = perspectiveDirections(start, [const Offset(100, 200), const Offset(700, 200)]);
      final s = GuideSnapper(start, directions: dirs);
      expect(s.active, isTrue);
      expect(s.following, isFalse);
      expect(s.apply(const Offset(303, 596)).point, const Offset(303, 596), reason: 'not yet decided');
      expect(s.following, isFalse);
      // going up and to the left, about towards the first vanishing point
      final toVp = (const Offset(100, 200) - start);
      final unit = toVp / toVp.distance;
      final pen = start + unit * 80 + const Offset(1.5, 0);
      final r = s.apply(pen);
      expect(r.restart, isTrue);
      final onLine = r.point - start;
      expect((onLine.dx * unit.dy - onLine.dy * unit.dx).abs(), lessThan(1e-9), reason: 'on the line to the vanishing point');
      final next = s.apply(start + unit * 150 + const Offset(6, -3));
      expect(next.restart, isFalse);
      expect(((next.point - start).dx * unit.dy - (next.point - start).dy * unit.dx).abs(), lessThan(1e-9));
    });

    test('a hand that is unsteady at the start still finds the direction once it has gone a little way', () {
      const start = Offset(300, 600);
      final s = GuideSnapper(start, directions: perspectiveDirections(start, [const Offset(100, 200), const Offset(700, 200)]));
      final toVp = const Offset(100, 200) - start;
      final unit = toVp / toVp.distance;
      final normal = Offset(-unit.dy, unit.dx);
      // 4 units to the side at every other step: 13 degrees at the first, as the chord from the start, then less and less
      var restarted = false;
      for (var i = 1; i <= 8; i++) {
        final r = s.apply(start + unit * (17.7 * i) + normal * (i.isOdd ? 4 : -4));
        restarted = restarted || r.restart;
      }
      expect(restarted, isTrue);
      expect(s.following, isTrue);
    });

    test('a line that curves is not made straight, a line that goes another way is free, and stays free', () {
      const start = Offset(300, 600);
      final s = GuideSnapper(start, directions: perspectiveDirections(start, [const Offset(100, 200), const Offset(700, 200)]));
      // 20 degrees off every direction: left and a little up
      s.apply(const Offset(290, 598));
      expect(s.apply(const Offset(150, 560)).point, const Offset(150, 560));
      expect(s.apply(const Offset(60, 470)).point, const Offset(60, 470));
      expect(s.active, isFalse, reason: 'it went far with nothing to follow');
      // even if it later happens to point at a vanishing point
      expect(s.apply(const Offset(120, 220)).point, const Offset(120, 220));
      expect(s.following, isFalse);

      // a bow: it ends up pointing straight up, but has not gone straight
      final bow = GuideSnapper(start, directions: perspectiveDirections(start, [const Offset(100, 200)]));
      for (final p in [const Offset(340, 540), const Offset(375, 470), const Offset(370, 400), const Offset(340, 340), const Offset(290, 300)]) {
        expect(bow.apply(p).restart, isFalse);
      }
    });

    test('the vertical locks too, either way', () {
      const start = Offset(300, 600);
      final s = GuideSnapper(start, directions: perspectiveDirections(start, [const Offset(100, 200), const Offset(700, 200)]));
      s.apply(const Offset(301, 590));
      final r = s.apply(const Offset(304, 450)); // (the first of these is too near the start to decide on)
      expect(r.point.dx, 300);
      expect(r.point.dy, 450);
      final down = GuideSnapper(start, directions: perspectiveDirections(start, [const Offset(100, 200)]));
      down.apply(const Offset(299, 612));
      expect(down.apply(const Offset(296, 700)).point, const Offset(300, 700));
    });

    test('an edge wins over a direction, and with nothing near and nothing to follow nothing is done', () {
      const start = Offset(150, 272 + 4);
      final s = GuideSnapper(start, edges: ruler.edges, directions: perspectiveDirections(start, [const Offset(100, 100)]));
      expect(s.following, isTrue);
      expect(s.apply(const Offset(300, 290)).point.dy, 272);
      final none = GuideSnapper(const Offset(5, 5));
      expect(none.active, isFalse);
      expect(none.apply(const Offset(50, 50)).point, const Offset(50, 50));
    });
  });

  group('protractor and circles', () {
    test('an arc finds the nearest point of itself, and an end where the part that is not there is nearest', () {
      const half = SnapArc(Offset(100, 100), 50, math.pi, math.pi); // the upper half (y is down)
      expect(half.nearest(const Offset(100, 20)).dy, closeTo(50, 1e-9));
      expect(half.nearest(const Offset(100, 20)).dx, closeTo(100, 1e-9));
      expect(half.distanceTo(const Offset(100, 20)), closeTo(30, 1e-9));
      final below = half.nearest(const Offset(160, 200)); // in the part that is not there: the end on the right
      expect((below - const Offset(150, 100)).distance, lessThan(1e-6));
      const full = SnapArc(Offset.zero, 10, 0, 2 * math.pi);
      expect(full.nearest(const Offset(0, 30)).dy, closeTo(10, 1e-9));
      expect(full.nearest(Offset.zero), isNotNull, reason: 'the centre has no nearest point, but it is not an error');
    });

    test('a protractor has its straight side as an edge and its half circle as an arc, turned with it', () {
      final level = DrawingAid(AidKind.protractor, 0, const Offset(300, 400), length: 200);
      expect(level.edges.single.a, const Offset(100, 400));
      expect(level.edges.single.b, const Offset(500, 400));
      expect(level.arcs.single.radius, 200);
      expect(level.arcs.single.centre, const Offset(300, 400));
      expect(level.arcs.single.distanceTo(const Offset(300, 200)), closeTo(0, 1e-9), reason: 'the top of the arc');
      expect(level.arcs.single.distanceTo(const Offset(300, 600)), greaterThan(150), reason: 'nothing below the base');
      final turned = level.copyWith(angle: math.pi / 2); // a quarter turn clockwise: the arc is on the right now
      expect(turned.arcs.single.distanceTo(const Offset(500, 400)), closeTo(0, 1e-9));
      expect(turned.edges.single.a.dx, closeTo(300, 1e-9));
      expect(level.outline.first.dx, closeTo(100, 1e-9));
      expect(level.outline.every((p) => p.dy <= 400 + 1e-9), isTrue, reason: 'the half disc is above its base');
    });

    test('a line begun on the edge of a circle goes round it, wherever the pen is, and one begun away from them is free', () {
      final stencil = DrawingAid(AidKind.circles, 0, const Offset(300, 300), length: 150);
      expect(stencil.arcs.map((a) => a.radius), [150, 100, 50]);
      final snapper = GuideSnapper(const Offset(448, 300), arcs: stencil.arcs);
      expect(snapper.following, isTrue);
      for (var deg = 10; deg <= 90; deg += 10) {
        final a = deg * math.pi / 180;
        final pen = const Offset(300, 300) + Offset(math.cos(a), math.sin(a)) * (150 + (deg.isEven ? 7 : -5)); // a hand off the edge
        final point = snapper.apply(pen).point;
        expect((point - const Offset(300, 300)).distance, closeTo(150, 1e-6));
      }
      // the nearest of the three circles
      final inner = GuideSnapper(const Offset(300, 252), arcs: stencil.arcs);
      expect((inner.apply(const Offset(330, 270)).point - const Offset(300, 300)).distance, closeTo(50, 1e-6));
      final away = GuideSnapper(const Offset(300, 300), arcs: stencil.arcs); // at the centre: 50 from the inner one, more than the reach
      expect(away.active, isFalse);
    });
  });
}
