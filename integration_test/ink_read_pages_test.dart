// Reads real pages the way the app reads a note (blocks, lines, pieces of a line, GLM-OCR through ONNX Runtime) and writes what each line
// says with its box, to compare with the page by eye. The pages are given by path and are not part of the repository:
//   flutter test integration_test/ink_read_pages_test.dart -d linux --dart-define=MODEL_DIR=$HOME/hw-bench/glm_release \
//     --dart-define=SELECT=/path/pages.json --dart-define=OUT=/path/reads.json [--dart-define=ONLY=page_0,page_1]
// SELECT is a list of {id, strokes: [{c, w, pts: [x0, y0, ...]}]}, the format tool/handwriting_bench/segment_view_test.dart takes.
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
const outPath = String.fromEnvironment('OUT');
const only = String.fromEnvironment('ONLY');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('read pages and write each line', (tester) async {
    await tester.runAsync(() async {
      final vocabulary = GlmVocabulary.parse(File('assets/glm_ocr/vocab.txt').readAsStringSync());
      final reader = GlmOnnxReader();
      final pages = jsonDecode(File(selectPath).readAsStringSync()) as List;
      final out = <String, Object?>{};
      for (final page in pages) {
        final id = page['id'] as String;
        if (only.isNotEmpty && !only.split(',').contains(id)) continue;
        final strokes = [
          for (final s in page['strokes'] as List)
            if ((s['pts'] as List).length >= 4)
              DrawingStroke(
                color: Color(s['c'] as int),
                width: (s['w'] as num?)?.toDouble() ?? 3,
                points: () {
                  final v = (s['pts'] as List).cast<num>();
                  return [for (var i = 0; i + 1 < v.length; i += 2) Offset(v[i].toDouble(), v[i + 1].toDouble())];
                }(),
              ),
        ];
        final lines = <Map<String, Object?>>[];
        var n = 0;
        for (final block in clusterStrokes(0, strokes)) {
          for (final line in groupIntoLines(block.strokes)) {
            final pieces = GlmOcrService.joinChunks(line);
            final pictures = [for (final p in pieces) await renderInkForGlmOcr(p, rows: GlmQuality.standard.rows)];
            final readings = await reader.readScored('$modelDir/vision.onnx', '$modelDir/text.onnx', '$modelDir/embeddings.bin', pictures);
            final parts = [
              for (final r in readings)
                {'text': vocabulary.decode(r.tokens), 'confidence': r.confidence, 'kept': GlmOcrService.isWriting(vocabulary.decode(r.tokens), r.confidence)},
            ];
            final b = line.map((c) => c.bounds).reduce((a, b) => a.expandToInclude(b));
            lines.add({'n': n++, 'box': [b.left.round(), b.top.round(), b.right.round(), b.bottom.round()], 'strokes': line.fold<int>(0, (a, c) => a + c.strokes.length), 'parts': parts});
          }
        }
        out[id] = lines;
        debugPrint('$id read: ${lines.length} lines');
      }
      await reader.close();
      File(outPath).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    });
  }, timeout: const Timeout(Duration(minutes: 120)));
}
