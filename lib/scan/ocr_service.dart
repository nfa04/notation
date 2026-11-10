import '../util/apart.dart';
import '../llm/onnx_session.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../llm/model_files.dart';
import 'ocr_geometry.dart';

/// A script the text reader has a model for.
class OcrLanguage {
  final String id, name;
  final int megabytes;
  const OcrLanguage(this.id, this.name, this.megabytes);

  static const all = [
    OcrLanguage('latin', 'English, German, French, Spanish, Italian, ... (Latin script)', 8),
    OcrLanguage('eslav', 'Russian, Ukrainian, Bulgarian (Cyrillic)', 8),
    OcrLanguage('greek', 'Greek', 8),
    OcrLanguage('korean', 'Korean', 13),
    OcrLanguage('thai', 'Thai', 8),
    OcrLanguage('chinese', 'Chinese and Japanese', 84),
  ];

  static OcrLanguage byId(String? id) => all.firstWhere((l) => l.id == id, orElse: () => all.first);
}

/// What runs the two networks: the real one is ONNX Runtime ([OnnxOcrModels]); tests pass a stand-in.
abstract class OcrModels {
  /// The map of how likely each pixel is text, [DetectorInput.height] x [DetectorInput.width].
  Future<Float32List> detect(DetectorInput input);

  /// The scores of one line: [steps] x [classes].
  Future<({List<double> scores, int steps, int classes})> read(ReaderInput input);

  Future<void> close();
}

/// [OcrModels] with the detection and the reading model, run by ONNX Runtime.
class OnnxOcrModels implements OcrModels {
  final String detectorPath, readerPath;
  OrtSession? _detector, _reader;
  OnnxOcrModels(this.detectorPath, this.readerPath);

  static final _options = OrtSessionOptions(intraOpNumThreads: 4, interOpNumThreads: 1, useArena: false);

  @override
  Future<Float32List> detect(DetectorInput input) async {
    final session = _detector ??= await openOnnxSession(detectorPath, options: _options);
    final tensor = await OrtValue.fromList(input.data, [1, 3, input.height, input.width]);
    final out = await session.run({'x': tensor});
    await tensor.dispose();
    final map = out.values.first;
    final flat = await map.asFlattenedList();
    for (final v in out.values) {
      await v.dispose();
    }
    final result = Float32List(flat.length);
    for (var i = 0; i < flat.length; i++) {
      result[i] = (flat[i] as num).toDouble();
    }
    return result;
  }

  @override
  Future<({List<double> scores, int steps, int classes})> read(ReaderInput input) async {
    final session = _reader ??= await openOnnxSession(readerPath, options: _options);
    final tensor = await OrtValue.fromList(input.data, [1, 3, readerHeight, input.width]);
    final out = await session.run({'x': tensor});
    await tensor.dispose();
    final scores = out.values.first;
    final shape = scores.shape; // [1, steps, classes]
    final flat = await scores.asFlattenedList();
    for (final v in out.values) {
      await v.dispose();
    }
    return (scores: [for (final v in flat) (v as num).toDouble()], steps: shape[1], classes: shape[2]);
  }

  @override
  Future<void> close() async {
    await _detector?.close();
    await _reader?.close();
    _detector = _reader = null;
  }
}

class _Language {
  OcrLanguage value;
  _Language(this.value);
}

/// Reads the text in pictures (a photographed page, a screenshot, a scan). PaddleOCR's models (Apache 2.0, as converted to ONNX
/// by monkt) run in ONNX Runtime, so it works on every platform the app does; they are not part of the app: the 2 MB that find the
/// lines and the 8 MB that read them (for the script chosen) are downloaded on request. Nothing leaves the device.
class OcrService extends ModelFilesService {
  static const _repo = 'https://huggingface.co/monkt/paddleocr-onnx/resolve/main';
  static const languageKey = 'ocr_language';

  final _Language _language;
  final Future<String?> Function(String key) _get;
  final Future<void> Function(String key, String value) _set;
  final OcrModels Function(String detectorPath, String readerPath) _models;

  OcrService._(this._language, this._get, this._set, this._models, {Future<Directory> Function()? modelDirectory, super.download})
      : super(files: _filesOf(_language.value), folderName: 'ocr', modelDirectory: modelDirectory ?? (() async => Directory(p.join((await getApplicationSupportDirectory()).path, 'models', 'ocr', _language.value.id))));

  factory OcrService(
    Future<String?> Function(String key) get,
    Future<void> Function(String key, String value) set, {
    OcrModels Function(String detectorPath, String readerPath)? models,
    Future<Directory> Function(String languageId)? modelDirectory,
    Future<void> Function(String, String, void Function(double))? download,
  }) {
    final language = _Language(OcrLanguage.all.first);
    return OcrService._(language, get, set, models ?? OnnxOcrModels.new,
        modelDirectory: modelDirectory == null ? null : () => modelDirectory(language.value.id), download: download);
  }

  static Map<String, ({String url, int megabytes})> _filesOf(OcrLanguage l) => {
        'det.onnx': (url: '$_repo/detection/v3/det.onnx', megabytes: 3),
        'rec.onnx': (url: '$_repo/languages/${l.id}/rec.onnx', megabytes: l.megabytes),
        'dict.txt': (url: '$_repo/languages/${l.id}/dict.txt', megabytes: 1),
      };

  OcrLanguage get language => _language.value;

  /// The script the person chose (kept), looked at again for what is on the device.
  @override
  Future<void> load() async {
    _language.value = OcrLanguage.byId(await _get(languageKey));
    files = _filesOf(_language.value);
    _alphabet = null;
    await super.load();
  }

  Future<void> setLanguage(OcrLanguage l) async {
    if (l.id == _language.value.id) return;
    await unload();
    _language.value = l;
    files = _filesOf(l);
    _alphabet = null;
    await _set(languageKey, l.id);
    await super.load();
  }

  List<String>? _alphabet;

  @override
  Future<void> unload() async {}

  /// The text in the picture [bytes] (any format the `image` package reads). Throws if the models are not here or cannot run.
  Future<OcrPage> recognize(Uint8List bytes, {void Function(double)? progress}) async {
    if (!installed) throw StateError('The text reader is not installed.');
    final alphabet = _alphabet ??= readerAlphabet(await (await file('dict.txt')).readAsString());
    final models = _models((await file('det.onnx')).path, (await file('rec.onnx')).path);
    try {
      final prepared = await _prepareDetectorFrom(bytes);
      progress?.call(0.1);
      final map = await models.detect(prepared);
      final boxes = findTextBoxes(map, prepared.width, prepared.height, prepared.sourceWidth, prepared.sourceHeight);
      progress?.call(0.3);
      final lines = <OcrLine>[];
      final crops = await _prepareReadersFrom(bytes, [for (final b in boxes) b.rect]);
      for (var i = 0; i < boxes.length; i++) {
        final r = await models.read(crops[i]);
        final line = decodeCtc(r.scores, r.steps, r.classes, alphabet);
        if (line.text.trim().isNotEmpty) lines.add(OcrLine(line.text, boxes[i].rect, line.confidence));
        progress?.call(0.3 + 0.7 * (i + 1) / boxes.length);
      }
      return OcrPage(lines, prepared.sourceWidth, prepared.sourceHeight);
    } finally {
      await models.close();
    }
  }
}

Future<DetectorInput> _prepareDetectorFrom(Uint8List bytes) => runApart(() {
      final image = img.decodeImage(bytes);
      if (image == null) throw const FormatException('That is not a picture.');
      return prepareDetector(image);
    });

Future<List<ReaderInput>> _prepareReadersFrom(Uint8List bytes, List<Rect> boxes) => runApart(() {
      final image = img.decodeImage(bytes)!;
      return [for (final b in boxes) prepareReader(image, b)];
    });
