import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/models/canvas_models.dart';

DrawingStroke box(double l, double t, double r, double b) =>
    DrawingStroke(color: const Color(0xFF000000), width: 2, points: [Offset(l, t), Offset((l + r) / 2, (t + b) / 2 + 1), Offset(r, b)]);

/// `x/2 + 1 = 3` with the fraction stacked: the middle of the line is at [y]; [h] is the height of a digit. Lots of flat
/// strokes (the bar, the bar of +, both of =), the way a line of maths is.
List<DrawingStroke> fractionLine(double y, {double h = 30, double left = 100}) {
  final w = h * 0.6;
  var x = left;
  final out = <DrawingStroke>[];
  out.add(box(x, y - h - 4, x + w, y - 6)); // numerator
  out.add(box(x - 4, y - 1, x + w + 4, y + 1)); // bar
  out.add(box(x, y + 6, x + w, y + h + 4)); // denominator
  x += w + h * 0.5;
  out.add(box(x, y - 1, x + w, y + 1)); // +
  out.add(box(x + w / 2, y - h / 4, x + w / 2 + 1, y + h / 4));
  x += w + h * 0.5;
  out.add(box(x, y - h / 2, x + w * 0.5, y + h / 2)); // 1
  x += w + h * 0.5;
  out.add(box(x, y - 5, x + w, y - 4)); // =
  out.add(box(x, y + 4, x + w, y + 5));
  x += w + h * 0.5;
  out.add(box(x, y - h / 2, x + w, y + h / 2)); // 3
  return out;
}

void main() {
  test('a stacked fraction stays in its line, however many flat strokes the line has', () {
    final all = [...fractionLine(100), ...fractionLine(190), ...fractionLine(280)];
    final rows = clusterStrokes(0, all, rows: true);
    expect(rows.map((r) => r.strokes.length), [9, 9, 9]);
    expect(rows.map((r) => r.bounds.center.dy.round()), [100, 190, 280].map((y) => closeTo(y, 2)));
  });

  test('a long solution (a big cluster) is cut into rows without tearing its fractions', () {
    final all = [for (var i = 0; i < 9; i++) ...fractionLine(100 + i * 85.0)];
    expect(all.length, lessThan(largestCluster), reason: 'few strokes, but taller than ${tallestCluster.round()}');
    final rows = clusterStrokes(0, all, rows: true);
    expect(rows, hasLength(9));
    expect(rows.every((r) => r.strokes.length == 9), isTrue);
  });

  test('tight lines of plain digits are separate rows', () {
    final all = [for (var i = 0; i < 4; i++) box(100, 100 + i * 48.0, 118, 100 + i * 48.0 + 30), for (var i = 0; i < 4; i++) box(130, 100 + i * 48.0, 148, 100 + i * 48.0 + 30)];
    expect(clusterStrokes(0, all, rows: true), hasLength(4));
  });

  test('a margin line along the whole solution does not join the rows', () {
    final all = [...fractionLine(100), ...fractionLine(190), box(60, 60, 62, 260)];
    final rows = clusterStrokes(0, all, rows: true);
    expect(rows, hasLength(2));
    expect(rows.fold<int>(0, (n, r) => n + r.strokes.length), 19);
  });

  test('a single line is a single row', () {
    final rows = clusterStrokes(0, fractionLine(100), rows: true);
    expect(rows, hasLength(1));
  });

  /// Three digits, 30 high, at [top]; a few of the extra strokes below hang off them.
  List<DrawingStroke> digits(double top, {double left = 100}) =>
      [for (var i = 0; i < 3; i++) box(left + i * 30, top, left + i * 30 + 18, top + 30)];

  test('a last superscript hangs off its line and stays with it', () {
    final all = [...digits(106), box(182, 84, 194, 102), ...digits(170)];
    final rows = clusterStrokes(0, all, rows: true);
    expect(rows.map((r) => r.strokes.length), [4, 3]);
  });

  test('an accent floating over a letter stays with its line', () {
    final all = [...digits(106), box(98, 88, 122, 90), ...digits(170)];
    final rows = clusterStrokes(0, all, rows: true);
    expect(rows.map((r) => r.strokes.length), [4, 3]);
  });

  test('a slanted bar still makes a fraction', () {
    final fraction = [box(100, 60, 118, 84), box(92, 90, 132, 104), box(100, 110, 118, 134)];
    final rows = clusterStrokes(0, [...fraction, ...[for (final s in fraction) box(s.points.first.dx, s.points.first.dy + 120, s.points.last.dx, s.points.last.dy + 120)]], rows: true);
    expect(rows.map((r) => r.strokes.length), [3, 3]);
  });

  test('a short line of its own is not taken for a script of the line above', () {
    final all = [...digits(106), box(100, 160, 118, 190)];
    final rows = clusterStrokes(0, all, rows: true);
    expect(rows.map((r) => r.strokes.length), [3, 1]);
  });

  test('two tight lines stay two, the second one starting where the first one ends', () {
    final all = [...digits(100), ...digits(134)]; // (4 units between the lines)
    expect(clusterStrokes(0, all, rows: true).map((r) => r.strokes.length), [3, 3]);
  });
}
