import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/models/shape_snap.dart';
import 'package:notes/models/shapes.dart';
import 'package:notes/models/straighten.dart';

/// [outline] drawn by a hand: points along it with some shake, started and ended a little off, as hands do.
List<Offset> byHand(List<Offset> outline, {double shake = 2.5, int seed = 4, double turn = 0}) {
  final rnd = math.Random(seed);
  final c = outline.fold<Offset>(Offset.zero, (a, p) => a + p) / outline.length.toDouble();
  Offset rot(Offset p) {
    final d = p - c;
    return c + Offset(d.dx * math.cos(turn) - d.dy * math.sin(turn), d.dx * math.sin(turn) + d.dy * math.cos(turn));
  }

  return [for (final p in outline) rot(p) + Offset((rnd.nextDouble() - 0.5) * shake, (rnd.nextDouble() - 0.5) * shake)];
}

List<Offset> outlineOf(ShapeTool tool, Offset a, Offset b) => shapePoints(tool, a, b, step: 5);

void main() {
  group('a drawing very close to a shape becomes that shape', () {
    for (final tool in [ShapeTool.rectangle, ShapeTool.ellipse, ShapeTool.triangle, ShapeTool.diamond]) {
      test(tool.label, () {
        final drawn = byHand(outlineOf(tool, const Offset(100, 100), const Offset(340, 260)));
        final r = snapToShape(drawn);
        expect(r, isNotNull);
        expect(r!.tool, tool);
        // exactly the shape the tool draws between the corners of the box
        final box = (left: drawn.map((p) => p.dx).reduce(math.min), top: drawn.map((p) => p.dy).reduce(math.min), right: drawn.map((p) => p.dx).reduce(math.max), bottom: drawn.map((p) => p.dy).reduce(math.max));
        expect(r.points, shapePoints(tool, Offset(box.left, box.top), Offset(box.right, box.bottom)));
        expect((r.points.first - r.points.last).distance, lessThan(0.001)); // (closed: it can be filled)
      });
    }

    test('a rectangle that is a few degrees off, and one that does not quite close', () {
      final turned = byHand(outlineOf(ShapeTool.rectangle, const Offset(100, 100), const Offset(340, 260)), turn: 0.07);
      expect(snapToShape(turned)?.tool, ShapeTool.rectangle);
      final open = outlineOf(ShapeTool.rectangle, const Offset(100, 100), const Offset(340, 260));
      expect(snapToShape(byHand(open.sublist(0, open.length - 8)))?.tool, ShapeTool.rectangle); // (the last side stops a little short)
    });

    test('a square turned by 45 degrees is a diamond, a circle is an ellipse', () {
      final square = outlineOf(ShapeTool.rectangle, const Offset(100, 100), const Offset(260, 260));
      expect(snapToShape(byHand(square, turn: math.pi / 4))?.tool, ShapeTool.diamond);
      expect(snapToShape(byHand(outlineOf(ShapeTool.ellipse, const Offset(100, 100), const Offset(260, 260))))?.tool, ShapeTool.ellipse);
    });
  });

  group('everything else stays as drawn', () {
    test('a letter: a small circle', () {
      expect(snapToShape(byHand(outlineOf(ShapeTool.ellipse, const Offset(100, 100), const Offset(124, 124)), shake: 1)), isNull);
      expect(snapToShape(byHand(outlineOf(ShapeTool.rectangle, const Offset(100, 100), const Offset(130, 250)), shake: 1)), isNull); // (a tall thin one)
    });

    test('an open line: a "C", a wave, a spiral, a scribble', () {
      final ellipse = outlineOf(ShapeTool.ellipse, const Offset(100, 100), const Offset(300, 260));
      expect(snapToShape(byHand(ellipse.sublist(0, ellipse.length ~/ 2))), isNull); // half an ellipse
      expect(snapToShape([for (var i = 0; i < 80; i++) Offset(100 + i * 4.0, 150 + 40 * math.sin(i / 5))]), isNull);
      expect(snapToShape([for (var i = 0; i < 200; i++) Offset(200 + (10 + i * 0.5) * math.cos(i / 8), 200 + (10 + i * 0.5) * math.sin(i / 8))]), isNull);
      final rnd = math.Random(1);
      expect(snapToShape([for (var i = 0; i < 200; i++) Offset(100 + rnd.nextDouble() * 200, 100 + rnd.nextDouble() * 150)]), isNull);
    });

    test('a loop that is a blob, not a shape', () {
      // something egg- and pear-shaped, with a dent: not close enough to any of them
      final blob = [
        for (var i = 0; i <= 60; i++)
          Offset(200 + 110 * math.cos(2 * math.pi * i / 60) * (1 + 0.35 * math.sin(3 * 2 * math.pi * i / 60)), 200 + 80 * math.sin(2 * math.pi * i / 60)),
      ];
      expect(snapToShape(blob), isNull);
    });
  });

  group('shorter lines are straightened too', () {
    List<Offset> dash(double length, {double shake = 1}) {
      final rnd = math.Random(2);
      return [for (var i = 0; i <= 12; i++) Offset(100 + length * i / 12, 100) + Offset((rnd.nextDouble() - 0.5) * shake, (rnd.nextDouble() - 0.5) * shake)];
    }

    test('a dash of 24 or 12 units becomes a straight line; 4 units (a dot) are left alone', () {
      expect(straightLine(dash(24)), isNotNull);
      expect(straightLine(dash(12)), isNotNull);
      expect(straightLine(dash(4, shake: 0.2)), isNull);
    });

    test('a short curve is not made straight: the shorter, the less it may bend', () {
      List<Offset> arc(double length, double bend) => [for (var i = 0; i <= 12; i++) Offset(100 + length * i / 12, 100 - bend * math.sin(math.pi * i / 12))];
      expect(straightLine(arc(26, 4)), isNull); // (the stroke of a "(" or a "c")
      expect(straightLine(arc(26, 1)), isNotNull);
      expect(straightLine(arc(100, 4)), isNotNull); // (the same bend on a long line is the hand)
    });
  });
}
