// Draws how the app cuts real pages of handwriting into blocks and lines, to look at with the eyes:
//   flutter test tool/handwriting_bench/segment_view_test.dart --dart-define=SELECT=/path/pages.json --dart-define=OUT=/path/out
// SELECT: a list of {id, strokes: [{c: ARGB int, b: brush or null, w: width, pts: [x0, y0, x1, y1, ...]}]} (one page each).
// OUT/<page>.png: each block (InkCluster) in a grey box, its lines (groupIntoLines, what the reader is given one by one) in turns of
// colour (OUT/<page>_rows.png: the lines of rowsOf, the maths check's cut, instead); strokes that are not taken for handwriting (isInkStroke) in light grey.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/ink/ink_grouping.dart';
import 'package:notes/models/canvas_models.dart';

const selectPath = String.fromEnvironment('SELECT');
const outDir = String.fromEnvironment('OUT');

final _colours = [
  img.ColorRgb8(220, 30, 30),
  img.ColorRgb8(30, 120, 220),
  img.ColorRgb8(20, 160, 60),
  img.ColorRgb8(200, 110, 0),
  img.ColorRgb8(150, 40, 190),
  img.ColorRgb8(0, 160, 160),
];

/// Numbers that may tell writing from drawing, for a row: in letter heights of the page.
String describeRow(InkCluster row, double letter) {
  double length(DrawingStroke s) {
    var l = 0.0;
    for (var i = 1; i < s.points.length; i++) {
      l += (s.points[i] - s.points[i - 1]).distance;
    }
    return l;
  }

  final lengths = [for (final s in row.strokes) length(s) / letter]..sort();
  final total = lengths.fold(0.0, (a, b) => a + b);
  final area = row.bounds.width * row.bounds.height / (letter * letter);
  final closedBig = row.strokes.where((s) => s.isClosed && strokeBounds(s).shortestSide > 1.2 * letter).length;
  return 'n=${row.strokes.length} h=${(row.bounds.height / letter).toStringAsFixed(1)} maxLen=${lengths.last.toStringAsFixed(1)} medLen=${lengths[lengths.length ~/ 2].toStringAsFixed(1)} '
      'ink/area=${(total / math.max(area, 1)).toStringAsFixed(2)} closedBig=$closedBig';
}

void main() {
  test('draw the cut', () {
    final pages = jsonDecode(File(selectPath).readAsStringSync()) as List;
    Directory(outDir).createSync(recursive: true);
    for (final (page, byRows) in [for (final p in pages) for (final r in [false, true]) (p, r)]) {
      final strokes = [
        for (final s in page['strokes'] as List)
          DrawingStroke(
            color: Color(s['c'] as int),
            width: (s['w'] as num?)?.toDouble() ?? 3,
            brush: (s['b'] as String?) ?? penBrushId,
            points: () {
              final v = (s['pts'] as List).cast<num>();
              return [for (var i = 0; i + 1 < v.length; i += 2) Offset(v[i].toDouble(), v[i + 1].toDouble())];
            }(),
          ),
      ];
      final withPoints = strokes.where((s) => s.points.isNotEmpty).toList();
      if (withPoints.isEmpty) continue;
      var box = strokeBounds(withPoints.first);
      for (final s in withPoints) {
        box = box.expandToInclude(strokeBounds(s));
      }
      final scale = 1400 / math.max(box.width, box.height);
      final w = (box.width * scale).ceil() + 20, h = (box.height * scale).ceil() + 20;
      final pic = img.Image(width: w, height: h)..clear(img.ColorRgb8(255, 255, 255));
      (int, int) at(Offset p) => (((p.dx - box.left) * scale).round() + 10, ((p.dy - box.top) * scale).round() + 10);
      void stroke(DrawingStroke s, img.Color c) {
        for (var i = 1; i < s.points.length; i++) {
          final a = at(s.points[i - 1]), b = at(s.points[i]);
          img.drawLine(pic, x1: a.$1, y1: a.$2, x2: b.$1, y2: b.$2, color: c, thickness: 2);
        }
      }

      for (final s in withPoints) {
        if (!isInkStroke(s)) stroke(s, img.ColorRgb8(200, 200, 200));
      }
      final clusters = clusterStrokes(0, withPoints);
      final letter = letterHeight([for (final s in withPoints) if (isInkStroke(s)) strokeBounds(s)]);
      var rowNumber = 0;
      final report = StringBuffer('${page['id']}: ${withPoints.length} strokes, ${clusters.length} blocks\n');
      for (final c in clusters) {
        final a = at(c.bounds.topLeft), b = at(c.bounds.bottomRight);
        img.drawRect(pic, x1: a.$1 - 3, y1: a.$2 - 3, x2: b.$1 + 3, y2: b.$2 + 3, color: img.ColorRgb8(150, 150, 150));
        final lines = byRows ? [for (final r in rowsOf(c)) [InkChunk(r.strokes, r.bounds)]] : groupIntoLines(c.strokes);
        for (var l = 0; l < lines.length; l++) {
          for (final chunk in lines[l]) {
            for (final s in chunk.strokes) {
              stroke(s, _colours[l % _colours.length]);
            }
          }
        }
        report.writeln('  block ${c.strokes.length} strokes ${c.bounds.width.round()}x${c.bounds.height.round()} -> ${lines.length} lines');
        if (byRows) {
          for (final row in rowsOf(c)) {
            final n = rowNumber++;
            final p = at(row.bounds.topLeft);
            img.drawString(pic, '$n', font: img.arial14, x: p.$1 - 14, y: p.$2 - 4, color: img.ColorRgb8(0, 0, 0));
            report.writeln('    row $n ${describeRow(row, letter)}');
          }
        }
      }
      File('$outDir/${page['id']}${byRows ? '_rows' : ''}.png').writeAsBytesSync(img.encodePng(pic));
      // ignore: avoid_print
      print(report);
    }
  });
}
