import 'dart:math' as math;
import 'dart:ui';

/// Paper style of the blank notebook pages (imported PDFs keep their own).
enum PageBackground {
  blank('Blank'),
  grid('Grid'),
  lines('Lines'),
  dots('Dot grid'),
  isometric('Isometric grid'),
  staff('Music staff'),
  tab('Guitar tab');

  final String label;
  const PageBackground(this.label);

  /// Whether an infinite canvas can have this paper: the ruling of a canvas goes on for ever, which the staves of a page do not.
  /// What the database's `background` column holds for this paper: the three it was made for keep their names, the others are
  /// "blank" there (older versions then show a blank page) and are kept whole in the `paper` column.
  String get legacyName => this == grid || this == lines ? name : 'blank';

  /// The `paper` column for this paper: its name if it is not one of the three that `background` holds, else null.
  String? get paperName => this == blank || this == grid || this == lines ? null : name;

  /// The paper of a row: `background` if it names grid or lines (a version without the other papers wrote it, so it is what was
  /// chosen last), else `paper` (what a blank `background` stands for), else blank.
  static PageBackground stored(Object? paper, Object? background) {
    final legacy = values.where((v) => v.name == background).firstOrNull ?? blank;
    if (legacy != blank) return legacy;
    return values.where((v) => v.name == paper).firstOrNull ?? blank;
  }

  bool get fitsCanvas => this == blank || this == grid || this == lines || this == dots;
}

const double paperSpacing = 28.0;

/// Colour of the ruling, opaque so that PDF and screen look the same.
const Color paperLineColor = Color(0xFFD5DBE6);

/// Colour of the lines of music paper and tab: darker than the ruling of other paper, as notes are read against them.
const Color paperStaffColor = Color(0xFF98A3B8);

/// The colour [background] is ruled in.
Color paperInk(PageBackground background) => background == PageBackground.staff || background == PageBackground.tab ? paperStaffColor : paperLineColor;

/// Colour of the dots of a dot grid (a dot is small, so it is a little darker than a line).
const Color paperDotColor = Color(0xFFB8C0CF);

/// The staves of music paper: five lines [staffGap] apart, a stave every [staffPitch], side margins of [staffMargin]. Guitar tab has
/// six lines [tabGap] apart. (Page units: an A4 sheet is 800 across.)
const double staffGap = 9, staffPitch = 96, tabGap = 12, tabPitch = 112, staffMargin = 40, staffTop = 64;

/// Ruling of [background] on a page of [size], as (from, to) segments. Shared
/// by the on-screen painter and the PDF export.
List<(Offset, Offset)> paperLines(PageBackground background, Size size) {
  final lines = <(Offset, Offset)>[];
  switch (background) {
    case PageBackground.blank || PageBackground.dots:
      return lines;
    case PageBackground.staff:
      return _staves(size, 5, staffGap, staffPitch);
    case PageBackground.tab:
      return _staves(size, 6, tabGap, tabPitch);
    case PageBackground.isometric:
      return _isometric(size);
    case PageBackground.grid || PageBackground.lines:
      break;
  }

  // lines: start below a top margin so the first line is not on the edge
  final startY = background == PageBackground.lines ? paperSpacing * 2 : paperSpacing;
  for (double y = startY; y < size.height; y += paperSpacing) {
    lines.add((Offset(0, y), Offset(size.width, y)));
  }
  if (background == PageBackground.grid) {
    for (double x = paperSpacing; x < size.width; x += paperSpacing) {
      lines.add((Offset(x, 0), Offset(x, size.height)));
    }
  }
  return lines;
}

/// The dots of [background] on a page of [size] (a dot grid: one where the lines of graph paper would cross), or none.
List<Offset> paperDots(PageBackground background, Size size) {
  if (background != PageBackground.dots) return const [];
  return [
    for (double y = paperSpacing; y < size.height; y += paperSpacing)
      for (double x = paperSpacing; x < size.width; x += paperSpacing) Offset(x, y),
  ];
}

/// Staves of [count] lines [gap] apart, one every [pitch] down the page, with a bar line at each end.
List<(Offset, Offset)> _staves(Size size, int count, double gap, double pitch) {
  final lines = <(Offset, Offset)>[];
  final left = staffMargin, right = size.width - staffMargin;
  if (right <= left) return lines;
  for (var top = staffTop; top + gap * (count - 1) <= size.height - staffMargin; top += pitch) {
    for (var i = 0; i < count; i++) {
      lines.add((Offset(left, top + i * gap), Offset(right, top + i * gap)));
    }
    final bottom = top + gap * (count - 1);
    lines.add((Offset(left, top), Offset(left, bottom)));
    lines.add((Offset(right, top), Offset(right, bottom)));
  }
  return lines;
}

/// A triangular lattice for isometric drawing: vertical lines and two families at 30 degrees above and below the horizontal, all
/// meeting in points, with triangles of side [paperSpacing].
List<(Offset, Offset)> _isometric(Size size) {
  final lines = <(Offset, Offset)>[];
  final dx = paperSpacing * math.sqrt(3) / 2;
  for (var x = dx; x < size.width; x += dx) {
    lines.add((Offset(x, 0), Offset(x, size.height)));
  }
  final slope = math.tan(math.pi / 6);
  for (final k in [slope, -slope]) {
    // the line y = y0 + k x, for the part of it inside the page
    for (var y0 = -size.width * slope.abs() - paperSpacing; y0 <= size.height + size.width * slope.abs(); y0 += paperSpacing) {
      final xAtTop = (0 - y0) / k, xAtBottom = (size.height - y0) / k;
      final a = math.max(0.0, math.min(xAtTop, xAtBottom));
      final b = math.min(size.width, math.max(xAtTop, xAtBottom));
      if (b - a > 1) lines.add((Offset(a, y0 + k * a), Offset(b, y0 + k * b)));
    }
  }
  return lines;
}
