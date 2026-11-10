// Runs a real Qwen model for summaries (default Qwen3-1.7B) through ONNX Runtime. Needs
// `model_int8.onnx` (or the spec's modelFile, with its data files) and `tokenizer.json` of the model's onnx-community repository in one folder:
//   flutter test integration_test/llm_large_onnx_test.dart -d linux --dart-define=MODEL_DIR=/path
// and for another size --dart-define=MODEL=qwen2.5-0.5b (see ChatModelSpec)
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/llm/chat_models.dart';
import 'package:notes/llm/onnx_chat_provider.dart';
import 'package:notes/llm/onnx_qwen.dart';
import 'package:notes/llm/qwen_tokenizer.dart';

const dir = String.fromEnvironment('MODEL_DIR');
const threads = int.fromEnvironment('THREADS', defaultValue: 4);
const modelFile = String.fromEnvironment('MODEL_FILE');
const modelId = String.fromEnvironment('MODEL', defaultValue: 'qwen3-1.7b');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the larger model summarizes, streams and can be stopped', (tester) async {
    final tok = QwenTokenizer.parse(File('$dir/tokenizer.json').readAsStringSync());
    final spec = ChatModelSpec.all.firstWhere((s) => s.id == modelId);
    final lm = OnnxQwen('$dir/${modelFile.isEmpty ? spec.modelFile : modelFile}', layers: spec.layers, kvHeads: spec.kvHeads, headDim: spec.headDim, threads: threads);
    final stop = {tok.idOf('<|im_end|>')!, tok.idOf('<|endoftext|>')!};
    const text = 'The second law of thermodynamics states that the total entropy of an isolated system can never decrease '
        'over time. It can remain constant in ideal cases where the system is in a steady state or undergoing a '
        'reversible process. The increase in total entropy of the universe is the reason why processes such as '
        'heat flowing from hot to cold are irreversible.';
    final parts = OnnxChatProvider.chat(SummaryConfig.defaults.copyWith(length: SummaryLength.brief).promptFor(text), thinking: spec.thinking);
    final start = tok.encode(parts.fixed);
    final prompt = [...start, ...tok.encode(parts.question)];
    try {
      await lm.generate(prompt.sublist(0, 20), maxNewTokens: 1, stop: stop); // loads the model
      for (final n in [1, 11, 31]) {
        final w = Stopwatch()..start();
        await lm.generate(prompt, sharedPrefix: start.length, maxNewTokens: n, stop: {}, repetitionPenalty: 1.1);
        debugPrint('BENCH prompt=${prompt.length} shared=${start.length} new=$n -> ${w.elapsedMilliseconds} ms');
      }
      final watch = Stopwatch()..start();
      var progress = 0;
      final ids = await lm.generate(prompt,
          sharedPrefix: start.length, maxNewTokens: 120, stop: stop, repetitionPenalty: 1.1, onProgress: (t) => progress = t.length);
      final answer = tok.decode(ids).trim();
      debugPrint('summary (${ids.length} tokens, ${watch.elapsedMilliseconds} ms): $answer');
      expect(progress, ids.length); // it was told about every token
      expect(answer.toLowerCase(), contains('entropy'));
      expect(ids.length, lessThan(120)); // it ended by itself

      // stopped after a few tokens
      var count = 0;
      final short = await lm.generate(prompt,
          sharedPrefix: start.length, maxNewTokens: 120, stop: stop, onProgress: (t) => count = t.length, shouldStop: () => count >= 5);
      expect(short.length, 5);
    } finally {
      await lm.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
