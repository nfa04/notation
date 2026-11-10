import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/algebra/plot.dart';
import 'package:notes/screens/plot_dialog.dart';

void main() {
  group('what can be plotted', () {
    test('y = f(x) in its forms', () {
      final a = planPlot('y = x^2 - 1')!;
      expect((a.xName, a.yName, a.isImplicit), ('x', 'y', false));
      expect(a.valueAt(3), 8);
      final b = planPlot('f(x) = 2x')!;
      expect((b.xName, b.valueAt(4)), ('x', 8));
      final c = planPlot(r'\sin(t) = s');
      expect(c!.xName, 't'); // the lone letter on one side is the value
      expect(c.yName, 's');
      expect(planPlot('x^2 + 1')!.valueAt(2), 5);
      expect(planPlot('y = 3')!.valueAt(100), 3);
    });

    test('a circle is implicit', () {
      final s = planPlot('x^2 + y^2 = 4')!;
      expect(s.isImplicit, isTrue);
      expect(s.valueAt2(2, 0), 0);
    });

    test('what is not drawn', () {
      expect(planPlot('2x + 3 = 11'), isNull); // one letter, both sides: that is solving
      expect(planPlot('E = mc^2'), isNull); // three letters
      expect(planPlot('3 + 4'), isNull);
      expect(planPlot(r'\int x dx'), isNull);
      expect(planPlot(''), isNull);
    });
  });

  group('the curve', () {
    test('a parabola is one line through the right points', () {
      final s = planPlot('y = x^2')!;
      final lines = explicitLines(s, const PlotRange(-2, 2, -1, 5), samples: 4);
      expect(lines.length, 1);
      expect(lines.single, [const Offset(-2, 4), const Offset(-1, 1), const Offset(0, 0), const Offset(1, 1), const Offset(2, 4)]);
    });

    test('a pole breaks the line, a hole in the domain too', () {
      final tan = planPlot(r'y = \tan(x)')!;
      expect(explicitLines(tan, const PlotRange(-3, 3, -5, 5)).length, greaterThan(1));
      final ln = planPlot(r'y = \ln(x)')!;
      final lines = explicitLines(ln, const PlotRange(-5, 5, -3, 3));
      expect(lines.expand((l) => l).every((p) => p.dx > 0), isTrue);
    });

    test('the first view shows the shape', () {
      final r = autoRange(planPlot('y = x^2')!);
      expect(r.xmin, -10);
      expect(r.ymin, lessThanOrEqualTo(0));
      expect(r.ymax, greaterThan(50));
      final c = autoRange(planPlot('x^2 + y^2 = 9')!);
      expect(c.ymax, 5); // a circle of radius 3 fits the smallest view that shows it well
    });

    test('a circle comes out as a ring of segments', () {
      final s = planPlot('x^2 + y^2 = 4')!;
      final segs = implicitSegments(s, const PlotRange(-3, 3, -3, 3));
      expect(segs, isNotEmpty);
      for (final (a, b) in segs) {
        expect(a.distance, closeTo(2, 0.05));
        expect(b.distance, closeTo(2, 0.05));
      }
    });

    test('zooming keeps the point under the cursor', () {
      const r = PlotRange(-10, 10, -5, 5);
      final z = r.zoomed(2, 4, 1);
      expect(z.width, 10);
      expect((4 - z.xmin) / z.width, closeTo((4 - r.xmin) / r.width, 1e-9));
    });

    test('grid steps are round numbers', () {
      expect(niceStep(20), 2);
      expect(niceStep(1), 0.1);
      expect(niceStep(100), 10);
    });
  });

  testWidgets('the dialog shows the plot and adds a PNG to the page', (tester) async {
    Uint8List? added;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlotDialog(spec: planPlot('y = x^2')!, onAdd: (png, size) async => added = png),
      ),
    ));
    expect(find.text('Plot'), findsOneWidget);
    // dragging moves, wheel/pinch zoom: just make sure it does not throw
    await tester.drag(find.byKey(const ValueKey('plot-area')), const Offset(40, 10));
    await tester.pump();
    await tester.tap(find.text('Reset view'));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('add-plot')));
      for (var i = 0; i < 40 && added == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    expect(added, isNotNull);
    expect(added!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  });

  group('views at the edge of the numbers', () {
    void paint(PlotSpec spec, PlotRange range) {
      final rec = ui.PictureRecorder();
      PlotPainter(spec, range).paint(Canvas(rec), const Size(600, 400));
      rec.endRecording().dispose();
    }

    test('a function with huge values is drawn in its first view (the grid step does not overflow)', () {
      for (final f in [r'y = x^{400}', r'y = e^{e^{x}}', r'y = 10^{307} x']) {
        final spec = planPlot(f)!;
        final range = autoRange(spec);
        expect(range.usable, isTrue, reason: f);
        expect(() => paint(spec, range), returnsNormally, reason: f);
      }
      expect(niceStep(2e299, target: 6), closeTo(2e298, 1e284)); // (with pow in ints this was 0)
    });

    test('zooming stops where the numbers can no longer tell the view apart, in and out', () {
      for (final f in [r'y = \frac{1}{x}', r'x^2 + y^2 = 1', r'y = 0']) {
        final spec = planPlot(f)!;
        for (final factor in [2.0, 0.5]) {
          var range = autoRange(spec);
          for (var i = 0; i < 1200; i++) {
            range = range.zoomed(factor, range.center.dx, range.center.dy);
          }
          expect(range.usable, isTrue, reason: '$f x$factor');
          expect(() => paint(spec, range), returnsNormally, reason: '$f x$factor');
        }
      }
    });
  });
}
