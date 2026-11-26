import 'dart:math' as math;
import 'dart:typed_data';

import 'bits.dart';
import 'byte_source.dart';

/// Decoded sound, as it comes: a stream of blocks, each a list with one list of samples (-1..1) per channel.
abstract class PcmSource {
  /// What the file holds: 'aac', 'mp3', 'opus', 'flac', 'vorbis', 'pcm'.
  String get codec;
  int get sampleRate;
  int get channels;

  /// How long it is in seconds, when the file says (else null).
  double? get seconds;
  Stream<List<Float64List>> blocks();
}

/// Turns the channels of a block into one by averaging them.
Float64List downmix(List<Float64List> block) {
  if (block.length == 1) return block[0];
  final out = Float64List(block[0].length);
  final k = 1.0 / block.length;
  for (final c in block) {
    for (var i = 0; i < out.length; i++) {
      out[i] += c[i] * k;
    }
  }
  return out;
}

/// Changes the sampling rate of a stream of mono blocks with a windowed sinc filter (low pass at the lower of the two rates), block
/// by block.
class Resampler {
  final int inRate, outRate;
  final double _step; // input samples per output sample
  final double _cut; // cut off, relative to the input rate's Nyquist
  final int _half; // input samples on each side
  Float64List _buf = Float64List(0);
  double _next = 0; // position of the next output sample in _buf
  late final Float64List _table; // the kernel from -_half to _half in steps of 1/_perSample
  static const _perSample = 64;

  Resampler(this.inRate, this.outRate)
      : _step = inRate / outRate,
        _cut = math.min(1.0, outRate / inRate) * 0.96,
        _half = (6 * math.max(1.0, inRate / outRate)).ceil() {
    _table = Float64List(2 * _half * _perSample + 2);
    for (var i = 0; i < _table.length; i++) {
      _table[i] = _kernel(i / _perSample - _half);
    }
  }

  bool get isIdentity => inRate == outRate;

  double _kernel(double x) {
    final a = x * _cut;
    final s = a == 0 ? 1.0 : math.sin(math.pi * a) / (math.pi * a);
    final w = 0.5 + 0.5 * math.cos(math.pi * x / (_half + 1));
    return s * w * _cut;
  }

  Float32List push(Float64List input) {
    if (isIdentity) return Float32List.fromList(input);
    final joined = Float64List(_buf.length + input.length)
      ..setAll(0, _buf)
      ..setAll(_buf.length, input);
    _buf = joined;
    return _produce(false);
  }

  /// The last samples, with silence after the end.
  Float32List finish() {
    if (isIdentity) return Float32List(0);
    final padded = Float64List(_buf.length + _half + 2)..setAll(0, _buf);
    _buf = padded;
    final out = _produce(true);
    _buf = Float64List(0);
    return out;
  }

  Float32List _produce(bool last) {
    final out = <double>[];
    final limit = last ? _buf.length - _half - 2 : _buf.length - _half - 1;
    while (_next < limit) {
      final centre = _next;
      final i0 = centre.floor();
      var acc = 0.0, norm = 0.0;
      for (var i = i0 - _half + 1; i <= i0 + _half; i++) {
        final x = (i - centre + _half) * _perSample;
        final xi = x.floor();
        final w = _table[xi] + (_table[xi + 1] - _table[xi]) * (x - xi);
        norm += w;
        if (i >= 0 && i < _buf.length) acc += _buf[i] * w;
      }
      out.add(norm == 0 ? 0 : acc / norm);
      _next += _step;
    }
    // keep only what later outputs still need
    final keepFrom = math.max(0, _next.floor() - _half);
    if (keepFrom > 0) {
      _buf = Float64List.sublistView(_buf, math.min(keepFrom, _buf.length));
      _next -= keepFrom;
    }
    return Float32List.fromList(out);
  }
}

/// The sound of [source] as 16 kHz mono blocks (what Whisper takes), made as the file is decoded. Needs about as much memory as one
/// block, not as the whole file.
Stream<Float32List> mono16k(PcmSource source) async* {
  final resampler = Resampler(source.sampleRate, 16000);
  await for (final block in source.blocks()) {
    final out = resampler.push(downmix(block));
    if (out.isNotEmpty) yield out;
  }
  final rest = resampler.finish();
  if (rest.isNotEmpty) yield rest;
}

/// Sniffs what kind of file [source] is from its first bytes.
Future<String> sniffAudio(ByteSource source) async {
  final head = await source.read(0, 4096);
  if (head.length < 4) throw const AudioFormatException('This file is too short to be audio or video.');
  String at(int o, int n) => String.fromCharCodes(head.sublist(o, math.min(head.length, o + n)));
  if (at(0, 4) == 'RIFF' && at(8, 4) == 'WAVE') return 'wav';
  if (at(0, 4) == 'fLaC') return 'flac';
  if (at(0, 4) == 'OggS') return 'ogg';
  if (head[0] == 0x1A && head[1] == 0x45 && head[2] == 0xDF && head[3] == 0xA3) return 'matroska';
  if (head.length >= 12 && (at(4, 4) == 'ftyp' || at(4, 4) == 'moov' || at(4, 4) == 'mdat' || at(4, 4) == 'wide' || at(4, 4) == 'free' || at(4, 4) == 'skip')) return 'mp4';
  if (at(0, 3) == 'ID3') return 'mp3';
  if (head[0] == 0xFF && (head[1] & 0xF0) == 0xF0) {
    return (head[1] & 0x06) == 0 ? 'adts' : 'mp3'; // layer bits 00 = AAC in ADTS
  }
  if (head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) return 'mp3';
  throw const AudioFormatException('This is not a kind of audio or video file that can be read here.');
}
