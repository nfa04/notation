import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/algebra/plot.dart';
import 'package:notes/algebra/plot_style.dart';
import 'package:notes/screens/plot_dialog.dart';

class _Pic {
  final int width, height;
  final Uint8List rgba;
  _Pic(this.width, this.height, this.rgba);

  Color at(int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(rgba[i + 3], rgba[i], rgba[i + 1], rgba[i + 2]);
  }

  /// How many pixels are close to [c] (ignoring the alpha).
  int count(Color c, {int tolerance = 40}) {
    var n = 0;
    for (var i = 0; i < rgba.length; i += 4) {
      if ((rgba[i] - (c.r * 255).round()).abs() < tolerance && (rgba[i + 1] - (c.g * 255).round()).abs() < tolerance && (rgba[i + 2] - (c.b * 255).round()).abs() < tolerance && rgba[i + 3] > 200) n++;
    }
    return n;
  }
}

Future<_Pic> _decode(Uint8List png) async {
  final image = (await (await ui.instantiateImageCodec(png)).getNextFrame()).image;
  return _Pic(image.width, image.height, (await image.toByteData())!.buffer.asUint8List());
}

Future<_Pic> _draw(String formula, PlotRange range, PlotStyle style, {Size size = const Size(300, 200)}) async =>
    _decode(await renderPlotPng(planPlot(formula)!, range, size, scale: 2, style: style));

void main() {
  group('points worth marking', () {
    const range = PlotRange(-5, 5, -6, 6);

    test('a parabola has two zeros, a low point and an intercept', () {
      final marks = plotMarks(planPlot('y = x^2 + 2x - 3')!, range);
      final zeros = marks.where((m) => m.kind == PlotMarkKind.zero).map((m) => m.at.dx).toList()..sort();
      expect(zeros.length, 2);
      expect(zeros[0], closeTo(-3, 1e-6));
      expect(zeros[1], closeTo(1, 1e-6));
      final low = marks.singleWhere((m) => m.kind == PlotMarkKind.minimum);
      expect(low.at.dx, closeTo(-1, 1e-4));
      expect(low.at.dy, closeTo(-4, 1e-6));
      expect(marks.singleWhere((m) => m.kind == PlotMarkKind.intercept).at, const Offset(0, -3));
      expect(marks.any((m) => m.kind == PlotMarkKind.maximum), isFalse);
    });

    test('a curve that only touches the axis still has its zero', () {
      final marks = plotMarks(planPlot('y = (x - 1.3)^2')!, range);
      expect(marks.where((m) => m.kind == PlotMarkKind.zero).single.at.dx, closeTo(1.3, 1e-4));
    });

    test('a pole is not a zero, and the top of a cliff is not a peak', () {
      final tan = plotMarks(planPlot(r'y = \tan(x)')!, const PlotRange(-2, 2, -5, 5));
      expect(tan.where((m) => m.kind == PlotMarkKind.zero).map((m) => m.at.dx.abs() < 1e-6), [true]);
      expect(plotMarks(planPlot('y = 1/x')!, range), isEmpty);
      expect(plotMarks(planPlot('y = 1/x^2')!, range), isEmpty);
    });

    test('marks outside the view are left out, and what is switched off is not looked for', () {
      expect(plotMarks(planPlot('y = x^2 - 100')!, const PlotRange(-5, 5, -6, 6)), isEmpty);
      final marks = plotMarks(planPlot('y = x^2 + 2x - 3')!, range, zeros: false, extrema: false);
      expect(marks.map((m) => m.kind), [PlotMarkKind.intercept]);
      expect(plotMarks(const PlotSpec.blank(), range), isEmpty);
    });

    test('a sine has a zero at every multiple of pi and a peak between', () {
      final marks = plotMarks(planPlot(r'y = \sin(x)')!, PlotRange(-2 * math.pi - 0.1, 2 * math.pi + 0.1, -1.5, 1.5));
      expect(marks.where((m) => m.kind == PlotMarkKind.zero).length, 5);
      expect(marks.where((m) => m.kind == PlotMarkKind.maximum).length, 2);
      expect(marks.where((m) => m.kind == PlotMarkKind.minimum).length, 2);
    });
  });

  group('the geometry of the options', () {
    test('a circle is one closed line', () {
      final lines = implicitLines(planPlot('x^2 + y^2 = 4')!, const PlotRange(-3, 3, -3, 3));
      expect(lines.length, 1);
      expect((lines.single.first - lines.single.last).distance, lessThan(0.1));
      for (final p in lines.single) {
        expect(p.distance, closeTo(2, 0.05));
      }
    });

    test('two curves stay two lines', () {
      expect(implicitLines(planPlot('x^2 - y^2 = 1')!, const PlotRange(-4, 4, -4, 4)).length, 2);
    });

    test('the slope of x^2 is 2x', () {
      final slope = slopeOf(planPlot('y = x^2')!);
      expect(slope(3), closeTo(6, 1e-5));
      expect(slope(-1.5), closeTo(-3, 1e-5));
    });

    test('ticks in multiples of pi', () {
      final s = piStep(4 * math.pi)!;
      expect((s.num, s.den), (1, 2));
      expect(s.step, closeTo(math.pi / 2, 1e-12));
      expect([for (var i = -2; i <= 3; i++) piLabel(i, 1, 2)], ['-π', '-π/2', '0', 'π/2', 'π', '3π/2']);
      expect(piLabel(2, 1, 3), '2π/3');
      expect(piLabel(-3, 2, 1), '-6π');
      expect(piStep(0.1), isNull); // far in, decimals say it better
      expect(piStep(1000 * math.pi)!.step, greaterThan(50));
    });

    test('the fine grid divides a step the way a ruler does', () {
      expect(minorDivisions(1), 5);
      expect(minorDivisions(2), 4);
      expect(minorDivisions(5), 5);
      expect(minorDivisions(0.2), 4);
      expect(minorDivisions(50), 5);
    });

    test('a formula as plain text', () {
      expect(plainFormula('y = x^2 - 1'), 'y = x^2 - 1');
      expect(plainFormula(r'y = \frac{1}{x}'), 'y = (1)/(x)');
      expect(plainFormula(r'y = \sin(x) \cdot \pi'), 'y = sin(x) · π');
      expect(plainFormula(r'y = \sqrt{x}'), 'y = √(x)');
      expect(plainFormula(r'y = e^{-x}'), 'y = e^(-x)');
    });

    test('styles compare by what they show', () {
      expect(const PlotStyle(), const PlotStyle());
      expect(const PlotStyle().copyWith(grid: PlotGrid.fine), isNot(const PlotStyle()));
      expect(const PlotStyle().copyWith(title: 'a'), const PlotStyle().copyWith(title: 'a'));
      expect(const PlotStyle().copyWith(grid: PlotGrid.fine).hashCode, const PlotStyle().copyWith(grid: PlotGrid.fine).hashCode);
    });
  });

  group('the picture', () {
    const range = PlotRange(-5, 5, -5, 5);

    test('the default look is the old one', () async {
      final pic = await _draw('y = x', range, const PlotStyle());
      expect(pic.at(40, 20), const Color(0xFFFFFFFF));
      expect(pic.count(const Color(0xFF1565C0)), greaterThan(300));
    });

    test('the colour and the page change', () async {
      final red = await _draw('y = x', range, const PlotStyle(curve: Color(0xFFC62828)));
      expect(red.count(const Color(0xFFC62828)), greaterThan(300));
      expect(red.count(const Color(0xFF1565C0)), 0);
      final dark = await _draw('y = x', range, const PlotStyle(background: PlotBackground.dark));
      expect(dark.at(40, 20).computeLuminance(), lessThan(0.05));
      final clear = await _draw('y = x', range, const PlotStyle(background: PlotBackground.transparent));
      expect(clear.at(40, 20).a, 0);
      expect(clear.count(const Color(0xFF1565C0)), greaterThan(300)); // the curve is still there
    });

    test('dashes and dots leave gaps, a thicker line more ink', () async {
      final solid = (await _draw('y = x', range, const PlotStyle())).count(const Color(0xFF1565C0));
      final dashed = (await _draw('y = x', range, const PlotStyle(line: PlotLine.dashed))).count(const Color(0xFF1565C0));
      final dotted = (await _draw('y = x', range, const PlotStyle(line: PlotLine.dotted))).count(const Color(0xFF1565C0));
      final thick = (await _draw('y = x', range, const PlotStyle(lineWidth: 5))).count(const Color(0xFF1565C0));
      expect(dashed, lessThan(solid * 0.8));
      expect(dashed, greaterThan(solid * 0.3));
      expect(dotted, lessThan(dashed));
      expect(dotted, greaterThan(20));
      expect(thick, greaterThan(solid * 1.5));
      final ring = await _draw('x^2 + y^2 = 9', range, const PlotStyle(line: PlotLine.dashed));
      final ringSolid = await _draw('x^2 + y^2 = 9', range, const PlotStyle());
      expect(ring.count(const Color(0xFF1565C0)), lessThan(ringSolid.count(const Color(0xFF1565C0)) * 0.8));
    });

    test('the area under the curve is filled', () async {
      // y = 3 on a plane from -5 to 5: the strip from the x axis up to the line
      final plain = await _draw('y = 3', range, const PlotStyle());
      final filled = await _draw('y = 3', range, const PlotStyle(fillUnder: true));
      // 600 x 400 pixels: x = 0.5 is at 330 (between grid lines), y = 1.5 is at 140 (above the axis at
      // 200, below the line at 3), y = -1.5 at 260 (not filled)
      expect(plain.at(330, 140), const Color(0xFFFFFFFF));
      expect(filled.at(330, 140), isNot(const Color(0xFFFFFFFF)));
      expect(filled.at(330, 260), const Color(0xFFFFFFFF));
    });

    test('the slope is drawn beside the curve', () async {
      final without = (await _draw('y = x^2', const PlotRange(-3, 3, -3, 9), const PlotStyle())).count(const Color(0xFF1565C0), tolerance: 90);
      final with_ = (await _draw('y = x^2', const PlotRange(-3, 3, -3, 9), const PlotStyle(derivative: true))).count(const Color(0xFF1565C0), tolerance: 90);
      expect(with_, greaterThan(without + 100));
    });

    test('marks are dots on the curve', () async {
      // y = x^2 - 4 over -5..5: a zero at x = 2 sits at pixel (420, 200) of 600 x 400; 5 pixels to its
      // left the x axis runs on, unless the white ring of the dot is there
      final plain = await _draw('y = x^2 - 4', range, const PlotStyle(markLabels: false));
      final marked = await _draw('y = x^2 - 4', range, const PlotStyle(zeros: true, markLabels: false));
      expect(plain.at(415, 200).computeLuminance(), lessThan(0.3));
      expect(marked.at(415, 200).computeLuminance(), greaterThan(0.6));
    });

    test('hidden axes and grid leave the picture bare', () async {
      const bare = PlotStyle(grid: PlotGrid.none, axes: PlotAxes.hidden, numbers: false, border: false);
      final pic = await _draw('y = 3', range, bare);
      expect(pic.count(const Color(0xFFFFFFFF), tolerance: 1), greaterThan(pic.width * pic.height * 0.97));
      expect(pic.at(300, 200), const Color(0xFFFFFFFF)); // where the x axis was
      expect(pic.at(0, 0), const Color(0xFFFFFFFF)); // no border
    });

    test('the fine grid adds lines, the arrows and ticks add ink', () async {
      int paper(_Pic p) => p.count(const Color(0xFFFFFFFF), tolerance: 1);
      expect(paper(await _draw('y = 3', range, const PlotStyle(grid: PlotGrid.fine))), lessThan(paper(await _draw('y = 3', range, const PlotStyle())) - 1000));
      const bare = PlotStyle(grid: PlotGrid.none);
      final base = paper(await _draw('y = 3', range, bare));
      expect(paper(await _draw('y = 3', range, bare.copyWith(ticks: true))), lessThan(base - 20));
      expect(paper(await _draw('y = 3', range, bare.copyWith(arrows: true))), lessThan(base - 20));
      expect(paper(await _draw('y = 3', range, bare.copyWith(title: 'A title'))), lessThan(base - 20));
    });

    test('axes at the edges move the x axis to the bottom', () async {
      const style = PlotStyle(grid: PlotGrid.none, numbers: false, names: false, axes: PlotAxes.edges, border: false);
      final pic = await _draw('y = 3', range, style);
      expect(pic.at(300, 399).computeLuminance(), lessThan(0.2)); // the x axis along the bottom
      expect(pic.at(0, 200).computeLuminance(), lessThan(0.2)); // the y axis along the left
      expect(pic.at(300, 200), const Color(0xFFFFFFFF));
    });
  });

  group('the dialog', () {
    PlotPainter painterOf(WidgetTester tester) =>
        tester.widget<CustomPaint>(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PlotPainter)).painter! as PlotPainter;

    Future<void> tap(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    testWidgets('every option changes the preview, and the picture added has them', (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Uint8List? added;
      Size? addedSize;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: PlotDialog(spec: planPlot('y = x^2 - 4')!, onAdd: (png, size) async => (added, addedSize) = (png, size))),
      ));
      expect(painterOf(tester).style, const PlotStyle());

      await tap(tester, 'plot-color-1');
      await tap(tester, 'plot-line-dashed');
      await tap(tester, 'plot-fill');
      await tap(tester, 'plot-derivative');
      await tap(tester, 'plot-zeros');
      await tap(tester, 'plot-intercept');
      await tap(tester, 'plot-extrema');
      await tap(tester, 'plot-grid-fine');
      await tap(tester, 'plot-density-dense');
      await tap(tester, 'plot-axes-edges');
      await tap(tester, 'plot-ticks');
      await tap(tester, 'plot-arrows');
      await tap(tester, 'plot-pi');
      await tap(tester, 'plot-bg-dark');
      await tap(tester, 'plot-border');
      await tester.enterText(find.byKey(const ValueKey('plot-title')), 'My curve');
      await tester.pump();
      var s = painterOf(tester).style;
      expect(s.curve, plotCurveColors[1]);
      expect((s.line, s.fillUnder, s.derivative, s.zeros, s.intercept, s.extrema), (PlotLine.dashed, true, true, true, true, true));
      expect((s.grid, s.density, s.axes, s.ticks, s.arrows, s.piLabels), (PlotGrid.fine, PlotDensity.dense, PlotAxes.edges, true, true, true));
      expect((s.background, s.border, s.title), (PlotBackground.dark, false, 'My curve'));

      await tap(tester, 'plot-title-formula');
      expect(painterOf(tester).style.title, 'y = x^2 - 4');
      await tap(tester, 'plot-fill'); // and off again
      expect(painterOf(tester).style.fillUnder, isFalse);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('add-plot')));
        for (var i = 0; i < 40 && added == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      expect(added, isNotNull);
      final pic = await tester.runAsync(() => _decode(added!));
      expect(pic!.at(30, 30).computeLuminance(), lessThan(0.05)); // the dark page
      expect(addedSize, const Size(480, 360));
    });

    testWidgets('a circle stays round when the shape changes, and the scales can be made equal', (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Size? addedSize;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: PlotDialog(spec: planPlot('x^2 + y^2 = 9')!, onAdd: (png, size) async => addedSize = size)),
      ));
      double stretch(PlotRange r, Size s) => (r.height / r.width) / (s.height / s.width);
      var r = painterOf(tester).range;
      final start = stretch(r, const Size(480, 360));
      await tap(tester, 'plot-shape-Square');
      r = painterOf(tester).range;
      expect(stretch(r, const Size(420, 420)), closeTo(start, 1e-9));
      await tap(tester, 'plot-equal');
      r = painterOf(tester).range;
      expect(r.width, closeTo(r.height, 1e-9)); // a square shape with equal scales
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('add-plot')));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      expect(addedSize, const Size(420, 420));
    });

    testWidgets('a function offers marks and fills, an implicit curve and an empty plot do not', (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PlotDialog(spec: planPlot('x^2 + y^2 = 9')!))));
      expect(find.byKey(const ValueKey('plot-fill')), findsNothing);
      expect(find.byKey(const ValueKey('plot-zeros')), findsNothing);
      expect(find.byKey(const ValueKey('plot-line-dashed')), findsOneWidget);
      expect(find.byKey(const ValueKey('add-plot')), findsNothing);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: EmptyPlotDialog(onAdd: (_, _) async {}))));
      expect(find.byKey(const ValueKey('plot-color-0')), findsNothing);
      expect(find.byKey(const ValueKey('plot-grid-fine')), findsOneWidget);
    });

    testWidgets('a phone-sized screen holds the dialog without overflowing', (tester) async {
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PlotDialog(spec: planPlot('y = x^2')!, onAdd: (_, _) async {}))));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-plot')), findsOneWidget);
      await tap(tester, 'plot-bg-dark');
      expect(painterOf(tester).style.background, PlotBackground.dark);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: EmptyPlotDialog(onAdd: (_, _) async {}))));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('plot-place')), findsOneWidget);
    });

    testWidgets('a landscape phone still shows the preview and the buttons', (tester) async {
      tester.view.physicalSize = const Size(800, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PlotDialog(spec: planPlot('y = x^2')!, onAdd: (_, _) async {}))));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('plot-area')), findsOneWidget);
      expect(find.byKey(const ValueKey('add-plot')), findsOneWidget);
    });
  });
}
