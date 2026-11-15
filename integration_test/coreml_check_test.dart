// Checks CoreML on a Mac (meant for the macOS runner of .github/workflows/coreml-check.yml): opens the formula encoder and the
// handwriting vision network with several CoreML settings and with the plain processor, runs the same pictures through each and
// says how far each answer is from the processor's, how long opening and running took, and whether a second open found its cache.
//   flutter test integration_test/coreml_check_test.dart -d macos --dart-define=MODEL_DIR=/path --dart-define=OUT=/path/coreml.json
// MODEL_DIR holds teller/encoder.onnx, teller/encoder-gpu.onnx, glm/vision.onnx, glm/vision-gpu.onnx (+ .data); missing files are left out.
// The test fails when the processor cannot run a file, or when the app's own CoreML setting ([coreMlOptions]) opens a file and answers
// more than 5 % away from the processor. Everything else is reported, not judged (a runner has no Neural Engine, for one).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/ink/glm_ocr.dart';
import 'package:notes/ink/ink_image.dart';
import 'package:notes/llm/onnx_session.dart';
import 'package:notes/models/canvas_models.dart';

const modelDir = String.fromEnvironment('MODEL_DIR');
const outFile = String.fromEnvironment('OUT');
const runs = int.fromEnvironment('RUNS', defaultValue: 3);

DrawingStroke pen(List<Offset> points) => DrawingStroke(color: const Color(0xFF000000), width: 3, points: points);

/// A wavy pen line from [x0] to [x1] around [y], a stand-in for a word.
DrawingStroke word(double x0, double x1, double y, {double height = 18}) =>
    pen([for (var x = x0; x <= x1; x += 2) Offset(x, y + height / 2 * math.sin((x - x0) / 6) + height / 4 * math.cos((x - x0) / 2.3))]);

/// Something like "x² + 1 = y" in strokes.
List<DrawingStroke> formula() => [
      pen([const Offset(0, 0), const Offset(30, 40)]), pen([const Offset(30, 0), const Offset(0, 40)]), // x
      pen([const Offset(36, -20), const Offset(44, -28), const Offset(52, -20), const Offset(36, -6), const Offset(54, -6)]), // 2
      pen([const Offset(70, 20), const Offset(100, 20)]), pen([const Offset(85, 5), const Offset(85, 35)]), // +
      pen([const Offset(115, 5), const Offset(122, 0), const Offset(122, 40)]), // 1
      pen([const Offset(140, 14), const Offset(170, 14)]), pen([const Offset(140, 26), const Offset(170, 26)]), // =
      pen([const Offset(185, 0), const Offset(200, 22)]), pen([const Offset(215, 0), const Offset(192, 50)]), // y
    ];

/// One way to open a model: a name and the options, or null for the plain processor.
typedef Way = ({String name, Future<OrtSessionOptions> Function(String path) options});

OrtSessionOptions withCoreMl(Map<String, String>? coreMl) => OrtSessionOptions(
      providers: const [OrtProvider.CORE_ML, OrtProvider.CPU],
      providerOptions: coreMl == null ? null : {OrtProvider.CORE_ML: coreMl},
      logSeverityLevel: 1, // (info: the CoreML provider says how many of the nodes it took, in how many pieces)
    );

late Directory cacheRoot;

final ways = <Way>[
  (name: 'processor', options: (_) async => OrtSessionOptions(providers: const [OrtProvider.CPU])),
  (name: 'coreml-default', options: (_) async => withCoreMl(null)), // (what the app did before: NeuralNetwork, no cache)
  (name: 'mlprogram-all', options: (p) async => withCoreMl(await coreMlOptions(p, root: cacheRoot))), // (what the app does now)
  (name: 'mlprogram-all-again', options: (p) async => withCoreMl(await coreMlOptions(p, root: cacheRoot))), // (should find the cache)
  (name: 'mlprogram-cpu', options: (p) async => withCoreMl(await coreMlOptions(p, computeUnits: 'CPUOnly', root: Directory('${cacheRoot.path}-cpu')))),
  (name: 'mlprogram-gpu', options: (p) async => withCoreMl(await coreMlOptions(p, computeUnits: 'CPUAndGPU', root: Directory('${cacheRoot.path}-gpu')))),
  (name: 'mlprogram-ane', options: (p) async => withCoreMl(await coreMlOptions(p, computeUnits: 'CPUAndNeuralEngine', root: Directory('${cacheRoot.path}-ane')))),
];

/// Inputs of one picture for a model: made fresh for each run (a run may take its inputs over).
typedef Inputs = Future<Map<String, OrtValue>> Function();

Future<Float32List> runOnce(OrtSession session, Inputs inputs) async {
  final given = await inputs();
  final out = await session.run(given);
  try {
    final flat = await out.values.first.asFlattenedList();
    return Float32List.fromList([for (final v in flat) (v as num).toDouble()]);
  } finally {
    for (final v in [...given.values, ...out.values]) {
      await v.dispose();
    }
  }
}

/// How far [a] is from [b]: the length of the difference over the length of [b], and the largest difference.
({double relative, double largest}) distance(Float32List a, Float32List b) {
  if (a.length != b.length) return (relative: double.infinity, largest: double.infinity);
  var diff = 0.0, norm = 0.0, largest = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d.isNaN || a[i].isNaN) return (relative: double.nan, largest: double.nan);
    diff += d * d;
    norm += b[i] * b[i];
    largest = math.max(largest, d);
  }
  return (relative: math.sqrt(diff / math.max(norm, 1e-30)), largest: largest);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CoreML gives the processor\'s answers, and how fast', (tester) async {
    cacheRoot = Directory('${Directory.systemTemp.path}/coreml-check-${DateTime.now().millisecondsSinceEpoch}');
    final results = <Map<String, Object?>>[];
    final failures = <String>[];

    // the pictures: one formula; two lines of handwriting of different widths (CoreML with an input size it has not seen yet)
    final teller = await renderInkForTexTeller(formula());
    Inputs tellerInputs() => () async => {'pixel_values': await OrtValue.fromList(teller, [1, 1, texTellerImageSize, texTellerImageSize])};
    final lines = [
      await renderInkForGlmOcr([word(0, 120, 20), word(140, 260, 22)], rows: 10, pad: true),
      await renderInkForGlmOcr([for (var i = 0; i < 6; i++) word(i * 140.0, i * 140.0 + 120, 20 + (i % 2) * 3.0)], rows: 10, pad: true),
    ];
    Inputs glmInputs(GlmPicture p) => () async => {
          'pixel_values': await OrtValue.fromList(p.patches, [p.count, 3 * 2 * glmPatch * glmPatch]),
          'pos_ids': await int64Value(glmPatchPositions(p.gridHeight, p.gridWidth), [p.count, 2]),
        };

    final models = <String, List<({String label, Inputs inputs})>>{
      'teller/encoder.onnx': [(label: 'formula', inputs: tellerInputs())],
      'teller/encoder-gpu.onnx': [(label: 'formula', inputs: tellerInputs())],
      'glm/vision.onnx': [for (final p in lines) (label: '${p.gridHeight}x${p.gridWidth}', inputs: glmInputs(p))],
      'glm/vision-gpu.onnx': [for (final p in lines) (label: '${p.gridHeight}x${p.gridWidth}', inputs: glmInputs(p))],
    };

    debugPrint('coreml-check: CoreML available: ${await OnnxRuntime().getAvailableProviders()}');
    for (final MapEntry(key: name, value: pictures) in models.entries) {
      final path = '$modelDir/$name';
      if (!File(path).existsSync()) {
        debugPrint('coreml-check: $name not in $modelDir, left out');
        continue;
      }
      final reference = <String, Float32List>{};
      for (final way in ways) {
        final row = <String, Object?>{'model': name, 'way': way.name};
        results.add(row);
        OrtSession? session;
        try {
          final opening = Stopwatch()..start();
          session = await OnnxRuntime().createSession(path, options: await way.options(path));
          row['openMs'] = opening.elapsedMilliseconds;
          for (final picture in pictures) {
            final first = Stopwatch()..start();
            final answer = await runOnce(session, picture.inputs);
            final firstMs = first.elapsedMilliseconds;
            final times = <int>[];
            for (var i = 0; i < runs; i++) {
              final w = Stopwatch()..start();
              await runOnce(session, picture.inputs);
              times.add(w.elapsedMilliseconds);
            }
            times.sort();
            final picked = <String, Object?>{'firstMs': firstMs, 'runMs': times.isEmpty ? null : times[times.length ~/ 2]};
            if (way.name == 'processor') {
              reference[picture.label] = answer;
            } else if (reference[picture.label] case final ref?) {
              final d = distance(answer, ref);
              picked['relativeError'] = d.relative;
              picked['largestDifference'] = d.largest;
              if (way.name.startsWith('mlprogram-all') && !(d.relative <= 0.05)) {
                failures.add('$name ${way.name} ${picture.label}: ${(d.relative * 100).toStringAsFixed(2)} % from the processor');
              }
            }
            row[picture.label] = picked;
          }
        } catch (e) {
          row['error'] = '$e';
          if (way.name == 'processor') failures.add('$name on the processor: $e');
        } finally {
          await session?.close();
        }
        debugPrint('coreml-check | ${jsonEncode(row)}');
      }
    }

    // a short table for the job's log
    debugPrint('coreml-check: ---- summary (open ms; per picture: first run ms / median run ms / error vs processor) ----');
    for (final r in results) {
      String part(String label, Map<String, Object?> m) {
        final err = m['relativeError'];
        return '$label: ${m['firstMs']}/${m['runMs']} ms${err is double ? ' ${(err * 100).toStringAsFixed(2)} %' : ''}';
      }

      final parts = [
        for (final e in r.entries)
          if (e.value case final Map<String, Object?> m) part(e.key, m),
      ];
      debugPrint('coreml-check | ${r['model']} | ${r['way']} | open ${r['openMs'] ?? '-'} | ${r['error'] ?? parts.join(' | ')}');
    }
    if (outFile.isNotEmpty) File(outFile).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(results));
    expect(results, isNotEmpty, reason: 'no model files in $modelDir');
    expect(failures, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 90)));
}
