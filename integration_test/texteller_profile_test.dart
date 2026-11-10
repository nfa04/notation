// Where the time of one TexTeller reading goes, through the plugin: the picture, the encoder, each decoder step (the call, the
// scores coming back, the keys and values). Same dart-defines as texteller_onnx_test.dart, and THREADS (default: the app's choice).
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/ink/ink_image.dart';
import 'package:notes/ink/math_decoder.dart';
import 'package:notes/ink/onnx_texteller_model.dart';
import 'package:notes/ink/texteller_decoder.dart';

import 'texteller_onnx_test.dart' show readInk;

const modelDir = String.fromEnvironment('MODEL_DIR');
const inkDir = String.fromEnvironment('INK_DIR');
const inkList = String.fromEnvironment('INK_LIST');
const count = int.fromEnvironment('COUNT', defaultValue: 30);
const threads = int.fromEnvironment('THREADS', defaultValue: 0);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('where the time of a TexTeller reading goes', (tester) async {
    final ids = File(inkList).readAsLinesSync().where((l) => l.trim().isNotEmpty).take(count).toList();
    final vocab = MathVocab.parse(await rootBundle.loadString('assets/texteller/vocab.txt'));
    final model = await OnnxTexTeller.open('$modelDir/encoder.onnx', '$modelDir/decoder.onnx', threads: threads == 0 ? null : threads);
    try {
      // the first reading opens the sessions; leave it out of the averages
      final warm = readInk('$inkDir/${ids.first}.inkml');
      final cold = Stopwatch()..start();
      await model.read(await renderInkForTexTeller(warm.strokes));
      final coldMs = cold.elapsedMilliseconds;
      final opened = Map.of(model.spent);
      model.spent.clear();
      model.steps = 0;

      final total = Stopwatch()..start();
      var tokens = 0;
      final per = <int>[];
      for (final id in ids.skip(1)) {
        final ink = readInk('$inkDir/$id.inkml');
        final watch = Stopwatch()..start();
        final got = await model.read(await renderInkForTexTeller(ink.strokes));
        per.add(watch.elapsedMilliseconds);
        tokens += got.length;
        texTellerLatex(vocab, got);
      }
      per.sort();
      final n = ids.length - 1;
      final lines = [
        'threads ${model.threads}: first (opens the sessions) $coldMs ms, opening itself ${(opened['open'] ?? 0) ~/ 1000} ms',
        'median ${per[per.length ~/ 2]} ms, p90 ${per[(per.length * 0.9).floor() - 1]} ms, mean ${total.elapsedMilliseconds ~/ n} ms over $n inks, ${(tokens / n).toStringAsFixed(1)} tokens, ${(model.steps / n).toStringAsFixed(1)} steps each',
        for (final e in (model.spent.entries.toList()..sort((a, b) => b.value.compareTo(a.value))))
          '  ${e.key.padRight(14)} ${(e.value / n / 1000).toStringAsFixed(1).padLeft(7)} ms per ink'
              '${e.key.startsWith('step.') && model.steps > 0 ? '  (${(e.value / model.steps / 1000).toStringAsFixed(2)} ms per step)' : ''}',
      ];
      debugPrint('PROFILE\n${lines.join('\n')}');
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
