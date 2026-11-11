import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../llm/onnx_qwen.dart' show onnxThreads;
import '../llm/onnx_session.dart';
import 'glm_ocr.dart';
import 'paddle_vl.dart' show withoutLoop;

/// Reads pictures with GLM-OCR in ONNX Runtime (the two networks and the table of words made by
/// `tool/handwriting_bench/glm_onnx/make_release.py`) and returns the token ids written for each, as the app reads lines of
/// handwriting: the vision network turns the picture into one vector per 2 x 2 patches; the language model reads the prompt, with those
/// vectors in the places of the picture, and writes the text token by token (greedy). It is the same model the Python of the benchmark
/// ran, token for token.
///
/// Opening the two networks costs more than reading a block (2.1 s on a Ryzen 7 8845HS, about 760 MB of files), and the background
/// reading asks for block after block: they stay open for [keepOpen] after a reading and are let go of when nothing more is asked, or
/// at once when the system says memory is short. Both open hold about 870 MB (the language model alone about 410 MB).
class GlmOnnxReader with WidgetsBindingObserver {
  final Duration keepOpen;

  GlmOnnxReader({this.keepOpen = const Duration(seconds: 15)});

  OrtSession? _vision, _language;
  GlmEmbeddings? _table;

  /// The files the open sessions are of (another set closes them first).
  String? _files;
  Timer? _idle;
  bool _observing = false;
  Future<void> _turn = Future.value();

  /// Low priority: the reading goes on in the background while the person writes, and takes only the time the screen leaves over.
  OrtSessionOptions _options() => OrtSessionOptions(intraOpNumThreads: onnxThreads, interOpNumThreads: 1, useArena: false, lowPriority: true);

  /// The token ids of each of [pictures]. One call at a time: the sessions are shared.
  Future<List<List<int>>> read(String visionPath, String textPath, String embeddingsPath, List<GlmPicture> pictures, {int maxTokens = 80}) async =>
      [for (final r in await readScored(visionPath, textPath, embeddingsPath, pictures, maxTokens: maxTokens)) r.tokens];

  /// [read], with how sure the model was of each reading: the geometric mean of the probabilities of the tokens it chose (1 when it wrote
  /// nothing), and the probability of each token. A drawing read as text is read with little confidence; a word it was unsure of has a
  /// token with a low one.
  Future<List<GlmReading>> readScored(String visionPath, String textPath, String embeddingsPath, List<GlmPicture> pictures, {int maxTokens = 80}) {
    final result = _turn.then((_) => _read(visionPath, textPath, embeddingsPath, pictures, maxTokens));
    _turn = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<List<GlmReading>> _read(String visionPath, String textPath, String embeddingsPath, List<GlmPicture> pictures, int maxTokens) async {
    _idle?.cancel();
    final files = '$visionPath\u0000$textPath\u0000$embeddingsPath';
    if (_files != files) await _close();
    _files = files;
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    try {
      final vision = _vision ??= await openOnnxSession(visionPath, options: _options());
      final features = [for (final p in pictures) await _see(vision, p)];
      final table = _table ??= await GlmEmbeddings.open(embeddingsPath);
      final language = _language ??= await openOnnxSession(textPath, options: _options(), accelerate: false);
      return [
        for (var i = 0; i < pictures.length; i++)
          await _write(language, pictures[i], features[i], table, maxTokens).then((r) {
            final tokens = withoutLoop(r.tokens);
            return (tokens: tokens, confidence: r.confidence, logProbs: r.logProbs.sublist(0, tokens.length));
          }),
      ];
    } catch (_) {
      await _close(); // (a session in a bad state is not used again)
      rethrow;
    } finally {
      if (_files != null) {
        if (keepOpen == Duration.zero) {
          await _close();
        } else {
          _idle = Timer(keepOpen, close);
        }
      }
    }
  }

  /// Lets go of the networks (after the reading going on now, if one is).
  Future<void> close() {
    final done = _turn.then((_) => _close());
    _turn = done;
    return done;
  }

  Future<void> _close() async {
    _idle?.cancel();
    _idle = null;
    _files = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    final vision = _vision, language = _language, table = _table;
    _vision = null;
    _language = null;
    _table = null;
    await vision?.close();
    await language?.close();
    await table?.close();
  }

  @override
  void didHaveMemoryPressure() => unawaited(close());
}

Future<Float32List> _see(OrtSession vision, GlmPicture p) async {
  final pixels = await OrtValue.fromList(p.patches, [p.count, 3 * 2 * glmPatch * glmPatch]);
  final positions = await int64Value(glmPatchPositions(p.gridHeight, p.gridWidth), [p.count, 2]);
  final out = await vision.run({'pixel_values': pixels, 'pos_ids': positions});
  final result = out[vision.outputNames.first] ?? out.values.first;
  final flat = await result.asFlattenedList();
  final features = Float32List(flat.length);
  for (var i = 0; i < flat.length; i++) {
    features[i] = (flat[i] as num).toDouble();
  }
  for (final v in [pixels, positions, ...out.values]) {
    await v.dispose();
  }
  return features;
}

/// The language model's turn: the cache stays on the native side; its first position is one of zeros that the mask hides (the graph
/// wants a cache with something in it), and the model is given the position of every token itself (the picture's tokens have
/// three: time, row and column).
Future<GlmReading> _write(OrtSession session, GlmPicture picture, Float32List features, GlmEmbeddings table, int maxTokens) async {
  Future<void> breathe() => Future<void>.delayed(const Duration(milliseconds: 8));

  final prompt = glmPrompt(picture.gridHeight, picture.gridWidth);
  final positions = glmPromptPositions(picture.gridHeight, picture.gridWidth);
  final empty = await OrtValue.fromList(Float32List(glmKvHeads * glmHeadDim), [1, glmKvHeads, 1, glmHeadDim]);
  var cache = <String, OrtValue>{
    for (var i = 0; i < glmLayers; i++) ...{'past_key_values.$i.key': empty, 'past_key_values.$i.value': empty},
  };
  var held = <OrtValue>[];
  final letGo = <Future<void>>[];
  final mask = <int>[0];

  Future<OrtValue> step(Float32List embeddings, List<int> where, int count) async {
    final input = await OrtValue.fromList(embeddings, [1, count, glmHidden]);
    final position = await int64Value(where, [3, 1, count]);
    final attention = await int64Value(mask, [1, mask.length]);
    final out = await session.run({'inputs_embeds': input, 'position_ids': position, 'attention_mask': attention, ...cache});
    mask.addAll(List.filled(count, 1));
    for (final v in [input, position, attention, ...held]) {
      letGo.add(v.dispose());
    }
    final logits = out.remove('logits')!;
    held = out.values.toList();
    cache = {for (final e in out.entries) e.key.replaceFirst('present.', 'past_key_values.'): e.value};
    return logits;
  }

  final result = <int>[];
  var logProbability = 0.0;
  final logProbs = <double>[];
  try {
    final first = Float32List(prompt.length * glmHidden);
    for (var i = 0; i < prompt.length; i++) {
      final row = prompt[i] == glmImageToken ? features.sublist((i - glmPromptBefore.length) * glmHidden, (i - glmPromptBefore.length + 1) * glmHidden) : await table.row(prompt[i]);
      first.setRange(i * glmHidden, (i + 1) * glmHidden, row);
    }
    var next = positions.reduce((a, b) => a > b ? a : b) + 1;
    OrtValue? logits = await step(first, positions, prompt.length);
    for (var i = 0; i < maxTokens; i++) {
      final scores = await logits!.asFlattenedList();
      await logits.dispose();
      logits = null;
      var best = 0;
      var bestScore = double.negativeInfinity;
      for (var k = 0; k < scores.length; k++) {
        final s = (scores[k] as num).toDouble();
        if (s > bestScore) {
          bestScore = s;
          best = k;
        }
      }
      if (glmEndTokens.contains(best)) break;
      // (how likely the chosen token was: its score against all of them, log-sum-exp taken from the best for the sake of the floats)
      var sum = 0.0;
      for (var k = 0; k < scores.length; k++) {
        sum += math.exp((scores[k] as num).toDouble() - bestScore);
      }
      logProbability -= math.log(sum);
      logProbs.add(-math.log(sum));
      result.add(best);
      await breathe();
      logits = await step(await table.row(best), [next, next, next], 1);
      next++;
    }
    await logits?.dispose();
  } finally {
    for (final v in held) {
      letGo.add(v.dispose());
    }
    letGo.add(empty.dispose());
    await Future.wait(letGo);
  }
  return (tokens: result, confidence: result.isEmpty ? 1.0 : math.exp(logProbability / result.length), logProbs: logProbs);
}

/// What was read of one picture: its tokens, how sure the model was of them all together (see [GlmOnnxReader.readScored]), and the
/// log probability the model gave each token it chose (as many as the tokens).
typedef GlmReading = ({List<int> tokens, double confidence, List<double> logProbs});
