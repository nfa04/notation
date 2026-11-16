// On an Android phone with QNN: runs the parts of the handwriting reader's 16-bit vision network (tool/split_glm_vision.py) one after the
// other, each on QNN and on the processor, with the app's own session code (the compiled files in qnn_cache are used and made as in
// the app). Says for each part whether QNN ran it, how long opening and running took, how far QNN's answer is from the processor's,
// and the memory of the app. The processor's answer is passed on, so a part that fails on QNN does not stop the parts after it.
//   flutter test integration_test/qnn_parts_probe_test.dart -d <phone> [--dart-define=PATCHES=640] [--dart-define=FRESH=1]
// FRESH=1 deletes the compiled files of the parts first (each is compiled again).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/ink/glm_ocr.dart';
import 'package:notes/llm/onnx_session.dart';

const dir = '/data/user/0/io.github.nfa04.notation/files/models/glm_ocr';
const patches = int.fromEnvironment('PATCHES', defaultValue: 640);
const fresh = bool.fromEnvironment('FRESH');

int rssMb() {
  final line = File('/proc/self/status').readAsLinesSync().firstWhere((l) => l.startsWith('VmRSS:'));
  return int.parse(line.split(RegExp(r'\s+'))[1]) ~/ 1024;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the parts of the vision network on QNN', (tester) async {
    onnxAccelerationEnabled = true;
    if (fresh) {
      for (final f in Directory('$dir/qnn_cache').listSync().whereType<File>().where((f) => f.path.contains('vision-gpu.part'))) {
        f.deleteSync();
      }
    }
    final rows = 8, columns = patches ~/ rows;
    final rng = math.Random(1);
    final known = <String, OrtValue>{
      'pixel_values': await OrtValue.fromList(Float32List.fromList(List.generate(patches * 1176, (_) => rng.nextDouble() * 2 - 1)), [patches, 1176]),
      'pos_ids': await int64Value(glmPatchPositions(rows, columns), [patches, 2]),
    };
    debugPrint('probe: $patches patches, app at ${rssMb()} MB');
    for (var i = 1; File('$dir/vision-gpu.part$i.onnx').existsSync(); i++) {
      final path = '$dir/vision-gpu.part$i.onnx';
      final fixed = OrtSessionOptions(intraOpNumThreads: 4, useArena: false, freeDimensions: {'4*m': patches});
      Map<String, OrtValue>? onQnn;
      var timer = Stopwatch()..start();
      try {
        final s = await openOnnxSession(path, options: fixed);
        final opened = timer.elapsedMilliseconds;
        final rssOpen = rssMb();
        timer = Stopwatch()..start();
        onQnn = await s.run({for (final n in s.inputNames) n: known[n]!});
        final first = timer.elapsedMilliseconds;
        timer = Stopwatch()..start();
        for (final v in (await s.run({for (final n in s.inputNames) n: known[n]!})).values) {
          await v.dispose();
        }
        debugPrint('probe: part $i on the accelerator: first run $first ms, second run ${timer.elapsedMilliseconds} ms');
        debugPrint('probe: part $i on the accelerator: opened in $opened ms (app at $rssOpen MB), ran in ${timer.elapsedMilliseconds} ms, '
            'app at ${rssMb()} MB (where it ran: the "ran as" line before this)');
        await s.close();
      } catch (e) {
        debugPrint('probe: part $i on the accelerator FAILED after ${timer.elapsedMilliseconds} ms: ${e.toString().split('\n').first}');
      }
      timer = Stopwatch()..start();
      final cpu = await openOnnxSession(path, options: OrtSessionOptions(intraOpNumThreads: 4, useArena: false), accelerate: false);
      final onCpu = await cpu.run({for (final n in cpu.inputNames) n: known[n]!});
      debugPrint('probe: part $i on the processor: ${timer.elapsedMilliseconds} ms');
      await cpu.close();
      if (onQnn != null) {
        for (final name in onCpu.keys) {
          final a = await onQnn[name]!.asFlattenedList(), b = await onCpu[name]!.asFlattenedList();
          var worst = 0.0, top = 0.0;
          for (var k = 0; k < b.length; k++) {
            worst = math.max(worst, ((a[k] as num) - (b[k] as num)).abs().toDouble());
            top = math.max(top, (b[k] as num).abs().toDouble());
          }
          debugPrint('probe: part $i, $name: QNN differs from the processor by at most $worst (values up to $top)');
        }
        for (final v in onQnn.values) {
          await v.dispose();
        }
      }
      known.addAll(onCpu);
    }
    debugPrint('probe: done, app at ${rssMb()} MB');
  });
}
