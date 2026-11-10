// Runs the real formula model through ONNX Runtime. Needs the two ONNX files
// and two rendered formulas: pass their folder with
//   flutter test integration_test/math_onnx_test.dart -d linux --dart-define=MODEL_DIR=/path
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/ink/math_decoder.dart';
import 'package:notes/ink/onnx_math_model.dart';

const dir = String.fromEnvironment('MODEL_DIR');

Future<Float32List> pixelsOf(String png) async {
  final codec = await ui.instantiateImageCodec(await File(png).readAsBytes(), targetWidth: 384, targetHeight: 384);
  final image = (await codec.getNextFrame()).image;
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final rgb = Float32List(384 * 384 * 3);
  for (var i = 0; i < 384 * 384; i++) {
    for (var c = 0; c < 3; c++) {
      rgb[3 * i + c] = rgba.getUint8(4 * i + c) / 255;
    }
  }
  return toModelInput(rgb);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the real model reads rendered formulas', (tester) async {
    final vocab = MathVocab.parse(await rootBundle.loadString('assets/math/vocab.txt'));
    final model = await OnnxMathModel.open('$dir/encoder_model.onnx', '$dir/decoder_model.onnx');
    try {
      final watch = Stopwatch()..start();
      final ids = await greedyDecodeMath(model, await pixelsOf('$dir/f2.png'));
      debugPrint('E=mc^2 -> ${vocab.decode(ids)} (${watch.elapsedMilliseconds} ms, ${ids.length} tokens)');
      expect(vocab.decode(ids), 'E=mc^{2}');

      watch.reset();
      final ids2 = await greedyDecodeMath(model, await pixelsOf('$dir/f1.png'));
      debugPrint('fraction -> ${vocab.decode(ids2)} (${watch.elapsedMilliseconds} ms, ${ids2.length} tokens)');
      // (the model sometimes adds thin spaces around the plus)
      expect(vocab.decode(ids2).replaceAll(r'\,', ''), r'\frac{a+b}{2}=\sqrt{x^{2}+y^{2}}');
      watch.reset();
      final ids3 = await greedyDecodeMath(model, await pixelsOf('$dir/f3.png'));
      debugPrint('long -> ${vocab.decode(ids3)} (${watch.elapsedMilliseconds} ms, ${ids3.length} tokens)');
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
