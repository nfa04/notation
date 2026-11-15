import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/llm/onnx_session.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('coreml_options_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('CoreML gets the MLProgram format and a cache folder named by the file', () async {
    final models = Directory('${tmp.path}/models/glm_ocr')..createSync(recursive: true);
    final file = File('${models.path}/vision.onnx')..writeAsBytesSync([1, 2, 3]);
    final root = Directory('${tmp.path}/cache');
    final options = await coreMlOptions(file.path, root: root);
    expect(options['ModelFormat'], 'MLProgram');
    expect(options['MLComputeUnits'], 'ALL');
    final folder = options['ModelCacheDirectory']!;
    expect(Directory(folder).existsSync(), isTrue);
    expect(folder.split('/').last, startsWith('glm_ocr_vision.onnx-3-'));
    expect(await coreMlOptions(file.path, root: root), options, reason: 'the same file gets the same folder');
  });

  test('a changed file gets a new folder and the old one is removed; other models keep theirs', () async {
    final models = Directory('${tmp.path}/models/glm_ocr')..createSync(recursive: true);
    final vision = File('${models.path}/vision.onnx')..writeAsBytesSync([1, 2, 3]);
    final gpu = File('${models.path}/vision-gpu.onnx')..writeAsBytesSync([1]);
    File('${gpu.path}.data').writeAsBytesSync([1, 2]);
    final root = Directory('${tmp.path}/cache');
    final oldVision = await coreMlCacheFolder(vision.path, root: root);
    final gpuFolder = await coreMlCacheFolder(gpu.path, root: root);
    expect(gpuFolder!.split('/').last, matches(RegExp(r'^glm_ocr_vision-gpu\.onnx-1-\d+-2-\d+$')), reason: 'the weights file is in the name');

    vision.writeAsBytesSync([1, 2, 3, 4]); // (a new version of the model)
    final newVision = await coreMlCacheFolder(vision.path, root: root);
    expect(newVision, isNot(oldVision));
    expect(Directory(oldVision!).existsSync(), isFalse);
    expect(Directory(newVision!).existsSync(), isTrue);
    expect(Directory(gpuFolder).existsSync(), isTrue, reason: 'vision-gpu is another model, not an old vision');
  });

  test('no folder when the file is missing; the options are still given', () async {
    final options = await coreMlOptions('${tmp.path}/nothing/here.onnx', root: Directory('${tmp.path}/cache'));
    expect(options.containsKey('ModelCacheDirectory'), isFalse);
    expect(options['ModelFormat'], 'MLProgram');
  });
}
