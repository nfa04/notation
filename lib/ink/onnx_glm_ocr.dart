import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../llm/onnx_qwen.dart' show onnxThreads;
import '../llm/onnx_session.dart';
import '../llm/token_picker.dart';
import '../llm/warm_session.dart';
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

  /// Where the time went, in microseconds, by step (the vision network, the prompt, and for each token: the run of the language model, the
  /// making of its inputs, the choice of the token (see [TokenPicker]), the word's row of the table): for measuring. Cleared by the
  /// caller.
  final Map<String, int> spent = {};

  WarmSession? _vision;
  OrtSession? _language;
  TokenPicker? _picker;
  GlmEmbeddings? _table;

  int _openedAt = 0; // ([onnxAccelerationChanges] when the sessions were opened)

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
    // (other files, or the setting of where models run changed since they were opened: opened again)
    if (_files != files || _openedAt != onnxAccelerationChanges) await _close();
    _files = files;
    _openedAt = onnxAccelerationChanges;
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    try {
      // (a quantised network cannot run on an accelerator that compiles for exact sizes: it is cut into pieces, each compiled, and the
      // quantised ones run on the processor anyway, so it would only make the first reading take for ever; CoreML cannot build the 8-bit
      // one as an MLProgram, and its older format ran it 3 to 10 times slower than the processor on a Mac)
      // (on CoreML the 16-bit file runs one picture width at a time, the number of patches fixed; while a width is first built, the
      // processor reads, with the 8-bit file if it is still there: quicker on the processor than the 16-bit one)
      final vision = _vision ??= await openWarmSession(visionPath,
          options: _options(),
          accelerate: onnxCheckedForFp16(visionPath) || !await onnxTakesOnlyFp16Files(),
          pin: glmVisionPin,
          processorPath: _quickerOnProcessor(visionPath));
      final seeing = Stopwatch()..start();
      final features = await _seeAll(vision, pictures);
      spent['vision'] = (spent['vision'] ?? 0) + seeing.elapsedMicroseconds;
      final table = _table ??= await GlmEmbeddings.open(embeddingsPath);
      final language = _language ??= await openOnnxSession(textPath, options: _options(), accelerate: false);
      final picker = _picker ??= await TokenPicker.open();
      return [
        for (var i = 0; i < pictures.length; i++)
          await _write(language, picker, pictures[i], features[i], table, maxTokens, spent).then((r) {
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
          _idle = Timer(keepOpen, _idleClose);
        }
      }
    }
  }

  /// The quiet time is over: let go, unless the accelerator is still making a plan (letting go would throw the minutes of work away, and the
  /// next reading would begin the same plan again).
  void _idleClose() {
    if (_vision?.compiling != null) {
      _idle = Timer(keepOpen, _idleClose);
    } else {
      unawaited(close());
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
    final vision = _vision, language = _language, table = _table, picker = _picker;
    _vision = null;
    _language = null;
    _picker = null;
    _table = null;
    await vision?.close();
    await language?.close();
    await table?.close();
    await picker?.close();
  }

  @override
  void didHaveMemoryPressure() => unawaited(close());
}

/// The size of a picture as the accelerator sees it (it makes one plan for each).
String _sizeOf(GlmPicture p) => '${p.gridHeight}x${p.gridWidth}';

/// [_see] of every picture, in an order that changes the accelerator's plan as seldom as possible: the size whose plan is in memory first,
/// then the others size by size (MIGraphX holds one plan; changing it loads the other from disk, about 3 s, where a run takes 0.3 s).
Future<List<Float32List>> _seeAll(WarmSession vision, List<GlmPicture> pictures) async {
  final loaded = vision.loaded;
  final order = List.generate(pictures.length, (i) => i)
    ..sort((a, b) {
      final ka = _sizeOf(pictures[a]), kb = _sizeOf(pictures[b]);
      if ((ka == loaded) != (kb == loaded)) return ka == loaded ? -1 : 1;
      final byCount = pictures[a].count.compareTo(pictures[b].count);
      return byCount != 0 ? byCount : ka.compareTo(kb);
    });
  final features = List<Float32List?>.filled(pictures.length, null);
  for (final i in order) {
    features[i] = await _see(vision, pictures[i]);
  }
  return [for (final f in features) f!];
}

Future<Float32List> _see(WarmSession vision, GlmPicture p) async {
  // (every 2 x 2 patches make one row of features)
  final wanted = (p.count ~/ 4) * glmHidden;
  // (an answer of another size is the plan of another picture size, which the accelerator can give on the first run of a session: see
  // [WarmSession.run]; it runs again then)
  final out = await vision.run(
    () async => {
      'pixel_values': await OrtValue.fromList(p.patches, [p.count, 3 * 2 * glmPatch * glmPatch]),
      'pos_ids': await int64Value(glmPatchPositions(p.gridHeight, p.gridWidth), [p.count, 2]),
    },
    key: _sizeOf(p),
    accept: (out) => out.values.first.shape.fold<int>(1, (a, b) => a * b) == wanted,
  );
  try {
    final flat = await out.values.first.asFlattenedList();
    if (flat.length != wanted) throw StateError('The vision network gave ${flat.length} numbers where $wanted were expected.');
    final features = Float32List(flat.length);
    for (var i = 0; i < flat.length; i++) {
      features[i] = (flat[i] as num).toDouble();
    }
    return features;
  } finally {
    for (final v in out.values) {
      await v.dispose();
    }
  }
}

/// The language model's turn: the cache stays on the native side; its first position is one of zeros that the mask hides (the graph
/// wants a cache with something in it), and the model is given the position of every token itself (the picture's tokens have
/// three: time, row and column).
Future<GlmReading> _write(OrtSession session, TokenPicker picker, GlmPicture picture, Float32List features, GlmEmbeddings table, int maxTokens, Map<String, int> spent) async {
  Future<T> timed<T>(String what, Future<T> Function() f) async {
    final watch = Stopwatch()..start();
    try {
      return await f();
    } finally {
      spent[what] = (spent[what] ?? 0) + watch.elapsedMicroseconds;
    }
  }

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
    // (made together: each is a call to the plugin, and they need not wait for one another)
    final made = await timed('step.inputs', () => Future.wait([OrtValue.fromList(embeddings, [1, count, glmHidden]), int64Value(where, [3, 1, count]), int64Value(mask, [1, mask.length])]));
    final input = made[0], position = made[1], attention = made[2];
    final out = await timed(count == 1 ? 'step.run' : 'prompt.run', () => session.run({'inputs_embeds': input, 'position_ids': position, 'attention_mask': attention, ...cache}));
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
      // (picked where the scores are: two numbers come over, see [TokenPicker])
      final picked = await timed('step.pick', () => picker.pick(logits!));
      await logits!.dispose();
      logits = null;
      final best = picked.token;
      if (glmEndTokens.contains(best)) break;
      logProbability += picked.logProb;
      logProbs.add(picked.logProb);
      result.add(best);
      spent['tokens'] = (spent['tokens'] ?? 0) + 1;
      logits = await step(await timed('step.embed', () => table.row(best)), [next, next, next], 1);
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

/// The vision network's free input size: the number of patches (pixel_values is [patches, 1176]). CoreML can only build the network
/// with it fixed (it fails on the free one, error -14), so it runs one picture width at a time (see [PinnedSize]).
const PinnedSize glmVisionPin = (name: '4*m', input: 'pixel_values', axis: 0);

/// The 8-bit vision file next to the 16-bit one, if it is there: the processor reads quicker with it (the answers have the same shape).
String? _quickerOnProcessor(String visionPath) {
  if (kIsWeb || !visionPath.endsWith('/vision-gpu.onnx')) return null;
  final standard = '${visionPath.substring(0, visionPath.length - 'vision-gpu.onnx'.length)}vision.onnx';
  return File(standard).existsSync() ? standard : null;
}
