import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ink/math_service.dart';
import 'package:notes/ink/paddle_vl_service.dart';
import 'package:notes/llm/chat_models.dart';
import 'package:notes/llm/embedding_service.dart';
import 'package:notes/llm/llm_service.dart';
import 'package:notes/llm/model_pins.dart';
import 'package:notes/scan/ocr_service.dart';
import 'package:notes/speech/speech_to_text.dart';

void main() {
  test('every script the text reader offers is pinned (its files are built from the language)', () {
    for (final l in OcrLanguage.all) {
      for (final path in ['detection/v3/det.onnx', 'languages/${l.id}/rec.onnx', 'languages/${l.id}/dict.txt']) {
        expect(pinnedDownload('https://huggingface.co/monkt/paddleocr-onnx/resolve/main/$path').sha256, isNotNull, reason: path);
      }
    }
  });

  final urls = <String>{
    for (final m in ChatModelSpec.all) ...m.files.values.map((f) => f.url),
    for (final m in EmbeddingModelSpec.all) ...m.files.values.map((f) => f.url),
    for (final m in WhisperSpec.all) ...m.files.values.map((f) => f.url),
    ...PaddleVlService.modelFiles.values.map((f) => f.url),
    ...LlmService.modelFiles.values.map((f) => f.url),
    ...MathService.modelFiles.values.map((f) => f.url),
  };

  test('every file the app fetches from somebody else on Hugging Face is pinned', () {
    expect(urls, isNotEmpty);
    for (final u in urls) {
      final pin = pinnedDownload(u); // (throws for a file the table does not know)
      expect(pin.sha256, isNotNull, reason: u);
      expect(pin.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: u);
      expect(pin.url, isNot(contains('/resolve/main/')), reason: u);
    }
  });

  test('addresses that are not on main of a listed repository are left alone', () {
    expect(pinnedDownload('https://huggingface.co/nfa04/glm-ocr-onnx/resolve/main/a.onnx').sha256, isNull);
    expect(pinnedDownload('https://example.org/x').url, 'https://example.org/x');
  });
}
