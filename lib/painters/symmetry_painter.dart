import 'package:flutter/material.dart';

import '../models/symmetry.dart';

/// The lines a drawing is repeated about while symmetry is on: faint, so that they guide the eye and are never part of the page.
class SymmetryGuidePainter extends CustomPainter {
  final Symmetry symmetry;
  final Offset centre;
  final Color color;

  SymmetryGuidePainter(this.symmetry, this.centre, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (final (from, to) in symmetry.guides(centre, size)) {
      // dashes, so that they are not taken for a drawn line
      final length = (to - from).distance;
      if (length < 1) continue;
      final step = (to - from) / length;
      for (var d = 0.0; d < length; d += 14) {
        canvas.drawLine(from + step * d, from + step * (d + 7 > length ? length : d + 7), paint);
      }
    }
    canvas.drawCircle(centre, 3, paint);
  }

  @override
  bool shouldRepaint(covariant SymmetryGuidePainter old) => old.symmetry != symmetry || old.centre != centre || old.color != color;
}
