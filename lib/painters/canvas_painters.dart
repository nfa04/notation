import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui show Image;
import 'dart:ui' show Picture, PictureRecorder, PointMode;

import 'package:flutter/material.dart';
import '../models/brush.dart';
import '../models/pdf_models.dart';
import '../models/canvas_models.dart';
import '../models/canvas_view.dart';
import '../models/layers.dart';
import '../models/page_background.dart';
import '../models/stroke_label.dart';
import 'soft_strokes.dart';

class HighlightsPainter extends CustomPainter {
  final List<PdfHighlight> highlights;

  HighlightsPainter({required this.highlights});

  @override
  void paint(Canvas canvas, Size size) {
    for (final h in highlights) {
      final paint = Paint()
        ..color = h.color
        ..style = PaintingStyle.fill;
      canvas.drawRect(h.rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant HighlightsPainter oldDelegate) => true;
}

final Expando<(int, Path)> _paths = Expando('stroke paths');

/// The line of [stroke] as a path through its points. Made once for a line and kept while the line stays as it is.
Path strokePath(DrawingStroke stroke) {
  final key = stroke.stamp;
  final kept = _paths[stroke];
  if (kept != null && kept.$1 == key) return kept.$2;
  final path = Path()..addPolygon(stroke.points, false);
  _paths[stroke] = (key, path);
  return path;
}

/// The pieces of [path] that are drawn when the line is [dash]ed or dotted ([width] thick); the whole path for a solid line.
Path dashed(Path path, StrokeDash dash, double width) {
  if (dash == StrokeDash.solid) return path;
  final on = dash == StrokeDash.dashed ? math.max(8.0, width * 3.5) : 0.1;
  final off = dash == StrokeDash.dashed ? math.max(6.0, width * 2.5) : math.max(5.0, width * 2.2);
  final out = Path();
  for (final metric in path.computeMetrics()) {
    for (var d = 0.0; d < metric.length; d += on + off) {
      out.addPath(metric.extractPath(d, math.min(d + on, metric.length)), Offset.zero);
    }
  }
  return out;
}

final Expando<(int, BrushShape?)> _shapes = Expando('brush shapes');

/// What the brush of [stroke] makes of it, kept while the line stays as it is; null for the pen, and for a brush that is not
/// here (the line is drawn as the pen draws it).
BrushShape? brushShape(DrawingStroke stroke) {
  final brush = Brushes.byId(stroke.brush);
  if (brush == null || brush.id == penBrushId) return null;
  final key = Object.hash(stroke.stamp, identityHashCode(brush));
  final kept = _shapes[stroke];
  if (kept != null && kept.$1 == key) return kept.$2;
  final shape = brush.shape(stroke);
  _shapes[stroke] = (key, shape);
  return shape;
}

final Expando<(int, Path)> _outlines = Expando('pressure outlines');

/// The shape of a line drawn with pressure: a filled outline, thicker where the pen pressed harder. [sensitivity] says how much
/// the pressure matters. The outline is made once for a line and kept while the line stays as it is.
Path pressureOutline(DrawingStroke stroke, double sensitivity) {
  final key = Object.hash(stroke.stamp, sensitivity);
  final kept = _outlines[stroke];
  if (kept != null && kept.$1 == key) return kept.$2;
  final path = ribbonOutline(
    stroke.points,
    pressureHalfWidths(stroke, sensitivity),
  ).path;
  _outlines[stroke] = (key, path);
  return path;
}

class UnifiedInkPainter extends CustomPainter {
  final List<DrawingStroke> strokes;

  /// How much pressure matters to the thickness of lines drawn with a pressure-sensitive pen.
  final double pressureSensitivity;

  /// The layers the lines are on, if the note has more than one (hidden layers are left out, and see-through ones drawn so).
  final LayerStack? layers;

  /// Only the lines of the layers at these places in the stack; null: all.
  final Set<int>? only;

  UnifiedInkPainter({required this.strokes, this.pressureSensitivity = 0.6, this.layers, this.only});

  @override
  void paint(Canvas canvas, Size size) => paintLayered(canvas, strokes, pressureSensitivity, layers, only: only);

  @override
  bool shouldRepaint(covariant UnifiedInkPainter oldDelegate) => true;
}

/// Draws [strokes] on their [layers]: the bottom layer first, a hidden layer not at all, and a layer with a way of its own (see-through,
/// laid over the others by a blend mode, clipped to the layer below, or a group of layers) as a whole. With no layers, or only the
/// plain one, it is [paintStrokes].
///
/// A layer that is clipped shows only where the layer below it (the next one that is not clipped, in the same group) has drawn; a layer
/// whose base is not among the drawn layers ([only]) is not clipped. A blend mode acts on what is drawn under the layer in this same
/// picture (the other layers' lines), not on pictures or the paper, which lie in layers of their own.
void paintLayered(Canvas canvas, Iterable<DrawingStroke> strokes, double pressureSensitivity, LayerStack? layers, {DrawingStroke? skip, Set<int>? only}) {
  if (layers == null || layers.isPlain) return paintStrokes(canvas, strokes, pressureSensitivity, skip: skip);
  final buckets = [for (final _ in layers.layers) <DrawingStroke>[]];
  for (final s in strokes) {
    buckets[layers.indexOf(s.layer)].add(s);
  }
  // whether the layer at [i] is among those drawn here, and whether anything of it (a group: of its layers) is
  bool included(int i) => layers.layers[i].isGroup || only == null || only.contains(i);
  bool hasInk(int i) {
    if (!layers.isShown(i) || !included(i)) return false;
    final l = layers.layers[i];
    return l.isGroup ? layers.membersOf(l.id).any(hasInk) : buckets[i].isNotEmpty;
  }

  void content(int i) {
    final l = layers.layers[i];
    if (l.isGroup) {
      series(layers.membersOf(l.id), content: content, included: included, hasInk: hasInk, layers: layers, canvas: canvas);
    } else {
      paintStrokes(canvas, buckets[i], pressureSensitivity, skip: skip);
    }
  }

  series(layers.topLevel, content: content, included: included, hasInk: hasInk, layers: layers, canvas: canvas);
}

/// The layers at [places] (one level of the stack, bottom first) drawn in order, each with its opacity and blend, a clipped one inside
/// the group of the layer it is clipped to.
void series(List<int> places, {required void Function(int) content, required bool Function(int) included, required bool Function(int) hasInk, required LayerStack layers, required Canvas canvas}) {
  Paint paintOf(NoteLayer l) => Paint()
    ..color = Color.fromRGBO(255, 255, 255, l.opacity)
    ..blendMode = l.blend.mode;
  bool plainLayer(NoteLayer l) => l.opacity >= 1 && l.blend == LayerBlend.normal;
  void node(int i) {
    final l = layers.layers[i];
    if (plainLayer(l)) return content(i);
    canvas.saveLayer(null, paintOf(l));
    content(i);
    canvas.restore();
  }

  // (a layer whose base is hidden or has nothing on it shows nothing; one whose base is not drawn here is not clipped)
  final here = [for (final i in places) if (included(i)) i];
  for (var k = 0; k < here.length; k++) {
    final base = here[k];
    final clipped = <int>[];
    while (k + 1 < here.length && layers.layers[here[k + 1]].clip) {
      clipped.add(here[++k]);
    }
    if (!hasInk(base)) continue;
    if (clipped.isEmpty) {
      node(base);
      continue;
    }
    final b = layers.layers[base];
    canvas.saveLayer(null, plainLayer(b) ? Paint() : paintOf(b));
    content(base);
    for (final c in clipped.where(hasInk)) {
      final l = layers.layers[c];
      canvas.saveLayer(null, plainLayer(l) ? Paint() : paintOf(l));
      content(c);
      canvas.saveLayer(null, Paint()..blendMode = BlendMode.dstIn); // (only where the base is)
      content(base);
      canvas.restore();
      canvas.restore();
    }
    canvas.restore();
  }
}

/// Draws [strokes] in order (leaving out [skip]). Lines that follow each other with the same solid, opaque look - most of
/// handwriting - go into one path and are drawn at once: a page of writing is a few draws, not thousands. (A see-through
/// line is drawn on its own, as where two of them cross must look darker.)
void paintStrokes(Canvas canvas, Iterable<DrawingStroke> strokes, double pressureSensitivity, {DrawingStroke? skip}) {
  Path? run;
  Paint? runPaint;
  Object? runLook;
  void flush() {
    if (run != null) canvas.drawPath(run!, runPaint!);
    run = null;
    runLook = null;
  }

  void draw(Path path, Paint paint, Object? look) {
    if (look != null && look == runLook) {
      run!.addPath(path, Offset.zero);
      return;
    }
    flush();
    if (look == null) {
      canvas.drawPath(path, paint);
    } else {
      run = Path()..addPath(path, Offset.zero);
      runPaint = paint;
      runLook = look;
    }
  }

  DrawingStroke? labelled; // (its text goes over it, after the lines drawn together with it are drawn)
  for (final stroke in strokes) {
    if (labelled != null) {
      flush();
      paintLabel(canvas, labelled);
      labelled = null;
    }
    if (identical(stroke, skip) || stroke.points.length < 2) continue;
    if (stroke.label != null) labelled = stroke;
    final plain = stroke.color.a >= 1 && stroke.dash == StrokeDash.solid && stroke.fill == null;
    final shape = stroke.brush == penBrushId ? null : brushShape(stroke);
    if (shape != null && (shape.next != null || shape.under.isNotEmpty)) {
      // (a shadow, a glow, an outline, or two brushes in one: drawn one after the other, never together with the lines round it)
      flush();
      paintBrushShape(canvas, stroke, shape, identityHashCode(Brushes.byId(stroke.brush)));
      continue;
    }
    if (shape != null) {
      Color shown(double opacity) => opacity >= 1 ? stroke.color : stroke.color.withValues(alpha: stroke.color.a * opacity);
      // (lines that darken what they lie on are never drawn together as one path: each is a layer of its own)
      final look = plain && shape.opacity >= 1 && shape.layers.isEmpty && !shape.multiply ? (shape.filled ? ('fill', stroke.color) : ('line', stroke.color, stroke.width)) : null;
      final soft = shape.soft;
      final blend = shape.multiply ? BlendMode.multiply : BlendMode.srcOver;
      if (soft != null) {
        flush();
        paintSoft(canvas, stroke, soft, identityHashCode(Brushes.byId(stroke.brush)));
      } else if (shape.filled) {
        draw(shape.path, Paint()..color = shown(shape.opacity)..blendMode = blend, look);
        for (final layer in shape.layers) {
          flush();
          final tint = layer.colorOf(stroke.color);
          canvas.drawPath(layer.path, Paint()..color = layer.opacity >= 1 ? tint : tint.withValues(alpha: tint.a * layer.opacity)..blendMode = blend);
        }
      } else {
        draw(
            dashed(shape.path, stroke.dash, stroke.width),
            Paint()
              ..color = shown(shape.opacity)
              ..strokeWidth = stroke.width
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round
              ..style = PaintingStyle.stroke
              ..blendMode = blend,
            look);
      }
      continue;
    }
    if (drawsWithPressure( stroke, pressureSensitivity)) {
      draw(pressureOutline(stroke, pressureSensitivity), Paint()..color = stroke.color, plain ? ('fill', stroke.color) : null);
      continue;
    }
    final path = strokePath(stroke);
    if (stroke.fill != null && stroke.isClosed) {
      flush();
      final shader = stroke.gradient?.shader(path.getBounds(), stroke.fill!);
      canvas.drawPath(path, Paint()
        ..color = stroke.fill!
        ..shader = shader
        ..style = PaintingStyle.fill);
    }
    final paint = Paint()
      ..color = stroke.color
      ..strokeWidth = stroke.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    draw(dashed(path, stroke.dash, stroke.width), paint, plain ? ('line', stroke.color, stroke.width) : null);
  }
  flush();
  if (labelled != null) paintLabel(canvas, labelled);
}

/// Draws all of [shape], which a brush made of [stroke]: what is behind the line, the line itself, its layers, and then the shape of
/// the second brush if it is a mix. Each part is drawn on its own (the lines are not merged into one path as handwriting is).
/// A shape that is drawn on a raster ([SoftLayers]) goes through [raster], the one all lines share if it is null.
void paintBrushShape(Canvas canvas, DrawingStroke stroke, BrushShape shape, int brushKey, {SoftRaster? raster}) {
  final line = shape.line ?? stroke;
  final blend = shape.multiply ? BlendMode.multiply : BlendMode.srcOver;
  Paint layerPaint(BrushLayer layer) {
    final tint = layer.colorOf(line.color);
    return Paint()
      ..color = layer.opacity >= 1 ? tint : tint.withValues(alpha: tint.a * layer.opacity)
      ..blendMode = blend;
  }

  Color shown(double opacity) => opacity >= 1 ? line.color : line.color.withValues(alpha: line.color.a * opacity);
  for (final layer in shape.under) {
    canvas.drawPath(layer.path, layerPaint(layer));
  }
  final soft = shape.soft;
  if (soft != null) {
    if (raster != null) {
      raster.paint(canvas, line, soft, brushKey);
    } else {
      paintSoft(canvas, line, soft, brushKey);
    }
  } else if (shape.filled) {
    canvas.drawPath(shape.path, Paint()..color = shown(shape.opacity)..blendMode = blend);
    for (final layer in shape.layers) {
      canvas.drawPath(layer.path, layerPaint(layer));
    }
  } else {
    canvas.drawPath(
        dashed(shape.path, line.dash, line.width),
        Paint()
          ..color = shown(shape.opacity)
          ..strokeWidth = line.width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke
          ..blendMode = blend);
  }
  final next = shape.next;
  if (next != null) paintBrushShape(canvas, stroke, next, brushKey, raster: raster);
}

/// How wide [text] is in letters of [size] in the font the labels are drawn in.
double measureLabelText(String text, double size, bool bold) {
  final painter = TextPainter(text: TextSpan(text: text, style: labelStyle(size, bold, const Color(0xFF000000))), textDirection: TextDirection.ltr)..layout();
  final w = painter.width;
  painter.dispose();
  return w;
}

/// The style the letters of a label are drawn in.
TextStyle labelStyle(double size, bool bold, Color color) => TextStyle(fontSize: size, color: color, fontWeight: bold ? FontWeight.bold : FontWeight.normal, height: 1);

final Expando<(int, List<LabelRun>)> _labelRuns = Expando('label runs');

/// The pieces of text of the label of [stroke], where they go. Made once for a line and kept while the line stays as it is.
List<LabelRun> labelRunsOf(DrawingStroke stroke) {
  final label = stroke.label;
  if (label == null) return const [];
  final key = stroke.stamp;
  final kept = _labelRuns[stroke];
  if (kept != null && kept.$1 == key) return kept.$2;
  final runs = layoutLabel(stroke.points, stroke.isClosed, stroke.width, label, measureLabelText);
  _labelRuns[stroke] = (key, runs);
  return runs;
}

/// Draws the text of the label of [stroke]: letter by letter along the line, or in lines inside the shape.
void paintLabel(Canvas canvas, DrawingStroke stroke) {
  final label = stroke.label;
  if (label == null) return;
  final color = label.colorFor(stroke.color, stroke.fill);
  for (final run in labelRunsOf(stroke)) {
    final painter = TextPainter(text: TextSpan(text: run.text, style: labelStyle(run.size, label.bold, color)), textDirection: TextDirection.ltr)..layout();
    final baseline = painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    canvas.save();
    canvas.translate(run.origin.dx, run.origin.dy);
    if (run.angle != 0) canvas.rotate(run.angle);
    painter.paint(canvas, Offset(0, -baseline));
    canvas.restore();
    painter.dispose();
  }
}

/// A picture of the lines of a page, as they were when [key] was taken, and the pictures of the chunks it is made of, by their keys.
typedef _InkPicture = ({int key, Picture picture, Map<int, Picture> chunks});

/// A run of lines that follow each other in the order they are drawn, with a key that changes when one of them does.
typedef _InkChunk = ({int key, List<DrawingStroke> strokes});

final Expando<Map<int, _InkPicture>> _pictures = Expando('ink pictures');

/// The lines of a page as pixels, [scale] screen pixels to a unit: what [InkLayerPainter] shows of a page with very many lines.
class _InkPixels {
  final int key;
  final double scale;
  final ui.Image image;

  /// Where it is kept, under [place].
  final Map<int, _InkPixels> slot;
  final int place;
  _InkPixels(this.key, this.scale, this.image, this.slot, this.place);

  void forget() {
    if (identical(slot[place], this)) slot.remove(place);
    _pixelsKept.remove(this);
    image.dispose();
  }
}

final Expando<Map<int, _InkPixels>> _pixels = Expando('ink pixels');

/// Those there are, the last made last: each is the size of the page on the screen, so only as many are kept as can be on the screen.
final _pixelsKept = <_InkPixels>[];
const _pixelsMost = 4, _pixelsLargest = 4096;

/// Tells that some page has its pixels now.
final _pixelsReady = ValueNotifier<int>(0);

/// The pages that wait to be made into pixels.
final _pixelsWaiting = <(int, int), Timer>{};

/// The finished lines of a page, kept as a picture that is made again only when one of them changed - not while another
/// one is being drawn over them ([skip], drawn by an [ActiveInkPainter] above). The picture is made of chunks of lines that
/// follow each other, each a picture of its own: a line added, changed or erased makes only its chunk again, not the page.
/// Put it in a RepaintBoundary of its own.
class InkLayerPainter extends CustomPainter {
  final List<DrawingStroke> strokes;
  final DrawingStroke? skip;
  final double pressureSensitivity;

  /// The layers the lines are on; null or plain for a note with one layer.
  final LayerStack? layers;

  /// Only the lines of the layers at these places in the stack (a page whose layers lie between its pictures and boxes has a painter
  /// for each run of them); null: all.
  final Set<int>? only;

  /// How many screen pixels a unit of the page is, if the page keeps its size on the screen while it is not being zoomed. A page with
  /// [pixelsFrom] lines or more is then shown as pixels once it is at rest: a kept picture is still drawn line by line for every frame
  /// (nothing keeps what is in a RepaintBoundary as pixels with Impeller), which with so many lines makes writing on it stutter.
  final double? pixelScale;

  /// From how many lines on a page is shown as pixels: below it the lines are drawn in less than a frame takes.
  static const pixelsFrom = 1500;

  late final List<_InkChunk> _chunks;
  late final int _key;

  InkLayerPainter({required this.strokes, this.skip, this.pressureSensitivity = 0.6, this.layers, this.only, this.pixelScale}) : super(repaint: pixelScale == null ? null : _pixelsReady) {
    _chunks = _chunksOf(_order(strokes, skip, layers, only), pressureSensitivity, layers, only);
    _key = Object.hashAll([for (final c in _chunks) c.key]);
  }

  /// The lines that are drawn here, in the order they are drawn in: those of the shown layers, the bottom layer's first.
  static List<DrawingStroke> _order(List<DrawingStroke> strokes, DrawingStroke? skip, LayerStack? layers, Set<int>? only) {
    final others = [for (final s in strokes) if (!identical(s, skip)) s];
    return layers == null || layers.isPlain ? others : layers.ordered(others, only: only);
  }

  /// About how many lines a chunk holds, and the most it may.
  static const _chunkMask = 127, _chunkMost = 512;

  /// [drawn] in chunks. A chunk ends after a line picked by the line itself (its identity), not by its place: erasing or adding a
  /// line changes its own chunk and leaves where the others begin and end as they were.
  /// (the line being drawn counts for nothing, so that putting the pen down changes nothing here)
  static List<_InkChunk> _chunksOf(List<DrawingStroke> drawn, double sensitivity, LayerStack? layers, Set<int>? only) {
    final seed = Object.hash(sensitivity, Brushes.revision, layers?.fingerprint, only == null ? null : Object.hashAllUnordered(only));
    final chunks = <_InkChunk>[];
    var from = 0, h = seed;
    for (var i = 0; i < drawn.length; i++) {
      final s = drawn[i];
      h = Object.hash(h, identityHashCode(s), s.stamp);
      if (identityHashCode(s) & _chunkMask == _chunkMask || i + 1 - from >= _chunkMost || i + 1 == drawn.length) {
        chunks.add((key: Object.hash(h, i + 1 - from), strokes: drawn.sublist(from, i + 1)));
        from = i + 1;
        h = seed;
      }
    }
    return chunks;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final only = this.only;
    final slot = _pictures[strokes] ??= {};
    final place = only == null ? 0 : Object.hashAllUnordered(only);
    var kept = slot[place];
    if (kept == null || kept.key != _key) {
      final recorder = PictureRecorder();
      final c = Canvas(recorder);
      final chunks = <int, Picture>{};
      if (layers != null && !layers!.isPlain && layers!.composes) {
        // (a see-through layer is drawn as a whole: it cannot be made of chunks of lines from the layers below and above it)
        paintLayered(c, [for (final s in strokes) if (!identical(s, skip)) s], pressureSensitivity, layers, only: only);
      } else {
        for (final chunk in _chunks) {
          final picture = chunks[chunk.key] ??= kept?.chunks[chunk.key] ??
              () {
                final r = PictureRecorder();
                paintStrokes(Canvas(r), chunk.strokes, pressureSensitivity);
                return r.endRecording();
              }();
          c.drawPicture(picture);
        }
      }
      // (the pictures it replaces are left to be collected: the last frame may still show them)
      kept = slot[place] = (key: _key, picture: recorder.endRecording(), chunks: chunks);
    }
    final scale = pixelScale;
    if (scale == null || strokes.length < pixelsFrom) return canvas.drawPicture(kept.picture);
    final pixels = _pixels[strokes]?[place];
    if (pixels != null && pixels.key == _key && pixels.scale == scale) {
      // (one pixel of it to one of the screen: nothing to smooth, and it stays as sharp as the lines)
      final w = pixels.image.width, h = pixels.image.height;
      canvas.drawImageRect(pixels.image, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Rect.fromLTWH(0, 0, w / scale, h / scale), Paint()..filterQuality = FilterQuality.none);
      return;
    }
    canvas.drawPicture(kept.picture);
    _pixelsSoon(place, kept.picture, size, scale);
  }

  /// Makes the page into pixels a moment after it was last painted differently (not during a zoom, which paints it every frame).
  void _pixelsSoon(int place, Picture picture, Size size, double scale) {
    final key = _key, list = strokes;
    final w = (size.width * scale).ceil(), h = (size.height * scale).ceil();
    if (w <= 0 || h <= 0 || w > _pixelsLargest || h > _pixelsLargest) return; // (an infinite canvas: far too big for this)
    final job = (identityHashCode(list), place);
    _pixelsWaiting.remove(job)?.cancel();
    _pixelsWaiting[job] = Timer(const Duration(milliseconds: 150), () async {
      _pixelsWaiting.remove(job);
      final recorder = PictureRecorder();
      Canvas(recorder)
        ..scale(scale)
        ..drawPicture(picture);
      final scaled = recorder.endRecording();
      try {
        final image = await scaled.toImage(w, h);
        if (_pictures[list]?[place]?.key != key) return image.dispose(); // (it changed meanwhile)
        final slot = _pixels[list] ??= {};
        slot[place]?.forget();
        final made = _InkPixels(key, scale, image, slot, place);
        slot[place] = made;
        _pixelsKept.add(made);
        while (_pixelsKept.length > _pixelsMost) {
          _pixelsKept.first.forget();
        }
        _pixelsReady.value++;
      } catch (e) {
        debugPrint('the lines of a page could not be made into pixels: $e');
      } finally {
        scaled.dispose();
      }
    });
  }

  @override
  bool shouldRepaint(covariant InkLayerPainter old) => old._key != _key || !identical(old.strokes, strokes) || old.pixelScale != pixelScale;
}

/// The line that is being drawn now: painted again at every move of the pen through [repaint], without building anything.
class ActiveInkPainter extends CustomPainter {
  final DrawingStroke? Function() stroke;
  final double pressureSensitivity;

  /// The lines drawn together with the one (its repeats, when drawing with symmetry).
  final List<DrawingStroke> Function()? alongside;

  ActiveInkPainter(this.stroke, {required Listenable repaint, this.pressureSensitivity = 0.6, this.alongside}) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final s = stroke();
    if (s != null) paintStrokes(canvas, [s, ...?alongside?.call()], pressureSensitivity);
  }

  @override
  bool shouldRepaint(covariant ActiveInkPainter old) => true;
}

class PageBackgroundPainter extends CustomPainter {
  final PageBackground background;

  PageBackgroundPainter(this.background);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = paperInk(background)
      ..strokeWidth = 1.0;
    for (final (from, to) in paperLines(background, size)) {
      canvas.drawLine(from, to, paint);
    }
    final dots = paperDots(background, size);
    if (dots.isNotEmpty) {
      canvas.drawPoints(
          PointMode.points,
          dots,
          Paint()
            ..color = paperDotColor
            ..strokeWidth = 2.4
            ..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(covariant PageBackgroundPainter old) => old.background != background;
}

/// The ruling of an infinite canvas. The surface is far too big to rule all of it, so only [view] is: the part of the surface that
/// is on the screen, and how many screen pixels a unit is. The lines run from the middle of the surface, and are spaced further
/// apart while zoomed out, so that they never crowd into a grey wash.
class CanvasBackgroundPainter extends CustomPainter {
  final PageBackground background;
  final ({Rect rect, double scale}) Function() view;

  CanvasBackgroundPainter(this.background, this.view, {super.repaint});

  @override
  void paint(Canvas canvas, Size size) {
    if (background == PageBackground.blank) return;
    final (:rect, :scale) = view();
    var step = paperSpacing;
    while (step * scale < 7) {
      step *= 2;
    }
    final paint = Paint()
      ..color = paperLineColor
      ..strokeWidth = math.max(1.0, 1 / scale);
    final area = rect.intersect(Offset.zero & size);
    if (area.isEmpty) return;
    double first(double from, double origin) => origin + ((from - origin) / step).ceil() * step;
    if (background == PageBackground.dots) {
      canvas.drawPoints(
          PointMode.points,
          [
            for (var y = first(area.top, canvasOrigin.dy); y <= area.bottom; y += step)
              for (var x = first(area.left, canvasOrigin.dx); x <= area.right; x += step) Offset(x, y),
          ],
          Paint()
            ..color = paperDotColor
            ..strokeWidth = math.max(2.4, 2.4 / scale)
            ..strokeCap = StrokeCap.round);
      return;
    }
    for (var y = first(area.top, canvasOrigin.dy); y <= area.bottom; y += step) {
      canvas.drawLine(Offset(area.left, y), Offset(area.right, y), paint);
    }
    if (background == PageBackground.grid) {
      for (var x = first(area.left, canvasOrigin.dx); x <= area.right; x += step) {
        canvas.drawLine(Offset(x, area.top), Offset(x, area.bottom), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CanvasBackgroundPainter old) => old.background != background;
}

/// The shape being drawn with the lasso: a dashed line that closes itself.
class LassoPainter extends CustomPainter {
  final List<Offset> points;
  final Color color;

  LassoPainter(this.points, this.color, {super.repaint});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final path = Path()..addPolygon(points, true);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.12));
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, math.min(d + 5, metric.length)), line);
      }
    }
  }

  @override
  bool shouldRepaint(covariant LassoPainter old) => true;
}
