// Runs the real Whisper through ONNX Runtime. Needs `encoder.onnx`, `decoder.onnx`, `tokenizer.json` and `config.json`
// (see WhisperSpec) in one folder, and `audio16k.f32` (16 kHz mono float32 speech):
//   flutter test integration_test/whisper_onnx_test.dart -d linux --dart-define=MODEL_DIR=/path --dart-define=EXPECT=...
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/speech/speech_to_text.dart';
import 'package:notes/speech/whisper_tokenizer.dart';

const dir = String.fromEnvironment('MODEL_DIR');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the real Whisper writes down what is said', (tester) async {
    final config = jsonDecode(File('$dir/config.json').readAsStringSync()) as Map;
    final engine = OnnxWhisper(
      encoderPath: '$dir/encoder.onnx',
      decoderPath: '$dir/decoder.onnx',
      tokenizer: WhisperTokenizer.parse(File('$dir/tokenizer.json').readAsStringSync()),
      suppressed: {for (final t in config['suppress_tokens'] as List) (t as num).toInt()},
      layers: config['decoder_layers'] as int,
      heads: config['decoder_attention_heads'] as int,
    );
    final bytes = File('$dir/audio16k.f32').readAsBytesSync();
    final samples = Float32List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
    final watch = Stopwatch()..start();
    String? found;
    final text = await engine.transcribe(samples, detected: (l) => found = l);
    debugPrint('wrote "$text" (language $found) in ${watch.elapsedMilliseconds} ms');
    expect(found, 'en');
    expect(text.toLowerCase(), contains('mitochondria'));
    expect(text.toLowerCase(), contains('contract law'));
    final again = await engine.transcribe(samples, language: 'en');
    expect(again, text);
    await engine.close();
  });
}
