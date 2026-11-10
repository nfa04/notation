import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'calendar_style.dart';
import 'style_service.dart';

/// A tinted box with the border and corners of [style]: the building block
/// for every event, task and sticker the user can customise.
class StyledBox extends StatelessWidget {
  final ResolvedStyle style;
  final Widget child;
  final EdgeInsetsGeometry padding;

  /// How strong the fill is; the border always has the full colour.
  final double fillOpacity;

  const StyledBox({
    super.key,
    required this.style,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    this.fillOpacity = 0.28,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: StyledBoxPainter(
        color: style.color,
        border: style.border,
        borderWidth: style.borderWidth,
        radius: style.radius,
        fillOpacity: fillOpacity,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class StyledBoxPainter extends CustomPainter {
  final Color color;
  final BorderKind border;
  final double borderWidth;
  final double radius;
  final double fillOpacity;

  const StyledBoxPainter({
    required this.color,
    required this.border,
    required this.borderWidth,
    required this.radius,
    required this.fillOpacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // corners can never be rounder than half the box
    final r = math.min(radius, math.min(size.width, size.height) / 2);
    final outer = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(r));

    canvas.drawRRect(outer, Paint()..color = color.withValues(alpha: fillOpacity));

    final w = borderWidth;
    switch (border) {
      case BorderKind.none:
        break;
      case BorderKind.solid:
        canvas.drawRRect(
          outer.deflate(w / 2),
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = w,
        );
      case BorderKind.dashed:
        _dashed(canvas, outer.deflate(w / 2), dash: w * 3 + 3, gap: w * 2 + 2, round: false);
      case BorderKind.dotted:
        _dashed(canvas, outer.deflate(w / 2), dash: 0.1, gap: w * 2.2 + 1, round: true);
      case BorderKind.accent:
        canvas.save();
        canvas.clipRRect(outer);
        canvas.drawRect(Rect.fromLTWH(0, 0, math.max(3, w * 1.6), size.height), Paint()..color = color);
        canvas.restore();
    }
  }

  void _dashed(Canvas canvas, RRect rrect, {required double dash, required double gap, required bool round}) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..strokeCap = round ? StrokeCap.round : StrokeCap.butt;
    final path = Path()..addRRect(rrect);
    for (final ui.PathMetric metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += dash + gap) {
        canvas.drawPath(metric.extractPath(d, math.min(d + dash, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(StyledBoxPainter old) =>
      old.color != color ||
      old.border != border ||
      old.borderWidth != borderWidth ||
      old.radius != radius ||
      old.fillOpacity != fillOpacity;
}
