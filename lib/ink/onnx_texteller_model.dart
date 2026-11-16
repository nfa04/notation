import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../llm/onnx_session.dart';
import '../llm/warm_session.dart';
import '../web/browser_threads.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'ink_image.dart' show texTellerImageSize;
import 'texteller_decoder.dart';

/// What the encoder gives for a picture: 785 places (28 x 28 pieces and one more) of 768 numbers.
const List<int> texTellerHidden = [785, 768];

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
  WarmSession? _encoder;
  int _openedAt = onnxAccelerationChanges;
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
    _decoderLetGo = false;
    // (the setting of where models run changed since the sessions were opened: opened again)
    if (_openedAt != onnxAccelerationChanges) await close();
    _openedAt = onnxAccelerationChanges;
    OrtValue? hidden;
    try {
      hidden = await _encode(pixels);
      return await _decode(hidden, maxTokens);
    } finally {
      await hidden?.dispose();
      if (keepOpen == Duration.zero) {
        await close();
      } else {
        _idle = Timer(keepOpen, _idleClose);
      }
    }
  }

  Future<OrtSession> _decoderSession() async {
    final made = _decoder ?? await _timed<OrtSession>('open', () => openOnnxSession(_decoderPath, options: _options, accelerate: false));
    _decoder = made;
    return made;
  }

  Future<WarmSession> _encoderSession() async {
    // (shapes are not fixed: with them NNAPI took so much of the 32-bit encoder that its compile ran past ten minutes on a Pixel 8 Pro)
    // (MIGraphX and CoreML get the fixed 16-bit encoder only: on a Mac's CoreML the 8-bit one answered 15 % off, see [onnxFp16Files])
    final made = _encoder ?? await _timed<WarmSession>('open', () async => openWarmSession(_encoderPath, options: _options, oneSize: true, accelerate: onnxCheckedForFp16(_encoderPath) || !await onnxTakesOnlyFp16Files()));
    _encoder = made;
    return made;
  }

  Future<OrtValue> _encode(Float32List pixels) async {
    final encoder = await _encoderSession();
    // (the picture is always the same size: one plan; a wrong shape is checked for all the same, see [WarmSession.run])
    bool right(OrtValue v) => v.shape.length == 3 && v.shape[1] == texTellerHidden[0] && v.shape[2] == texTellerHidden[1];
    OrtValue hiddenOf(Map<String, OrtValue> out) => out['last_hidden_state'] ?? out.values.first;
    final out = await _timed(
      'encode.run',
      () => encoder.run(() async => {'pixel_values': await OrtValue.fromList(pixels, [1, 1, texTellerImageSize, texTellerImageSize])}, accept: (out) => right(hiddenOf(out))),
    );
    final hidden = hiddenOf(out);
    for (final e in out.values) {
      if (!identical(e, hidden)) await e.dispose();
    }
    if (right(hidden)) return hidden;
    final shape = hidden.shape;
    await hidden.dispose();
    throw StateError('The formula encoder gave $shape where [1, ${texTellerHidden.join(', ')}] was expected.');
  }

  /// Makes the encoder's plan for the graphics card now (AMD: about 2 minutes the first time, kept on disk) with a blank picture, so that
  /// no reading has to wait for it. The encoder has one picture size only, so this is the one plan.
  Future<void> precompile() async {
    _idle?.cancel();
    _decoderLetGo = false;
    try {
      final hidden = await _encode(Float32List(texTellerImageSize * texTellerImageSize));
      await hidden.dispose();
      // (the plan of a new session can be the right one only by chance of the first run: a second one shows it is the encoder's own)
      final again = await _encode(Float32List(texTellerImageSize * texTellerImageSize));
      await again.dispose();
    } finally {
      if (keepOpen == Duration.zero) {
        await close();
      } else {
        _idle = Timer(keepOpen, _idleClose);
      }
    }
  }

  Future<TexTellerReading> _decode(OrtValue hidden, int maxTokens) async {
    final decoder = await _decoderSession();
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

  // (not while the accelerator is making a plan: that would throw the minutes away and start it again)
  /// How long the encoder stays open: NNAPI compiles it again for every new session (seconds to minutes, and no cache), so while it
  /// runs there it is kept longer than the decoder (which the processor opens in a moment).
  static const _chipKeep = Duration(minutes: 2);
  bool _decoderLetGo = false;

  void _idleClose() {
    if (_encoder?.compiling != null) {
      _idle = Timer(keepOpen, _idleClose);
    } else if (_encoder != null && !_decoderLetGo && onnxCompiledForChip.contains(_encoderPath) && _chipKeep > keepOpen) {
      // (the decoder goes now, the encoder later)
      _decoderLetGo = true;
      final decoder = _decoder;
      _decoder = null;
      unawaited(decoder?.close());
      _idle = Timer(_chipKeep - keepOpen, _idleClose);
    } else {
      unawaited(close());
    }
  }

  @override
  Future<void> close() async {
    _idle?.cancel();
    _idle = null;
    _decoderLetGo = false;
    final encoder = _encoder, decoder = _decoder;
    _encoder = null;
    _decoder = null;
    await encoder?.close();
    await decoder?.close();
  }
}
