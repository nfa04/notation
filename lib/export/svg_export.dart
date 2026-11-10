import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Color, Offset, Rect, Size;

import '../models/brush.dart';
import '../models/canvas_models.dart';
import '../models/gradient.dart';
import '../models/layers.dart';
import '../models/page_background.dart';
import '../painters/canvas_painters.dart' show brushShape;

/// Pages as SVG: the lines stay lines (a pen line is a path with its width, a line drawn with pressure or a brush is its outline, a
/// closed shape its fill), so that a vector program opens them as shapes to edit. The layers are groups with their names (Inkscape
/// layers), with their opacity and blend mode; pictures and the text boxes (which are drawn as the editor draws them, formulas
/// included) are pictures in the file. What cannot be written as a shape - a brush that blurs, text along a line - is a picture of
/// that line. A clipped layer is not clipped here.

/// Gradients the shapes of a page use, written once into the file.
class SvgDefs {
  final StringBuffer _xml = StringBuffer();
  int _count = 0;

  /// Adds a gradient from [start] to [end] over [box]; its id.
  String gradient(FillGradient g, Color start, Rect box) {
    final id = 'grad${++_count}';
    final stops = '<stop offset="0" stop-color="${svgColor(start)}"${_opacityAttr('stop-opacity', start.a)}/><stop offset="1" stop-color="${svgColor(g.end)}"${_opacityAttr('stop-opacity', g.end.a)}/>';
    if (g.radial) {
      final c = box.center;
      final r = math.max(1.0, math.sqrt(box.width * box.width + box.height * box.height) / 2);
      _xml.write('<radialGradient id="$id" gradientUnits="userSpaceOnUse" cx="${_n(c.dx)}" cy="${_n(c.dy)}" r="${_n(r)}">$stops</radialGradient>');
    } else {
      final (from, to) = g.line(box);
      _xml.write('<linearGradient id="$id" gradientUnits="userSpaceOnUse" x1="${_n(from.dx)}" y1="${_n(from.dy)}" x2="${_n(to.dx)}" y2="${_n(to.dy)}">$stops</linearGradient>');
    }
    return id;
  }

  bool get isEmpty => _count == 0;

  @override
  String toString() => _xml.toString();
}

/// A number with at most two decimals (finer than any screen or printer shows).
String _n(num v) {
  if (v == v.roundToDouble()) return v.round().toString();
  final s = v.toStringAsFixed(2);
  return s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
}

/// `#rrggbb` (the opacity is written apart).
String svgColor(Color c) {
  String h(double v) => (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${h(c.r)}${h(c.g)}${h(c.b)}';
}

String _opacityAttr(String name, double a) => a >= 1 ? '' : ' $name="${_n(double.parse(a.toStringAsFixed(3)))}"';

/// Text safe inside an attribute or an element.
String svgEscape(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

String _blendCss(LayerBlend b) => switch (b) {
      LayerBlend.normal => 'normal',
      LayerBlend.multiply => 'multiply',
      LayerBlend.screen => 'screen',
      LayerBlend.overlay => 'overlay',
      LayerBlend.softLight => 'soft-light',
      LayerBlend.darken => 'darken',
      LayerBlend.lighten => 'lighten',
      LayerBlend.colorDodge => 'color-dodge',
      LayerBlend.colorBurn => 'color-burn',
      LayerBlend.difference => 'difference',
    };

String _poly(List<Offset> pts, {bool close = false}) {
  final b = StringBuffer();
  for (var i = 0; i < pts.length; i++) {
    b.write('${i == 0 ? 'M' : 'L'}${_n(pts[i].dx)} ${_n(pts[i].dy)}');
  }
  if (close) b.write('Z');
  return b.toString();
}

String _circle(Offset c, double r) => 'M${_n(c.dx - r)} ${_n(c.dy)}A${_n(r)} ${_n(r)} 0 1 0 ${_n(c.dx + r)} ${_n(c.dy)}A${_n(r)} ${_n(r)} 0 1 0 ${_n(c.dx - r)} ${_n(c.dy)}Z';

String _oval(Rect r) =>
    'M${_n(r.left)} ${_n(r.center.dy)}A${_n(r.width / 2)} ${_n(r.height / 2)} 0 1 0 ${_n(r.right)} ${_n(r.center.dy)}A${_n(r.width / 2)} ${_n(r.height / 2)} 0 1 0 ${_n(r.left)} ${_n(r.center.dy)}Z';

/// [outline] filled with [color] (its alpha is [opacity] times its own): polygons, ovals and ribbons that change in thickness as
/// one path, a ribbon of one thickness as its line stroked that thick (the same shape). Pieces overlap without cancelling, so the
/// whole is one group with the opacity, not a see-through piece each.
String svgOutline(Outline outline, Color color, double opacity, {bool multiply = false}) {
  final fill = StringBuffer();
  final lines = StringBuffer();
  for (final piece in outline.pieces) {
    switch (piece) {
      case OutlinePolygon(:final points):
        fill.write(_poly(points, close: true));
      case OutlineOval(:final rect):
        fill.write(_oval(rect));
      case OutlineRibbon():
        final even = piece.evenHalf;
        if (even != null) {
          if (piece.points.length == 1) {
            fill.write(_circle(piece.points.first, even));
          } else {
            lines.write('<path d="${_poly(piece.points)}" fill="none" stroke="${svgColor(color)}" stroke-width="${_n(even * 2)}" stroke-linecap="round" stroke-linejoin="round"/>');
          }
        } else {
          piece.visit((a, b, c, d) => fill.write(_poly([a, b, c, d], close: true)), (centre, radius) => fill.write(_circle(centre, radius)));
        }
    }
  }
  final body = '${fill.isEmpty ? '' : '<path d="$fill" fill="${svgColor(color)}"/>'}$lines';
  final a = color.a * opacity;
  if (a >= 1 && !multiply) return body;
  return '<g${_opacityAttr('opacity', a)}${multiply ? ' style="mix-blend-mode:multiply"' : ''}>$body</g>';
}

/// A shape of a brush that is stroked with the line's width (no brush makes one yet): its pieces as outlines.
String _svgStroked(Outline outline, DrawingStroke line, double opacity, bool multiply) {
  final d = StringBuffer();
  for (final piece in outline.pieces) {
    switch (piece) {
      case OutlinePolygon(:final points):
        d.write(_poly(points, close: true));
      case OutlineOval(:final rect):
        d.write(_oval(rect));
      case OutlineRibbon(:final points):
        d.write(_poly(points));
    }
  }
  final a = line.color.a * opacity;
  return '<path d="$d" fill="none" stroke="${svgColor(line.color)}"${_opacityAttr('stroke-opacity', a)} stroke-width="${_n(line.width)}" stroke-linecap="round" stroke-linejoin="round"${multiply ? ' style="mix-blend-mode:multiply"' : ''}/>';
}

bool _needsPicture(BrushShape shape) => shape.soft != null || (shape.next != null && _needsPicture(shape.next!));

String _brushSvg(DrawingStroke drawn, BrushShape shape) {
  final line = shape.line ?? drawn;
  final c = line.color;
  final b = StringBuffer();
  if (shape.filled) {
    String layer(BrushLayer l) => svgOutline(l.outline, l.tinted ? l.colorOf(c).withValues(alpha: c.a) : c, l.opacity, multiply: shape.multiply);
    for (final l in shape.under) {
      b.write(layer(l));
    }
    b.write(svgOutline(shape.outline, c, shape.opacity, multiply: shape.multiply));
    for (final l in shape.layers) {
      b.write(layer(l));
    }
  } else {
    b.write(_svgStroked(shape.outline, line, shape.opacity, shape.multiply));
  }
  final next = shape.next;
  if (next != null) b.write(_brushSvg(drawn, next));
  return b.toString();
}

/// The line [s] as SVG. [raster] makes a picture of a line that cannot be written as shapes (null: leave it out).
Future<String> svgStroke(DrawingStroke s, {required double sensitivity, required SvgDefs defs, required Future<String?> Function(DrawingStroke) raster}) async {
  if (s.points.length < 2) return '';
  // text along the line, and brushes that blur: a picture of the line
  if (s.label != null) return await raster(s) ?? '';
  final shape = s.brush == penBrushId ? null : brushShape(s);
  if (shape != null) {
    if (_needsPicture(shape)) return await raster(s) ?? '';
    return _brushSvg(s, shape);
  }
  if (drawsWithPressure(s, sensitivity)) {
    return svgOutline(Outline.ribbon(s.points, pressureHalfWidths(s, sensitivity)), s.color, 1);
  }
  final b = StringBuffer();
  final fill = s.fill;
  if (fill != null && s.isClosed) {
    final box = _boundsOf(s.points);
    final g = s.gradient;
    final paint = g != null ? 'url(#${defs.gradient(g, fill, box)})' : svgColor(fill);
    b.write('<path d="${_poly(s.points, close: true)}" fill="$paint"${g == null ? _opacityAttr('fill-opacity', fill.a) : ''}/>');
  }
  if (s.color.a > 0) {
    final dash = switch (s.dash) {
      StrokeDash.solid => '',
      StrokeDash.dashed => ' stroke-dasharray="${_n(math.max(8.0, s.width * 3.5))} ${_n(math.max(6.0, s.width * 2.5))}"',
      StrokeDash.dotted => ' stroke-dasharray="0.1 ${_n(math.max(5.0, s.width * 2.2))}"',
    };
    b.write('<path d="${_poly(s.points)}" fill="none" stroke="${svgColor(s.color)}"${_opacityAttr('stroke-opacity', s.color.a)} stroke-width="${_n(s.width)}" stroke-linecap="round" stroke-linejoin="round"$dash/>');
  }
  return b.toString();
}

Rect _boundsOf(List<Offset> points) {
  var l = double.infinity, t = double.infinity, r = double.negativeInfinity, b = double.negativeInfinity;
  for (final p in points) {
    l = math.min(l, p.dx);
    r = math.max(r, p.dx);
    t = math.min(t, p.dy);
    b = math.max(b, p.dy);
  }
  return Rect.fromLTRB(l, t, r, b);
}

/// A picture placed on the page: [bytes] of an image of [mime] type.
String svgImage(List<int> bytes, String mime, Rect at, {double opacity = 1}) =>
    '<image x="${_n(at.left)}" y="${_n(at.top)}" width="${_n(at.width)}" height="${_n(at.height)}" preserveAspectRatio="none"${_opacityAttr('opacity', opacity)} xlink:href="data:$mime;base64,${base64Encode(bytes)}"/>';

/// The ruling of [background] on a page of [size], as lines and dots.
String svgPaper(PageBackground background, Size size) {
  final lines = paperLines(background, size);
  final dots = paperDots(background, size);
  if (lines.isEmpty && dots.isEmpty) return '';
  final b = StringBuffer('<g id="paper-ruling">');
  if (lines.isNotEmpty) {
    final d = StringBuffer();
    for (final (from, to) in lines) {
      d.write('M${_n(from.dx)} ${_n(from.dy)}L${_n(to.dx)} ${_n(to.dy)}');
    }
    b.write('<path d="$d" fill="none" stroke="${svgColor(paperInk(background))}" stroke-width="1"/>');
  }
  if (dots.isNotEmpty) {
    final d = StringBuffer();
    for (final p in dots) {
      d.write(_circle(p, 1.2));
    }
    b.write('<path d="$d" fill="${svgColor(paperDotColor)}"/>');
  }
  b.write('</g>');
  return b.toString();
}

/// What lies on one layer of a page, as SVG elements: its pictures at the bottom, the lines over them, the boxes on top.
class SvgLayerParts {
  final List<String> pictures = [], ink = [], boxes = [];
  bool get isEmpty => pictures.isEmpty && ink.isEmpty && boxes.isEmpty;
}

/// The whole file. [view] is the part of the page space the picture shows (the page, or the part of a canvas with something on it);
/// [parts] holds what lies on the layer at each place of the [layers]; [behind] is everything under the layers (the paper, its
/// ruling, a PDF page, a written document, highlights).
String svgDocument({required Rect view, required LayerStack layers, required Map<int, SvgLayerParts> parts, required SvgDefs defs, List<String> behind = const [], String? title}) {
  String node(int i) {
    final l = layers.layers[i];
    if (!layers.isShown(i)) return '';
    String attrs() =>
        ' id="layer-${svgEscape(l.id.isEmpty ? 'base' : l.id)}" inkscape:groupmode="layer" inkscape:label="${svgEscape(l.name)}"${_opacityAttr('opacity', l.opacity)}${l.blend != LayerBlend.normal ? ' style="mix-blend-mode:${_blendCss(l.blend)}"' : ''}';
    if (l.isGroup) {
      final inner = [for (final m in layers.membersOf(l.id)) node(m)].join();
      return inner.isEmpty ? '' : '<g${attrs()}>$inner</g>';
    }
    final p = parts[i];
    if (p == null || p.isEmpty) return '';
    return '<g${attrs()}>${p.pictures.join()}${p.ink.join()}${p.boxes.join()}</g>';
  }

  final body = [for (final i in layers.topLevel) node(i)].join();
  final defsText = defs.isEmpty ? '' : '<defs>$defs</defs>';
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" '
      'width="${_n(view.width)}" height="${_n(view.height)}" viewBox="${_n(view.left)} ${_n(view.top)} ${_n(view.width)} ${_n(view.height)}">\n'
      '${title == null ? '' : '<title>${svgEscape(title)}</title>\n'}'
      '$defsText${behind.join()}$body\n</svg>\n';
}
