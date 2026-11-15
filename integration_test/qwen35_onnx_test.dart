// Runs the real Qwen3.5-0.8B (text only) through ONNX Runtime. Needs `model_q4.onnx`, `model_q4.onnx_data` and `tokenizer.json` from
// onnx-community/Qwen3.5-0.8B-Text-ONNX in one folder, and optionally `ref.json` there ({"prompt": [ids], "ref": [ids]}: what the
// reference run of the Hugging Face model gives for the chat below):
//   flutter test integration_test/qwen35_onnx_test.dart -d linux --dart-define=MODEL_DIR=/path
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/llm/onnx_chat_provider.dart';
import 'package:notes/llm/onnx_qwen.dart';
import 'package:notes/llm/qwen_tokenizer.dart';

const dir = String.fromEnvironment('MODEL_DIR');

// The 2B and larger models come as a decoder plus a separate model for the words: MODEL_FILE=decoder_model_merged_q4.onnx
// EMBED_FILE=embed_tokens_q4.onnx (and the shape of the cache is read from the model itself).
const modelFile = String.fromEnvironment('MODEL_FILE', defaultValue: 'model_q4.onnx');
const embedFile = String.fromEnvironment('EMBED_FILE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the real model reads the chat and answers sensibly (state of the linear layers, hidden position, one score row)', (tester) async {
    final tok = QwenTokenizer.parse(File('$dir/tokenizer.json').readAsStringSync());
    final lm = OnnxQwen('$dir/$modelFile', layers: 24, kvHeads: 2, headDim: 256, embedPath: embedFile.isEmpty ? null : '$dir/$embedFile');
    final stop = {tok.idOf('<|im_end|>')!, tok.idOf('<|endoftext|>')!};
    try {
      final parts = OnnxChatProvider.chat(const AiPrompt(system: 'You are a helpful assistant.', user: 'Name three primary colours and say one word about each.'));
      final start = tok.encode(parts.fixed);
      final prompt = [...start, ...tok.encode(parts.question)];
      final ref = File('$dir/ref.json');
      if (ref.existsSync()) {
        final r = jsonDecode(ref.readAsStringSync()) as Map<String, dynamic>;
        expect(prompt, (r['prompt'] as List).cast<int>(), reason: 'the same tokens as the reference tokenizer');
      }
      for (var round = 0; round < 2; round++) {
        final watch = Stopwatch()..start();
        final ids = await lm.generate(prompt, sharedPrefix: start.length, maxNewTokens: 64, stop: stop);
        final answer = tok.decode(ids);
        debugPrint('round $round: "${answer.replaceAll('\n', ' ')}" (${watch.elapsedMilliseconds} ms, ${ids.length} tokens)');
        expect(answer, contains('Red'), reason: round == 0 ? 'first answer' : 'with the prefix kept from the first');
        expect(answer, contains('Blue'));
      }
    } finally {
      await lm.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
