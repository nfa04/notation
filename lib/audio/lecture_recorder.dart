import 'dart:async';
import 'dart:typed_data';

import '../speech/mic_recorder.dart';
import '../speech/whisper_audio.dart';
import 'sound_marks.dart';
import 'wav.dart';

/// What a lecture recording came to: the sound (a mu-law WAV, small enough for an hour), how long it is, and the elements written
/// while it ran with the moment of each.
class LectureResult {
  final Uint8List wav;
  final Duration length;
  final List<SoundMark> marks;

  const LectureResult(this.wav, this.length, this.marks);
}

/// Records the sound while the person goes on writing (not in a dialog that stops everything else), and notes the moment each new
/// stroke or text box appears. The sound is packed as it comes, so a long lecture does not fill the memory.
class LectureRecorder {
  final MicRecorder _mic;
  final Duration _every;
  final SpeechWavWriter _kept = SpeechWavWriter(fromRate: whisperSampleRate);
  final MarkCollector _marks = MarkCollector();
  Timer? _tick;
  bool _on = false;

  LectureRecorder({MicRecorder? mic, Duration every = const Duration(seconds: 2)})
      : _mic = mic ?? MicRecorder(),
        _every = every;

  bool get recording => _on;

  /// How long has been recorded.
  Duration get length => _mic.length;

  /// How loud the last moment was (0 to 1), for a meter.
  double get level => _mic.level;

  /// Starts recording; [existing] is what is on the pages already (those elements are not marked). False when the microphone is not
  /// allowed.
  Future<bool> start(Map<int, List<String>> existing) async {
    if (_on) return true;
    if (!await _mic.allowed()) return false;
    _marks.begin(existing);
    await _mic.start();
    _on = true;
    _tick = Timer.periodic(_every, (_) => _kept.add(_mic.take()));
    return true;
  }

  /// Notes the elements that are new since the last call, at the moment it is now.
  void observe(Map<int, List<String>> idsByPage) {
    if (_on) _marks.observe(idsByPage, _mic.length);
  }

  /// Ends the recording; null when nothing was recorded.
  Future<LectureResult?> finish() async {
    if (!_on) return null;
    _on = false;
    _tick?.cancel();
    final length = _mic.length;
    _kept.add(_mic.take());
    _kept.add(await _mic.stop());
    _mic.dispose();
    if (length < const Duration(seconds: 1)) return null;
    return LectureResult(_kept.finish(), length, List.of(_marks.marks));
  }

  /// Ends the recording and throws the sound away.
  Future<void> cancel() async {
    if (!_on) return;
    _on = false;
    _tick?.cancel();
    await _mic.stop();
    _mic.dispose();
  }
}
