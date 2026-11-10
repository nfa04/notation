import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'whisper_audio.dart';

/// Takes sound from the microphone as 16 kHz mono samples (what Whisper wants), and tells how loud it is.
abstract class MicRecorder extends ChangeNotifier {
  factory MicRecorder() => PluginMicRecorder();

  bool get recording;

  /// How loud the last moment was, 0..1, for a meter.
  double get level;

  /// How long has been recorded.
  Duration get length;

  /// Whether the app may use the microphone (asks if it must).
  Future<bool> allowed();

  Future<void> start();

  /// Everything recorded since [start] (or since the last [take]) that has not been taken; [take] empties the buffer.
  Float32List take();

  /// Ends the recording and returns what was recorded and not yet taken.
  Future<Float32List> stop();
}

/// [MicRecorder] on the `record` package: 16 kHz mono samples, handed on in pieces as they come.
class PluginMicRecorder extends ChangeNotifier implements MicRecorder {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final BytesBuilder _pending = BytesBuilder(copy: false);
  int _total = 0;
  bool _recording = false;
  double _level = 0;
  int _lastNotify = 0;

  @override
  bool get recording => _recording;

  @override
  double get level => _level;

  @override
  Duration get length => Duration(milliseconds: _total * 1000 ~/ (whisperSampleRate * 2));

  @override
  Future<bool> allowed() => _recorder.hasPermission();

  /// The start under way: a second call while the microphone is being opened waits for it instead of opening it again.
  Future<void>? _starting;

  @override
  Future<void> start() => _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    if (_recording) return;
    if (!await _recorder.hasPermission()) throw StateError('The microphone may not be used. Allow it in the settings of the device.');
    _pending.clear();
    _total = 0;
    final stream = await _recorder.startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: whisperSampleRate, numChannels: 1, echoCancel: false, noiseSuppress: false));
    _recording = true;
    _sub = stream.listen((bytes) {
      _pending.add(bytes);
      _total += bytes.length;
      // the meter: the loudest sample of this piece
      var peak = 0;
      final view = ByteData.sublistView(bytes);
      for (var i = 0; i + 1 < bytes.length; i += 2 * 8) {
        final v = view.getInt16(i, Endian.little).abs();
        if (v > peak) peak = v;
      }
      _level = peak / 32768;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastNotify > 100) {
        _lastNotify = now;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  @override
  Float32List take() {
    final bytes = _pending.takeBytes();
    final samples = Float32List(bytes.length ~/ 2);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little) / 32768;
    }
    return samples;
  }

  @override
  Future<Float32List> stop() async {
    if (!_recording) return Float32List(0);
    _recording = false;
    await _recorder.stop();
    await _sub?.cancel();
    _sub = null;
    _level = 0;
    notifyListeners();
    return take();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _recorder.dispose();
    super.dispose();
  }
}
