import 'package:flutter/rendering.dart';

import '../models/canvas_models.dart';
import '../models/layers.dart';
import 'canvas_painters.dart';

/// The lines of the pages next to the one being drawn, faint and in one colour each (earlier pages red, the next green), so that a
/// frame of an animation can be drawn by what the one before it was: an onion skin. Not part of the page: it is not drawn into
/// exports and takes no touch.
class OnionGhost {
  final List<DrawingStroke> strokes;
  final Color tint;

  /// 0 to 1: how strongly it shows.
  final double opacity;
  const OnionGhost(this.strokes, this.tint, this.opacity);
}

class OnionSkinPainter extends CustomPainter {
  /// The pages to show, the one furthest away first.
  final List<OnionGhost> ghosts;
  final LayerStack? layers;
  final double pressureSensitivity;
  late final int _key = Object.hashAll([for (final g in ghosts) Object.hash(g.tint, g.opacity, Object.hashAll([for (final s in g.strokes) s.stamp]))]);

  OnionSkinPainter(this.ghosts, {this.layers, this.pressureSensitivity = 0.6});

  @override
  void paint(Canvas canvas, Size size) {
    for (final g in ghosts) {
      // (the page drawn as it is, then all of it taken to one colour at the opacity of the ghost)
      canvas.saveLayer(null, Paint()..colorFilter = ColorFilter.mode(g.tint.withValues(alpha: g.opacity), BlendMode.srcIn));
      paintLayered(canvas, g.strokes, pressureSensitivity, layers);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant OnionSkinPainter old) => old._key != _key || old.layers != layers;
}
