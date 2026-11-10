import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/guides.dart';

/// The guides laid over a page: the lines of an overlay (thirds, golden ratio...), the spokes of a perspective drawing, and a ruler or
/// a set square. They are for the eye; the page does not have them.
class GuidesPainter extends CustomPainter {
  final GuideOverlay overlay;

  /// The vanishing points on this page, in page units (none: no perspective).
  final List<Offset> vanishing;

  /// The ruler or set square if it is on this page.
  final DrawingAid? aid;
  final Color color;
  final Color paper;

  GuidesPainter({required this.overlay, required this.vanishing, required this.aid, required this.color, required this.paper});

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (final (a, b) in overlay.lines(size)) {
      _dashed(canvas, a, b, line);
    }
    if (vanishing.isNotEmpty) {
      final spoke = Paint()
        ..color = color.withValues(alpha: 0.22)
        ..strokeWidth = 1;
      canvas.save();
      canvas.clipRect(Offset.zero & size);
      for (final (a, b) in perspectiveLines(vanishing, size)) {
        canvas.drawLine(a, b, spoke);
      }
      canvas.restore();
    }
    final aid = this.aid;
    if (aid != null) _paintAid(canvas, aid);
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    final length = (b - a).distance;
    if (length < 1) return;
    final step = (b - a) / length;
    for (var d = 0.0; d < length; d += 12) {
      canvas.drawLine(a + step * d, a + step * math.min(length, d + 6), paint);
    }
  }

  void _paintAid(Canvas canvas, DrawingAid aid) {
    final path = Path()..addPolygon(aid.outline, true);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.10));
    canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
    if (aid.kind == AidKind.protractor) return _paintProtractor(canvas, aid);
    if (aid.kind == AidKind.circles) {
      for (final a in aid.arcs.skip(1)) {
        canvas.drawCircle(a.centre, a.radius, Paint()..color = color.withValues(alpha: 0.5)..style = PaintingStyle.stroke..strokeWidth = 1);
      }
      canvas.drawLine(aid.origin - const Offset(5, 0), aid.origin + const Offset(5, 0), Paint()..color = color.withValues(alpha: 0.6));
      canvas.drawLine(aid.origin - const Offset(0, 5), aid.origin + const Offset(0, 5), Paint()..color = color.withValues(alpha: 0.6));
      return;
    }
    if (aid.kind != AidKind.ruler) return;

    // the scale along the lower edge: a tick for every millimetre, longer for half and whole centimetres, and the centimetres counted
    canvas.save();
    canvas.translate(aid.origin.dx, aid.origin.dy);
    canvas.rotate(aid.angle);
    final tick = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..strokeWidth = 1;
    const mm = GuideOverlay.centimetre / 10;
    final bottom = DrawingAid.rulerWidth / 2;
    for (var i = 0; i * mm <= aid.length; i++) {
      final x = i * mm;
      final h = i % 10 == 0 ? 14.0 : (i % 5 == 0 ? 9.0 : 5.0);
      canvas.drawLine(Offset(x, bottom), Offset(x, bottom - h), tick);
      if (i % 10 == 0 && i > 0) {
        final label = TextPainter(
          text: TextSpan(text: '${i ~/ 10}', style: TextStyle(color: color.withValues(alpha: 0.85), fontSize: 10)),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(canvas, Offset(x - label.width / 2, bottom - 15 - label.height));
      }
    }
    canvas.restore();
  }

  /// The scale of a protractor: a tick for every 5 degrees (longer for 10, longest for 30) round the arc, and the 30s counted.
  void _paintProtractor(Canvas canvas, DrawingAid aid) {
    canvas.save();
    canvas.translate(aid.origin.dx, aid.origin.dy);
    canvas.rotate(aid.angle);
    final tick = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..strokeWidth = 1;
    final r = aid.length;
    for (var deg = 0; deg <= 180; deg += 5) {
      final a = math.pi * deg / 180;
      final h = deg % 30 == 0 ? 16.0 : (deg % 10 == 0 ? 10.0 : 6.0);
      final dir = Offset(math.cos(a), -math.sin(a)); // (0 degrees on the right, up from there)
      canvas.drawLine(dir * r, dir * (r - h), tick);
      if (deg % 30 == 0) {
        final label = TextPainter(
          text: TextSpan(text: '$deg°', style: TextStyle(color: color.withValues(alpha: 0.85), fontSize: 10)),
          textDirection: TextDirection.ltr,
        )..layout();
        final at = dir * (r - 28);
        label.paint(canvas, at - Offset(label.width / 2, label.height / 2));
      }
    }
    canvas.drawLine(const Offset(0, -6), const Offset(0, 6), tick);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant GuidesPainter old) =>
      old.overlay != overlay || old.aid != aid || old.color != color || old.vanishing.length != vanishing.length || !_same(old.vanishing, vanishing);

  static bool _same(List<Offset> a, List<Offset> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
