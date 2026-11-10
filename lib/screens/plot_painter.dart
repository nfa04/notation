import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../algebra/plot.dart';
import '../algebra/plot_style.dart';

/// Draws [spec] in the [style]: grid, axes with numbers, and the curve.
class PlotPainter extends CustomPainter {
  final PlotSpec spec;
  final PlotRange range;
  final PlotStyle style;

  PlotPainter(this.spec, this.range, {this.style = const PlotStyle()});

  @override
  void paint(Canvas canvas, Size size) {
    final bg = style.background;
    if (!bg.isTransparent) canvas.drawRect(Offset.zero & size, Paint()..color = bg.color);
    final k = size.width / 480; // text and lines scale with a bigger picture
    double px(double x) => (x - range.xmin) / range.width * size.width;
    double py(double y) => size.height - (y - range.ymin) / range.height * size.height;

    final gridPaint = Paint()
      ..color = bg.grid
      ..strokeWidth = k;
    final minorPaint = Paint()
      ..color = bg.grid.withValues(alpha: bg.grid.a * 0.55)
      ..strokeWidth = 0.7 * k;
    final axis = Paint()
      ..color = bg.ink
      ..strokeWidth = 1.5 * k;
    final label = TextStyle(color: bg.label, fontSize: 10 * k * style.labelScale);

    final density = style.density.factor;
    final xTarget = math.max(2, (8 * density).round()), yTarget = math.max(2, (6 * density).round());
    final pi = style.piLabels ? piStep(range.width, target: xTarget) : null;
    final xStep = pi?.step ?? niceStep(range.width, target: xTarget);
    final yStep = niceStep(range.height, target: yTarget);
    final xDiv = pi != null ? (pi.num == 1 && pi.den == 1 ? 4 : 2) : minorDivisions(xStep);
    final yDiv = minorDivisions(yStep);

    void text(String s, Offset at, {bool centerX = false, bool rightAlign = false, TextStyle? font}) {
      final tp = TextPainter(text: TextSpan(text: s, style: font ?? label), textDirection: TextDirection.ltr)..layout();
      var o = at;
      if (centerX) o = Offset(at.dx - tp.width / 2, at.dy);
      if (rightAlign) o = Offset(at.dx - tp.width, at.dy);
      tp.paint(canvas, o);
    }

    // where the axes cross: through the origin (kept on screen), or along the left and bottom edges
    final cross = style.axes == PlotAxes.cross;
    final ax = cross ? py(range.ymin <= 0 && range.ymax >= 0 ? 0 : (range.ymin > 0 ? range.ymin : range.ymax)).clamp(0.0, size.height) : size.height;
    final ay = cross ? px(range.xmin <= 0 && range.xmax >= 0 ? 0 : (range.xmin > 0 ? range.xmin : range.xmax)).clamp(0.0, size.width) : 0.0;

    if (style.grid != PlotGrid.none) {
      if (style.grid == PlotGrid.fine) {
        final mx = xStep / xDiv, my = yStep / yDiv;
        if (mx / range.width * size.width >= 5 * k) {
          for (var i = (range.xmin / mx).ceil(); i * mx <= range.xmax; i++) {
            if (i % xDiv != 0) canvas.drawLine(Offset(px(i * mx), 0), Offset(px(i * mx), size.height), minorPaint);
          }
        }
        if (my / range.height * size.height >= 5 * k) {
          for (var i = (range.ymin / my).ceil(); i * my <= range.ymax; i++) {
            if (i % yDiv != 0) canvas.drawLine(Offset(0, py(i * my)), Offset(size.width, py(i * my)), minorPaint);
          }
        }
      }
      for (var i = (range.xmin / xStep).ceil(); i * xStep <= range.xmax; i++) {
        canvas.drawLine(Offset(px(i * xStep), 0), Offset(px(i * xStep), size.height), gridPaint);
      }
      for (var i = (range.ymin / yStep).ceil(); i * yStep <= range.ymax; i++) {
        canvas.drawLine(Offset(0, py(i * yStep)), Offset(size.width, py(i * yStep)), gridPaint);
      }
    }

    final lineWidth = style.lineWidth * k;
    final curvePaint = Paint()
      ..color = style.curve
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // the area between the curve and the x axis goes under the axes
    if (style.fillUnder && !spec.isBlank && !spec.isImplicit) {
      final base = py(0).clamp(0.0, size.height);
      final fill = Paint()..color = style.curve.withValues(alpha: 0.2);
      canvas.save();
      canvas.clipRect(Offset.zero & size);
      for (final line in explicitLines(spec, range, samples: _samples(size))) {
        final path = Path()..moveTo(px(line.first.dx), base);
        for (final p in line) {
          path.lineTo(px(p.dx), py(p.dy));
        }
        canvas.drawPath(path..lineTo(px(line.last.dx), base)..close(), fill);
      }
      canvas.restore();
    }

    final axesShown = style.axes != PlotAxes.hidden;
    if (axesShown) {
      canvas.drawLine(Offset(0, ax), Offset(size.width, ax), axis);
      canvas.drawLine(Offset(ay, 0), Offset(ay, size.height), axis);
      if (style.ticks) {
        for (var i = (range.xmin / xStep).ceil(); i * xStep <= range.xmax; i++) {
          canvas.drawLine(Offset(px(i * xStep), ax - 3 * k), Offset(px(i * xStep), ax + 3 * k), axis);
        }
        for (var i = (range.ymin / yStep).ceil(); i * yStep <= range.ymax; i++) {
          canvas.drawLine(Offset(ay - 3 * k, py(i * yStep)), Offset(ay + 3 * k, py(i * yStep)), axis);
        }
      }
      if (style.arrows) {
        final head = Paint()..color = bg.ink;
        final a = 6 * k;
        canvas.drawPath(
            Path()
              ..moveTo(size.width, ax)
              ..lineTo(size.width - a * 1.6, ax - a * 0.55)
              ..lineTo(size.width - a * 1.6, ax + a * 0.55)
              ..close(),
            head);
        canvas.drawPath(
            Path()
              ..moveTo(ay, 0)
              ..lineTo(ay - a * 0.55, a * 1.6)
              ..lineTo(ay + a * 0.55, a * 1.6)
              ..close(),
            head);
      }
    }
    if (style.numbers) {
      // (where the axes cross, 0 would sit on both of them)
      for (var i = (range.xmin / xStep).ceil(); i * xStep <= range.xmax; i++) {
        if (cross && i == 0) continue;
        text(pi != null ? piLabel(i, pi.num, pi.den) : _num(i * xStep), Offset(px(i * xStep), math.min(ax + 3 * k, size.height - 14 * k * style.labelScale)), centerX: true);
      }
      for (var i = (range.ymin / yStep).ceil(); i * yStep <= range.ymax; i++) {
        if (cross && i == 0) continue;
        text(_num(i * yStep), Offset(math.max(ay - 4 * k, 28 * k * style.labelScale), py(i * yStep) - 6 * k * style.labelScale), rightAlign: true);
      }
    }
    if (style.names && axesShown) {
      final arrow = style.arrows ? 12 * k : 0.0;
      text(spec.xName, Offset(size.width - 12 * k * style.labelScale - arrow, math.max(0, ax - 16 * k * style.labelScale)));
      text(spec.yName, Offset(math.min(size.width - 12 * k, ay + 5 * k), 2 * k + arrow));
    }

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (spec.isBlank) {
      // nothing to draw: the hand does that
    } else if (spec.isImplicit) {
      _stroke(canvas, [
        for (final line in implicitLines(spec, range, columns: size.width > 700 ? 260 : 140)) _path(line, px, py),
      ], curvePaint, style.line);
    } else {
      final samples = _samples(size);
      if (style.derivative) {
        final slope = Paint()
          ..color = style.curve.withValues(alpha: 0.65)
          ..style = PaintingStyle.stroke
          ..strokeWidth = lineWidth * 0.75
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        _stroke(canvas, [for (final line in curveLines(slopeOf(spec), range, samples: samples)) _path(line, px, py)], slope, PlotLine.dashed);
      }
      _stroke(canvas, [for (final line in explicitLines(spec, range, samples: samples)) _path(line, px, py)], curvePaint, style.line);
      if (style.hasMarks) {
        final marks = plotMarks(spec, range, zeros: style.zeros, intercept: style.intercept, extrema: style.extrema);
        final dot = Paint()..color = style.curve;
        final ring = Paint()
          ..color = bg.isTransparent ? Colors.white : bg.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6 * k;
        for (final m in marks) {
          final at = Offset(px(m.at.dx), py(m.at.dy));
          canvas.drawCircle(at, 3.8 * k, dot);
          canvas.drawCircle(at, 3.8 * k, ring);
        }
        if (style.markLabels && marks.length <= 8) {
          for (final m in marks) {
            final tp = TextPainter(
              text: TextSpan(text: '(${_num(m.at.dx, 3)}, ${_num(m.at.dy, 3)})', style: label.copyWith(color: bg.ink)),
              textDirection: TextDirection.ltr,
            )..layout();
            final below = m.kind == PlotMarkKind.minimum;
            final o = Offset(px(m.at.dx) - tp.width / 2, py(m.at.dy) + (below ? 6 * k : -6 * k - tp.height));
            tp.paint(canvas, Offset(o.dx.clamp(2 * k, math.max(2 * k, size.width - tp.width - 2 * k)), o.dy.clamp(2 * k, math.max(2 * k, size.height - tp.height - 2 * k))));
          }
        }
      }
    }
    canvas.restore();

    if (style.title.trim().isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(text: style.title.trim(), style: TextStyle(color: bg.ink, fontSize: 13 * k * style.labelScale, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: size.width - 24 * k);
      final at = Offset((size.width - tp.width) / 2, 6 * k);
      if (!bg.isTransparent) {
        canvas.drawRRect(RRect.fromRectAndRadius((at & tp.size).inflate(4 * k), Radius.circular(4 * k)), Paint()..color = bg.color.withValues(alpha: 0.85));
      }
      tp.paint(canvas, at);
    }
    if (style.border) {
      canvas.drawRect(
          Offset.zero & size,
          Paint()
            ..color = bg.border
            ..style = PaintingStyle.stroke);
    }
  }

  static int _samples(Size size) => size.width > 700 ? 1400 : 700;

  static Path _path(List<Offset> line, double Function(double) px, double Function(double) py) {
    final path = Path()..moveTo(px(line.first.dx), py(line.first.dy));
    for (final p in line.skip(1)) {
      path.lineTo(px(p.dx), py(p.dy));
    }
    return path;
  }

  /// [paths] with [paint], as a whole line, in dashes or in dots.
  static void _stroke(Canvas canvas, List<Path> paths, Paint paint, PlotLine line) {
    if (line == PlotLine.solid) {
      for (final p in paths) {
        canvas.drawPath(p, paint);
      }
      return;
    }
    final w = paint.strokeWidth;
    final on = line == PlotLine.dashed ? w * 4 : 0.01, off = line == PlotLine.dashed ? w * 2.5 : w * 2.4;
    final out = Path();
    for (final path in paths) {
      for (final m in path.computeMetrics()) {
        if (m.length / (on + off) > 20000) continue; // (a hair-thin line over a huge picture: not worth it)
        for (var d = 0.0; d < m.length; d += on + off) {
          out.addPath(m.extractPath(d, math.min(d + on, m.length)), Offset.zero);
        }
      }
    }
    canvas.drawPath(out, paint);
  }

  static String _num(double v, [int digits = 4]) {
    if (v.abs() >= 1e5 || (v != 0 && v.abs() < 1e-3)) return v.toStringAsExponential(0);
    final s = v.toStringAsFixed(digits);
    return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
  }

  @override
  bool shouldRepaint(PlotPainter old) => old.spec != spec || old.range != range || old.style != style;
}

/// The picture of [spec] as a PNG, [size] in logical pixels at [scale] times.
Future<Uint8List> renderPlotPng(PlotSpec spec, PlotRange range, Size size, {double scale = 3, PlotStyle style = const PlotStyle()}) async {
  final big = size * scale;
  final recorder = ui.PictureRecorder();
  PlotPainter(spec, range, style: style).paint(Canvas(recorder), big);
  final image = await recorder.endRecording().toImage(big.width.round(), big.height.round());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}
