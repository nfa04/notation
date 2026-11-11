// Reads real pages of handwriting the way the app does (blocks, lines, pieces of a line, GLM-OCR through ONNX Runtime) and prints what
// was read of every row of writing, to see what the reader makes of text, maths and drawings:
//   flutter test integration_test/page_read_test.dart -d linux --dart-define=MODEL_DIR=$HOME/hw-bench/glm_release \
//     --dart-define=SELECT=/path/pages.json [--dart-define=ONLY=pageid,pageid] [--dart-define=OUT=/path/reads.json]
// SELECT as for segment_view_test.dart. Rows are those of the maths check (rowsOf), each read as text.
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/ink/glm_ocr.dart';
import 'package:notes/ink/glm_ocr_service.dart';
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/ink/ink_grouping.dart';
import 'package:notes/ink/ink_image.dart';
import 'package:notes/ink/onnx_glm_ocr.dart';
import 'package:notes/models/canvas_models.dart';

const modelDir = String.fromEnvironment('MODEL_DIR');
const selectPath = String.fromEnvironment('SELECT');
const only = String.fromEnvironment('ONLY');
const outPath = String.fromEnvironment('OUT');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('read the rows of real pages', (tester) async {
    await tester.runAsync(() async {
      final vocabulary = GlmVocabulary.parse(File('assets/glm_ocr/vocab.txt').readAsStringSync());
      final reader = GlmOnnxReader();
      final out = <Map<String, Object?>>[];
      final pages = jsonDecode(File(selectPath).readAsStringSync()) as List;
      for (final page in pages) {
        if (only.isNotEmpty && !only.split(',').contains(page['id'])) continue;
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
        ].where((s) => s.points.isNotEmpty).toList();
        final rows = clusterStrokes(0, strokes, rows: true);
        for (var r = 0; r < rows.length; r++) {
          final row = rows[r];
          final pieces = [for (final line in groupIntoLines(row.strokes)) ...GlmOcrService.joinChunks(line)];
          final watch = Stopwatch()..start();
          final pictures = [for (final p in pieces) await renderInkForGlmOcr(p, rows: GlmQuality.standard.rows)];
          final tokens = await reader.read('$modelDir/vision.onnx', '$modelDir/text.onnx', '$modelDir/embeddings.bin', pictures);
          final text = [for (final t in tokens) vocabulary.decode(t)].join(' | ');
          final b = row.bounds;
          debugPrint('${page['id']} row $r (${row.strokes.length} strokes, ${b.width.round()}x${b.height.round()} at ${b.left.round()},${b.top.round()}, '
              '${pieces.length} pieces, ${watch.elapsedMilliseconds} ms): $text');
          out.add({'page': page['id'], 'row': r, 'strokes': row.strokes.length, 'box': [b.left, b.top, b.right, b.bottom], 'text': text});
        }
      }
      await reader.close();
      if (outPath.isNotEmpty) File(outPath).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    });
  }, timeout: const Timeout(Duration(minutes: 60)));
}
