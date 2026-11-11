import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import '../web/browser_threads.dart';
import 'onnx_session.dart';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'causal_lm.dart';

/// Threads for the model: half the cores, between 2 and 8 (a phone with eight cores has four fast ones). (A browser does not say
/// how many it has to Dart: see lib/web/browser_threads_web.dart.)
int get onnxThreads => kIsWeb ? browserThreads() : (Platform.numberOfProcessors ~/ 2).clamp(2, 8);

/// Qwen3-0.6B (`onnx-community/Qwen3-0.6B-ONNX`, `model_int8.onnx`) run by ONNX
/// Runtime. The attention cache stays on the native side between steps: only
/// the scores of the last token ever come over to Dart.
class OnnxQwen implements CausalLm {
  final String path;
  final int layers, kvHeads, headDim;
  OrtSession? _session;

  /// Threads the model computes with.
  final int threads;

  OnnxQwen(this.path, {this.layers = 28, this.kvHeads = 8, this.headDim = 128, this.threads = 4});

  Future<OrtSession> _open() async =>
      _session ??= await openOnnxSession(path, options: OrtSessionOptions(intraOpNumThreads: threads, interOpNumThreads: 1, useArena: false), accelerate: false);

  /// On desktop the plugin runs the model on the thread that also draws the window, so a long call
  /// freezes the screen (a spinning circle stutters). The prompt is therefore fed in slices, and
  /// between slices and between tokens the thread gets a moment to draw.
  static const _slice = 48;

  static Future<void> _breathe() => Future<void>.delayed(const Duration(milliseconds: 8));

  // what the model made of the shared start of the prompts, kept between requests
  List<int> _prefixTokens = const [];
  Map<String, OrtValue>? _prefixCache;
  int _prefixMask = 0;

  Future<void> _dropPrefix() async {
    final cache = _prefixCache;
    _prefixCache = null;
    _prefixTokens = const [];
    for (final v in {...?cache?.values}) {
      await v.dispose();
    }
  }

  @override
  Future<List<int>> generate(
    List<int> prompt, {
    required int maxNewTokens,
    required Set<int> stop,
    int sharedPrefix = 0,
    void Function(List<int> generated)? onProgress,
    bool Function()? shouldStop,
    double repetitionPenalty = 1,
  }) async {
    if (prompt.isEmpty) return const [];
    final session = await _open();

    // The model wants a cache as input even at the start, and the plugin cannot
    // make an empty tensor: one position of zeros stands in, hidden by the mask.
    final empty = await OrtValue.fromList(Float32List(kvHeads * headDim), [1, kvHeads, 1, headDim]);
    var cache = <String, OrtValue>{
      for (var i = 0; i < layers; i++) ...{'past_key_values.$i.key': empty, 'past_key_values.$i.value': empty},
    };
    var held = <OrtValue>[]; // the cache of the step before, to let go of
    final letGo = <Future<void>>[];
    final mask = <int>[0]; // the stand-in position, then one 1 per real token
    var done = 0; // prompt tokens the cache already covers

    Future<OrtValue> step(List<int> tokens, int firstPosition) async {
      mask.addAll(List.filled(tokens.length, 1));
      final ids = await int64Value(tokens, [1, tokens.length]);
      final attention = await int64Value(mask, [1, mask.length]);
      final positions = await int64Value([for (var i = 0; i < tokens.length; i++) firstPosition + i], [1, tokens.length]);
      final out = await session.run({
        'input_ids': ids,
        'attention_mask': attention,
        if (session.inputNames.contains('position_ids')) 'position_ids': positions, // (the GenAI exports have none)
        ...cache,
      });
      // letting go of last step's tensors (dozens of calls) goes on while the next step runs
      for (final v in [ids, attention, positions, ...held]) {
        letGo.add(v.dispose());
      }
      final logits = out.remove('logits')!;
      held = out.values.toList();
      cache = {for (final e in out.entries) e.key.replaceFirst('present.', 'past_key_values.'): e.value};
      return logits;
    }

    // feeds [tokens] (starting at position [first]) to the model slice by slice, without reading any scores
    Future<void> feed(List<int> tokens, int first, {bool interruptible = false}) async {
      for (var at = 0; at < tokens.length; at += _slice) {
        if (interruptible && (shouldStop?.call() ?? false)) return;
        final unused = await step(tokens.sublist(at, math.min(at + _slice, tokens.length)), first + at);
        await unused.dispose();
        await _breathe();
      }
    }

    final result = <int>[];
    try {
      final shared = sharedPrefix.clamp(0, prompt.length - 1);
      if (shared > 0) {
        final tokens = prompt.sublist(0, shared);
        if (_prefixCache == null || !_sameTokens(_prefixTokens, tokens)) {
          await _dropPrefix();
          await feed(tokens, 0);
          _prefixCache = cache; // kept for the next time; not let go of with `held`
          _prefixTokens = tokens;
          _prefixMask = mask.length;
          held = [];
        } else {
          cache = _prefixCache!;
          mask
            ..clear()
            ..addAll(List.filled(_prefixMask, 1))
            ..[0] = 0;
        }
        done = shared;
      }

      // everything but the last prompt token in one go, without reading its scores
      // (one row per token would be 150 000 numbers each)
      if (prompt.length - 1 > done) {
        await feed(prompt.sublist(done, prompt.length - 1), done, interruptible: true);
      }
      var next = prompt.last;
      var position = prompt.length - 1;
      final seen = <int>{if (repetitionPenalty > 1) ...prompt};
      for (var i = 0; i < maxNewTokens; i++) {
        if (shouldStop?.call() ?? false) break;
        final logits = await step([next], position++);
        final token = _argmax(await logits.asFlattenedList(), seen, repetitionPenalty);
        await logits.dispose();
        if (stop.contains(token)) break;
        result.add(token);
        if (repetitionPenalty > 1) seen.add(token);
        onProgress?.call(result);
        next = token;
        await _breathe();
      }
    } finally {
      for (final v in held) {
        letGo.add(v.dispose());
      }
      letGo.add(empty.dispose());
      await Future.wait(letGo);
    }
    return result;
  }

  static bool _sameTokens(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static int _argmax(List<dynamic> scores, [Set<int> seen = const {}, double penalty = 1]) {
    var best = 0;
    var bestScore = double.negativeInfinity;
    for (var i = 0; i < scores.length; i++) {
      var s = (scores[i] as num).toDouble();
      // as in the usual repetition penalty: a used token's score is pulled towards "unlikely"
      if (penalty > 1 && seen.contains(i)) s = s > 0 ? s / penalty : s * penalty;
      if (s > bestScore) {
        bestScore = s;
        best = i;
      }
    }
    return best;
  }

  @override
  Future<void> close() async {
    await _dropPrefix();
    await _session?.close();
    _session = null;
  }
}
