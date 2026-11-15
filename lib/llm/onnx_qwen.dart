import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
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

  /// The model that turns token numbers into the vectors the decoder takes (Qwen3.5 2B and up come as a decoder that wants
  /// `inputs_embeds`, with the picture part left out, and a separate small model for the words). Null: the decoder takes `input_ids`.
  final String? embedPath;
  OrtSession? _embed;

  OnnxQwen(this.path, {this.layers = 28, this.kvHeads = 8, this.headDim = 128, this.threads = 4, this.embedPath});

  /// What the model carries from one step to the next, found out from the model itself: the attention cache of the layers
  /// that have one (Qwen2.5, Qwen3, and every fourth layer of Qwen3.5) and the states of the linear-attention layers of
  /// Qwen3.5 (a convolution state and a recurrent state per layer, which do not grow).
  List<({String name, List<int> shape, bool attention})>? _states;

  Future<OrtSession> _open() async {
    final session = _session ??= await openOnnxSession(path, options: OrtSessionOptions(intraOpNumThreads: threads, interOpNumThreads: 1, useArena: false), accelerate: false);
    _states ??= await _statesOf(session);
    if (embedPath != null && session.inputNames.contains('inputs_embeds')) {
      _embed ??= await openOnnxSession(embedPath!, options: OrtSessionOptions(intraOpNumThreads: threads, interOpNumThreads: 1, useArena: false), accelerate: false);
    }
    return session;
  }

  Future<List<({String name, List<int> shape, bool attention})>> _statesOf(OrtSession session) async {
    try {
      final found = <({String name, List<int> shape, bool attention})>[];
      for (final info in await session.getInputInfo()) {
        final name = '${info['name']}';
        if (!name.startsWith('past_')) continue;
        // (a size the model leaves open, the batch and the length of the cache, is 1: the cache starts with one hidden position)
        final shape = [for (final d in (info['shape'] as List)) (d as num) > 0 ? d.toInt() : 1];
        found.add((name: name, shape: shape, attention: name.startsWith('past_key_values')));
      }
      if (found.isNotEmpty) return found;
    } catch (_) {
      // the old way: an attention cache in every layer
    }
    return [
      for (var i = 0; i < layers; i++) ...[
        (name: 'past_key_values.$i.key', shape: [1, kvHeads, 1, headDim], attention: true),
        (name: 'past_key_values.$i.value', shape: [1, kvHeads, 1, headDim], attention: true),
      ],
    ];
  }

  /// The input that takes what the output [present] carries on: present.3.key -> past_key_values.3.key,
  /// present_conv.4 -> past_conv.4.
  @visibleForTesting
  static String pastName(String present) => present.startsWith('present_')
      ? 'past_${present.substring(8)}'
      : present.replaceFirst('present.', 'past_key_values.');

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
    final states = _states!;
    final start = <OrtValue>[]; // the tensors the first step starts with, to let go of at the end
    final empties = <String, OrtValue>{}; // one hidden position per shape, shared by the layers
    var cache = <String, OrtValue>{};
    for (final st in states) {
      final size = st.shape.fold<int>(1, (a, b) => a * b);
      if (st.attention) {
        cache[st.name] = empties[st.shape.join(',')] ??= await OrtValue.fromList(Float32List(size), st.shape);
      } else {
        cache[st.name] = await OrtValue.fromList(Float32List(size), st.shape); // (zeros: nothing has been read yet)
      }
    }
    start.addAll({...cache.values});
    final scalarOne = session.inputNames.contains('num_logits_to_keep') ? await int64Value([1], const []) : null; // (the scores of the last position only)
    var held = <OrtValue>[]; // the cache of the step before, to let go of
    final letGo = <Future<void>>[];
    final mask = <int>[0]; // the stand-in position, then one 1 per real token
    var done = 0; // prompt tokens the cache already covers

    Future<OrtValue> step(List<int> tokens, int firstPosition) async {
      mask.addAll(List.filled(tokens.length, 1));
      final ids = await int64Value(tokens, [1, tokens.length]);
      final attention = await int64Value(mask, [1, mask.length]);
      // the words as vectors, when the decoder does not take the numbers themselves
      final embeds = _embed == null ? null : (await _embed!.run({'input_ids': ids}))['inputs_embeds']!;
      final firstToLast = [for (var i = 0; i < tokens.length; i++) firstPosition + i];
      // (Qwen3.5 has three rows of positions, for the text, the height and the width of a picture: for text all three are the same)
      final positions = embeds == null
          ? await int64Value(firstToLast, [1, tokens.length])
          : await int64Value([...firstToLast, ...firstToLast, ...firstToLast], [3, 1, tokens.length]);
      final out = await session.run({
        if (embeds == null) 'input_ids': ids else 'inputs_embeds': embeds,
        'attention_mask': attention,
        if (session.inputNames.contains('position_ids')) 'position_ids': positions, // (the GenAI exports have none)
        'num_logits_to_keep': ?scalarOne,
        ...cache,
      });
      // letting go of last step's tensors (dozens of calls) goes on while the next step runs
      for (final v in [ids, attention, positions, ?embeds, ...held]) {
        letGo.add(v.dispose());
      }
      final logits = out.remove('logits')!;
      held = out.values.toList();
      cache = {for (final e in out.entries) pastName(e.key): e.value};
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
      for (final v in start) {
        letGo.add(v.dispose());
      }
      if (scalarOne != null) letGo.add(scalarOne.dispose());
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
    await _embed?.close();
    _embed = null;
  }
}
