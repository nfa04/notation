import 'dart:math' as math;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart';

import '../llm/model_files.dart';
import '../models/canvas_models.dart';
import '../web/web_files.dart';
import 'glm_ocr.dart';
import 'ink_grouping.dart';
import 'ink_image.dart';
import 'onnx_glm_ocr.dart';

/// How carefully GLM-OCR looks at a line: the rows of 14 pixels its picture has. The vision network's work, three quarters of the time,
/// grows with the square of them. Measured on 68 lines of real handwriting (error of characters, and seconds a line on a desktop with
/// four threads): 10 rows 10.8 % and 2.3 s, 8 rows 12.0 % and 1.5 s, 6 rows 14.3 % and 1.0 s.
enum GlmQuality {
  standard(10),
  quick(8),
  light(6);

  final int rows;
  const GlmQuality(this.rows);
}

/// Reads handwriting with GLM-OCR (zai-org, MIT licence, 0.9 billion parameters; the original model, not retrained, in ONNX files made
/// from it by `tool/handwriting_bench/glm_onnx/` and published at https://huggingface.co/nfa04/glm-ocr-onnx, weights in 8 bits for the vision network and 4 bits for the language model, which reads
/// as well as the full ones on the benchmark of real handwriting), run by ONNX Runtime so that it works wherever the app does. It reads
/// a whole line at a time with a language model's idea of which words are likely: much better than the small readers on German
/// and English notes, at about 800 MB to download and 2 to 3 GB of memory while it reads. The files are not part of the app.
class GlmOcrService extends ModelFilesService {
  /// Where the files are (Hugging Face, which also lets a browser read them): the original model, converted to ONNX and quantised, not
  /// retrained (see the model card there). Another place can be set with `--dart-define=GLM_OCR_REPO=https://...`; the files of
  /// another place are not checked against [checksums] (they may be built differently).
  static const defaultRepo = 'https://huggingface.co/nfa04/glm-ocr-onnx/resolve/main';
  static const repo = String.fromEnvironment('GLM_OCR_REPO', defaultValue: defaultRepo);
  static const modelFiles = {
    'vision.onnx': (url: '$repo/vision.onnx', megabytes: 430),
    'text.onnx': (url: '$repo/text.onnx', megabytes: 297),
    'embeddings.bin': (url: '$repo/embeddings.bin', megabytes: 88),
  };

  /// SHA-256 of the three files: a download that does not match (cut short, or not the file that was published) is thrown away.
  static const checksums = {
    'vision.onnx': 'e4565d57d7714b0b180718d8bb0a58d59fe7a68486028fe2fa774ce994f0f03a',
    'text.onnx': '1c886fa00f1b62c3a58728cadc49718c44fb046dca4e12171c1734cec9f00a41',
    'embeddings.bin': '9f74c48b8b5a645fbc438f2ee3c317a2102948149ff1deb3dfc678675b8094d5',
  };

  /// A line is cut into pieces that are not wider than this many times their height: the network's work grows with the width.
  static const widestPiece = 24.0;

  /// Turns the pictures of lines into token ids. Tests pass a fake.
  final Future<List<List<int>>> Function(String visionPath, String textPath, String embeddingsPath, List<GlmPicture> pictures) _read;
  final Future<String> Function() _loadVocab;
  final Map<String, String> _checks;

  GlmOcrService({
    Future<List<List<int>>> Function(String, String, String, List<GlmPicture>)? read,
    Future<String> Function()? loadVocab,
    Map<String, String>? checksums,
    super.modelDirectory,
    super.download,
  })  : _read = read ?? _readWithOnnx,
        _loadVocab = loadVocab ?? (() => rootBundle.loadString('assets/glm_ocr/vocab.txt')),
        _checks = checksums ?? (repo == defaultRepo ? GlmOcrService.checksums : const {}),
        super(files: modelFiles, folderName: 'glm_ocr');

  static Future<List<List<int>>> _readWithOnnx(String vision, String text, String embeddings, List<GlmPicture> pictures) =>
      readPicturesGlm(visionPath: vision, textPath: text, embeddingsPath: embeddings, pictures: pictures);

  GlmVocabulary? _vocabulary;

  @override
  Future<void> unload() async => _vocabulary = null;

  @override
  Future<void> install() async {
    await super.install();
    if (!installed) return;
    for (final entry in _checks.entries) {
      final f = await file(entry.key);
      await ensureWebFile(f.path); // (in a browser a model's file may be left empty until it is needed)
      final got = await f.exists() ? (await sha256.bind(f.openRead()).first).toString() : '';
      if (got == entry.value) continue;
      await remove();
      error = 'The downloaded file ${entry.key} is not the one that was published (its checksum differs). Try again.';
      notifyListeners();
      return;
    }
  }

  /// The text of each of [lines] (the strokes of one line of writing each), drawn [quality.rows] patches high. Throws if the model is
  /// not installed or cannot run.
  Future<List<String>> readLines(List<List<DrawingStroke>> lines, {GlmQuality quality = GlmQuality.standard}) async {
    if (!installed) throw StateError('The handwriting model is not installed.');
    final pictures = [for (final line in lines) await renderInkForGlmOcr(line, rows: quality.rows)];
    final tokens = await _read(
      (await file('vision.onnx')).path,
      (await file('text.onnx')).path,
      (await file('embeddings.bin')).path,
      pictures,
    );
    final vocabulary = _vocabulary ??= GlmVocabulary.parse(await _loadVocab());
    return [for (final t in tokens) vocabulary.decode(t)];
  }

  /// The text of each of [lines], as the chunks of words [groupIntoLines] cut them into: neighbouring chunks are put together again as
  /// long as the piece is not wider than [widestPiece] times its height, since the model reads a whole stretch better than a few words,
  /// and the pieces of one line are joined with a space.
  Future<List<String>> readChunkedLines(List<List<InkChunk>> lines, {GlmQuality quality = GlmQuality.standard}) async {
    final pieces = <List<DrawingStroke>>[];
    final lineOf = <int>[];
    for (var l = 0; l < lines.length; l++) {
      for (final piece in joinChunks(lines[l])) {
        pieces.add(piece);
        lineOf.add(l);
      }
    }
    final read = await readLines(pieces, quality: quality);
    final texts = List.generate(lines.length, (_) => <String>[]);
    for (var i = 0; i < read.length; i++) {
      if (read[i].isNotEmpty) texts[lineOf[i]].add(read[i]);
    }
    return [for (final t in texts) t.join(' ')];
  }

  /// The strokes of [line]'s chunks put together into pieces that are at most [widestPiece] times as wide as they are high.
  static List<List<DrawingStroke>> joinChunks(List<InkChunk> line) {
    final out = <List<DrawingStroke>>[];
    var current = <DrawingStroke>[];
    Rect? box;
    for (final chunk in line) {
      final joined = box == null ? chunk.bounds : box.expandToInclude(chunk.bounds);
      if (current.isNotEmpty && joined.width > widestPiece * math.max(joined.height, 1.0)) {
        out.add(current);
        current = [];
        box = null;
      }
      current = [...current, ...chunk.strokes];
      box = box == null ? chunk.bounds : box.expandToInclude(chunk.bounds);
    }
    if (current.isNotEmpty) out.add(current);
    return out;
  }
}
