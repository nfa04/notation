import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/region_fill.dart';

DrawingStroke line(List<Offset> pts, {double width = 4}) => DrawingStroke(color: const Color(0xFF000000), width: width, points: pts);

DrawingStroke box(Rect r, {double width = 4}) => line([r.topLeft, r.topRight, r.bottomRight, r.bottomLeft, r.topLeft], width: width);

DrawingStroke circle(Offset c, double radius, {double width = 4}) =>
    line([for (var i = 0; i <= 72; i++) c + Offset(math.cos(i * 5 * math.pi / 180), math.sin(i * 5 * math.pi / 180)) * radius], width: width);

double area(List<Offset> p) {
  var s = 0.0;
  for (var i = 0; i < p.length - 1; i++) {
    s += p[i].dx * p[i + 1].dy - p[i + 1].dx * p[i].dy;
  }
  return (s / 2).abs();
}

void main() {
  test('a touch inside a box finds the box, down to the middle of its lines', () {
    final r = regionAround(const Offset(100, 100), [box(const Rect.fromLTWH(0, 0, 200, 200))]);
    final o = r.outline!;
    expect(o.first, o.last, reason: 'a closed polygon');
    expect(area(o), closeTo(200 * 200, 200 * 200 * 0.04));
    expect(pointInPolygon(const Offset(100, 100), o), isTrue);
    expect(pointInPolygon(const Offset(-20, 100), o), isFalse);
  });

  test('a ring leaves its inside empty, and a touch inside it finds only the inside', () {
    final lines = [box(const Rect.fromLTWH(0, 0, 300, 300)), circle(const Offset(150, 150), 60)];
    final ring = regionAround(const Offset(20, 20), lines).outline!;
    expect(area(ring), closeTo(300 * 300 - math.pi * 60 * 60, 2500));
    expect(pointInPolygon(const Offset(150, 150), ring), isFalse, reason: 'the hole is not filled');
    expect(pointInPolygon(const Offset(20, 20), ring), isTrue);
    final inside = regionAround(const Offset(150, 150), lines).outline!;
    expect(area(inside), closeTo(math.pi * 60 * 60, 700));
  });

  test('a shape with a gap is open until the gap closing is as big as the gap', () {
    // a box whose right side has a 10 unit gap
    final lines = [
      line([const Offset(0, 100), const Offset(0, 0), const Offset(200, 0), const Offset(200, 95)]),
      line([const Offset(200, 105), const Offset(200, 200), const Offset(0, 200), const Offset(0, 100)]),
    ];
    expect(regionAround(const Offset(100, 100), lines).problem, RegionProblem.open);
    expect(regionAround(const Offset(100, 100), lines, gap: 5).problem, RegionProblem.open);
    final r = regionAround(const Offset(100, 100), lines, gap: 14);
    expect(area(r.outline!), closeTo(200 * 200, 200 * 200 * 0.06));
  });

  test('on a page the edge of the paper closes the area; without lines or on a line there is a reason', () {
    final page = const Rect.fromLTWH(0, 0, 400, 500);
    final r = regionAround(const Offset(300, 400), [box(const Rect.fromLTWH(10, 10, 100, 100))], page: page);
    expect(area(r.outline!), closeTo(400 * 500 - 100 * 100, 4000));
    expect(regionAround(const Offset(5, 5), [], page: page).problem, RegionProblem.noLines);
    final on = regionAround(const Offset(60, 10), [box(const Rect.fromLTWH(10, 10, 100, 100), width: 40)], page: page);
    expect(on.outline, isNotNull, reason: 'a touch on a thick line takes the nearest free place');
  });

  test('a fill the bucket made is no wall; a fill with a line is', () {
    final fill = DrawingStroke(color: const Color(0x00000000), width: 1, fill: const Color(0xFFFF0000), points: [const Offset(0, 0), const Offset(200, 0), const Offset(200, 200), const Offset(0, 200), const Offset(0, 0)]);
    expect(isBucketFill(fill), isTrue);
    expect(regionAround(const Offset(100, 100), [fill]).problem, RegionProblem.noLines);
  });
}
