// Which reader writes handwritten formulas better: the handwriting reader (GLM-OCR, which writes maths as LaTeX between dollar signs
// as it reads a line) or the maths check's formula reader (TexTeller), on InkML files of real handwritten formulas with their LaTeX
// (MathWriting, https://github.com/google-research/google-research/tree/master/mathwriting: not part of the repo, its licence is
// non-commercial), each read the way the app reads a row:
//   flutter test integration_test/formula_reader_compare_test.dart -d linux --dart-define=MODEL_DIR=$HOME/hw-bench/glm_release \
//     --dart-define=MATH_DIR=/path/to/texteller --dart-define=INK_DIR=/path/to/mathwriting/test [--dart-define=COUNT=100] [--dart-define=OUT=/path/out.json]
// Prints the character error of each against the label (spaces, braces, dollar signs and the like left out) and how long each took.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/ink/glm_ocr.dart';
import 'package:notes/ink/glm_ocr_service.dart';
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/ink/ink_grouping.dart';
import 'package:notes/ink/ink_image.dart';
import 'package:notes/ink/math_service.dart';
import 'package:notes/ink/onnx_glm_ocr.dart';
import 'package:notes/models/canvas_models.dart';

import 'ink_read_eval_test.dart' show distance, normalise;

const modelDir = String.fromEnvironment('MODEL_DIR');
const mathDir = String.fromEnvironment('MATH_DIR');
const inkDirs = String.fromEnvironment('INK_DIR');
const count = int.fromEnvironment('COUNT', defaultValue: 100);
const outPath = String.fromEnvironment('OUT');

({String label, List<DrawingStroke> strokes}) readInk(String path) {
  final text = File(path).readAsStringSync();
  final label = RegExp(r'type="normalizedLabel">(.*?)</annotation>', dotAll: true).firstMatch(text)!.group(1)!;
  var strokes = <DrawingStroke>[];
  for (final m in RegExp(r'<trace id=[^>]*>(.*?)</trace>', dotAll: true).allMatches(text)) {
    final points = [
      for (final p in m.group(1)!.split(','))
        if (p.trim().isNotEmpty) Offset(double.parse(p.trim().split(RegExp(r'\s+'))[0]), double.parse(p.trim().split(RegExp(r'\s+'))[1])),
    ];
    if (points.length >= 2) strokes.add(DrawingStroke(color: const Color(0xFF000000), width: 3, points: points));
  }
  // (the devices differ a hundredfold in their units: written at the size of a page's handwriting, a letter about 30 high)
  final scale = 30 / letterHeight([for (final s in strokes) strokeBounds(s)]);
  strokes = [for (final s in strokes) DrawingStroke(color: s.color, width: 3, points: [for (final p in s.points) p * scale])];
  return (label: label.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&'), strokes: strokes);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('both readers read real handwritten formulas', (tester) async {
    await tester.runAsync(() async {
      final vocabulary = GlmVocabulary.parse(File('assets/glm_ocr/vocab.txt').readAsStringSync());
      final glm = GlmOnnxReader();
      final teller = MathService(defaultModel: FormulaModel.texteller, tellerDirectory: () async => Directory(mathDir));
      await teller.load();
      final files = [
        for (final dir in inkDirs.split(','))
          ...(Directory(dir).listSync().whereType<File>().where((f) => f.path.endsWith('.inkml')).toList()..sort((a, b) => a.path.compareTo(b.path))),
      ].take(count);
      var glmErrors = 0, tellerErrors = 0, chars = 0, glmExact = 0, tellerExact = 0, n = 0;
      var glmMs = 0, tellerMs = 0;
      final out = <Map<String, Object?>>[];
      for (final f in files) {
        final ink = readInk(f.path);
        final want = normalise(ink.label);
        if (want.isEmpty) continue;
        var watch = Stopwatch()..start();
        // as the app reads a row as text: its lines, each in pieces
        final pieces = [for (final line in groupIntoLines(ink.strokes)) ...GlmOcrService.joinChunks(line)];
        final pictures = [for (final p in pieces) await renderInkForGlmOcr(p, rows: GlmQuality.standard.rows)];
        final tokens = await glm.read('$modelDir/vision.onnx', '$modelDir/text.onnx', '$modelDir/embeddings.bin', pictures);
        final byGlm = [for (final t in tokens) vocabulary.decode(t)].join(' ');
        glmMs += watch.elapsedMilliseconds;
        watch = Stopwatch()..start();
        final byTeller = await teller.recognize(ink.strokes);
        tellerMs += watch.elapsedMilliseconds;
        final g = distance(want, normalise(byGlm)), t = distance(want, normalise(byTeller));
        glmErrors += g;
        tellerErrors += t;
        chars += want.length;
        if (g == 0) glmExact++;
        if (t == 0) tellerExact++;
        n++;
        out.add({'file': f.path.split('/').last, 'label': ink.label, 'glm': byGlm, 'teller': byTeller, 'glmCer': g / want.length, 'tellerCer': t / want.length});
      }
      await glm.close();
      debugPrint('$n formulas, $chars characters:\n'
          '  handwriting reader (GLM):   ${(100 * glmErrors / math.max(1, chars)).toStringAsFixed(1)} % character error, $glmExact exact, ${glmMs ~/ math.max(1, n)} ms each\n'
          '  formula reader (TexTeller): ${(100 * tellerErrors / math.max(1, chars)).toStringAsFixed(1)} % character error, $tellerExact exact, ${tellerMs ~/ math.max(1, n)} ms each');
      if (outPath.isNotEmpty) File(outPath).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    });
  }, timeout: const Timeout(Duration(minutes: 90)));
}
