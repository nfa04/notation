import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:pdf/pdf.dart' as pw;

import '../models/brush.dart';
import '../models/canvas_models.dart';

/// Draws the line [stroke] of a brush, whose shape is [shape], on [canvas] of a page [pageHeight] tall (the PDF counts up from the
/// bottom, the page down from the top).
///
/// The pieces of the shape go in as they are: a polygon as its corners, a circle as four curves, and a ribbon of one thickness all
/// along (the rings of an airbrush) as its line, stroked that thick with round ends and joints, which is the same shape. Nothing is
/// sampled along an outline, so the file holds about as many numbers as the shape has points. The points are rounded to hundredths
/// of the page's units, far finer than any printer shows, so each is written in a few digits.
void drawBrushOnPdf(pw.PdfGraphics canvas, double pageHeight, DrawingStroke stroke, BrushShape shape) {
  final c = stroke.color;
  final colour = pw.PdfColor(c.r, c.g, c.b);
  canvas
    ..saveContext()
    ..setFillColor(colour)
    ..setStrokeColor(colour)
    ..setLineCap(pw.PdfLineCap.round)
    ..setLineJoin(pw.PdfLineJoin.round);
  final page = _PdfPage(canvas, pageHeight);
  if (shape.filled) {
    final blend = shape.multiply ? pw.PdfBlendMode.multiply : null;
    page.fill(shape.outline, c.a * shape.opacity, blend);
    for (final layer in shape.layers) {
      // (a layer that varies the colour of the line is filled in its own colour)
      if (layer.lightness != 0 || layer.hue != 0) {
        final t = layer.colorOf(c);
        canvas.setFillColor(pw.PdfColor(t.r, t.g, t.b));
        page.fill(layer.outline, c.a * layer.opacity, blend);
        canvas.setFillColor(colour);
      } else {
        page.fill(layer.outline, c.a * layer.opacity, blend);
      }
    }
  } else {
    // (a shape to be stroked with the width of the line: no brush makes one yet)
    final alpha = c.a * shape.opacity;
    canvas
      ..setGraphicState(pw.PdfGraphicState(strokeOpacity: alpha, opacity: alpha))
      ..setLineWidth(stroke.width);
    for (final piece in shape.outline.pieces) {
      switch (piece) {
        case OutlinePolygon(:final points):
          page.polygon(points);
        case OutlineOval(:final rect):
          page.oval(rect);
        case OutlineRibbon(:final points):
          page.line(points);
      }
    }
    canvas.strokePath();
  }
  canvas.restoreContext();
}

/// How finely the width of a line drawn with pressure follows the pen in a PDF, in the units of the page.
const pressureWidthStep = 0.1;

/// Draws [stroke], a line of the pen that is [half] thick (half of it) at each point by how hard the pen pressed (see
/// `pressureHalfWidths`), on [canvas] of a page [pageHeight] tall.
///
/// An opaque line is written as its points, stroked with round ends and joints, in runs of one width: a new run begins where the
/// width has changed by [pressureWidthStep] (a segment whose ends differ by more is cut into pieces of a step). That is a few bytes
/// a point, about what a line of one width takes, and differs from the screen by about half a step (the joints of runs overlap, which an opaque
/// colour does not show). A see-through line would show those overlaps darker, so it is written as its exact outline, filled once.
void drawPressureLineOnPdf(pw.PdfGraphics canvas, double pageHeight, DrawingStroke stroke, List<double> half) {
  final c = stroke.color;
  final colour = pw.PdfColor(c.r, c.g, c.b);
  final pts = stroke.points;
  if (pts.isEmpty) return;
  canvas
    ..saveContext()
    ..setFillColor(colour)
    ..setStrokeColor(colour)
    ..setLineCap(pw.PdfLineCap.round)
    ..setLineJoin(pw.PdfLineJoin.round);
  final page = _PdfPage(canvas, pageHeight);
  if (c.a < 1) {
    page.fill(Outline.ribbon(pts, half), c.a);
  } else if (pts.length == 1) {
    canvas.setLineWidth(half.first * 2);
    page.line(pts);
    canvas.strokePath();
  } else {
    double? width;
    for (var i = 0; i < pts.length - 1; i++) {
      // (a segment whose width changes by more than a step is cut into pieces of a step each, so that the width follows it)
      final w0 = half[i] * 2, w1 = half[i + 1] * 2;
      final pieces = math.max(1, ((w1 - w0).abs() / pressureWidthStep).ceil());
      for (var j = 0; j < pieces; j++) {
        final w = math.max(1, ((w0 + (w1 - w0) * (j + 0.5) / pieces) / pressureWidthStep).round()) * pressureWidthStep;
        if (w != width) {
          if (width != null) canvas.strokePath();
          canvas.setLineWidth(w);
          width = w;
          page.moveTo(Offset.lerp(pts[i], pts[i + 1], j / pieces)!);
        }
        page.lineTo(Offset.lerp(pts[i], pts[i + 1], (j + 1) / pieces)!);
      }
    }
    canvas.strokePath();
  }
  canvas.restoreContext();
}

/// Writes the points of a page (y down) as the PDF has them (y up), in hundredths.
class _PdfPage {
  final pw.PdfGraphics canvas;
  final double height;
  _PdfPage(this.canvas, this.height);

  static double _x(double x) => (x * 100).roundToDouble() / 100;
  double _y(double y) => ((height - y) * 100).roundToDouble() / 100;

  /// Fills [outline] [opacity] opaque, all of it at once (where its pieces overlap it is no darker).
  void fill(Outline outline, double opacity, [pw.PdfBlendMode? blend]) {
    final pieces = outline.pieces;
    if (pieces.isEmpty || opacity <= 0) return;
    canvas.setGraphicState(pw.PdfGraphicState(opacity: opacity, blendMode: blend));
    // ribbons of one and the same thickness: stroked, as one path
    final even = _evenHalf(pieces);
    if (even != null) {
      canvas.setLineWidth(even * 2);
      for (final piece in pieces) {
        line((piece as OutlineRibbon).points);
      }
      canvas.strokePath();
      return;
    }
    for (final piece in pieces) {
      switch (piece) {
        case OutlinePolygon(:final points):
          polygon(points);
        case OutlineOval(:final rect):
          oval(rect);
        case OutlineRibbon():
          piece.visit((a, b, c, d) => polygon([a, b, c, d]), (centre, radius) => oval(Rect.fromCircle(center: centre, radius: radius)));
      }
    }
    canvas.fillPath();
  }

  /// The half thickness every piece shares, if all are ribbons of one thickness all along.
  static double? _evenHalf(List<OutlinePiece> pieces) {
    double? h;
    for (final piece in pieces) {
      if (piece is! OutlineRibbon || piece.points.isEmpty) return null;
      final e = piece.evenHalf;
      if (e == null || e <= 0 || (h != null && (e - h).abs() > 1e-6)) return null;
      h = e;
    }
    return h;
  }

  void moveTo(Offset p) => canvas.moveTo(_x(p.dx), _y(p.dy));

  void lineTo(Offset p) => canvas.lineTo(_x(p.dx), _y(p.dy));

  void line(List<Offset> points) {
    if (points.isEmpty) return;
    canvas.moveTo(_x(points.first.dx), _y(points.first.dy));
    // (a line of one point is a dot: the round ends of a line of no length)
    if (points.length == 1) canvas.lineTo(_x(points.first.dx), _y(points.first.dy));
    for (var i = 1; i < points.length; i++) {
      canvas.lineTo(_x(points[i].dx), _y(points[i].dy));
    }
  }

  void polygon(List<Offset> points) {
    if (points.isEmpty) return;
    line(points);
    canvas.closePath();
  }

  /// An ellipse as four curves, wound as a path's oval is (clockwise on the page), so that it adds to what it overlaps.
  void oval(Rect r) {
    const k = 0.5522847498;
    final cx = r.center.dx, cy = r.center.dy, rx = r.width / 2, ry = r.height / 2;
    canvas
      ..moveTo(_x(cx + rx), _y(cy))
      ..curveTo(_x(cx + rx), _y(cy + k * ry), _x(cx + k * rx), _y(cy + ry), _x(cx), _y(cy + ry))
      ..curveTo(_x(cx - k * rx), _y(cy + ry), _x(cx - rx), _y(cy + k * ry), _x(cx - rx), _y(cy))
      ..curveTo(_x(cx - rx), _y(cy - k * ry), _x(cx - k * rx), _y(cy - ry), _x(cx), _y(cy - ry))
      ..curveTo(_x(cx + k * rx), _y(cy - ry), _x(cx + rx), _y(cy - k * ry), _x(cx + rx), _y(cy))
      ..closePath();
  }
}
