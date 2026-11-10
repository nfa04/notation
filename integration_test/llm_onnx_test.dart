// Runs the real Qwen3-0.6B through ONNX Runtime. Needs `model_int8.onnx` and
// `tokenizer.json` from onnx-community/Qwen3-0.6B-ONNX in one folder:
//   flutter test integration_test/llm_onnx_test.dart -d linux --dart-define=MODEL_DIR=/path
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/llm/llm_service.dart';
import 'package:notes/llm/onnx_qwen.dart';
import 'package:notes/llm/qwen_tokenizer.dart';

const dir = String.fromEnvironment('MODEL_DIR');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the real model writes the same titles as the reference run', (tester) async {
    final tok = QwenTokenizer.parse(File('$dir/tokenizer.json').readAsStringSync());
    final lm = OnnxQwen('$dir/model_int8.onnx');
    final stop = {tok.idOf('<|im_end|>')!, tok.idOf('<|endoftext|>')!};
    try {
      // (input, what a greedy run of the same model gives in Python's ONNX Runtime, reading the examples first and the question after)
      const cases = {
        'Final exam': 'Final exam',
        'Exercise session moved to (Thursday)': 'Exercise session moved to Thursday',
        'Please note that the library will be closed for renovation': 'Library renovation closing',
      };
      for (final e in cases.entries) {
        final watch = Stopwatch()..start();
        final (fixed, question) = LlmService.promptParts(e.key);
        final start = tok.encode(fixed);
        // the first request reads the instructions and examples, the others reuse that
        final ids = await lm.generate([...start, ...tok.encode(question)],
            sharedPrefix: start.length, maxNewTokens: 24, stop: stop);
        final answer = tok.decode(ids);
        debugPrint('"${e.key}" -> "$answer" (${watch.elapsedMilliseconds} ms, ${ids.length} tokens)');
        // (reusing the examples' cache changes the last digits of the scores: a full stop may come or go)
        expect(answer.replaceAll(RegExp(r'\.$'), ''), e.value);
      }
    } finally {
      await lm.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
