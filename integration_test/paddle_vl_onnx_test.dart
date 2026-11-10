// Runs the real PaddleOCR-VL through ONNX Runtime. Needs `vision.onnx`, `decoder.onnx`, `embeddings.bin` and `tokenizer.json` (see
// PaddleVlService) in one folder, and the pictures `a.png` and `b.png` (112 pixels high, a multiple of 28 wide, one line of text each):
//   flutter test integration_test/paddle_vl_onnx_test.dart -d linux --dart-define=MODEL_DIR=/path --dart-define=EXPECT_A=... --dart-define=EXPECT_B=...
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:notes/ink/ink_image.dart';
import 'package:notes/ink/onnx_paddle_vl.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/ink/paddle_vl.dart';

const dir = String.fromEnvironment('MODEL_DIR');
const expectA = String.fromEnvironment('EXPECT_A');
const expectB = String.fromEnvironment('EXPECT_B');

PaddleVlPicture picture(String name) {
  final image = img.decodePng(File('$dir/$name').readAsBytesSync())!.convert(numChannels: 4);
  final rgba = image.getBytes(order: img.ChannelOrder.rgba);
  return PaddleVlPicture(paddleVlPatches(rgba, image.width, image.height), image.height ~/ 14, image.width ~/ 14);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the real PaddleOCR-VL reads two lines of text', (tester) async {
    final watch = Stopwatch()..start();
    final tokens = await readPicturesOnnx(
      visionPath: '$dir/vision.onnx',
      decoderPath: '$dir/decoder.onnx',
      embeddingsPath: '$dir/embeddings.bin',
      pictures: [picture('a.png'), picture('b.png')],
    );
    final vocabulary = PaddleVlVocabulary.parse(File('$dir/tokenizer.json').readAsStringSync());
    final text = [for (final t in tokens) vocabulary.decode(t)];
    debugPrint('read $text in ${watch.elapsedMilliseconds} ms');
    expect(text, [expectA, expectB]);
  });

  testWidgets('and reads the outline of the same text drawn as strokes (`strokes.json`: lists of points)', (tester) async {
    final strokes = [
      for (final s in jsonDecode(File('$dir/strokes.json').readAsStringSync()) as List)
        DrawingStroke(color: const Color(0xFF000000), width: 3, points: [for (final p in s as List) Offset((p[0] as num).toDouble(), (p[1] as num).toDouble())]),
    ];
    final tokens = await readPicturesOnnx(
      visionPath: '$dir/vision.onnx',
      decoderPath: '$dir/decoder.onnx',
      embeddingsPath: '$dir/embeddings.bin',
      pictures: [await renderInkForPaddleVl(strokes)],
    );
    final vocabulary = PaddleVlVocabulary.parse(File('$dir/tokenizer.json').readAsStringSync());
    debugPrint('read from strokes: ${vocabulary.decode(tokens.single)}');
    expect(vocabulary.decode(tokens.single), expectA);
  });
}
