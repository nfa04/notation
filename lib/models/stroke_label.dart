import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/widgets.dart' show StringCharacters;

/// Where the text of a label goes on its line or shape.
enum LabelPlace {
  /// Letter by letter along the line (round a shape: along its outline).
  along('Along the line'),

  /// Written in the middle of a shape, in lines that fit it.
  inside('Inside the shape');

  final String label;
  const LabelPlace(this.label);
}

/// Where the text starts when it runs along a line.
enum LabelAlign {
  start('Start'),
  middle('Middle'),
  end('End');

  final String label;
  const LabelAlign(this.label);
}

/// On which side of the line the text runs along it.
enum LabelSide {
  above('Above'),
  on('On the line'),
  below('Below');

  final String label;
  const LabelSide(this.label);
}

/// Text that belongs to a line or a shape (`DrawingStroke.label`): it runs along the line, or is written inside the shape, and goes where
/// the line goes. How it is laid out is [layoutLabel].
class StrokeLabel {
  final String text;

  /// The size of the letters, in the units of the page.
  final double size;
  final LabelPlace place;

  /// Along a line: where the text starts.
  final LabelAlign align;

  /// Along a line: which side of it the text runs on. (Round a shape the outside is above and the inside below.)
  final LabelSide side;

  /// Along an open line, the text runs from the end the line was drawn from to the other - unless the line was drawn from right to
  /// left, which is turned round so that it reads the right way; this turns it the other way.
  final bool turned;
  final bool bold;

  /// The colour of the text; null: the colour of the line along it, and inside a shape black or white, whichever shows on the fill.
  final Color? color;

  const StrokeLabel({
    required this.text,
    this.size = 20,
    this.place = LabelPlace.along,
    this.align = LabelAlign.middle,
    this.side = LabelSide.above,
    this.turned = false,
    this.bold = false,
    this.color,
  });

  bool get isEmpty => text.trim().isEmpty;

  StrokeLabel copyWith({String? text, double? size, LabelPlace? place, LabelAlign? align, LabelSide? side, bool? turned, bool? bold, Color? color, bool noColor = false}) => StrokeLabel(
        text: text ?? this.text,
        size: size ?? this.size,
        place: place ?? this.place,
        align: align ?? this.align,
        side: side ?? this.side,
        turned: turned ?? this.turned,
        bold: bold ?? this.bold,
        color: noColor ? null : (color ?? this.color),
      );

  /// The colour the text is drawn in for a line of [lineColor] with [fill] inside.
  Color colorFor(Color lineColor, Color? fill) {
    final own = color;
    if (own != null) return own;
    if (place == LabelPlace.along || fill == null) return place == LabelPlace.along ? lineColor : const Color(0xFF000000);
    // (the fill may be see-through: it is on white paper)
    final shown = Color.alphaBlend(fill, const Color(0xFFFFFFFF));
    return shown.computeLuminance() > 0.45 ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
  }

  String encode() => jsonEncode({
        't': text,
        's': size,
        if (place != LabelPlace.along) 'p': place.name,
        if (align != LabelAlign.middle) 'a': align.name,
        if (side != LabelSide.above) 'd': side.name,
        if (turned) 'r': 1,
        if (bold) 'b': 1,
        if (color != null) 'c': color!.toARGB32(),
      });

  /// The label [encode] made; null for nothing (or something that is not one, or a label without text).
  static StrokeLabel? decode(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      final j = jsonDecode(source);
      if (j is! Map || j['t'] is! String) return null;
      T pick<T extends Enum>(List<T> values, Object? name, T fallback) => values.firstWhere((v) => v.name == name, orElse: () => fallback);
      final label = StrokeLabel(
        text: j['t'] as String,
        size: ((j['s'] as num?) ?? 20).toDouble().clamp(4.0, 400.0),
        place: pick(LabelPlace.values, j['p'], LabelPlace.along),
        align: pick(LabelAlign.values, j['a'], LabelAlign.middle),
        side: pick(LabelSide.values, j['d'], LabelSide.above),
        turned: j['r'] == 1,
        bold: j['b'] == 1,
        color: j['c'] is num ? Color((j['c'] as num).toInt()) : null,
      );
      return label.isEmpty ? null : label;
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is StrokeLabel &&
      other.text == text &&
      other.size == size &&
      other.place == place &&
      other.align == align &&
      other.side == side &&
      other.turned == turned &&
      other.bold == bold &&
      other.color?.toARGB32() == color?.toARGB32();

  @override
  int get hashCode => Object.hash(text, size, place, align, side, turned, bold, color?.toARGB32());
}

/// A piece of text to put on the page: [text] with its baseline starting at [origin], turned by [angle] (radians, clockwise on the
/// page), in letters of [size].
class LabelRun {
  final String text;
  final Offset origin;
  final double angle;
  final double size;

  const LabelRun(this.text, this.origin, this.angle, this.size);

  @override
  String toString() => 'LabelRun($text, $origin, ${angle.toStringAsFixed(2)}, $size)';
}

/// How wide [text] is in letters of [size] (bold or not).
typedef MeasureText = double Function(String text, double size, bool bold);

/// The pieces of text that make up [label] on a line through [points] ([closed]: it comes back to where it began, [lineWidth] thick),
/// each with where it goes. [measure] says how wide text is in the font that will draw it.
///
/// Along a line every letter is a piece of its own, put on the line where the letters before it end and turned the way the line goes
/// there; text that is longer than the line is made smaller to fit it. Round a closed shape the text starts at its top (running clockwise,
/// so the top reads left to right) and, unless it starts there, is centred on it or ends at it. Inside a shape the text is broken into
/// lines at its spaces that fit the shape and are centred on it; if they are too many for the shape the letters get smaller.
List<LabelRun> layoutLabel(List<Offset> points, bool closed, double lineWidth, StrokeLabel label, MeasureText measure) {
  if (label.isEmpty || points.length < 2) return const [];
  return label.place == LabelPlace.inside ? _inside(points, label, measure) : _along(points, closed, lineWidth, label, measure);
}

List<LabelRun> _inside(List<Offset> points, StrokeLabel label, MeasureText measure) {
  var left = double.infinity, top = double.infinity, right = -double.infinity, bottom = -double.infinity;
  for (final p in points) {
    left = math.min(left, p.dx);
    top = math.min(top, p.dy);
    right = math.max(right, p.dx);
    bottom = math.max(bottom, p.dy);
  }
  final bounds = Rect.fromLTRB(left, top, right, bottom);
  if (bounds.width < 4 || bounds.height < 4) return const [];
  // a shape that fills its box (a rectangle) takes most of it; one that does not (a circle, a triangle) has room only in its middle
  final fills = _area(points).abs() / (bounds.width * bounds.height);
  final share = fills > 0.92 ? 0.9 : (fills > 0.75 ? 0.68 : 0.5);
  final box = Rect.fromCenter(center: bounds.center, width: bounds.width * share, height: bounds.height * share);

  var size = label.size;
  List<String> lines = const [];
  for (var round = 0; round < 40; round++) {
    lines = _wrap(label.text, box.width, size, label.bold, measure);
    final tooWide = lines.any((l) => measure(l, size, label.bold) > box.width + 0.5);
    if (lines.length * size * _lineHeight <= box.height && !tooWide) break;
    size = math.max(3, size * 0.92);
    if (size <= 3) break;
  }
  final total = lines.length * size * _lineHeight;
  final runs = <LabelRun>[];
  for (var i = 0; i < lines.length; i++) {
    final w = measure(lines[i], size, label.bold);
    final top = box.center.dy - total / 2 + i * size * _lineHeight;
    runs.add(LabelRun(lines[i], Offset(box.center.dx - w / 2, top + size * 0.98), 0, size)); // (the baseline of letters of that size)
  }
  return runs;
}

/// How tall a line of text is, in sizes.
const _lineHeight = 1.25;

/// [text] broken into lines of at most [width] at its spaces (a word longer than that is broken where it must); a new line in it is one.
List<String> _wrap(String text, double width, double size, bool bold, MeasureText measure) {
  final lines = <String>[];
  for (final paragraph in text.split('\n')) {
    var line = '';
    for (var word in paragraph.split(RegExp(r'\s+')).where((w) => w.isNotEmpty)) {
      while (measure(word, size, bold) > width && word.characters.length > 1) {
        // a word that is wider than the shape: as much of it as fits
        var fit = 1;
        while (fit < word.characters.length && measure(word.characters.take(fit + 1).toString(), size, bold) <= width) {
          fit++;
        }
        if (line.isNotEmpty) {
          lines.add(line);
          line = '';
        }
        lines.add(word.characters.take(fit).toString());
        word = word.characters.skip(fit).toString();
      }
      final next = line.isEmpty ? word : '$line $word';
      if (line.isNotEmpty && measure(next, size, bold) > width) {
        lines.add(line);
        line = word;
      } else {
        line = next;
      }
    }
    lines.add(line);
  }
  while (lines.length > 1 && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

/// The area of the polygon of [points] (the sign says which way round it goes: positive is clockwise on the page).
double _area(List<Offset> points) {
  var a = 0.0;
  for (var i = 0; i < points.length; i++) {
    final p = points[i], q = points[(i + 1) % points.length];
    a += p.dx * q.dy - q.dx * p.dy;
  }
  return a / 2;
}

List<LabelRun> _along(List<Offset> raw, bool closed, double lineWidth, StrokeLabel label, MeasureText measure) {
  var pts = _dedupe(raw);
  if (closed && pts.length > 2 && (pts.first - pts.last).distance < 1e-6) pts = pts.sublist(0, pts.length - 1);
  if (pts.length < 2) return const [];
  if (closed) {
    // clockwise, from the top: the top then reads from the left to the right
    if (_area(pts) < 0) pts = pts.reversed.toList();
    var first = 0;
    for (var i = 1; i < pts.length; i++) {
      if (pts[i].dy < pts[first].dy - 1e-9 || (pts[i].dy <= pts[first].dy + 1e-9 && pts[i].dx < pts[first].dx)) first = i;
    }
    pts = [...pts.sublist(first), ...pts.sublist(0, first)];
    pts.add(pts.first);
  } else if ((pts.last.dx < pts.first.dx) != label.turned) {
    // (drawn from right to left: read it from the other end)
    pts = pts.reversed.toList();
  }

  final cum = <double>[0];
  for (var i = 1; i < pts.length; i++) {
    cum.add(cum.last + (pts[i] - pts[i - 1]).distance);
  }
  final length = cum.last;
  if (length < 1e-6) return const [];

  final letters = label.text.replaceAll(RegExp(r'\s+'), ' ').trim().characters.toList();
  var size = label.size;
  double width() => letters.fold(0.0, (w, c) => w + measure(c, size, label.bold));
  var total = width();
  if (total > length) {
    // too long for the line: smaller, so that it fits
    size = math.max(3, size * length / total * 0.98);
    total = width();
  }

  Offset at(double d) {
    if (closed) d = d % length;
    d = d.clamp(0.0, length);
    var lo = 0, hi = cum.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] <= d) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = cum[hi] - cum[lo];
    return span <= 0 ? pts[lo] : Offset.lerp(pts[lo], pts[hi], (d - cum[lo]) / span)!;
  }

  var d = switch (label.align) {
    LabelAlign.start => 0.0,
    LabelAlign.middle => closed ? -total / 2 : (length - total) / 2,
    LabelAlign.end => closed ? -total : length - total,
  };
  // above the line: its half width and a little air; on it: the middle of the letters on it; below: the letters hang under it
  final lift = switch (label.side) {
    LabelSide.above => lineWidth / 2 + size * 0.15,
    LabelSide.on => -size * 0.35,
    LabelSide.below => -(lineWidth / 2 + size * 0.85),
  };
  final runs = <LabelRun>[];
  for (final c in letters) {
    final w = measure(c, size, label.bold);
    if (c != ' ') {
      final from = at(d), to = at(d + w);
      final chord = to - from;
      if (chord.distance > 1e-9) {
        final angle = math.atan2(chord.dy, chord.dx);
        final up = Offset(math.sin(angle), -math.cos(angle));
        runs.add(LabelRun(c, from + up * lift, angle, size));
      }
    }
    d += w;
  }
  return runs;
}

List<Offset> _dedupe(List<Offset> points) {
  final out = <Offset>[];
  for (final p in points) {
    if (out.isEmpty || (p - out.last).distance > 1e-9) out.add(p);
  }
  return out;
}
