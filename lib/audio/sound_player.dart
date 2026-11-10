import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../web/blob_url_io.dart' if (dart.library.js_interop) '../web/blob_url_web.dart';

/// Plays a sound file kept with a note, one at a time, and says where it is.
abstract class SoundPlayer extends ChangeNotifier {
  /// The player for this system: the audio plugin on Android, iOS and macOS, a program of the system on Linux and Windows.
  /// (In a browser the plugin plays it too, from the bytes: there is no program to start.)
  factory SoundPlayer() => kIsWeb || Platform.isAndroid || Platform.isIOS || Platform.isMacOS ? PluginSoundPlayer() : ProcessSoundPlayer();

  /// The file being played or paused; null when stopped.
  String? get path;
  bool get playing;
  bool get paused;

  /// How far the sound has got, and how long it is (zero while not known).
  Duration get position;
  Duration get length;

  /// Whether the sound can be paused and moved within ([pause], [seek]); a system program may not allow it.
  bool get canSeek;

  /// Starts [path] at [from] (another sound that was playing stops). Throws when the sound cannot be played.
  Future<void> play(String path, {Duration from = Duration.zero, Duration? length});
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(Duration to);
  Future<void> stop();
}

/// [SoundPlayer] on `just_audio`.
class PluginSoundPlayer extends ChangeNotifier implements SoundPlayer {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  String? _path;
  String? _blobUrl;
  Duration _position = Duration.zero;
  bool _playing = false, _paused = false;

  static String _mimeOf(String path) => switch (path.split('.').last.toLowerCase()) {
        'wav' => 'audio/wav',
        'mp3' => 'audio/mpeg',
        'm4a' || 'aac' => 'audio/mp4',
        'ogg' || 'oga' => 'audio/ogg',
        'webm' => 'audio/webm',
        'flac' => 'audio/flac',
        _ => 'application/octet-stream',
      };

  PluginSoundPlayer() {
    _stateSub = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _playing = false;
        _paused = false;
        _path = null;
        _position = Duration.zero;
      }
      notifyListeners();
    });
    _positionSub = _player.positionStream.listen((p) {
      _position = p;
      notifyListeners();
    });
  }

  @override
  String? get path => _path;
  @override
  bool get playing => _playing;
  @override
  bool get paused => _paused;
  @override
  Duration get position => _position;
  @override
  Duration get length => _player.duration ?? Duration.zero;
  @override
  bool get canSeek => true;

  @override
  Future<void> play(String path, {Duration from = Duration.zero, Duration? length}) async {
    if (kIsWeb) {
      // the files of the web are in memory (lib/web/web_files_web.dart): the browser is given the bytes at an address of their own
      final old = _blobUrl;
      _blobUrl = blobUrlOf(await File(path).readAsBytes(), _mimeOf(path));
      await _player.setAudioSource(AudioSource.uri(Uri.parse(_blobUrl!)), initialPosition: from);
      if (old != null) revokeBlobUrl(old);
    } else {
      await _player.setFilePath(path, initialPosition: from);
    }
    _path = path;
    _playing = true;
    _paused = false;
    notifyListeners();
    unawaited(_player.play());
  }

  @override
  Future<void> pause() async {
    if (!_playing) return;
    _playing = false;
    _paused = true;
    notifyListeners();
    await _player.pause();
  }

  @override
  Future<void> resume() async {
    if (_path == null || _playing) return;
    _playing = true;
    _paused = false;
    notifyListeners();
    unawaited(_player.play());
  }

  @override
  Future<void> seek(Duration to) => _player.seek(to);

  @override
  Future<void> stop() async {
    _playing = false;
    _paused = false;
    _path = null;
    _position = Duration.zero;
    notifyListeners();
    await _player.stop();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _positionSub?.cancel();
    _player.dispose();
    final url = _blobUrl;
    if (url != null) revokeBlobUrl(url);
    super.dispose();
  }
}

/// [SoundPlayer] on a program of the system: `ffplay`, `paplay` or `aplay` on Linux, PowerShell on Windows. The program is stopped
/// and paused with signals where the system has them (not on Windows, where a pause is a stop). The position is counted, not asked.
class ProcessSoundPlayer extends ChangeNotifier implements SoundPlayer {
  /// [command] says which program plays a file and with which arguments (tests give another); null: the system's.
  ProcessSoundPlayer({Future<List<String>?> Function(String path, Duration from)? command}) : _commandFor = command ?? _systemCommand;

  final Future<List<String>?> Function(String path, Duration from) _commandFor;
  Process? _process;
  String? _path;
  bool _playing = false, _paused = false;
  Duration _from = Duration.zero, _length = Duration.zero;
  final Stopwatch _clock = Stopwatch();
  Timer? _tick;
  bool _canSeek = false;

  @override
  String? get path => _path;
  @override
  bool get playing => _playing;
  @override
  bool get paused => _paused;
  @override
  Duration get length => _length;
  @override
  bool get canSeek => _canSeek;

  @override
  Duration get position {
    final p = _from + _clock.elapsed;
    return _length > Duration.zero && p > _length ? _length : p;
  }

  static Future<List<String>?> _systemCommand(String path, Duration from) async {
    if (Platform.isWindows) {
      final escaped = path.replaceAll("'", "''");
      return ['powershell', '-NoProfile', '-Command', "(New-Object Media.SoundPlayer '$escaped').PlaySync()"];
    }
    Future<bool> has(String program) async => (await Process.run('which', [program])).exitCode == 0;
    if (await has('ffplay')) {
      return ['ffplay', '-nodisp', '-autoexit', '-loglevel', 'quiet', if (from > Duration.zero) ...['-ss', (from.inMilliseconds / 1000).toStringAsFixed(2)], path];
    }
    if (await has('paplay')) return ['paplay', path];
    if (await has('aplay')) return ['aplay', '-q', path];
    return null;
  }

  @override
  Future<void> play(String path, {Duration from = Duration.zero, Duration? length}) async {
    await stop();
    final command = await _commandFor(path, from);
    if (command == null) throw StateError('There is no program to play sound with (ffplay, paplay or aplay).');
    final process = await Process.start(command.first, command.skip(1).toList());
    _process = process;
    _path = path;
    _playing = true;
    _paused = false;
    _length = length ?? _length;
    // only ffplay can start in the middle; the others begin at the start whatever was asked
    _canSeek = command.first == 'ffplay';
    _from = _canSeek ? from : Duration.zero;
    _clock
      ..reset()
      ..start();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => notifyListeners());
    notifyListeners();
    // (the output must be read or a full pipe would stop the program)
    process.stdout.drain<void>();
    process.stderr.drain<void>();
    unawaited(process.exitCode.then((_) {
      if (!identical(_process, process)) return; // another sound has started since
      _end();
    }));
  }

  void _end() {
    _tick?.cancel();
    _clock
      ..stop()
      ..reset();
    _process = null;
    _path = null;
    _playing = false;
    _paused = false;
    _from = Duration.zero;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    final p = _process;
    if (p == null || !_playing || Platform.isWindows) return stop();
    p.kill(ProcessSignal.sigstop);
    _clock.stop();
    _playing = false;
    _paused = true;
    notifyListeners();
  }

  @override
  Future<void> resume() async {
    final p = _process;
    if (p == null || !_paused) return;
    p.kill(ProcessSignal.sigcont);
    _clock.start();
    _playing = true;
    _paused = false;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration to) async {
    final file = _path;
    if (file == null || !_canSeek) return;
    await play(file, from: to, length: _length);
  }

  @override
  Future<void> stop() async {
    final p = _process;
    if (p == null) return;
    _process = null; // (so that its end is not taken for the end of the next sound)
    if (_paused) p.kill(ProcessSignal.sigcont);
    p.kill();
    _end();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _process?.kill();
    super.dispose();
  }
}
