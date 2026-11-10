// Runs the real GLM-OCR files through ONNX Runtime with the app's Dart code. Needs the files made by
// tool/handwriting_bench/glm_onnx/make_release.py (vision.onnx, text.onnx, embeddings.bin) in MODEL_DIR and the benchmark data:
//   flutter test integration_test/glm_ocr_onnx_test.dart -d linux --dart-define=MODEL_DIR=~/hw-bench/glm_release \
//     --dart-define=DATA_DIR=~/hw-bench/mine --dart-define=PICTURES=r10x --dart-define=REF=ref_r10x
// DATA_DIR/PICTURES/<line>.png are pictures drawn by tool/handwriting_bench/glm_onnx (a multiple of 28 wide), DATA_DIR/results/REF.json
// what the Python reader read from them; DATA_DIR/lines.json has the strokes and DATA_DIR/truth.json the text of the lines.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:notes/ink/glm_ocr.dart';
import 'package:notes/ink/ink_image.dart';
import 'package:notes/ink/onnx_glm_ocr.dart';
import 'package:notes/models/canvas_models.dart';

const modelDir = String.fromEnvironment('MODEL_DIR');
const dataDir = String.fromEnvironment('DATA_DIR');
const pictures = String.fromEnvironment('PICTURES', defaultValue: 'r10x');
const ref = String.fromEnvironment('REF', defaultValue: 'ref_r10x');

int _distance(String a, String b) {
  var prev = List.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final row = [i, ...List.filled(b.length, 0)];
    for (var j = 1; j <= b.length; j++) {
      row[j] = [prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)].reduce((x, y) => x < y ? x : y);
    }
    prev = row;
  }
  return prev.last;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final vocabulary = GlmVocabulary.parse(File('assets/glm_ocr/vocab.txt').readAsStringSync());
  Future<List<String>> read(List<GlmPicture> pics) async {
    final watch = Stopwatch()..start();
    final tokens = await readPicturesGlm(
      visionPath: '$modelDir/vision.onnx',
      textPath: '$modelDir/text.onnx',
      embeddingsPath: '$modelDir/embeddings.bin',
      pictures: pics,
    );
    debugPrint('read ${pics.length} lines in ${watch.elapsedMilliseconds} ms (${(watch.elapsedMilliseconds / pics.length).round()} ms a line)');
    return [for (final t in tokens) vocabulary.decode(t)];
  }

  testWidgets('the Dart runtime reads the same pictures to the same text as the Python reader', (tester) async {
    final expected = (jsonDecode(File('$dataDir/results/$ref.json').readAsStringSync()) as Map).cast<String, String>();
    final ids = expected.keys.toList();
    final pics = <GlmPicture>[];
    for (final id in ids) {
      final image = img.decodePng(File('$dataDir/$pictures/$id.png').readAsBytesSync())!.convert(numChannels: 4);
      final rgba = image.getBytes(order: img.ChannelOrder.rgba);
      pics.add(GlmPicture(glmPatches(rgba, image.width, image.height), image.height ~/ glmPatch, image.width ~/ glmPatch));
    }
    final got = await read(pics);
    var same = 0;
    for (var i = 0; i < ids.length; i++) {
      if (got[i] == expected[ids[i]]) {
        same++;
      } else {
        debugPrint('differs: ${ids[i]}\n  dart  : ${got[i]}\n  python: ${expected[ids[i]]}');
      }
    }
    debugPrint('same text on $same of ${ids.length} lines');
    expect(same, greaterThanOrEqualTo(ids.length - 1)); // (a different build of the runtime may tip one close call)
  });

  testWidgets('and reads ink drawn by the app\'s own renderer', (tester) async {
    final truth = (jsonDecode(File('$dataDir/truth.json').readAsStringSync()) as Map).cast<String, String>();
    final lines = {for (final l in jsonDecode(File('$dataDir/lines.json').readAsStringSync()) as List) (l['id'] as String): l};
    final ids = truth.keys.take(12).toList();
    final pics = <GlmPicture>[
      for (final id in ids)
        await renderInkForGlmOcr([
          for (final s in lines[id]['strokes'] as List)
            DrawingStroke(color: const Color(0xFF000000), width: 3, points: [
              for (var i = 0; i + 1 < (s as List).length; i += 2) Offset((s[i] as num).toDouble(), (s[i + 1] as num).toDouble()),
            ]),
        ]),
    ];
    final got = await read(pics);
    var errors = 0, length = 0;
    for (var i = 0; i < ids.length; i++) {
      errors += _distance(truth[ids[i]]!, got[i]);
      length += truth[ids[i]]!.length;
      debugPrint('${truth[ids[i]]}  ->  ${got[i]}');
    }
    debugPrint('character error rate ${(100 * errors / length).toStringAsFixed(1)} % on ${ids.length} lines');
    expect(errors / length, lessThan(0.25));
  });
}
