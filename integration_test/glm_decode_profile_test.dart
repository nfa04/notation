// Where the handwriting reader's time goes, step by step (GlmOnnxReader.spent), on font-drawn lines (tool/coreml_probe/lines, Caveat font,
// no one's own writing). Writes what was read to OUT, so that a change meant to be faster can be checked to read the same text.
//   flutter test integration_test/glm_decode_profile_test.dart -d linux --dart-define=MODEL_DIR=~/.local/share/io.github.nfa04.notation/models/glm_ocr \
//     --dart-define=OUT=/path/read.tsv
// The Linux app is one instance per user (D-Bus): with the app already open, run it with DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent,
// or it hands over to the open one and the test never starts. For timings close to the real app, `flutter drive --profile` with
// test_driver/integration_test.dart (integrationDriver()) instead of `flutter test` (debug).
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:notes/ink/glm_ocr.dart';
import 'package:notes/ink/onnx_glm_ocr.dart';

const modelDir = String.fromEnvironment('MODEL_DIR');
const outFile = String.fromEnvironment('OUT');
const linesDir = String.fromEnvironment('LINES', defaultValue: 'tool/coreml_probe/lines');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('where the time of a line goes', (tester) async {
    final vocabulary = GlmVocabulary.parse(File('assets/glm_ocr/vocab.txt').readAsStringSync());
    final truth = {
      for (final l in File('$linesDir/truth.tsv').readAsLinesSync().where((l) => l.contains('\t'))) l.split('\t')[0]: l.split('\t')[1],
    };
    final names = truth.keys.toList()..sort();
    final pictures = <GlmPicture>[];
    for (final n in names) {
      final image = img.decodePng(File('$linesDir/$n').readAsBytesSync())!.convert(numChannels: 4);
      pictures.add(GlmPicture(glmPatches(image.getBytes(order: img.ChannelOrder.rgba), image.width, image.height), image.height ~/ glmPatch, image.width ~/ glmPatch));
    }
    final reader = GlmOnnxReader(keepOpen: const Duration(minutes: 5));
    final files = ['$modelDir/vision.onnx', '$modelDir/text.onnx', '$modelDir/embeddings.bin'];
    await reader.read(files[0], files[1], files[2], [pictures.first]); // (opened, and warmed)
    reader.spent.clear();

    final watch = Stopwatch()..start();
    final read = <String>[];
    for (final p in pictures) {
      read.add(vocabulary.decode((await reader.read(files[0], files[1], files[2], [p])).single));
    }
    final total = watch.elapsedMicroseconds;
    await reader.close();

    final tokens = reader.spent['tokens'] ?? 1;
    String ms(int us) => (us / 1000).toStringAsFixed(1);
    debugPrint('glm-profile: ${pictures.length} lines, $tokens tokens, ${ms(total ~/ pictures.length)} ms a line');
    final steps = reader.spent.entries.where((e) => e.key != 'tokens').toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in steps) {
      final perToken = e.key.startsWith('step.') ? ', ${ms(e.value ~/ tokens)} ms a token' : '';
      debugPrint('glm-profile:   ${e.key.padRight(14)} ${ms(e.value ~/ pictures.length).padLeft(8)} ms a line (${(100 * e.value / total).toStringAsFixed(1)} %)$perToken');
    }
    var same = 0;
    for (var i = 0; i < names.length; i++) {
      if (read[i] == truth[names[i]]) same++;
    }
    debugPrint('glm-profile: $same of ${names.length} lines exactly as written');
    if (outFile.isNotEmpty) File(outFile).writeAsStringSync([for (var i = 0; i < names.length; i++) '${names[i]}\t${read[i]}'].join('\n'));
  }, timeout: const Timeout(Duration(minutes: 30)));
}
