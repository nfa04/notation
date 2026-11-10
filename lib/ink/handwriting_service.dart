import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../llm/model_files.dart';
import '../models/canvas_models.dart';
import 'glm_ocr_service.dart';
import 'ink_grouping.dart';
import 'ink_recognizer.dart';
import 'paddle_vl_service.dart';

/// Which model reads the handwriting: GLM-OCR (MIT; the standard) or PaddleOCR-VL (Apache 2.0; slower on a tablet and it often writes
/// in capitals). Both are big vision-language models that read a whole line as a picture; see [GlmOcrService] and [PaddleVlService].
/// (TrOCR, which read a few words at a time, was taken out: it was trained on the IAM database, which is only for research, and
/// read far worse.)
enum HandwritingReader { glm, paddle }

/// Reads handwriting with the model the person chose: it delegates the download, the status and the reading to the service of
/// that model, and remembers the choice (and how carefully GLM-OCR looks) in the settings.
class HandwritingService extends InkRecognizer {
  static const readerKey = 'handwriting_reader';

  /// How carefully GLM-OCR looks (kept): see [GlmQuality].
  static const qualityKey = 'handwriting_quality';

  /// GLM-OCR, the standard reader.
  final GlmOcrService glm;

  /// PaddleOCR-VL; null: not offered.
  final PaddleVlService? paddle;
  final Future<String?> Function(String key)? _readSetting;
  final Future<void> Function(String key, String value)? _writeSetting;
  final Future<void> Function() _removeOldFiles;

  HandwritingService({
    GlmOcrService? glm,
    this.paddle,
    Future<String?> Function(String key)? readSetting,
    Future<void> Function(String key, String value)? writeSetting,
    Future<void> Function()? removeOldFiles,
  })  : glm = glm ?? GlmOcrService(),
        _readSetting = readSetting,
        _writeSetting = writeSetting,
        _removeOldFiles = removeOldFiles ?? _removeTrocr {
    this.glm.addListener(notifyListeners);
    paddle?.addListener(notifyListeners);
  }

  /// What the TrOCR reader of earlier versions left on the device (about 60 MB): it is not used any more.
  static Future<void> _removeTrocr() async {
    if (kIsWeb) return;
    try {
      final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'models', 'trocr'));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // (not worth a message: it is only old files)
    }
  }

  HandwritingReader _reader = HandwritingReader.glm;
  HandwritingReader get reader => _reader;

  GlmQuality _quality = GlmQuality.standard;
  GlmQuality get quality => _quality;

  bool get _usesPaddle => _reader == HandwritingReader.paddle && paddle != null;

  /// The service of the chosen reader.
  ModelFilesService get _current => _usesPaddle ? paddle! : glm;

  /// Chooses the model that reads (kept), and looks at what is on the device for it.
  Future<void> setReader(HandwritingReader r) async {
    if (r == _reader) return;
    _reader = r;
    await _writeSetting?.call(readerKey, r.name);
    await load();
  }

  Future<void> setQuality(GlmQuality q) async {
    if (q == _quality) return;
    _quality = q;
    await _writeSetting?.call(qualityKey, q.name);
    notifyListeners();
  }

  @override
  HandwritingStatus get status => _current.status;
  bool get installed => status == HandwritingStatus.installed;
  @override
  double get progress => _current.progress;
  @override
  String? get error => _current.error;
  @override
  int get sizeMb => _current.sizeMb;

  @override
  Future<void> load() async {
    final wanted = await _readSetting?.call(readerKey);
    // (a person who chose TrOCR, or nobody, gets GLM-OCR)
    _reader = HandwritingReader.values.where((r) => r.name == wanted).firstOrNull ?? HandwritingReader.glm;
    final q = await _readSetting?.call(qualityKey);
    _quality = GlmQuality.values.where((v) => v.name == q).firstOrNull ?? GlmQuality.standard;
    await _removeOldFiles();
    await _current.load();
    notifyListeners();
  }

  @override
  Future<void> install() => _current.install();

  @override
  Future<void> remove() => _current.remove();

  /// The text written by [strokes]: lines top to bottom. Throws if the model is not installed or cannot run on this device.
  @override
  Future<String> recognize(List<DrawingStroke> strokes) async {
    if (!installed) throw StateError('The handwriting model is not installed.');
    final lines = groupIntoLines([for (final s in strokes) if (s.color.a > 0.9 && Brushes.writes(s.brush)) s]); // not the highlighter
    if (lines.isEmpty) return '';
    if (_usesPaddle) {
      return (await paddle!.readLines([
        for (final line in lines) [for (final chunk in line) ...chunk.strokes],
      ])).join('\n');
    }
    return (await glm.readChunkedLines(lines, quality: _quality)).join('\n');
  }
}
