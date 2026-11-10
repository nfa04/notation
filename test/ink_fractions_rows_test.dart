import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/models/canvas_models.dart';

DrawingStroke bar(double x, double y, double w) => DrawingStroke(color: const Color(0xFF000000), width: 2, points: [for (var i = 0; i <= 6; i++) Offset(x + w * i / 6, y + (i.isEven ? 0 : 0.5))]);

/// Something a letter high and [w] wide (a zigzag, so that it is a letter and not a bar).
DrawingStroke glyph(double x, double y, {double w = 14, double h = 22}) =>
    DrawingStroke(color: const Color(0xFF000000), width: 2, points: [for (var i = 0; i < 8; i++) Offset(x + w * i / 7, y + (i.isEven ? 0 : h))]);

/// `=`: two bars.
List<DrawingStroke> equals(double x, double y) => [bar(x, y, 16), bar(x, y + 9, 16)];

/// A fraction at ([x], [y]) of the line's middle: a bar of [w], [top] glyphs over it and [bottom] under it. The line is 22 high (y to y + 22).
List<DrawingStroke> fraction(double x, double y, double w, {int top = 1, int bottom = 1, double gapAbove = 8, double gapBelow = 12}) {
  final barY = y + 11;
  return [
    bar(x, barY, w),
    for (var i = 0; i < top; i++) glyph(x + 4 + i * 18, barY - gapAbove - 22, h: 20),
    for (var i = 0; i < bottom; i++) glyph(x + 4 + i * 18, barY + gapBelow, h: 20),
  ];
}


// The boxes (left, top, right, bottom) of the strokes of three lines of real handwriting that were once cut into several rows.
const _substitution = <List<double>>[
  [263, 481, 284, 502], [292, 478, 306, 505], [294, 492, 306, 492], [311, 500, 328, 512], [313, 506, 328, 506],
  [356, 490, 369, 490], [358, 495, 369, 495], [401, 478, 424, 478], [407, 516, 481, 516], [408, 502, 426, 502],
  [409, 480, 412, 502], [431, 540, 442, 555], [437, 490, 456, 504], [445, 530, 456, 538], [496, 495, 507, 496],
  [496, 492, 506, 492], [529, 505, 587, 505], [539, 480, 552, 496], [550, 518, 567, 531], [598, 490, 619, 505],
  [634, 508, 686, 508], [646, 478, 665, 499], [654, 519, 663, 532], [663, 469, 679, 481], [666, 513, 677, 519],
  [699, 489, 714, 506],
];

const _rootLine = <List<double>>[
  [77, 180, 83, 194], [99, 181, 107, 181], [99, 185, 109, 185], [122, 162, 141, 204], [140, 163, 193, 163],
  [145, 180, 159, 194], [161, 185, 169, 196], [171, 175, 179, 194], [211, 186, 221, 186], [211, 181, 220, 181],
  [245, 161, 262, 205], [265, 161, 440, 161], [267, 179, 280, 195], [290, 183, 290, 185], [303, 178, 311, 194],
  [318, 196, 318, 207], [323, 184, 330, 196], [336, 176, 346, 197], [349, 178, 365, 195], [366, 185, 379, 193],
  [386, 173, 386, 192], [392, 184, 399, 195], [398, 171, 409, 179], [415, 186, 416, 186], [421, 178, 430, 196],
  [435, 195, 436, 203], [437, 176, 447, 176], [438, 180, 447, 195], [451, 187, 465, 195], [485, 178, 497, 182],
  [486, 184, 496, 189], [518, 174, 532, 193], [539, 194, 542, 205], [552, 176, 562, 188], [556, 178, 561, 195],
  [566, 172, 578, 193], [581, 169, 593, 195], [608, 184, 620, 196], [633, 171, 641, 196], [645, 182, 653, 196],
];

const _dxLine = <List<double>>[
  [102, 255, 115, 283], [123, 254, 129, 282], [138, 277, 148, 277], [138, 258, 142, 280], [144, 257, 144, 283],
  [155, 267, 163, 279], [158, 266, 164, 282], [168, 250, 183, 288], [204, 270, 214, 270], [205, 266, 214, 266],
  [237, 291, 323, 291], [245, 255, 259, 283], [246, 269, 258, 272], [258, 314, 273, 334], [259, 309, 270, 312],
  [259, 323, 267, 325], [267, 250, 276, 286], [278, 266, 288, 279], [280, 266, 286, 280], [285, 310, 291, 334],
  [285, 321, 296, 325], [289, 248, 306, 285], [290, 307, 295, 332], [333, 251, 347, 281], [351, 264, 362, 281],
  [378, 264, 388, 264], [379, 268, 390, 269], [417, 298, 524, 298], [425, 316, 443, 334], [426, 314, 438, 314],
  [428, 260, 437, 285], [430, 324, 436, 328], [448, 253, 458, 279], [450, 264, 458, 267], [452, 313, 460, 338],
  [453, 324, 461, 324], [461, 311, 467, 337], [466, 263, 476, 278], [466, 264, 473, 278], [482, 267, 492, 297],
  [540, 252, 554, 281], [554, 265, 569, 282], [585, 267, 599, 270], [586, 265, 599, 266],
];

/// A heading with its underline, and under it a line that begins with a word and a colon, then a formula.
const _headingAndLabel = <List<double>>[
  [12, 35, 21, 53], [23, 23, 35, 63], [36, 86, 55, 86], [47, 89, 48, 111], [47, 42, 62, 59], [56, 18, 75, 69],
  [57, 99, 66, 111], [69, 103, 78, 111], [85, 101, 98, 112], [98, 102, 107, 114], [109, 88, 119, 111],
  [115, 25, 126, 59], [122, 100, 135, 110], [128, 43, 138, 56], [133, 90, 146, 112], [142, 84, 144, 91],
  [147, 42, 159, 53], [153, 100, 174, 111], [163, 40, 174, 51], [178, 39, 184, 79], [183, 112, 183, 112],
  [183, 101, 184, 103], [191, 42, 230, 81], [233, 42, 243, 55], [246, 44, 256, 85], [263, 33, 275, 55],
  [270, 45, 281, 55], [270, 100, 283, 110], [282, 20, 282, 28], [287, 44, 288, 54], [290, 103, 291, 104],
  [294, 42, 304, 54], [298, 100, 311, 140], [305, 24, 387, 84], [327, 98, 338, 98], [365, 88, 387, 115],
  [391, 85, 406, 90], [393, 88, 395, 113], [394, 98, 404, 98], [395, 56, 396, 57], [397, 46, 398, 48],
  [409, 115, 419, 117], [410, 107, 424, 120], [444, 94, 455, 94], [446, 99, 454, 100], [478, 99, 495, 112],
  [503, 102, 504, 104], [515, 99, 530, 113],
];

/// A stroke that fills [box] (left, top, right, bottom): a flat one is a line, the others zigzag.
DrawingStroke fill(List<double> box) {
  final l = box[0], t = box[1], r = box[2], b = box[3];
  if (b - t <= 1) return DrawingStroke(color: const Color(0xFF000000), width: 2, points: [for (var i = 0; i <= 6; i++) Offset(l + (r - l) * i / 6, t + (b - t) * i / 6)]);
  return DrawingStroke(color: const Color(0xFF000000), width: 2, points: [for (var i = 0; i < 8; i++) Offset(l + (r - l) * i / 7, i.isEven ? t : b)]);
}

/// The rest of a page of handwriting, far from the line: the size of what is close is measured against the writing of the whole page.
List<DrawingStroke> _restOfThePage() => [
      for (var i = 0; i < 40; i++) fill([40.0 + i * 17, 900, 52.0 + i * 17, 912]),
      for (var i = 0; i < 20; i++) fill([40.0 + i * 33, 980, 54.0 + i * 33, 1005]),
    ];

/// The rows that the strokes of [boxes] are in when the page has other writing as well: every one of them has to be in the same row.
void expectOneRow(List<List<double>> boxes) {
  final mine = [for (final b in boxes) fill(b)];
  final rows = clusterStrokes(0, [...mine, ..._restOfThePage()], rows: true).where((r) => r.strokes.any(mine.contains)).toList();
  expect(rows, hasLength(1), reason: 'the strokes of one line are in ${rows.length} rows');
  expect(rows.single.strokes.where(mine.contains), hasLength(mine.length));
}

List<DrawingStroke> letters(double x, double y, int n) => [for (var i = 0; i < n; i++) glyph(x + i * 24, y)];

void main() {
  group('a line with several fractions is one row', () {
    test('three fractions, as in 2F = Ia/r^2 = (1/2) m R^2/r^2 a', () {
      final line = [
        ...letters(100, 200, 2),
        ...equals(160, 206),
        ...fraction(190, 200, 60, top: 2, bottom: 1),
        ...equals(270, 206),
        ...fraction(300, 200, 22),
        ...letters(340, 200, 2),
        ...fraction(395, 200, 60, top: 2, bottom: 2),
        ...letters(480, 200, 1),
      ];
      final rows = [for (final c in clusterStrokes(0, line, rows: true)) c];
      expect(rows, hasLength(1), reason: 'the numerators are all at one height and the denominators at another: that is no reason for a row each');
      expect(rows.single.strokes, hasLength(line.length));
    });

    test('a long denominator that is further from its bar still belongs to it', () {
      final line = [...letters(100, 200, 1), ...equals(130, 206), ...fraction(160, 200, 90, top: 3, bottom: 1, gapBelow: 24), ...letters(270, 200, 1)];
      expect(clusterStrokes(0, line, rows: true), hasLength(1));
    });

    test('the stroke over a root, with a long number under it, is not a row of its own', () {
      final line = [
        ...letters(100, 200, 2),
        ...equals(160, 206),
        glyph(190, 196, w: 18, h: 30),
        bar(208, 196, 150),
        ...letters(212, 204, 6),
        ...equals(380, 206),
        ...letters(410, 200, 3),
      ];
      final rows = clusterStrokes(0, line, rows: true);
      expect(rows, hasLength(1));
      expect(rows.single.strokes, hasLength(line.length));
    });
  });

  group('lines of real handwriting', () {
    test('2F = Ia/r^2 = (1/2) m R^2/r^2 a: three fractions with their numerators at one height', () {
      expectOneRow(_substitution);
    });

    test('a line with two roots, the second with a long number under it', () {
      expectOneRow(_rootLine);
    });

    test('d(x) = F/(EA) dx = pAxg/(EA) dx: the denominators are not rows of their own', () {
      expectOneRow(_dxLine);
    });
  });

  group('headings and labels', () {
    test('a heading with its underline, touching the line under it, is a row of its own; the label and the formula of that line are two', () {
      final mine = [for (final b in _headingAndLabel) fill(b)];
      final rows = clusterStrokes(0, [...mine, ..._restOfThePage()], rows: true).where((r) => r.strokes.any(mine.contains)).toList()
        ..sort((a, b) => a.bounds.top != b.bounds.top ? a.bounds.top.compareTo(b.bounds.top) : a.bounds.left.compareTo(b.bounds.left));
      expect(rows, hasLength(3), reason: 'the heading, the label (Translation:) and the formula');
      expect(rows[0].bounds.bottom, lessThan(rows[2].bounds.top + 20), reason: 'the heading is above the formula');
      expect(rows[1].bounds.right, lessThan(rows[2].bounds.left), reason: 'the word is left of the formula');
    });

    /// A word of [n] letters, a colon, then [after] letters after a gap of [gap].
    List<DrawingStroke> labelled(int n, int after, double gap) {
      final colonX = 100.0 + n * 24 + 8;
      return [
        ...letters(100, 200, n),
        glyph(colonX, 200, w: 2, h: 2),
        glyph(colonX, 212, w: 2, h: 2),
        ...letters(colonX + 6 + gap, 200, after),
      ];
    }

    test('a word with a colon and then a formula a good way off is two blocks', () {
      expect(clusterStrokes(0, labelled(6, 4, 28), rows: true).length, 2, reason: 'near enough to be one block of writing, far enough from the colon to be a label');
    });

    test('a colon with the next thing beside it (a : b) does not split', () {
      expect(clusterStrokes(0, labelled(6, 4, 8), rows: true).length, 1);
    });

    test('a short word is not a label', () {
      expect(clusterStrokes(0, [...letters(100, 200, 1), glyph(130, 200, w: 2, h: 2), glyph(130, 212, w: 2, h: 2), ...letters(160, 200, 4)], rows: true).length, 1);
    });

    test('the bar of a T over its own stem, with the line above far over it, is not a fraction', () {
      final above = letters(100, 100, 8);
      final t = [bar(100, 160, 19), glyph(108, 162, w: 1, h: 22), ...letters(130, 160, 4)];
      final rows = clusterStrokes(0, [...above, ...t], rows: true);
      expect(rows.length, 2);
    });
  });

  group('what is not a fraction stays apart', () {
    test('lines of a solution, close and one under the other, are still rows', () {
      final lines = [...letters(100, 100, 5), ...letters(100, 140, 5), ...letters(100, 180, 5)];
      expect(clusterStrokes(0, lines, rows: true), hasLength(3));
    });

    test('an equals sign is not a fraction bar', () {
      final line = [...letters(100, 200, 2), ...equals(160, 206), ...letters(190, 200, 2)];
      expect(clusterStrokes(0, line, rows: true), hasLength(1));
    });

    test('an underline under a row of writing does not take the row below into the row above', () {
      final heading = [...letters(100, 100, 14), bar(100, 130, 330)];
      final next = letters(100, 150, 16);
      final rows = clusterStrokes(0, [...heading, ...next], rows: true);
      expect(rows, hasLength(2));
    });

    test('a number after an equals sign with room around it is still the same line', () {
      final line = [...letters(100, 200, 3), ...equals(210, 206), ...letters(262, 200, 2)];
      expect(clusterStrokes(0, line), hasLength(1), reason: 'the room around the sign is a letter and a half');
    });
  });
}
