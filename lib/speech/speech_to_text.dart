import 'dart:async';
import '../llm/onnx_session.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/settings_repository.dart';
import '../ink/ink_recognizer.dart' show HandwritingStatus;
import '../llm/model_files.dart';
import 'whisper_audio.dart';
import 'whisper_tokenizer.dart';

/// One of the Whisper models on offer (MIT licence of OpenAI, Apache-2.0 on the ONNX copies; the ONNX files are those of `onnx-community`). The encoder is
/// kept in full precision: its 8-bit version makes Whisper-tiny write nonsense. The decoder is the 8-bit one.
class WhisperSpec {
  final String id, label, description, folder;
  final String encoderUrl, decoderUrl;
  final int encoderMb, decoderMb;

  /// The shape of the attention cache of the decoder.
  final int layers, heads;

  const WhisperSpec({
    required this.id,
    required this.label,
    required this.description,
    required this.folder,
    required this.encoderUrl,
    required this.decoderUrl,
    required this.encoderMb,
    required this.decoderMb,
    required this.layers,
    required this.heads,
  });

  static const _tiny = 'https://huggingface.co/onnx-community/whisper-tiny/resolve/main';
  static const _base = 'https://huggingface.co/onnx-community/whisper-base/resolve/main';

  Map<String, ({String url, int megabytes})> get files => {
        'encoder.onnx': (url: encoderUrl, megabytes: encoderMb),
        'decoder.onnx': (url: decoderUrl, megabytes: decoderMb),
        'tokenizer.json': (url: '${encoderUrl.startsWith(_tiny) ? _tiny : _base}/tokenizer.json', megabytes: 3),
        'config.json': (url: '${encoderUrl.startsWith(_tiny) ? _tiny : _base}/config.json', megabytes: 1),
      };

  static const base = WhisperSpec(
    id: 'whisper-base',
    label: 'Better',
    description: 'Whisper base: a good guess at 99 languages, German and English among them. Slower.',
    folder: 'whisper_base',
    encoderUrl: '$_base/onnx/encoder_model.onnx',
    decoderUrl: '$_base/onnx/decoder_model_merged_int8.onnx',
    encoderMb: 83,
    decoderMb: 54,
    layers: 6,
    heads: 8,
  );

  static const tiny = WhisperSpec(
    id: 'whisper-tiny',
    label: 'Faster',
    description: 'Whisper tiny: half the size and twice as fast, but it makes more mistakes, especially in German.',
    folder: 'whisper_tiny',
    encoderUrl: '$_tiny/onnx/encoder_model.onnx',
    decoderUrl: '$_tiny/onnx/decoder_model_merged_int8.onnx',
    encoderMb: 33,
    decoderMb: 31,
    layers: 4,
    heads: 6,
  );

  static const all = [base, tiny];
}

/// What turns one window of sound into text: the encoder and decoder of Whisper run by ONNX Runtime. Tests pass a fake.
abstract class WhisperEngine {
  /// The text of a window of at most 30 seconds. [language] is a code like 'de', or null to find it out; [detected] is told which one
  /// the model found. [onPartial] gets the text as it is written.
  Future<String> transcribe(Float32List window, {String? language, void Function(String language)? detected, bool Function()? shouldStop});
  Future<void> close();
}

/// [WhisperEngine] that runs the Whisper encoder and decoder with ONNX Runtime (greedy decoding with a cache for the decoder).
class OnnxWhisper implements WhisperEngine {
  final String encoderPath, decoderPath;
  final WhisperTokenizer tokenizer;
  final Set<int> suppressed;
  final int layers, heads;

  OnnxWhisper({required this.encoderPath, required this.decoderPath, required this.tokenizer, required this.suppressed, required this.layers, required this.heads});

  OrtSession? _encoder, _decoder;
  static final _options = OrtSessionOptions(intraOpNumThreads: 4, interOpNumThreads: 1, useArena: false);

  static const _vocab = 51865;
  static const _startOfTranscript = 50258;
  static const _firstLanguage = 50259;
  static const _transcribe = 50359;
  static const _noTimestamps = 50363;
  static const _endOfText = 50257;
  static const _maxTokens = 220;

  /// The languages, by the order of their tokens (the first 99 of Whisper).
  static const languages = [
    'en', 'zh', 'de', 'es', 'ru', 'ko', 'fr', 'ja', 'pt', 'tr', 'pl', 'ca', 'nl', 'ar', 'sv', 'it', 'id', 'hi', 'fi', 'vi', 'he', 'uk', 'el', 'ms',
    'cs', 'ro', 'da', 'hu', 'ta', 'no', 'th', 'ur', 'hr', 'bg', 'lt', 'la', 'mi', 'ml', 'cy', 'sk', 'te', 'fa', 'lv', 'bn', 'sr', 'az', 'sl', 'kn',
    'et', 'mk', 'br', 'eu', 'is', 'hy', 'ne', 'mn', 'bs', 'kk', 'sq', 'sw', 'gl', 'mr', 'pa', 'si', 'km', 'sn', 'yo', 'so', 'af', 'oc', 'ka', 'be',
    'tg', 'sd', 'gu', 'am', 'yi', 'lo', 'uz', 'fo', 'ht', 'ps', 'tk', 'nn', 'mt', 'sa', 'lb', 'my', 'bo', 'tl', 'mg', 'as', 'tt', 'haw', 'ln', 'ha',
    'ba', 'jw', 'su',
  ];

  Future<OrtSession> _enc() async => _encoder ??= await openOnnxSession(encoderPath, options: _options);
  Future<OrtSession> _dec() async => _decoder ??= await openOnnxSession(decoderPath, options: _options);

  static Future<void> _breathe() => Future<void>.delayed(const Duration(milliseconds: 4));

  @override
  Future<String> transcribe(Float32List window, {String? language, void Function(String language)? detected, bool Function()? shouldStop}) async {
    final encoder = await _enc();
    final decoder = await _dec();
    final mel = await OrtValue.fromList(logMelSpectrogram(window), [1, whisperBands, whisperFrames]);
    final encoded = await encoder.run({'input_features': mel});
    await mel.dispose();
    final hidden = encoded['last_hidden_state']!;
    // the decoder wants a cache as input also for the first step, where the graph does not look at it: one position of zeros stands in
    final stand = await OrtValue.fromList(Float32List(heads * 64), [1, heads, 1, 64]);
    final names = [for (var i = 0; i < layers; i++) for (final part in const ['decoder.key', 'decoder.value', 'encoder.key', 'encoder.value']) 'past_key_values.$i.$part'];
    final noCache = await OrtValue.fromList([false], [1]);
    final useCache = await OrtValue.fromList([true], [1]);
    var cache = <String, OrtValue>{};

    /// One step: the scores of the last position, and the cache to go on with.
    Future<(List<double>, Map<String, OrtValue>)> step(List<int> ids, Map<String, OrtValue>? past) async {
      final input = await int64Value(ids, [1, ids.length]);
      final out = await decoder.run({
        'input_ids': input,
        'encoder_hidden_states': hidden,
        'use_cache_branch': past == null ? noCache : useCache,
        for (final n in names) n: past?[n] ?? stand,
      });
      await input.dispose();
      final logits = out.remove('logits')!;
      final flat = await logits.asFlattenedList();
      await logits.dispose();
      final last = [for (var i = flat.length - _vocab; i < flat.length; i++) (flat[i] as num).toDouble()];
      final cache = {for (final e in out.entries) e.key.replaceFirst('present.', 'past_key_values.'): e.value};
      return (last, cache);
    }

    final tokens = <int>[];
    try {
      var lang = language == null ? null : languages.indexOf(language);
      if (lang == null || lang < 0) {
        // which language is spoken: the model's own guess at the first position
        final (scores, probe) = await step([_startOfTranscript], null);
        for (final v in probe.values) {
          await v.dispose();
        }
        var best = 0;
        var bestScore = double.negativeInfinity;
        for (var i = 0; i < languages.length; i++) {
          final s = scores[_firstLanguage + i];
          if (s > bestScore) {
            bestScore = s;
            best = i;
          }
        }
        lang = best;
        detected?.call(languages[best]);
      }
      final prompt = [_startOfTranscript, _firstLanguage + lang, _transcribe, _noTimestamps];
      var (scores, first0) = await step(prompt, null);
      cache = first0;
      var first = true;
      for (var i = 0; i < _maxTokens; i++) {
        if (shouldStop?.call() ?? false) break;
        var best = -1;
        var bestScore = double.negativeInfinity;
        for (var t = 0; t < _vocab; t++) {
          if (suppressed.contains(t) || t > _noTimestamps || (first && (t == 220 || t == _endOfText))) continue;
          if (scores[t] > bestScore) {
            bestScore = scores[t];
            best = t;
          }
        }
        first = false;
        if (best == _endOfText || best < 0) break;
        tokens.add(best);
        if (_loops(tokens)) {
          tokens.removeRange(tokens.length - 12, tokens.length);
          break;
        }
        final previous = cache;
        final next = await step([best], previous);
        // the encoder part of the cache stays what it was; the new one is the same numbers
        for (final e in next.$2.entries) {
          if (e.key.contains('.encoder.')) await e.value.dispose();
        }
        cache = {for (final e in next.$2.entries) if (!e.key.contains('.encoder.')) e.key: e.value, for (final e in previous.entries) if (e.key.contains('.encoder.')) e.key: e.value};
        for (final e in previous.entries) {
          if (!e.key.contains('.encoder.')) await e.value.dispose();
        }
        scores = next.$1;
        await _breathe();
      }
    } finally {
      for (final v in {...cache.values, stand, noCache, useCache, hidden}) {
        await v.dispose();
      }
    }
    return tokenizer.decode(tokens).trim();
  }

  /// Whether the last tokens are the same group over and over (the model stuck on a word): then it is cut short.
  static bool _loops(List<int> t) {
    for (final size in const [1, 2, 3, 4]) {
      final repeats = size == 1 ? 8 : (12 ~/ size);
      if (t.length < size * repeats) continue;
      var same = true;
      for (var r = 1; r < repeats && same; r++) {
        for (var k = 0; k < size; k++) {
          if (t[t.length - 1 - k] != t[t.length - 1 - k - r * size]) {
            same = false;
            break;
          }
        }
      }
      if (same) return true;
    }
    return false;
  }

  @override
  Future<void> close() async {
    await _encoder?.close();
    await _decoder?.close();
    _encoder = _decoder = null;
  }
}

/// Speech to text: Whisper on the device. The model is downloaded when wanted and kept in memory for a while after the last use.
class SpeechToText extends ModelFilesService {
  static const _modelKey = 'whisper_model';
  static const _languageKey = 'whisper_language';

  final SettingsRepository? _settings;
  final Future<Directory> Function() _modelsRoot;
  final Future<WhisperEngine> Function(WhisperSpec spec, Directory dir)? _engineFactory;
  final Duration keepLoaded;

  SpeechToText({
    SettingsRepository? settings,
    Future<Directory> Function()? modelsRoot,
    Future<WhisperEngine> Function(WhisperSpec spec, Directory dir)? engine,
    super.download,
    this.keepLoaded = const Duration(minutes: 3),
  })  : _settings = settings,
        _modelsRoot = modelsRoot ?? (() async => Directory(p.join((await getApplicationSupportDirectory()).path, 'models'))),
        _engineFactory = engine,
        super(files: WhisperSpec.base.files, folderName: 'whisper');

  WhisperSpec _spec = WhisperSpec.base;
  WhisperSpec get spec => _spec;
  List<WhisperSpec> get specs => WhisperSpec.all;

  /// A language code, or null to find out what is spoken.
  String? language;

  @override
  Future<Directory> directory() async => Directory(p.join((await _modelsRoot()).path, _spec.folder));

  @override
  Future<void> load() async {
    final saved = await _settings?.get(_modelKey);
    _spec = specs.where((s) => s.id == saved).firstOrNull ?? _spec;
    files = _spec.files;
    final l = await _settings?.get(_languageKey);
    language = l == null || l == 'auto' ? null : l;
    await super.load();
  }

  Future<void> select(WhisperSpec next) async {
    if (next.id == _spec.id || status == HandwritingStatus.downloading) return;
    await unload();
    _spec = next;
    files = next.files;
    await _settings?.set(_modelKey, next.id);
    await super.load();
  }

  Future<void> setLanguage(String? code) async {
    language = code;
    await _settings?.set(_languageKey, code ?? 'auto');
    notifyListeners();
  }

  WhisperEngine? _engine;
  Timer? _unloadTimer;
  Future<void> _queue = Future.value();

  @override
  Future<void> unload() async {
    _unloadTimer?.cancel();
    final e = _engine;
    _engine = null;
    await e?.close();
  }

  Future<WhisperEngine> _open() async {
    final existing = _engine;
    if (existing != null) return existing;
    final dir = await directory();
    final factory = _engineFactory;
    if (factory != null) return _engine = await factory(_spec, dir);
    final config = jsonDecode(await File(p.join(dir.path, 'config.json')).readAsString()) as Map;
    return _engine = OnnxWhisper(
      encoderPath: p.join(dir.path, 'encoder.onnx'),
      decoderPath: p.join(dir.path, 'decoder.onnx'),
      tokenizer: WhisperTokenizer.parse(await File(p.join(dir.path, 'tokenizer.json')).readAsString()),
      suppressed: {for (final t in (config['suppress_tokens'] as List? ?? const [])) (t as num).toInt()},
      layers: _spec.layers,
      heads: _spec.heads,
    );
  }

  /// The text of [samples] (16 kHz, mono, -1..1) of any length: cut into pieces of under 30 seconds where it is quiet, the quiet
  /// ones left out. [onText] is told the text so far after each piece. One request at a time; the next waits.
  Future<String> transcribe(
    Float32List samples, {
    String? language,
    void Function(String textSoFar)? onText,
    void Function(double done)? progress,
    bool Function()? shouldStop,
  }) {
    final result = _queue.then((_) => _transcribe(samples, language ?? this.language, onText, progress, shouldStop));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String> _transcribe(Float32List samples, String? lang, void Function(String)? onText, void Function(double)? progress, bool Function()? shouldStop) async {
    if (!installed) throw StateError('The speech model is not downloaded yet.');
    _unloadTimer?.cancel();
    try {
      final engine = await _open();
      final pieces = splitAtQuiet(samples);
      final text = StringBuffer();
      var spoken = lang;
      for (var i = 0; i < pieces.length; i++) {
        if (shouldStop?.call() ?? false) break;
        progress?.call(i / pieces.length);
        // a piece with hardly any sound in it is not given to the model (it would invent words)
        if (loudness(pieces[i]) < 0.004) continue;
        final said = await engine.transcribe(pieces[i], language: spoken, detected: (l) => spoken ??= l, shouldStop: shouldStop);
        if (said.isEmpty) continue;
        if (text.isNotEmpty) text.write(' ');
        text.write(said);
        onText?.call(text.toString());
      }
      progress?.call(1);
      return text.toString();
    } catch (e) {
      await unload(); // start from scratch next time
      rethrow;
    } finally {
      _unloadTimer = Timer(keepLoaded, unload);
    }
  }

  @override
  void dispose() {
    _unloadTimer?.cancel();
    super.dispose();
  }
}

/// The languages of Whisper that the app offers by name; the others can be found out by the model itself.
const speechLanguages = {
  'en': 'English', 'de': 'Deutsch', 'fr': 'Français', 'es': 'Español', 'it': 'Italiano', 'pt': 'Português', 'nl': 'Nederlands',
  'pl': 'Polski', 'ru': 'Русский', 'tr': 'Türkçe', 'ja': '日本語', 'zh': '中文', 'ko': '한국어', 'ar': 'العربية', 'sv': 'Svenska',
};
