// Runs the real TexTeller files through the app's own code (the thin-pen picture, the cached decoder on ONNX Runtime, the
// vocabulary) over inks of the MathWriting data set, and writes what it read and how long it took. Needs the two ONNX files
// (see tool/texteller_models.py), MathWriting .inkml files and a list of their names:
//   flutter test integration_test/texteller_onnx_test.dart -d linux --dart-define=MODEL_DIR=/path/to/texteller \
//     --dart-define=INK_DIR=/path/to/test --dart-define=INK_LIST=/path/to/ids.txt --dart-define=COUNT=300 --dart-define=OUT=/path/out.jsonl
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/ink/ink_image.dart';
import 'package:notes/ink/math_service.dart';
import 'package:notes/models/canvas_models.dart';

const modelDir = String.fromEnvironment('MODEL_DIR');
const inkDir = String.fromEnvironment('INK_DIR');
const inkList = String.fromEnvironment('INK_LIST');
const count = int.fromEnvironment('COUNT', defaultValue: 50);
const outFile = String.fromEnvironment('OUT');
const which = String.fromEnvironment('MODEL', defaultValue: 'texteller'); // or 'pix2text' (MODEL_DIR is then the folder of its two files)

({String label, List<DrawingStroke> strokes}) readInk(String path) {
  final text = File(path).readAsStringSync();
  final label = RegExp(r'type="normalizedLabel">(.*?)</annotation>', dotAll: true).firstMatch(text)!.group(1)!;
  final strokes = <DrawingStroke>[];
  for (final m in RegExp(r'<trace id=[^>]*>(.*?)</trace>', dotAll: true).allMatches(text)) {
    final points = [
      for (final p in m.group(1)!.split(','))
        if (p.trim().isNotEmpty) Offset(double.parse(p.trim().split(RegExp(r'\s+'))[0]), double.parse(p.trim().split(RegExp(r'\s+'))[1])),
    ];
    if (points.length >= 2) strokes.add(DrawingStroke(color: const Color(0xFF000000), width: 3, points: points));
  }
  return (label: label.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&'), strokes: strokes);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('TexTeller reads MathWriting inks through the app code', (tester) async {
    final ids = File(inkList).readAsLinesSync().where((l) => l.trim().isNotEmpty).take(count).toList();
    final old = which == 'pix2text';
    final service = old
        ? MathService(defaultModel: FormulaModel.pix2text, modelDirectory: () async => Directory(modelDir))
        : MathService(defaultModel: FormulaModel.texteller, tellerDirectory: () async => Directory(modelDir));
    await service.load();
    expect(service.model, old ? FormulaModel.pix2text : FormulaModel.texteller);
    expect(service.status.name, 'installed', reason: 'the model files are not in $modelDir');

    final sink = File(outFile).openWrite();
    final total = Stopwatch()..start();
    var renderMs = 0, firstMs = 0;
    for (var i = 0; i < ids.length; i++) {
      final ink = readInk('$inkDir/${ids[i]}.inkml');
      final r = Stopwatch()..start();
      await renderInkForTexTeller(ink.strokes);
      renderMs += r.elapsedMilliseconds;
      final watch = Stopwatch()..start();
      String pred;
      try {
        pred = await service.recognize(ink.strokes);
      } catch (e) {
        pred = '';
        debugPrint('FAILED ${ids[i]}: $e');
      }
      final ms = watch.elapsedMilliseconds;
      if (i == 0) firstMs = ms;
      sink.writeln(jsonEncode({'id': ids[i], 'label': ink.label, 'pred': pred, 'secs': ms / 1000, 'aspect': 0.0, 'nstrokes': ink.strokes.length}));
    }
    await sink.close();
    await service.unload();
    debugPrint('${which.toUpperCase()} ${ids.length} inks in ${total.elapsedMilliseconds} ms; first (cold) $firstMs ms; picture drawing '
        '${(renderMs / ids.length).toStringAsFixed(1)} ms each');
  }, timeout: const Timeout(Duration(minutes: 60)));
}
