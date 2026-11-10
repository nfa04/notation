import 'package:flutter/material.dart';

import '../models/align_snap.dart';

/// The lines that show where a moved thing lines up with the others (see `align_snap.dart`).
class AlignLinesPainter extends CustomPainter {
  final List<AlignLine> lines;
  final Color color;

  /// A strong colour, with a pale halo under it, so that the line shows on light, dark and coloured paper alike.
  static const defaultColor = Color(0xFFE6007A);

  AlignLinesPainter(this.lines, [this.color = defaultColor]);

  @override
  void paint(Canvas canvas, Size size) {
    final halo = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 4;
    final core = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    for (final paint in [halo, core]) {
      for (final l in lines) {
        canvas.drawLine(
          l.vertical ? Offset(l.at, l.from) : Offset(l.from, l.at),
          l.vertical ? Offset(l.at, l.to) : Offset(l.to, l.at),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant AlignLinesPainter old) => old.color != color || old.lines.length != lines.length || !_same(old.lines, lines);

  static bool _same(List<AlignLine> a, List<AlignLine> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
