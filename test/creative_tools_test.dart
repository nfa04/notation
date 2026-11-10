import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/models/brush.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/stabilizer.dart';
import 'package:notes/models/symmetry.dart';

DrawingStroke stroke(List<Offset> points, {String brush = penBrushId, double width = 4, List<int>? pressures}) =>
    DrawingStroke(id: 's1', color: Colors.black, width: width, points: points, brush: brush, pressures: pressures);

List<Offset> wave([int n = 40]) => [for (var i = 0; i < n; i++) Offset(10.0 + i * 5, 50 + 20 * math.sin(i / 4))];

void main() {
  group('the brushes', () {
    test('every brush that comes with the app makes a shape of a line, and has a name, an icon and a place in the list', () {
      for (final brush in Brushes.creative) {
        expect(Brushes.byId(brush.id), same(brush), reason: brush.id);
        expect(brush.label, isNotEmpty);
        final pr = [for (var i = 0; i < 40; i++) 60 + i * 4];
        final shape = brush.shape(stroke(wave(), brush: brush.id, pressures: pr))!;
        expect(shape.path.getBounds().isEmpty, isFalse, reason: brush.id);
        expect(shape.filled, isTrue, reason: brush.id);
        expect(shape.path.getBounds().isFinite, isTrue, reason: brush.id);
      }
      expect({for (final b in Brushes.all) b.id}.length, Brushes.all.length, reason: 'no two share an id');
    });

    test('a dot or a single point is drawn too, and an empty line is not', () {
      for (final brush in Brushes.creative) {
        expect(brush.shape(stroke([const Offset(5, 5), const Offset(5.1, 5)], brush: brush.id)), isNotNull, reason: brush.id);
        expect(brush.shape(stroke([], brush: brush.id)), isNull, reason: brush.id);
      }
    });

    test('the same line looks the same every time (the unevenness comes from the line, not from chance)', () {
      for (final brush in [Brushes.pencil, Brushes.charcoal, Brushes.watercolour]) {
        final a = brush.shape(stroke(wave(), brush: brush.id))!.path.getBounds();
        final b = brush.shape(stroke(wave(), brush: brush.id))!.path.getBounds();
        expect(a, b, reason: brush.id);
      }
    });

    test('the soft brushes paint in layers that get narrower, and are not read as handwriting', () {
      for (final brush in [Brushes.airbrush, Brushes.watercolour]) {
        final shape = brush.shape(stroke(wave(), brush: brush.id))!;
        expect(shape.layers, isNotEmpty);
        final widths = [shape.path.getBounds().height, for (final l in shape.layers) l.path.getBounds().height];
        for (var i = 1; i < widths.length; i++) {
          expect(widths[i], lessThanOrEqualTo(widths[i - 1] * 1.3), reason: '${brush.id} layer $i');
        }
        expect(brush.writing, isFalse);
        expect(Brushes.writes(brush.id), isFalse);
      }
      for (final id in [penBrushId, 'pencil', 'fountain', 'calligraphy', 'marker', 'charcoal', 'ext:somebody/unknown']) {
        expect(Brushes.writes(id), isTrue, reason: id);
      }
      expect(Brushes.writes(rollerBrushId), isFalse);
    });

    test('a fountain pen is thicker where it presses and runs out to a point; a marker stays even', () {
      final line = [for (var i = 0; i < 60; i++) Offset(10.0 + i * 4, 50)];
      final press = [for (var i = 0; i < 60; i++) i < 30 ? 40 : 250];
      final fountain = Brushes.fountain.shape(stroke(line, brush: 'fountain', pressures: press, width: 6))!.path;
      final soft = fountain.getBounds();
      bool inside(double x, double y) => fountain.contains(Offset(x, y));
      expect(inside(60, 50.5), isTrue);
      expect(inside(60, 53), isFalse, reason: 'light: thin');
      expect(inside(200, 53), isTrue, reason: 'hard: thick');
      expect(inside(10, 52), isFalse, reason: 'the start runs out to a point');
      expect(soft.height, greaterThan(8));
      final marker = Brushes.marker.shape(stroke(line, brush: 'marker', width: 6))!.path.getBounds();
      expect(marker.height, closeTo(6, 1));
    });

    test('a calligraphy nib is thick across and thin along', () {
      // the nib is held at 40 degrees: a line drawn along it is thin, one drawn across it is as thick as the nib is wide
      Offset dir(double degrees) => Offset(math.cos(degrees * math.pi / 180), math.sin(degrees * math.pi / 180));
      const from = Offset(100, 100);
      double thickness(double degrees) {
        final line = [for (var i = 0; i <= 20; i++) from + dir(degrees) * (i * 5.0)];
        final path = Brushes.calligraphy.shape(stroke(line, brush: 'calligraphy', width: 4))!.path;
        final side = Offset(-dir(degrees).dy, dir(degrees).dx);
        final middle = from + dir(degrees) * 50;
        var t = 0.0;
        while (t < 20 && path.contains(middle + side * t)) {
          t += 0.25;
        }
        return t * 2;
      }

      expect(thickness(130), greaterThan(thickness(40) * 3));
    });

    test('the brushes that come with the app cannot be taken away, those of extensions can', () {
      Brushes.unregister('pencil');
      expect(Brushes.byId('pencil'), isNotNull);
      Brushes.register(const ParamBrush('ext:t/felt', 'Felt', BrushParams()));
      expect(Brushes.byId('ext:t/felt'), isNotNull);
      Brushes.unregister('ext:t/felt');
      expect(Brushes.byId('ext:t/felt'), isNull);
    });
  });

  group('the line stabiliser', () {
    test('with no strength the line is the pen', () {
      final s = LineStabiliser(0)..start(const Offset(0, 0));
      expect(s.active, isFalse);
      expect(s.follow(const Offset(3, 1)), const Offset(3, 1));
      expect(s.finish(const Offset(9, 9)), isEmpty);
    });

    test('small wobbles inside the string do not move the line, and a pull does, trailing the pen', () {
      final s = LineStabiliser(1)..start(const Offset(0, 0));
      expect(s.follow(const Offset(5, 3)), isNull);
      expect(s.follow(const Offset(-6, 4)), isNull);
      Offset? last;
      for (var x = 0.0; x <= 200; x += 4) {
        last = s.follow(Offset(x, 0)) ?? last;
      }
      expect(last, isNotNull);
      expect(last!.dx, lessThan(200));
      expect(last.dx, greaterThan(200 - LineStabiliser.longest - 1));
    });

    test('a shaky straight pull gives a straighter line than the pen did', () {
      final rng = math.Random(7);
      final pen = [for (var x = 0.0; x <= 300; x += 3) Offset(x, 40 + (rng.nextDouble() - 0.5) * 8)];
      final s = LineStabiliser(0.8)..start(pen.first);
      final out = [pen.first];
      for (final p in pen.skip(1)) {
        final q = s.follow(p);
        if (q != null) out.add(q);
      }
      out.addAll(s.finish(pen.last));
      double spread(List<Offset> l) {
        final ys = [for (final p in l) p.dy];
        final mean = ys.reduce((a, b) => a + b) / ys.length;
        return ys.map((y) => (y - mean) * (y - mean)).reduce((a, b) => a + b) / ys.length;
      }
      expect(spread(out), lessThan(spread(pen) / 3));
      expect(out.last, pen.last, reason: 'it ends where the pen was lifted');
    });

    test('finishing brings the line to the pen in small steps, and does nothing when it is there', () {
      final s = LineStabiliser(1)..start(const Offset(0, 0));
      final steps = s.finish(const Offset(60, 0));
      expect(steps.last, const Offset(60, 0));
      expect(steps.length, greaterThan(3));
      expect(s.finish(const Offset(60, 0)), isEmpty);
    });
  });

  group('symmetry', () {
    const centre = Offset(100, 100);

    test('how many lines each kind makes besides the one drawn', () {
      expect(Symmetry.off.copies, 0);
      expect(const Symmetry(SymmetryKind.leftRight).copies, 1);
      expect(const Symmetry(SymmetryKind.upDown).copies, 1);
      expect(const Symmetry(SymmetryKind.both).copies, 3);
      expect(const Symmetry(SymmetryKind.radial, turns: 6).copies, 5);
      expect(const Symmetry(SymmetryKind.kaleidoscope, turns: 4).copies, 7);
      for (final k in SymmetryKind.values) {
        for (final n in [Symmetry.fewest, 5, Symmetry.most]) {
          expect(Symmetry(k, turns: n).transforms(centre).length, Symmetry(k, turns: n).copies, reason: '$k $n');
        }
      }
    });

    test('turns stay between the fewest and the most', () {
      expect(const Symmetry(SymmetryKind.radial).withTurns(1).turns, Symmetry.fewest);
      expect(const Symmetry(SymmetryKind.radial).withTurns(99).turns, Symmetry.most);
      expect(const Symmetry(SymmetryKind.radial, turns: 99).copies, Symmetry.most - 1);
    });

    test('mirrors flip about the centre', () {
      const p = Offset(130, 70);
      expect(const Symmetry(SymmetryKind.leftRight).transforms(centre).single(p), const Offset(70, 70));
      expect(const Symmetry(SymmetryKind.upDown).transforms(centre).single(p), const Offset(130, 130));
      expect(const Symmetry(SymmetryKind.both).transforms(centre).map((t) => t(p)), [const Offset(70, 70), const Offset(130, 130), const Offset(70, 130)]);
    });

    test('turns keep the distance to the centre and are spread evenly', () {
      const p = Offset(150, 100);
      final out = [for (final t in const Symmetry(SymmetryKind.radial, turns: 4).transforms(centre)) t(p)];
      for (final q in out) {
        expect((q - centre).distance, closeTo(50, 1e-9));
      }
      expect(out[0].dx, closeTo(100, 1e-9));
      expect(out[0].dy, closeTo(150, 1e-9));
      expect(out[1].dx, closeTo(50, 1e-9));
      expect(out[2].dy, closeTo(50, 1e-9));
    });

    test('a kaleidoscope has a mirror image in every turn, and none of the copies is the line itself', () {
      const p = Offset(130, 80);
      final all = [for (final t in const Symmetry(SymmetryKind.kaleidoscope, turns: 5).transforms(centre)) t(p)];
      for (final q in all) {
        expect((q - centre).distance, closeTo((p - centre).distance, 1e-9));
        expect((q - p).distance, greaterThan(1e-6));
      }
      expect(all.toSet().length, all.length);
    });

    test('the guides are as many as the lines a kind makes them with', () {
      expect(Symmetry.off.guides(centre, const Size(200, 200)), isEmpty);
      expect(const Symmetry(SymmetryKind.both).guides(centre, const Size(200, 200)).length, 2);
      expect(const Symmetry(SymmetryKind.radial, turns: 7).guides(centre, const Size(200, 200)).length, 7);
    });
  });
}
