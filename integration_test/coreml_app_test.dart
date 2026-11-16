// The app's own CoreML path on a Mac (meant for .github/workflows/coreml-check.yml): the handwriting reader's 16-bit vision network
// through openWarmSession with its input size pinned (one CoreML session per picture width, a cache folder per width), and the formula
// encoder through openOnnxSession.
//   flutter test integration_test/coreml_app_test.dart -d macos --dart-define=MODEL_DIR=/path --dart-define=OUT=/path/app.json
// MODEL_DIR holds glm/vision-gpu.onnx (+ .data), glm/vision.onnx (the processor's file) and teller/encoder-gpu.onnx.
// Fails when CoreML does not take a model, answers far from the processor, or builds a width again that it had built (the cache).
// While a test runs the app's log does not reach the job: every step is also written to OUT.progress.
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
import 'package:notes/ink/onnx_glm_ocr.dart' show glmVisionPin;
import 'package:notes/llm/onnx_session.dart';
import 'package:notes/llm/warm_session.dart';
import 'package:notes/models/canvas_models.dart';

const modelDir = String.fromEnvironment('MODEL_DIR');
const outFile = String.fromEnvironment('OUT');

final _clock = Stopwatch()..start();

void say(String text) {
  final line = 'coreml-app [${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s] $text';
  debugPrint(line);
  if (outFile.isNotEmpty) File('$outFile.progress').writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

DrawingStroke pen(List<Offset> points) => DrawingStroke(color: const Color(0xFF000000), width: 3, points: points);

DrawingStroke word(double x0, double x1, double y) =>
    pen([for (var x = x0; x <= x1; x += 2) Offset(x, y + 9 * math.sin((x - x0) / 6) + 4.5 * math.cos((x - x0) / 2.3))]);

/// The answer's numbers, then let go of.
Future<Float32List> numbers(Map<String, OrtValue> out) async {
  try {
    final flat = await out.values.first.asFlattenedList();
    return Float32List.fromList([for (final v in flat) (v as num).toDouble()]);
  } finally {
    for (final v in out.values) {
      await v.dispose();
    }
  }
}

double relative(Float32List a, Float32List b) {
  if (a.length != b.length) return double.infinity;
  var diff = 0.0, norm = 0.0;
  for (var i = 0; i < a.length; i++) {
    diff += (a[i] - b[i]) * (a[i] - b[i]);
    norm += b[i] * b[i];
  }
  return math.sqrt(diff / math.max(norm, 1e-30));
}

/// Every file under [dir] with its size and time: a CoreML build writes new files, a load from the cache does not.
Map<String, String> snapshot(Directory dir) => {
      if (dir.existsSync())
        for (final f in dir.listSync(recursive: true).whereType<File>()) f.path: '${f.lengthSync()}@${f.lastModifiedSync().millisecondsSinceEpoch}',
    };

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CoreML through the app: built once per width, answers like the processor', (tester) async {
    final results = <String, Object?>{};
    final failures = <String>[];
    void save() {
      if (outFile.isNotEmpty) File(outFile).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(results));
    }

    onnxAccelerationEnabled = true;
    say('providers: ${await onnxAvailableAccelerators()}; CoreML in use: ${await onnxUsesCoreMl()}');
    expect(await onnxUsesCoreMl(), isTrue, reason: 'this check is for a Mac (or iPad) with CoreML');

    final gpu = '$modelDir/glm/vision-gpu.onnx', standard = '$modelDir/glm/vision.onnx', teller = '$modelDir/teller/encoder-gpu.onnx';
    // two lines of different widths, padded as the app pads them under CoreML
    final pictures = [
      await renderInkForGlmOcr([word(0, 120, 20), word(140, 260, 22)], rows: 10, pad: true),
      await renderInkForGlmOcr([for (var i = 0; i < 5; i++) word(i * 140.0, i * 140.0 + 120, 20)], rows: 10, pad: true),
    ];
    String keyOf(GlmPicture p) => '${p.gridHeight}x${p.gridWidth}';
    Future<Map<String, OrtValue>> Function() inputsOf(GlmPicture p) => () async => {
          'pixel_values': await OrtValue.fromList(p.patches, [p.count, 3 * 2 * glmPatch * glmPatch]),
          'pos_ids': await int64Value(glmPatchPositions(p.gridHeight, p.gridWidth), [p.count, 2]),
        };
    say('widths: ${pictures.map(keyOf).toList()}');

    // the processor's answers of the same 16-bit file, to compare with
    final reference = <String, Float32List>{};
    final cpu = await openOnnxSession(gpu, accelerate: false);
    for (final p in pictures) {
      final given = await inputsOf(p)();
      reference[keyOf(p)] = await numbers(await cpu.run(given));
      for (final v in given.values) {
        await v.dispose();
      }
    }
    await cpu.close();
    say('processor answers ready');

    // 1. the first start: every width is built once (the processor reads meanwhile)
    var vision = await openWarmSession(gpu, accelerate: true, pin: glmVisionPin, processorPath: File(standard).existsSync() ? standard : null);
    for (final p in pictures) {
      final key = keyOf(p);
      final first = Stopwatch()..start();
      await numbers(await vision.run(inputsOf(p), key: key));
      final firstMs = first.elapsedMilliseconds;
      final building = Stopwatch()..start();
      while (!vision.ready.contains(key) && building.elapsed < const Duration(minutes: 10)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (vision.compiling == null && !vision.ready.contains(key)) {
          await numbers(await vision.run(inputsOf(p), key: key)); // (the build ended: run again on the accelerator)
        }
      }
      if (!vision.ready.contains(key)) {
        failures.add('$key: CoreML did not take the vision network (${onnxSessionReport['vision-gpu.onnx']})');
        continue;
      }
      final run = Stopwatch()..start();
      final answer = await numbers(await vision.run(inputsOf(p), key: key));
      final err = relative(answer, reference[key]!);
      results['vision $key first start'] = {'firstReadMs': firstMs, 'builtWithinMs': building.elapsedMilliseconds, 'runMs': run.elapsedMilliseconds, 'relativeError': err};
      say('vision $key: first read $firstMs ms, built within ${building.elapsedMilliseconds} ms, then ${run.elapsedMilliseconds} ms, ${(err * 100).toStringAsFixed(2)} % from the processor');
      // (the network magnifies small differences: 5 to 9 % was measured with the same text read; far more is a wrong answer)
      if (!(err < 0.15)) failures.add('vision $key: ${(err * 100).toStringAsFixed(1)} % from the processor');
      save();
    }
    await vision.close();
    say('report: ${onnxSessionReport['vision-gpu.onnx']}');

    // 2. the next start: every width comes from the cache, nothing is built again
    final caches = {for (final p in pictures) keyOf(p): Directory((await coreMlCacheFolder(gpu, fixed: {glmVisionPin.name: p.count}))!)};
    final before = {for (final e in caches.entries) e.key: snapshot(e.value)};
    vision = await openWarmSession(gpu, accelerate: true, pin: glmVisionPin, processorPath: File(standard).existsSync() ? standard : null);
    for (final p in pictures) {
      final key = keyOf(p);
      final first = Stopwatch()..start();
      await numbers(await vision.run(inputsOf(p), key: key));
      final firstMs = first.elapsedMilliseconds;
      final waiting = Stopwatch()..start();
      while (!vision.ready.contains(key) && waiting.elapsed < const Duration(minutes: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (vision.compiling == null && !vision.ready.contains(key)) await numbers(await vision.run(inputsOf(p), key: key));
      }
      final after = snapshot(caches[key]!);
      final written = {for (final e in after.entries) if (before[key]![e.key] != e.value) e.key};
      results['vision $key next start'] = {'firstReadMs': firstMs, 'readyWithinMs': waiting.elapsedMilliseconds, 'filesWritten': written.length, 'cacheFiles': after.length};
      say('vision $key next start: first read $firstMs ms, ready within ${waiting.elapsedMilliseconds} ms, ${written.length} cache files written (of ${after.length})');
      if (after.isEmpty) failures.add('vision $key: nothing in its cache folder ${caches[key]!.path}');
      if (written.isNotEmpty) failures.add('vision $key: built again at the next start (${written.take(3).join(', ')})');
      save();
    }
    await vision.close();

    // 3. the formula encoder: one size, on CoreML through openOnnxSession
    if (File(teller).existsSync()) {
      final pixels = await renderInkForTexTeller([pen([const Offset(0, 0), const Offset(30, 40)]), pen([const Offset(30, 0), const Offset(0, 40)]), pen([const Offset(50, 20), const Offset(80, 20)])]);
      Future<Map<String, OrtValue>> given() async => {'pixel_values': await OrtValue.fromList(pixels, [1, 1, texTellerImageSize, texTellerImageSize])};
      final onCpu = await openOnnxSession(teller, accelerate: false);
      final ref = await numbers(await onCpu.run(await given()));
      await onCpu.close();
      final opening = Stopwatch()..start();
      final onCoreMl = await openOnnxSession(teller);
      final openMs = opening.elapsedMilliseconds;
      final where = onnxSessionReport['encoder-gpu.onnx'];
      final answer = await numbers(await onCoreMl.run(await given()));
      await onCoreMl.close();
      final err = relative(answer, ref);
      results['formula encoder'] = {'on': where, 'openMs': openMs, 'relativeError': err};
      say('formula encoder on $where, opened in $openMs ms, ${(err * 100).toStringAsFixed(2)} % from the processor');
      if (where != 'CORE_ML') failures.add('formula encoder not on CoreML: $where');
      if (!(err < 0.05)) failures.add('formula encoder: ${(err * 100).toStringAsFixed(1)} % from the processor');
    }
    save();
    say(failures.isEmpty ? 'all good' : 'failures: $failures');
    expect(failures, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 60)));
}
