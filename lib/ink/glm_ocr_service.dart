import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../export/pdf_ink_text.dart' show plainI;
import '../llm/model_files.dart';
import '../llm/onnx_session.dart' show onnxAccelerationEnabled, onnxAccelerationVersion, onnxCheckedForFp16, onnxPinsSizes, padPicturesNow;
import '../models/canvas_models.dart';
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

/// Which vision network is used. Both read the same way; they differ in the weights: 8 bits (more exact) or 4 bits (a third smaller). In a
/// browser the 4-bit one is the only one the graphics card (WebGPU) can run, and the 8-bit one on the browser's processor is 12 times
/// slower than it (36 s against 3 s a line, one thread, Radeon 780M); on 68 lines of real handwriting the 4-bit one read 13.3 % of the
/// characters wrong against 10.9 %.
enum GlmWeights {
  standard('vision.onnx', 430),
  compact('vision-web.onnx', 261),

  /// Not quantised (16-bit numbers): the one for a graphics card whose runtime cannot run the quantised operators (AMD's MIGraphX). Same
  /// readings as the unquantised original on the benchmark (10.9 % wrong, like the exact one); on the processor it is no faster and takes
  /// about 1 GB more memory, so while models run on the processor the standard file is used ([GlmOcrService.inUse]).
  gpu('vision-gpu.onnx', 870);

  /// The weights sit in a second file next to it.
  String? get dataFile => this == gpu ? 'vision-gpu.onnx.data' : null;

  /// On Android the 16-bit network comes cut into parts (tool/split_glm_vision.py), each with its weights in a file of its own, MB of them:
  /// QNN compiles and runs one part at a time there (compiling the whole took the app past 3.3 GB on a phone with 6 GB, and Android killed
  /// it). The first part only works out the rotary tables (no weights). The whole file is not downloaded there.
  static const gpuParts = [('vision-gpu.part1.onnx', 1), ('vision-gpu.part2.onnx', 213), ('vision-gpu.part3.onnx', 202), ('vision-gpu.part4.onnx', 202), ('vision-gpu.part5.onnx', 253)];

  final String file;
  final int megabytes;
  const GlmWeights(this.file, this.megabytes);

  /// What a browser starts with (see above); everywhere else the more exact one.
  static const platformDefault = kIsWeb ? compact : standard;
}

/// Reads handwriting with GLM-OCR (zai-org, MIT licence, 0.9 billion parameters; the original model, not retrained, in ONNX files made
/// from it by `tool/handwriting_bench/glm_onnx/` and published at https://huggingface.co/nfa04/glm-ocr-onnx, weights in 8 bits for the vision network and 4 bits for the language model, which reads
/// as well as the full ones on the benchmark of real handwriting), run by ONNX Runtime so that it works wherever the app does. It reads
/// a whole line at a time with a language model's idea of which words are likely: much better than the small readers on German
/// and English notes, at about 800 MB to download and 2 to 3 GB of memory while it reads. The files are not part of the app.
class GlmOcrService extends ModelFilesService {
  /// Where the files are (Hugging Face, which also lets a browser read them): the original model, converted to ONNX and quantised, not
  /// retrained (see the model card there). Another place can be set with `--dart-define=GLM_OCR_REPO=https://...`; the files of
  /// another place are not checked against [publishedChecksums] (they may be built differently).
  static const defaultRepo = 'https://huggingface.co/nfa04/glm-ocr-onnx/resolve/main';
  static const repo = String.fromEnvironment('GLM_OCR_REPO', defaultValue: defaultRepo);

  /// The vision network's file. A browser gets a variant with 4-bit weights (261 MB, read 2.4 points worse on the benchmark: 13.3 % against
  /// 10.9 %): the browser's graphics card (WebGPU) cannot run the 8-bit one (its MatMulNBits takes 2 and 4 bits only), and the 8-bit one on
  /// the processor of a browser is 12 times slower than the 4-bit on the card (36 s against 3 s a line, one thread, Radeon 780M).
  /// [android]: the 16-bit network as parts (see [GlmWeights.gpuParts]); by default where the app runs.
  static Map<String, ({String url, int megabytes})> filesFor(GlmWeights w, {bool? android}) => {
        if (w == GlmWeights.gpu && (android ?? (!kIsWeb && Platform.isAndroid)))
          for (final (file, mb) in GlmWeights.gpuParts) ...{
            file: (url: '$repo/$file', megabytes: 1),
            '$file.data': (url: '$repo/$file.data', megabytes: mb),
          }
        else ...{
          w.file: (url: '$repo/${w.file}', megabytes: w.dataFile == null ? w.megabytes : 1),
          if (w.dataFile != null) w.dataFile!: (url: '$repo/${w.dataFile}', megabytes: w.megabytes - 1),
        },
        'text.onnx': (url: '$repo/text.onnx', megabytes: 297),
        'embeddings.bin': (url: '$repo/embeddings.bin', megabytes: 88),
      };

  /// SHA-256 of the files: a download that does not match (cut short, or not the file that was published) is thrown away.
  static const publishedChecksums = {
    'vision.onnx': 'e4565d57d7714b0b180718d8bb0a58d59fe7a68486028fe2fa774ce994f0f03a',
    'vision-web.onnx': '7d70fa6cf6e9938f475e42c2b7b473ee560b4fd32d34a25b0400bf3f77500c3b',
    'vision-gpu.onnx': '7a4eedee27741d1b5314bfc62de280b080790d62e52c1d51f417f8feb0e562c4',
    'vision-gpu.onnx.data': '966e02f241403b5cc83f5f2de76bb006a3137b96874df458418e50b64c00ee99',
    'vision-gpu.part1.onnx': '9b08ed930be8f760ac1140e81936ec687959ffe044b5e6488546b5088610e75d',
    'vision-gpu.part1.onnx.data': '05b608a43e57419a39930a6b8c90cf95f4e7449db349eefc972262dacf7c0e4c',
    'vision-gpu.part2.onnx': 'f21b2ba9df9898e22c12614531558366fa32f0824a43e612a1f91f35d3fe2edb',
    'vision-gpu.part2.onnx.data': '987ba74009007827452d8b2862d03b5b219eeed168bda4663c251658b38aaec1',
    'vision-gpu.part3.onnx': 'eb1ab642de2ceef09f6ac38e0b265ba83c4a3709d805e0c37ea0f797c0527fc3',
    'vision-gpu.part3.onnx.data': 'd633aabe1ec5a49b53773f24d921a0b521823e9f7a0d37dabf34ae3d4a716dad',
    'vision-gpu.part4.onnx': '44bd2b9ce64ad333e4aa05b3b73d59cf1efa0965623daea7faa2de4b474ddd86',
    'vision-gpu.part4.onnx.data': '751d68b7c2dd8ee1e0520cee4b4475c97b7a68da5f4f77be7dce819270bcd032',
    'vision-gpu.part5.onnx': 'd242fa01278f4bbc6a3972b90ab7c9e9718e5ade2f281a5a6ccbde960ae84376',
    'vision-gpu.part5.onnx.data': 'a00251846330e2e4ce47fbae74d436888cbac117d3d419825a5c5ec2ef9d121e',
    'text.onnx': '1c886fa00f1b62c3a58728cadc49718c44fb046dca4e12171c1734cec9f00a41',
    'embeddings.bin': '9f74c48b8b5a645fbc438f2ee3c317a2102948149ff1deb3dfc678675b8094d5',
  };

  /// A word is called unsure when the model gave one of its tokens less than this much probability (a log, e^-0.5 = 0.6). On 68 lines of
  /// real handwriting this marked 22 % of the words, 60 % of which were read wrong (29 % of all were); under -0.7: 13 % of the words, 72 %
  /// of them wrong.
  static const unsureBelow = -0.5;

  /// A line is cut into pieces that are not wider than this many times their height: the network's work grows with the width.
  static const widestPiece = 24.0;

  /// Turns the pictures of lines into token ids, with how sure the model was of each. Tests pass a fake (of tokens only: sure of them).
  final Future<List<GlmReading>> Function(String visionPath, String textPath, String embeddingsPath, List<GlmPicture> pictures) _read;
  final Future<String> Function() _loadVocab;

  GlmOcrService({
    Future<List<List<int>>> Function(String, String, String, List<GlmPicture>)? read,
    Future<String> Function()? loadVocab,
    Map<String, String>? checksums,
    GlmWeights? weights,
    super.modelDirectory,
    super.download,
  })  : _weights = weights ?? GlmWeights.platformDefault,
        _read = read == null
            ? _onnx.readScored
            : ((a, b, c, d) async => [for (final t in await read(a, b, c, d)) (tokens: t, confidence: 1.0, logProbs: List.filled(t.length, 0.0))]),
        _loadVocab = loadVocab ?? (() => rootBundle.loadString('assets/glm_ocr/vocab.txt')),
        super(files: filesFor(_inUseOf(weights ?? GlmWeights.platformDefault)), folderName: 'glm_ocr', checksums: checksums ?? (repo == defaultRepo ? publishedChecksums : const {})) {
    onnxAccelerationVersion.addListener(_follow);
  }

  GlmWeights _weights;

  /// The vision network chosen (in the settings).
  GlmWeights get weights => _weights;

  /// The vision network used now: the chosen one, except that the one for graphics cards is not used while models run on the processor (it
  /// reads the same as the standard one there at the same speed, with about 1 GB more memory): the standard one is, downloaded then.
  GlmWeights get inUse => _inUseOf(_weights);

  static GlmWeights _inUseOf(GlmWeights w) => w == GlmWeights.gpu && !onnxAccelerationEnabled ? GlmWeights.standard : w;

  /// The file of the vision network in use.
  String get visionFile => inUse.file;

  /// The setting of where models run changed: the files of the vision network that is used now (counted as not installed until they are there).
  Future<void> _follow() async {
    final want = filesFor(inUse);
    if (want.keys.toSet().containsAll(files.keys) && files.keys.toSet().containsAll(want.keys)) return;
    await unload();
    files = want;
    await load();
  }

  @override
  bool get keepExisting => true;

  /// Changes which vision network is used. The other two files stay; only the vision file is fetched, and the one used before stays too
  /// (switching back needs no download; "Remove" deletes them all). Until the new one is there the model counts as not installed.
  Future<void> useWeights(GlmWeights w) async {
    if (w == _weights) return;
    await unload();
    _weights = w;
    files = filesFor(inUse);
    await load();
  }

  /// The networks, kept open between the readings of the background reader (see [GlmOnnxReader]).
  static final _onnx = GlmOnnxReader();

  GlmVocabulary? _vocabulary;

  @override
  Future<void> unload() async {
    _vocabulary = null;
    await _onnx.close();
  }

  /// The text of each of [lines] (the strokes of one line of writing each), drawn [quality.rows] patches high. Throws if the model is
  /// not installed or cannot run.
  Future<List<String>> readLines(List<List<DrawingStroke>> lines, {GlmQuality quality = GlmQuality.standard}) async =>
      [for (final r in await readLinesScored(lines, quality: quality)) r.text];

  /// [readLines], with the words of each that the model was unsure of (see [unsureBelow]).
  Future<List<({String text, List<String> unsure})>> readLinesScored(List<List<DrawingStroke>> lines, {GlmQuality quality = GlmQuality.standard}) async {
    if (!installed) throw StateError('The handwriting model is not installed.');
    // (CoreML runs the 16-bit vision file one picture width at a time and keeps each on disk: three widths only, see glmCoreMlWidths)
    final coreMl = onnxCheckedForFp16(visionFile) && await onnxPinsSizes(visionFile);
    final pad = await padPicturesNow();
    final pictures = [for (final line in lines) await renderInkForGlmOcr(line, rows: quality.rows, pad: pad, padTo: coreMl ? glmCoreMlWidths : null)];
    final tokens = await _read(
      (await file(visionFile)).path,
      (await file('text.onnx')).path,
      (await file('embeddings.bin')).path,
      pictures,
    );
    final vocabulary = _vocabulary ??= GlmVocabulary.parse(await _loadVocab());
    return [
      for (final r in tokens)
        () {
          final text = plainI(vocabulary.decode(r.tokens));
          return isWriting(text, r.confidence) ? (text: text, unsure: vocabulary.unsureWords(r.tokens, r.logProbs, unsureBelow)) : (text: '', unsure: const <String>[]);
        }(),
    ];
  }

  /// Whether [text], read with [confidence], is what is written and not what the model makes of a drawing: of a drawing it writes an
  /// empty block of markdown or a row of dashes with much confidence, or anything with little. (On generated pages: of 17 pieces that were
  /// mostly drawing this left out 14, of 318 of writing none. A lone digit is let be, though a drawing is sometimes read as one: it may be
  /// an answer written on its own.)
  static bool isWriting(String text, double confidence) {
    final t = text.trim();
    if (t.isEmpty || confidence < 0.5) return false;
    if (RegExp(r'^```[a-z]*\s*```$').hasMatch(t)) return false;
    return !RegExp(r'^[-_.,:;=~*·•|/\\ ]+$').hasMatch(t);
  }

  /// The text of each of [lines], as the chunks of words [groupIntoLines] cut them into: neighbouring chunks are put together again as
  /// long as the piece is not wider than [widestPiece] times its height, since the model reads a whole stretch better than a few words,
  /// and the pieces of one line are joined with a space.
  Future<List<String>> readChunkedLines(List<List<InkChunk>> lines, {GlmQuality quality = GlmQuality.standard}) async => (await readChunkedLinesScored(lines, quality: quality)).lines;

  /// [readChunkedLines], with the words of all the lines that the model was unsure of.
  Future<({List<String> lines, List<String> unsure})> readChunkedLinesScored(List<List<InkChunk>> lines, {GlmQuality quality = GlmQuality.standard}) async {
    final pieces = <List<DrawingStroke>>[];
    final lineOf = <int>[];
    for (var l = 0; l < lines.length; l++) {
      for (final piece in joinChunks(lines[l])) {
        pieces.add(piece);
        lineOf.add(l);
      }
    }
    final read = await readLinesScored(pieces, quality: quality);
    final texts = List.generate(lines.length, (_) => <String>[]);
    final unsure = <String>[];
    for (var i = 0; i < read.length; i++) {
      if (read[i].text.isEmpty) continue;
      texts[lineOf[i]].add(read[i].text);
      unsure.addAll(read[i].unsure);
    }
    return (lines: [for (final t in texts) t.join(' ')], unsure: unsure);
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
