import 'dart:io';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
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

  test('only the checked 16-bit files get the CoreML settings', () {
    expect(onnxCheckedForFp16('/m/texteller/encoder-gpu.onnx'), isTrue);
    expect(onnxCheckedForFp16('/m/glm_ocr/vision-gpu.onnx'), isTrue);
    for (final other in ['/m/texteller/encoder.onnx', '/m/texteller/encoder-fp32.onnx', '/m/glm_ocr/vision.onnx', '/m/glm_ocr/vision-web.onnx']) {
      expect(onnxCheckedForFp16(other), isFalse, reason: other);
    }
  });

  test('every fixed size gets a folder of its own inside the file\'s; a new version of the file takes all its sizes with it', () async {
    final models = Directory('${tmp.path}/models/glm_ocr')..createSync(recursive: true);
    final gpu = File('${models.path}/vision-gpu.onnx')..writeAsBytesSync([1]);
    final root = Directory('${tmp.path}/cache');
    final small = (await coreMlOptions(gpu.path, fixed: {'4*m': 240}, root: root))['ModelCacheDirectory']!;
    final large = (await coreMlOptions(gpu.path, fixed: {'4*m': 960}, root: root))['ModelCacheDirectory']!;
    expect(small, isNot(large), reason: 'CoreML keys its cache by the path only: one folder for two sizes gives one the other\'s model');
    expect(small.split('/').last, '4_m-240');
    expect(Directory(small).parent.path, Directory(large).parent.path);
    expect((await coreMlOptions(gpu.path, fixed: {'4*m': 240}, root: root))['ModelCacheDirectory'], small, reason: 'built once, found again');

    gpu.writeAsBytesSync([1, 2]); // (a new version of the model)
    await coreMlOptions(gpu.path, fixed: {'4*m': 240}, root: root);
    expect(Directory(small).existsSync(), isFalse);
    expect(Directory(large).existsSync(), isFalse);
  });

  test('the converted weights go once the compiled model is there; a model still being built keeps them', () async {
    // (ONNX Runtime's layout: <cache>/<key>/<n>_dynamic_mlprogram/model/{Data, compiled_model.mlmodelc, Manifest.json})
    final cache = Directory('${tmp.path}/cache/size')..createSync(recursive: true);
    Directory piece(int n, {required bool compiled}) {
      final model = Directory('${cache.path}/glmocrvisiongpu1/${n}_dynamic_mlprogram/model')..createSync(recursive: true);
      File('${model.path}/Data/com.microsoft.OnnxRuntime/model.mlmodel').createSync(recursive: true);
      File('${model.path}/Manifest.json').writeAsStringSync('{}');
      if (compiled) File('${model.path}/compiled_model.mlmodelc/model.mil').createSync(recursive: true);
      return model;
    }

    final done = piece(0, compiled: true), building = piece(1, compiled: false);
    expect(await coreMlDropConvertedWeights(cache.path), 1);
    expect(Directory('${done.path}/Data').existsSync(), isFalse);
    expect(Directory('${done.path}/compiled_model.mlmodelc').existsSync(), isTrue, reason: 'what the next session loads');
    expect(File('${done.path}/Manifest.json').existsSync(), isTrue, reason: 'the folder ONNX Runtime checks for stays');
    expect(Directory('${building.path}/Data').existsSync(), isTrue);
    expect(await coreMlDropConvertedWeights(cache.path), 0, reason: 'nothing left to drop');
    expect(await coreMlDropConvertedWeights('${tmp.path}/nowhere'), 0);
  });

  test('the fixed sizes reach CoreML and QNN, not NNAPI or the processor', () {
    final o = OrtSessionOptions(freeDimensions: {'4*m': 640});
    // (without them CoreML cannot build GLM's vision network: error -14, seen in the app check when they were dropped)
    expect(onnxOptionsFor(o, [OrtProvider.CORE_ML, OrtProvider.CPU]).freeDimensions, {'4*m': 640});
    expect(onnxOptionsFor(o, [OrtProvider.QNN, OrtProvider.CPU]).freeDimensions, {'4*m': 640});
    expect(onnxOptionsFor(o, [OrtProvider.NNAPI, OrtProvider.CPU]).freeDimensions, isNull);
    expect(onnxOptionsFor(o, [OrtProvider.CPU]).freeDimensions, isNull);
  });
}
