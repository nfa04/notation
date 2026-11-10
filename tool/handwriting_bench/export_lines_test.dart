// Cuts real handwriting into lines the way the app does and draws each line the way the app shows it to the two readers.
//   flutter test tool/handwriting_bench/export_lines_test.dart --dart-define=SELECT=/path/select.json --dart-define=OUT=/path/out
// SELECT: a list of {id, strokes: [{c: ARGB int, b: brush or null, pts: [x0, y0, x1, y1, ...]}]} (one page each).
// OUT gets lines.json (every line: its strokes and chunk boxes) and paddle/<line>.png (the picture PaddleOCR-VL reads, got back from
// the patches it is given). (TrOCR's pictures were made here too until TrOCR was taken out of the app.)
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/ink/ink_grouping.dart';
import 'package:notes/ink/ink_image.dart';
import 'package:notes/models/canvas_models.dart';

const selectPath = String.fromEnvironment('SELECT');
const outDir = String.fromEnvironment('OUT');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('export the lines', () async {
    final pages = jsonDecode(File(selectPath).readAsStringSync()) as List;
    Directory('$outDir/paddle').createSync(recursive: true);
    final lines = <Map<String, dynamic>>[];
    for (final page in pages) {
      final strokes = [
        for (final s in page['strokes'] as List)
          DrawingStroke(
            color: Color(s['c'] as int),
            width: 3,
            brush: (s['b'] as String?) ?? penBrushId,
            points: () {
              final v = (s['pts'] as List).cast<num>();
              return [for (var i = 0; i + 1 < v.length; i += 2) Offset(v[i].toDouble(), v[i + 1].toDouble())];
            }(),
          ),
      ];
      // what the app's ink index does (ink_prefetcher.dart): blocks of writing first, then each block is read by lines
      final clusters = clusterStrokes(0, strokes);
      final grouped = <List<InkChunk>>[];
      final clusterOf = <int>[];
      for (var k = 0; k < clusters.length; k++) {
        for (final line in groupIntoLines(clusters[k].strokes)) {
          grouped.add(line);
          clusterOf.add(k);
        }
      }
      for (var l = 0; l < grouped.length; l++) {
        final id = '${page['id']}_c${clusterOf[l].toString().padLeft(2, '0')}_${l.toString().padLeft(2, '0')}';
        final line = grouped[l];
        final all = [for (final c in line) ...c.strokes];
        final pic = await renderInkForPaddleVl(all);
        final width = pic.gridWidth * 14, height = pic.gridHeight * 14;
        final png = img.Image(width: width, height: height);
        var i = 0;
        for (var py = 0; py < pic.gridHeight; py++) {
          for (var px = 0; px < pic.gridWidth; px++) {
            for (var c = 0; c < 3; c++) {
              for (var ky = 0; ky < 14; ky++) {
                for (var kx = 0; kx < 14; kx++) {
                  final v = ((pic.patches[i++] + 1) * 127.5).round().clamp(0, 255);
                  if (c == 0) png.setPixelRgb(px * 14 + kx, py * 14 + ky, v, v, v);
                }
              }
            }
          }
        }
        File('$outDir/paddle/$id.png').writeAsBytesSync(img.encodePng(png));
        lines.add({
          'id': id,
          'chunks': [
            for (final c in line)
              {'box': [c.bounds.left, c.bounds.top, c.bounds.right, c.bounds.bottom], 'n': c.strokes.length},
          ],
          'strokes': [
            for (final s in all) [for (final p in s.points) ...[p.dx, p.dy]],
          ],
        });
      }
    }
    File('$outDir/lines.json').writeAsStringSync(jsonEncode(lines));
    debugPrint('exported ${lines.length} lines');
  });
}
