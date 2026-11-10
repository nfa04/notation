import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../ai/text_provider.dart' show AiCancel;
import '../audio/wav.dart';
import '../l10n/language.dart';

/// Reads a text out loud. The voices are those of the system (nothing to download, nothing sent anywhere): the speech
/// service of Android and iOS, Windows and macOS through `flutter_tts`, and on Linux `spd-say` (speech-dispatcher) or
/// `espeak-ng`, whichever is installed.
abstract class ReadAloud extends ChangeNotifier {
  /// The synthesizer of this platform.
  factory ReadAloud.forPlatform() => !kIsWeb && Platform.isLinux ? ProcessReadAloud() : PluginReadAloud();

  bool get speaking;

  /// Reading has been asked for but no sound has started yet (the voice is being loaded or the first piece made).
  bool get preparing;

  /// Whether this device can read at all (on Linux only when a speech program is installed).
  Future<bool> get available;

  /// Reads [text] in [language] (a code like 'en' or 'de'); returns when it has been read or stopped. A reading in progress is
  /// stopped first. [rate] is 0.5 (slow) to 2 (fast), 1 normal.
  Future<void> speak(String text, {String language = 'en', double rate = 1});

  Future<void> stop();

  /// Whether the voice can write the reading into a file ([synthesize]): with `espeak-ng` on Linux; not with the other systems' voices
  /// that play straight to the speaker.
  Future<bool> get canSynthesize;

  /// The reading of [text] as a WAV file (see [compressSpeechWav]) instead of out loud; null when this device cannot, or when [cancel]
  /// was cancelled. [onProgress] is told how many pieces of the text are done.
  Future<Uint8List?> synthesize(String text, {String language = 'en', double rate = 1, void Function(int done, int total)? onProgress, AiCancel? cancel});
}

/// Splits [text] into pieces of about [limit] characters at the ends of sentences, so that no piece is longer than the
/// speech services take (Android refuses more than about 4000 characters at once).
List<String> speechPieces(String text, {int limit = 1500}) {
  final pieces = <String>[];
  var current = StringBuffer();
  void flush() {
    final t = current.toString().trim();
    if (t.isNotEmpty) pieces.add(t);
    current = StringBuffer();
  }

  for (final sentence in text.replaceAll(RegExp(r'[ \t]+'), ' ').split(RegExp(r'(?<=[.!?:;])\s+|\n+'))) {
    var s = sentence.trim();
    if (s.isEmpty) continue;
    while (s.length > limit) {
      final cut = s.lastIndexOf(' ', limit);
      final at = cut > limit ~/ 2 ? cut : limit;
      if (current.length + at > limit) flush();
      current.write('${s.substring(0, at)} ');
      s = s.substring(at).trim();
    }
    if (current.length + s.length + 1 > limit) flush();
    current.write('$s ');
  }
  flush();
  return pieces;
}

/// Android, iOS, macOS and Windows: the system voices through `flutter_tts`, one piece of text at a time.
class PluginReadAloud extends BaseReadAloud {
  final FlutterTts _tts = FlutterTts();
  Completer<void>? _done;
  Completer<void>? _started;
  String? _error;
  bool _configured = false;

  PluginReadAloud() {
    _tts.setStartHandler(() {
      setPreparing(false);
      final s = _started;
      if (s != null && !s.isCompleted) s.complete();
    });
    _tts.setCompletionHandler(() => _finish());
    _tts.setCancelHandler(() => _finish());
    _tts.setErrorHandler((message) {
      _error = '$message';
      _finish();
    });
  }

  void _finish() {
    final d = _done;
    if (d != null && !d.isCompleted) d.complete();
  }

  @override
  Future<bool> get available async => true;

  /// The plugin holds every call until the system's speech engine has answered that it is ready; when the app cannot find
  /// or bind an engine (none installed, or hidden from the app) it never does, and a call would wait for ever.
  static Future<T> _answered<T>(Future<T> call) => call.timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw StateError(tr('This device has no working speech engine. Install one (for example eSpeak NG or SherpaTTS from F-Droid) and choose it in the system settings under Text-to-speech.')),
      );

  @override
  Future<void> speak(String text, {String language = 'en', double rate = 1}) async {
    await stop();
    if (!_configured) {
      await _tts.awaitSpeakCompletion(false);
      _configured = true;
    }
    final session = ++_session;
    _error = null;
    setSpeaking(true);
    setPreparing(true);
    try {
      await _answered(_tts.setLanguage(switch (language) { 'de' => 'de-DE', 'fr' => 'fr-FR', _ => 'en-US' }));
      // the engines take a rate of about 0.5 for normal speed
      await _answered(_tts.setSpeechRate((0.5 * rate).clamp(0.1, 1.0)));
      var first = true;
      for (final piece in speechPieces(text)) {
        if (session != _session) return;
        _done = Completer<void>();
        _started = Completer<void>();
        final accepted = await _answered(_tts.speak(piece));
        if (accepted != 1 && session == _session) throw StateError(tr('The speech engine of this device did not take the text (is a voice installed?).'));
        if (first) {
          // no sound within a while: the engine is missing or has no voice
          await Future.any([_started!.future, _done!.future, Future<void>.delayed(const Duration(seconds: 15))]);
          if (session != _session) return;
          if (_error == null && !_started!.isCompleted && !_done!.isCompleted) {
            await _tts.stop();
            throw StateError(tr('The speech engine of this device did not start (is a voice installed in the system settings?).'));
          }
          first = false;
        }
        await _done!.future;
        if (_error != null && session == _session) throw StateError('The speech engine reported: $_error');
      }
    } finally {
      if (session == _session) {
        setPreparing(false);
        setSpeaking(false);
      }
    }
  }

  @override
  Future<bool> get canSynthesize async => false;

  @override
  Future<Uint8List?> synthesize(String text, {String language = 'en', double rate = 1, void Function(int done, int total)? onProgress, AiCancel? cancel}) async => null;

  @override
  Future<void> stop() async {
    _session++;
    _finish();
    try {
      await _tts.stop().timeout(const Duration(seconds: 2));
    } catch (_) {}
    setPreparing(false);
    setSpeaking(false);
  }
}

/// Linux: a speech program of the system, one piece at a time.
class ProcessReadAloud extends BaseReadAloud {
  Process? _process;

  /// The speech programs installed, the better one first.
  static Future<List<String>> _programs() async => [
        for (final program in const ['spd-say', 'espeak-ng', 'espeak'])
          if ((await Process.run('which', [program])).exitCode == 0) program,
      ];

  @override
  Future<bool> get available async => (await _programs()).isNotEmpty;

  @override
  Future<void> speak(String text, {String language = 'en', double rate = 1}) async {
    await stop();
    final programs = await _programs();
    if (programs.isEmpty) throw StateError('There is no speech program installed (speech-dispatcher or espeak-ng).');
    final session = ++_session;
    setSpeaking(true);
    setPreparing(true);
    try {
      var which = 0; // a program that fails is given up on, and the next one reads from that piece on
      String? problem;
      for (final piece in speechPieces(text)) {
        while (true) {
          if (session != _session) return;
          if (which >= programs.length) throw StateError(problem ?? 'The speech program made no sound.');
          final program = programs[which];
          final args = switch (program) {
            'spd-say' => ['--wait', '-l', language, '-r', '${((rate - 1) * 100).round().clamp(-100, 100)}', '--', piece],
            _ => ['-v', language, '-s', '${(170 * rate).round()}', '--', piece],
          };
          final p = _process = await Process.start(program, args);
          setPreparing(false);
          final err = StringBuffer();
          p.stderr.transform(const SystemEncoding().decoder).listen(err.write);
          final code = await p.exitCode;
          if (session != _session) return;
          if (code == 0 && err.toString().trim().isEmpty) break;
          problem = '$program: ${err.toString().trim().isEmpty ? 'exit code $code' : err.toString().trim()}';
          which++;
          setPreparing(true);
        }
      }
    } finally {
      _process = null;
      if (session == _session) {
        setPreparing(false);
        setSpeaking(false);
      }
    }
  }

  static Future<String?> _espeak() async {
    for (final program in const ['espeak-ng', 'espeak']) {
      if ((await Process.run('which', [program])).exitCode == 0) return program;
    }
    return null;
  }

  @override
  Future<bool> get canSynthesize async => await _espeak() != null;

  @override
  Future<Uint8List?> synthesize(String text, {String language = 'en', double rate = 1, void Function(int done, int total)? onProgress, AiCancel? cancel}) async {
    final program = await _espeak();
    if (program == null) return null;
    final pieces = speechPieces(text);
    SpeechWavWriter? writer;
    for (var i = 0; i < pieces.length; i++) {
      if (cancel?.cancelled ?? false) return null;
      final result = await Process.run(program, ['-v', language, '-s', '${(170 * rate).round()}', '--stdout', '--', pieces[i]], stdoutEncoding: null);
      if (result.exitCode != 0) throw StateError('$program: ${'${result.stderr}'.trim().isEmpty ? 'exit code ${result.exitCode}' : '${result.stderr}'.trim()}');
      final sound = decodeWav(Uint8List.fromList(result.stdout as List<int>));
      if (sound == null) throw StateError(tr('The speech program made no sound.'));
      writer ??= SpeechWavWriter(rate: sound.sampleRate < 16000 ? sound.sampleRate : 16000, fromRate: sound.sampleRate);
      writer.add(sound.samples);
      writer.add(Float32List(sound.sampleRate ~/ 4)); // a breath between the pieces
      onProgress?.call(i + 1, pieces.length);
    }
    return writer?.finish();
  }

  @override
  Future<void> stop() async {
    _session++;
    _process?.kill();
    _process = null;
    setPreparing(false);
    setSpeaking(false);
  }
}

/// What the two have in common.
abstract class BaseReadAloud extends ChangeNotifier implements ReadAloud {
  bool _speaking = false;
  int _session = 0;

  @override
  bool get speaking => _speaking;

  bool _preparing = false;

  @override
  bool get preparing => _preparing;

  @protected
  void setPreparing(bool value) {
    if (_preparing == value) return;
    _preparing = value;
    notifyListeners();
  }

  @protected
  void setSpeaking(bool value) {
    if (_speaking == value) return;
    _speaking = value;
    notifyListeners();
  }
}
