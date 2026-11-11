import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../llm/onnx_qwen.dart' show onnxThreads;
import '../llm/onnx_session.dart';
import 'paddle_vl.dart';

/// A line of writing drawn for PaddleOCR-VL: [patches] as `paddleVlPatches` makes them, [gridHeight] x [gridWidth] of them.
class PaddleVlPicture {
  final Float32List patches;
  final int gridHeight, gridWidth;
  const PaddleVlPicture(this.patches, this.gridHeight, this.gridWidth);
}

const _layers = 18, _kvHeads = 2, _headDim = 128;

/// Reads the pictures with PaddleOCR-VL 1.5 (`onnx-community/PaddleOCR-VL-1.5-ONNX`, the 4-bit files) in ONNX Runtime and returns the
/// token ids written for each. The picture goes through the vision network first (closed again before the language model opens, to
/// keep the memory down); the language model then reads the prompt with the picture's features in it and writes the text token by
/// token. The words of the prompt come from the table of embeddings, which is read row by row from its file (it is 424 MB and only a
/// few rows are ever needed).
Future<List<List<int>>> readPicturesOnnx({
  required String visionPath,
  required String decoderPath,
  required String embeddingsPath,
  required List<PaddleVlPicture> pictures,
  int maxTokens = 160,
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

  final table = await File(embeddingsPath).open();
  final rows = <int, Float32List>{};
  Future<Float32List> row(int id) async {
    final known = rows[id];
    if (known != null) return known;
    await table.setPosition(id * paddleVlHiddenSize * 4);
    final bytes = await table.read(paddleVlHiddenSize * 4);
    return rows[id] = Float32List.sublistView(Uint8List.fromList(bytes));
  }

  final decoder = await openOnnxSession(decoderPath, options: options(), accelerate: false);
  try {
    return [
      for (var i = 0; i < pictures.length; i++)
        withoutLoop(await _write(decoder, pictures[i], features[i], row, maxTokens)),
    ];
  } finally {
    await decoder.close();
    await table.close();
  }
}

Future<Float32List> _see(OrtSession vision, PaddleVlPicture p) async {
  final count = p.gridHeight * p.gridWidth;
  final pixels = await OrtValue.fromList(p.patches, [1, count, 3, paddleVlPatch, paddleVlPatch]);
  final grid = await int64Value([1, p.gridHeight, p.gridWidth], [1, 3]);
  final out = await vision.run({'pixel_values': pixels, 'image_grid_thw': grid});
  final features = out[vision.outputNames.first] ?? out.values.first;
  final flat = await features.asFlattenedList();
  final result = Float32List(flat.length);
  for (var i = 0; i < flat.length; i++) {
    result[i] = (flat[i] as num).toDouble();
  }
  for (final v in [pixels, grid, ...out.values]) {
    await v.dispose();
  }
  return result;
}

/// The language model's turn, as in `OnnxQwen.generate`: the cache stays on the native side, one position of zeros (hidden by the
/// mask) stands in for the empty cache at the start, and between slices and tokens the thread gets a moment to draw.
Future<List<int>> _write(
  OrtSession session,
  PaddleVlPicture picture,
  Float32List features,
  Future<Float32List> Function(int id) row,
  int maxTokens,
) async {
  const slice = 64;
  Future<void> breathe() => Future<void>.delayed(const Duration(milliseconds: 8));

  final prompt = paddleVlPrompt(picture.gridHeight, picture.gridWidth);
  final firstPicturePosition = paddleVlBeforeImage.length;

  final empty = await OrtValue.fromList(Float32List(_kvHeads * _headDim), [1, _kvHeads, 1, _headDim]);
  var cache = <String, OrtValue>{
    for (var i = 0; i < _layers; i++) ...{'past_key_values.$i.key': empty, 'past_key_values.$i.value': empty},
  };
  var held = <OrtValue>[];
  final letGo = <Future<void>>[];
  final mask = <int>[0];

  Future<OrtValue> step(Float32List embeddings, int count) async {
    mask.addAll(List.filled(count, 1));
    final input = await OrtValue.fromList(embeddings, [1, count, paddleVlHiddenSize]);
    final attention = await int64Value(mask, [1, mask.length]);
    final out = await session.run({'inputs_embeds': input, 'attention_mask': attention, ...cache});
    for (final v in [input, attention, ...held]) {
      letGo.add(v.dispose());
    }
    final logits = out.remove('logits')!;
    held = out.values.toList();
    cache = {for (final e in out.entries) e.key.replaceFirst('present.', 'past_key_values.'): e.value};
    return logits;
  }

  // the rows of the prompt from [from] up to [to]: words from the table, the picture's places from the picture's features
  Future<Float32List> promptRows(int from, int to) async {
    final out = Float32List((to - from) * paddleVlHiddenSize);
    for (var at = from; at < to; at++) {
      final target = (at - from) * paddleVlHiddenSize;
      if (prompt[at] == paddleVlImageToken) {
        final source = (at - firstPicturePosition) * paddleVlHiddenSize;
        out.setRange(target, target + paddleVlHiddenSize, features, source);
      } else {
        out.setRange(target, target + paddleVlHiddenSize, await row(prompt[at]));
      }
    }
    return out;
  }

  final result = <int>[];
  try {
    for (var at = 0; at < prompt.length - 1; at += slice) {
      final end = at + slice < prompt.length - 1 ? at + slice : prompt.length - 1;
      await (await step(await promptRows(at, end), end - at)).dispose();
      await breathe();
    }
    OrtValue? logits = await step(await promptRows(prompt.length - 1, prompt.length), 1);
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
      if (best == paddleVlEndToken) break;
      result.add(best);
      await breathe();
      logits = await step(await row(best), 1);
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
