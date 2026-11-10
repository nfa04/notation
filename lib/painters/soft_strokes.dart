import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/brush.dart';
import '../models/canvas_models.dart';

/// Draws the soft layers of a line (see [SoftLayers]) in its colour, live: each blurred layer with a gaussian blur, then the sharp
/// ones. A blur costs a lot more than a plain fill, which is why [paintSoft] keeps a picture of a line that stays as it is.
void _drawLive(Canvas canvas, Color color, SoftLayers soft) {
  Color shown(double opacity) => color.withValues(alpha: color.a * opacity);
  final tooth = soft.grain.isEmpty ? null : _paperTooth();
  for (final l in soft.grain) {
    final paint = Paint();
    if (tooth == null) {
      paint.color = shown(l.opacity * 0.6);
    } else {
      // the pattern's own opacity is the opacity of the colour that shows where it is not empty
      paint
        ..shader = ImageShader(tooth, TileMode.repeated, TileMode.repeated, Matrix4.diagonal3Values(_toothSize, _toothSize, 1).storage, filterQuality: FilterQuality.medium)
        ..colorFilter = ColorFilter.mode(shown(l.opacity), BlendMode.srcIn);
    }
    canvas.drawPath(l.path, paint);
  }
  for (final l in soft.blurred) {
    canvas.drawPath(
      l.path,
      Paint()
        ..color = shown(l.opacity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, l.blur),
    );
  }
  for (final l in soft.crisp) {
    if (!l.path.getBounds().isEmpty) canvas.drawPath(l.path, Paint()..color = shown(l.opacity));
  }
}

/// How big a speck of the paper's grain is, in units of the page.
const double _toothSize = 0.6;
ui.Image? _tooth;
bool _toothFailed = false;

/// A square of fine specks that repeats without a seam: white noise, in a few strengths. Made once, the first time it is needed.
ui.Image? _paperTooth() {
  if (_tooth != null || _toothFailed) return _tooth;
  try {
    const side = 128;
    final rnd = math.Random(20261106);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final byStrength = [for (var i = 0; i < 4; i++) <Offset>[]];
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        final v = rnd.nextDouble();
        // about half the paper is bare, the rest takes paint in four strengths
        if (v > 0.5) byStrength[math.min(3, ((v - 0.5) * 8).floor())].add(Offset(x + 0.5, y + 0.5));
      }
    }
    for (var i = 0; i < 4; i++) {
      canvas.drawRawPoints(
        ui.PointMode.points,
        Float32List.fromList([for (final o in byStrength[i]) ...[o.dx, o.dy]]),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.4 + i * 0.2)
          ..strokeWidth = 1
          ..strokeCap = StrokeCap.square,
      );
    }
    final picture = recorder.endRecording();
    _tooth = picture.toImageSync(side, side);
    picture.dispose();
  } catch (_) {
    _toothFailed = true;
  }
  return _tooth;
}

class _Entry {
  final int key;
  int seen = 1;
  ui.Image? image;
  Rect bounds = Rect.zero;
  int bytes = 0;
  _Entry(this.key);

  void dispose() {
    image?.dispose();
    image = null;
    bytes = 0;
  }
}

/// Pictures of soft lines. The blur is the expensive part of drawing one, so a line that is the same in several frames in a row
/// is drawn once into an image (as sharp as the screen shows it now) and the image is drawn from then on. A line that changes
/// at every frame (the one being drawn) never gets an image. The images are kept in a budget of memory, the longest unused first
/// to go; with none, the line is drawn live as ever.
class SoftRaster {
  SoftRaster({this.budget = 48 * 1024 * 1024, this.entries = 400});

  final int budget;
  final int entries;
  final LinkedHashMap<DrawingStroke, _Entry> _map = LinkedHashMap<DrawingStroke, _Entry>(equals: identical, hashCode: identityHashCode);
  int _bytes = 0;

  /// Images that are kept just now, and their size (for the tests).
  int get count => _map.values.where((e) => e.image != null).length;
  int get bytes => _bytes;

  void clear() {
    for (final e in _map.values) {
      e.dispose();
    }
    _map.clear();
    _bytes = 0;
  }

  /// Draws [soft] of [stroke] on [canvas]: from an image if there is one, else live.
  void paint(Canvas canvas, DrawingStroke stroke, SoftLayers soft, int brushKey) {
    final scale = _deviceScale(canvas);
    final tier = _tier(scale);
    final key = Object.hash(stroke.stamp, brushKey, tier);
    var e = _map.remove(stroke);
    if (e == null || e.key != key) {
      if (e != null) {
        _bytes -= e.bytes;
        e.dispose();
      }
      e = _Entry(key);
    } else {
      e.seen++;
    }
    _map[stroke] = e; // (last used)
    _trim();
    if (e.image == null && e.seen >= 3) _render(e, stroke.color, soft, tier);
    final image = e.image;
    if (image == null) return _drawLive(canvas, stroke.color, soft);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      e.bounds,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  void _trim() {
    while (_map.length > entries || _bytes > budget) {
      final oldest = _map.keys.first;
      final e = _map.remove(oldest)!;
      _bytes -= e.bytes;
      e.dispose();
    }
  }

  void _render(_Entry e, Color color, SoftLayers soft, double tier) {
    try {
      final bounds = soft.bounds;
      if (bounds.isEmpty) return;
      // (a very long line gets fewer pixels for its length, rather than none)
      final scale = math.min(tier, 4096 / math.max(bounds.width, bounds.height));
      final w = (bounds.width * scale).ceil(), h = (bounds.height * scale).ceil();
      if (w < 1 || h < 1 || w * h * 4 > budget ~/ 2) return;
      final recorder = ui.PictureRecorder();
      final c = Canvas(recorder)
        ..scale(w / bounds.width, h / bounds.height)
        ..translate(-bounds.left, -bounds.top);
      _drawLive(c, color, soft);
      final picture = recorder.endRecording();
      e.image = picture.toImageSync(w, h);
      picture.dispose();
      e.bounds = bounds;
      e.bytes = w * h * 4;
      _bytes += e.bytes;
      _trim();
    } catch (_) {
      // an engine that cannot make images here: the line is drawn live
      e.image = null;
    }
  }

  /// How many pixels the screen shows for a unit of the page.
  static double _deviceScale(Canvas canvas) {
    try {
      final m = canvas.getTransform();
      return math.sqrt(m[0] * m[0] + m[1] * m[1]);
    } catch (_) {
      return 1;
    }
  }

  /// The scale pictures are made at: a power of two from a quarter to four, never less than what the screen shows, so that zooming
  /// a little does not make a new picture of every line.
  static double _tier(double scale) {
    if (scale <= 0.25) return 0.25;
    return math.min(4, math.pow(2, (math.log(scale) / math.ln2).ceil()).toDouble());
  }
}

/// The pictures [paintSoft] uses.
final SoftRaster softRaster = SoftRaster();

/// Draws the soft layers of [stroke] (see [SoftLayers]).
void paintSoft(Canvas canvas, DrawingStroke stroke, SoftLayers soft, int brushKey) => softRaster.paint(canvas, stroke, soft, brushKey);
