import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../llm/onnx_qwen.dart' show onnxThreads;
import '../llm/onnx_session.dart';
import 'glm_ocr.dart';
import 'paddle_vl.dart' show withoutLoop;

/// Reads the pictures with GLM-OCR in ONNX Runtime (the two networks and the table of words made by
/// `tool/handwriting_bench/glm_onnx/make_release.py`) and returns the token ids written for each, as the app reads lines of
/// handwriting: the vision network turns the picture into one vector per 2 x 2 patches (closed again before the language model opens,
/// to keep the memory down); the language model reads the prompt, with those vectors in the places of the picture, and writes the
/// text token by token (greedy). It is the same model the Python of the benchmark ran, token for token.
Future<List<List<int>>> readPicturesGlm({
  required String visionPath,
  required String textPath,
  required String embeddingsPath,
  required List<GlmPicture> pictures,
  int maxTokens = 80,
}) async {
  OrtSessionOptions options() => OrtSessionOptions(intraOpNumThreads: onnxThreads, interOpNumThreads: 1, useArena: false);

  final features = <Float32List>[];
  final vision = await openOnnxSession(visionPath, options: options());
  try {
    for (final p in pictures) {
      features.add(await _see(vision, p));
    }
  } finally {
    await vision.close();
  }

  final table = await GlmEmbeddings.open(embeddingsPath);
  final language = await openOnnxSession(textPath, options: options());
  try {
    return [
      for (var i = 0; i < pictures.length; i++) withoutLoop(await _write(language, pictures[i], features[i], table, maxTokens)),
    ];
  } finally {
    await language.close();
    await table.close();
  }
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
Future<List<int>> _write(OrtSession session, GlmPicture picture, Float32List features, GlmEmbeddings table, int maxTokens) async {
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
  return result;
}
