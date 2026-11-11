import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../llm/onnx_session.dart';
import '../web/browser_threads.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'ink_image.dart' show texTellerImageSize;
import 'texteller_decoder.dart';

/// [TexTellerModel] on top of the two ONNX files (the encoder and the decoder with a cache of keys and values).
///
/// The tensors stay inside ONNX Runtime: what the encoder gives is handed to the decoder as it is, and so are the keys and
/// values of one step to the next; only the scores of the next token come over to Dart. Opening the two sessions takes a
/// moment (about 320 MB of weights), and the background reading asks for formula after formula, so they stay open for
/// [keepOpen] after a reading and are let go of when nothing more is asked.
class OnnxTexTeller implements ScoredTexTeller {
  final String _encoderPath;
  final String _decoderPath;
  final Duration keepOpen;
  final int threads;
  OrtSession? _encoder;
  OrtSession? _decoder;
  Timer? _idle;

  /// Where the time went, in microseconds, by step (opening the sessions, the picture to the encoder, the encoder, the token to
  /// the decoder, the decoder, the scores back, the keys and values): for measuring on a device. Cleared by the caller.
  final Map<String, int> spent = {};
  int steps = 0;

  Future<T> _timed<T>(String what, Future<T> Function() f) async {
    final watch = Stopwatch()..start();
    try {
      return await f();
    } finally {
      spent[what] = (spent[what] ?? 0) + watch.elapsedMicroseconds;
    }
  }
  Future<void> _turn = Future.value();

  OnnxTexTeller._(this._encoderPath, this._decoderPath, this.keepOpen, this.threads);

  /// The files are opened when the first picture is read. [keepOpen] is how long they stay open after a reading (zero: closed
  /// after each one, for a device that has memory for one model at a time only).
  static Future<OnnxTexTeller> open(String encoderPath, String decoderPath,
          {Duration keepOpen = const Duration(seconds: 20), int? threads}) async =>
      OnnxTexTeller._(encoderPath, decoderPath, keepOpen, threads ?? (kIsWeb ? browserThreads() : math.min(4, math.max(2, Platform.numberOfProcessors ~/ 2))));

  OrtSessionOptions get _options => OrtSessionOptions(intraOpNumThreads: threads, interOpNumThreads: 1, useArena: false, lowPriority: true);

  @override
  Future<List<int>> read(Float32List pixels, {int maxTokens = texTellerMaxTokens}) async => (await readScored(pixels, maxTokens: maxTokens)).ids;

  @override
  Future<TexTellerReading> readScored(Float32List pixels, {int maxTokens = texTellerMaxTokens}) {
    // (one picture at a time: the sessions are shared)
    final result = _turn.then((_) => _read(pixels, maxTokens));
    _turn = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<TexTellerReading> _read(Float32List pixels, int maxTokens) async {
    _idle?.cancel();
    OrtValue? hidden;
    try {
      hidden = await _encode(pixels);
      return await _decode(hidden, maxTokens);
    } finally {
      await hidden?.dispose();
      if (keepOpen == Duration.zero) {
        await close();
      } else {
        _idle = Timer(keepOpen, () => unawaited(close()));
      }
    }
  }

  Future<OrtSession> _session(bool encoder) async {
    final open = encoder ? _encoder : _decoder;
    if (open != null) return open;
    final made = await _timed('open', () => openOnnxSession(encoder ? _encoderPath : _decoderPath, options: _options));
    encoder ? _encoder = made : _decoder = made;
    return made;
  }

  Future<OrtValue> _encode(Float32List pixels) async {
    final encoder = await _session(true);
    final input = await _timed('encode.input', () => OrtValue.fromList(pixels, [1, 1, texTellerImageSize, texTellerImageSize]));
    try {
      final out = await _timed('encode.run', () => encoder.run({'pixel_values': input}));
      final hidden = out['last_hidden_state'] ?? out.values.first;
      for (final e in out.values) {
        if (!identical(e, hidden)) await e.dispose();
      }
      return hidden;
    } finally {
      await input.dispose();
    }
  }

  Future<TexTellerReading> _decode(OrtValue hidden, int maxTokens) async {
    final decoder = await _session(false);
    final names = texTellerCacheNames().toList();
    // the first step has nothing cached; the graph wants something of the right kind there all the same (it is not used)
    final nothing = await OrtValue.fromList(Float32List(texTellerHeads * texTellerHeadSize), [1, texTellerHeads, 1, texTellerHeadSize]);
    final cacheOff = await OrtValue.fromList([false], [1]);
    final cacheOn = await OrtValue.fromList([true], [1]);
    final kept = <String, OrtValue>{}; // by the name it is handed back by (`past_key_values...`)
    // (every tensor let go of is a message to the plugin, about 50 of them for each token: they are sent without waiting for each
    // answer, while the next step runs, and all answered for at the end. Waiting for each took more time than the model.)
    final letGo = <Future<void>>[];
    void release(OrtValue v) => letGo.add(v.dispose());
    final ids = [texTellerStartToken];
    var logProb = 0.0;
    try {
      var first = true;
      while (ids.length < maxTokens) {
        steps++;
        final token = await _timed('step.token', () => int64Value([ids.last], [1, 1]));
        final feed = <String, OrtValue>{
          'input_ids': token,
          'encoder_hidden_states': hidden,
          'use_cache_branch': first ? cacheOff : cacheOn,
          for (final n in names) n.past: first ? nothing : kept[n.past]!,
        };
        final Map<String, OrtValue> out;
        try {
          out = await _timed('step.run', () => decoder.run(feed));
        } finally {
          await token.dispose();
        }
        final scores = out['logits']!;
        final flat = await _timed('step.scores', () => scores.asFlattenedList());
        release(scores);
        final next = lastArgMax(flat, scores.shape.last);
        logProb += lastLogProb(flat, scores.shape.last, next);

        await _timed('step.cache', () async {
          for (final n in names) {
            final fresh = out[n.present];
            if (fresh == null) continue;
            // the first step works out everything; later steps only add to the keys and values of the tokens, and hand the
            // (unchanged) ones of the picture back as nothing in particular
            if (first || n.decoder) {
              final old = kept[n.past];
              if (old != null) release(old);
              kept[n.past] = fresh;
            } else {
              release(fresh);
            }
          }
        });
        first = false;
        ids.add(next);
        if (next == texTellerEosToken) break;
      }
      return TexTellerReading(ids, logProb);
    } finally {
      for (final v in kept.values) {
        release(v);
      }
      release(nothing);
      release(cacheOff);
      release(cacheOn);
      await _timed('release', () => Future.wait(letGo));
    }
  }

  @override
  Future<void> close() async {
    _idle?.cancel();
    _idle = null;
    final encoder = _encoder, decoder = _decoder;
    _encoder = null;
    _decoder = null;
    await encoder?.close();
    await decoder?.close();
  }
}
