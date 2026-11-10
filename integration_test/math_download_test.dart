// Downloads the formula model the way the app does, on a real device.
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/ink/ink_recognizer.dart';
import 'package:notes/ink/math_service.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the model downloads and is found again', (tester) async {
    final base = await getApplicationSupportDirectory();
    final target = Directory('${base.path}/models/math_download_test');
    if (target.existsSync()) target.deleteSync(recursive: true);

    final service = MathService(defaultModel: FormulaModel.pix2text, modelDirectory: () async => target);
    var last = -1.0;
    service.addListener(() {
      if (service.progress - last >= 0.2) {
        last = service.progress;
        debugPrint('DL progress ${(service.progress * 100).round()}%');
      }
    });
    final watch = Stopwatch()..start();
    await service.install();
    debugPrint('DL status ${service.status} error ${service.error} after ${watch.elapsed.inSeconds}s');
    expect(service.error, isNull);
    expect(service.status, HandwritingStatus.installed);
    for (final f in target.listSync().whereType<File>()) {
      debugPrint('DL file ${f.path.split('/').last} ${f.lengthSync()}');
    }
    expect(File('${target.path}/encoder_model.onnx').lengthSync(), 87510770);
    expect(File('${target.path}/decoder_model.onnx').lengthSync(), 32026253);
    target.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
