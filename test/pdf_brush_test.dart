import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/export/pdf_brush.dart';
import 'package:notes/models/brush.dart';
import 'package:notes/models/brush_desc.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:pdf/pdf.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

// needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
final _pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

const _w = 300.0, _h = 160.0, _scale = 3;

DrawingStroke _stroke(Brush brush, {int n = 40}) {
  final rnd = math.Random(7);
  return DrawingStroke(
    id: 'line-${brush.id}',
    color: Colors.black,
    width: 3 * brush.widthScale,
    brush: brush.id,
    points: [for (var i = 0; i < n; i++) Offset(40.0 + i * 5.5, 80 + 35 * math.sin(i / 5))],
    pressures: [for (var i = 0; i < n; i++) 60 + rnd.nextInt(190)],
  );
}

/// How dark each pixel is (0 white, 255 black), of [paths] filled with their colours as the screen draws them.
Future<List<int>> _screen(List<(Path, Color)> paths) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..scale(_scale.toDouble())
    ..drawColor(Colors.white, BlendMode.src);
  for (final (path, colour) in paths) {
    canvas.drawPath(path, Paint()..color = colour);
  }
  final image = await recorder.endRecording().toImage((_w * _scale).round(), (_h * _scale).round());
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  image.dispose();
  return [for (var i = 0; i < bytes.length; i += 4) 255 - bytes[i + 1]];
}

/// The shape of a brush as the screen draws it where it cannot blur (its path and layers, the look a PDF has).
List<(Path, Color)> _brushPaths(DrawingStroke stroke, BrushShape shape) {
  final line = shape.line ?? stroke;
  return [
    for (final l in shape.under) (l.path, l.colorOf(line.color).withValues(alpha: line.color.a * l.opacity)),
    (shape.path, line.color.withValues(alpha: line.color.a * shape.opacity)),
    for (final l in shape.layers) (l.path, l.colorOf(line.color).withValues(alpha: line.color.a * l.opacity)),
    if (shape.next != null) ..._brushPaths(stroke, shape.next!),
  ];
}

/// The same, of what [draw] puts on a PDF page, drawn by PDFium; and how many bytes the drawing took in the file.
Future<(List<int>, int)> _pdf(void Function(pw.PdfGraphics canvas) draw) async {
  final doc = pw.PdfDocument(compress: false);
  final page = pw.PdfPage(doc, pageFormat: const pw.PdfPageFormat(_w, _h));
  final g = page.getGraphics();
  final before = (await pw.PdfDocument(compress: false).save()).length;
  draw(g);
  final bytes = await doc.save();
  final pdf = await PdfDocument.openData(bytes);
  try {
    final image = (await pdf.pages.first.render(fullWidth: _w * _scale, fullHeight: _h * _scale, backgroundColor: 0xffffffff))!;
    final px = image.pixels; // BGRA
    image.dispose();
    return ([for (var i = 0; i < px.length; i += 4) 255 - px[i + 1]], bytes.length - before);
  } finally {
    await pdf.dispose();
  }
}

/// That [pdf] shows what [screen] does: no holes, nothing missing or more, as dark, only edges smoothed a little differently.
void _expectSame(List<int> screen, List<int> pdf, String what, {double darkness = 0.03}) {
  final cols = (_w * _scale).round(), rows = (_h * _scale).round();
  // whether the picture is even around the pixel at x, y (not at an edge)
  bool flat(List<int> p, int x, int y) {
    var lo = 255, hi = 0;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final v = p[(y + dy) * cols + x + dx];
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
    return hi - lo < 24;
  }

  var ink = 0, holes = 0, darkScreen = 0, darkPdf = 0;
  for (var y = 1; y < rows - 1; y++) {
    for (var x = 1; x < cols - 1; x++) {
      final i = y * cols + x;
      darkScreen += screen[i];
      darkPdf += pdf[i];
      if (math.max(screen[i], pdf[i]) > 8) ink++;
      if ((screen[i] - pdf[i]).abs() > 48 && flat(screen, x, y) && flat(pdf, x, y)) holes++;
    }
  }
  expect(ink, greaterThan(1000), reason: '$what draws something');
  expect(holes, 0, reason: '$what: no holes, nothing missing, nothing more');
  expect(darkPdf / darkScreen, closeTo(1, darkness), reason: '$what: as dark as on the screen');
}

void main() {
  group('a shape kept as its pieces', () {
    test('its path is made from the pieces, and made again when one is added', () {
      final o = Outline()..addPolygon(const [Offset(0, 0), Offset(10, 0), Offset(10, 10)]);
      expect(o.path.getBounds(), const Rect.fromLTRB(0, 0, 10, 10));
      o.addOval(Rect.fromCircle(center: const Offset(20, 20), radius: 5));
      expect(o.path.getBounds(), const Rect.fromLTRB(0, 0, 25, 25));
      o.addOutline(Outline.ribbon(const [Offset(30, 0), Offset(40, 0)], const [2, 2]));
      expect(o.path.getBounds(), const Rect.fromLTRB(0, -2, 42, 25));
    });

    test('a ribbon knows when it is one thickness all along', () {
      expect(const OutlineRibbon([Offset.zero, Offset(5, 0)], [2, 2]).evenHalf, 2);
      expect(const OutlineRibbon([Offset.zero, Offset(5, 0)], [2, 3]).evenHalf, isNull);
    });
  });

  testWidgets('every brush looks the same in a PDF as on the screen, and takes little room there', skip: !_pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = _pdfium.absolute.path;
    await tester.runAsync(() async {
      for (final brush in [Brushes.roller, ...Brushes.creative]) {
        final stroke = _stroke(brush);
        final shape = brush.shape(stroke)!;
        final (pdf, size) = await _pdf((g) => drawBrushOnPdf(g, _h, stroke, shape));
        _expectSame(await _screen(_brushPaths(stroke, shape)), pdf, brush.id);
        // a line 215 long, uncompressed: charcoal (streaks of many widths, as quads and circles) takes about 180 KiB, the airbrush
        // about as much (it took 1.5 MiB when its outline was followed in short steps), the others far less
        expect(size, lessThan(256 * 1024), reason: '${brush.id} took $size bytes');
      }
    });
  });

  testWidgets('designed brushes of every kind, also with their numbers at the ends, look the same in a PDF as on the screen', skip: !_pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = _pdfium.absolute.path;
    final designs = [
      BrushDesc(BrushKind.ink, 'nib', const {'nibAngle': 30, 'taper': 0.8, 'jitter': 0.6, 'pressure': 0.9, 'width': 3}),
      BrushDesc(BrushKind.ink, 'plain'),
      BrushDesc(BrushKind.roller, 'dry', const {'dryness': 0.8, 'streaks': 1.5, 'ridge': 1, 'width': 8}),
      BrushDesc(BrushKind.roller, 'wet', const {'dryness': 0, 'streaks': 0, 'ridge': 0}),
      BrushDesc(BrushKind.soft, 'hard', const {'softness': 0, 'width': 4}),
      BrushDesc(BrushKind.soft, 'spray', const {'softness': 1, 'speckle': 8, 'wobble': 1, 'strength': 0.5}),
      BrushDesc(BrushKind.charcoal, 'dusty', const {'dust': 3, 'dryness': 0.8}),
      BrushDesc(BrushKind.charcoal, 'clean', const {'dust': 0, 'dryness': 0, 'body': 0.6}),
      // (what was added later: colour that varies, a blend, the ends of their own, the other numbers at the ends of their ranges)
      BrushDesc(BrushKind.ink, 'colours', const {'lightness': 1, 'hue': 60, 'width': 4, 'pressure': 0.8}),
      BrushDesc(BrushKind.ink, 'colours nib', const {'lightness': 0.6, 'hue': 30, 'nibAngle': 30, 'width': 5}),
      BrushDesc(BrushKind.ink, 'marker', const {'blend': 1, 'width': 8}),
      BrushDesc(BrushKind.ink, 'ends', const {'startTaper': 1, 'endTaper': 0, 'waver': 1, 'speedThin': 1, 'pressure': 1, 'pressureCurve': 3, 'width': 4}),
      BrushDesc(BrushKind.roller, 'roller 2', const {'streakLength': 3, 'laneWidth': 3, 'ridgeWidth': 0.4, 'blend': 1}),
      BrushDesc(BrushKind.soft, 'spray 2', const {'speckle': 8, 'speckleSize': 3, 'speckleSpread': 3, 'blur': 2}),
      BrushDesc(BrushKind.charcoal, 'charcoal 2', const {'grainSize': 3, 'runLength': 3, 'dustSpread': 3, 'dustSize': 3, 'dust': 2}),
      for (final shape in [0, 1, 2, 3, 4])
        BrushDesc(BrushKind.stamp, 'stamp $shape', {'shape': shape.toDouble(), 'width': 6, 'spacing': 0.5, 'scatter': 1, 'sizeJitter': 1, 'angleJitter': 1, 'follow': 1, 'squash': 0.5, 'lightness': 0.8, 'hue': 40}),
      // (a blend with the colour black cannot be told from none; the comparison has no blend of its own)
      BrushDesc(BrushKind.stamp, 'stamp darker', const {'blend': 1, 'opacity': 0.5}),
      BrushDesc(BrushKind.stamp, 'stamp plain'),
      // (the third batch: dashes, what is behind a line, colour along it, curves, a steady hand, stamps with the same, two brushes in one)
      BrushDesc(BrushKind.ink, 'dashes', const {'dash': 3, 'dashGap': 1.5, 'width': 3, 'pressure': 0.7}),
      BrushDesc(BrushKind.ink, 'dots', const {'dash': 1, 'dashGap': 1, 'width': 3}),
      BrushDesc(BrushKind.ink, 'dashes nib', const {'dash': 4, 'nibAngle': 30, 'width': 4}),
      BrushDesc(BrushKind.ink, 'behind', const {'shadow': 0.7, 'shadowBlur': 0.6, 'glow': 1, 'glowHue': 90, 'outline': 0.6, 'outlineTone': 2, 'width': 3}),
      BrushDesc(BrushKind.ink, 'flow', const {'gradientHue': 120, 'gradientLight': 0.3, 'rainbow': 8, 'fade': 0.7, 'pressure': 0.8, 'pressureShade': 1, 'width': 4}),
      BrushDesc(BrushKind.ink, 'flow dashed', const {'rainbow': 6, 'dash': 2, 'width': 3, 'opacity': 0.6}),
      BrushDesc(BrushKind.ink, 'curves', const {
        'pressureAt0': 0.3, 'pressureAt25': 1.9, 'pressureAt50': 0.5, 'pressureAt75': 1.5, 'pressureAt100': 0.2, //
        'speedAt0': 1.5, 'speedAt25': 1.2, 'speedAt50': 1, 'speedAt75': 0.6, 'speedAt100': 0.3, 'stabilise': 1, 'width': 3,
      }),
      BrushDesc(BrushKind.stamp, 'stamp effects', const {'shape': 3, 'width': 6, 'spacing': 0.9, 'shadow': 0.5, 'outline': 0.4, 'glow': 0.8, 'rainbow': 6, 'fade': 0.5, 'gradientHue': 80}),
      BrushDesc(BrushKind.mix, 'mix'),
      BrushDesc(BrushKind.mix, 'mix under', const {'underneath': 1, 'sizeB': 2}, [
        BrushDesc(BrushKind.ink, 'a', const {'width': 2, 'opacity': 0.6}),
        BrushDesc(BrushKind.stamp, 'b', const {'width': 3, 'shape': 3, 'spacing': 1.2, 'hue': 40}),
      ]),
    ];
    await tester.runAsync(() async {
      for (final design in designs) {
        final brush = design.build();
        final stroke = _stroke(brush);
        final shape = brush.shape(stroke)!;
        final (pdf, size) = await _pdf((g) => drawBrushOnPdf(g, _h, stroke, shape));
        // (a few dozen small dots are anti-aliased a little differently by the two renderers)
        _expectSame(await _screen(_brushPaths(stroke, shape)), pdf, design.name, darkness: design.name == 'dots' ? 0.06 : 0.03);
        expect(size, lessThan(512 * 1024), reason: '${design.name} took $size bytes');
      }
    });
  });

  testWidgets('a line of the pen is as thick in a PDF as on the screen where it pressed, and takes little more room than an even one',
      skip: !_pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = _pdfium.absolute.path;
    await tester.runAsync(() async {
      final rnd = math.Random(3);
      final smooth = [for (var i = 0; i < 80; i++) (150 + 100 * math.sin(i / 7)).round()];
      final jumpy = [for (var i = 0; i < 80; i++) 60 + rnd.nextInt(190)];
      for (final (colour, width, pressures) in [
        (Colors.black, 3.0, smooth),
        (Colors.black, 12.0, smooth),
        (Colors.black.withValues(alpha: 0.5), 6.0, smooth),
        // (a pressure that jumps from point to point: the pieces of a step are a little fuller than the screen's quads)
        (Colors.black, 3.0, jumpy),
        (Colors.black, 12.0, jumpy),
      ]) {
        final line = _stroke(Brushes.pen, n: 80);
        final stroke = DrawingStroke(id: line.id, color: colour, width: width, points: line.points, pressures: pressures);
        const sensitivity = 0.6;
        expect(drawsWithPressure(stroke, sensitivity), isTrue);
        final half = pressureHalfWidths(stroke, sensitivity);
        final what = 'a pen $width wide, opacity ${colour.a}${identical(pressures, jumpy) ? ', jumpy' : ''}';
        final (pdf, size) = await _pdf((g) => drawPressureLineOnPdf(g, _h, stroke, half));
        _expectSame(await _screen([(Outline.ribbon(stroke.points, half).path, colour)]), pdf, what,
            darkness: identical(pressures, jumpy) ? 0.05 : 0.03);
        if (colour.a >= 1 && identical(pressures, smooth)) {
          // its exact outline (quads and circles) takes about 19 KB; the runs of one width far less where the width changes slowly
          // (a thin line, 3 KB) and still less where it changes much at every point (a thick one, 10 KB). The same line of one width,
          // as it was written before, took 1.5 KB.
          final (_, outline) = await _pdf((g) => drawBrushOnPdf(g, _h, stroke, BrushShape(Outline.ribbon(stroke.points, half), filled: true)));
          expect(size, lessThan(outline * (width < 5 ? 0.25 : 0.6)), reason: '$what took $size bytes, its outline $outline');
        }
      }
    });
  });
}
