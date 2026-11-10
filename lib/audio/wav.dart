import 'dart:math' as math;
import 'dart:typed_data';

/// Speech kept with a note is stored as a WAV file with G.711 mu-law samples: one byte a sample, so 8 kHz speech is 29 MB an hour
/// (16-bit samples at 16 kHz would be four times that). Every platform's player reads this kind of WAV, and the codec is a few lines.
const _bias = 0x84;
const _clip = 32635;

/// One 16-bit sample as a mu-law byte.
int linearToMuLaw(int pcm) {
  var sample = pcm.clamp(-32768, 32767);
  final sign = sample < 0 ? 0x80 : 0;
  if (sample < 0) sample = -sample;
  if (sample > _clip) sample = _clip;
  sample += _bias;
  var exponent = 7;
  for (var mask = 0x4000; (sample & mask) == 0 && exponent > 0; mask >>= 1) {
    exponent--;
  }
  final mantissa = (sample >> (exponent + 3)) & 0x0f;
  return ~(sign | (exponent << 4) | mantissa) & 0xff;
}

/// A mu-law byte as a 16-bit sample.
int muLawToLinear(int byte) {
  final u = ~byte & 0xff;
  final sign = u & 0x80;
  final exponent = (u >> 4) & 0x07;
  final mantissa = u & 0x0f;
  final sample = (((mantissa << 3) + _bias) << exponent) - _bias;
  return sign != 0 ? -sample : sample;
}

/// What a WAV file holds: how the samples are written and where they are.
class WavInfo {
  /// 1 = 16-bit (or 8-bit) PCM, 7 = mu-law, 3 = 32-bit float.
  final int format;
  final int channels;
  final int sampleRate;
  final int bitsPerSample;
  final int dataOffset;
  final int dataLength;

  const WavInfo(this.format, this.channels, this.sampleRate, this.bitsPerSample, this.dataOffset, this.dataLength);

  int get frames => dataLength ~/ (channels * (bitsPerSample ~/ 8));
  Duration get duration => Duration(microseconds: frames * 1000000 ~/ sampleRate);
}

int _u16(ByteData d, int o) => d.getUint16(o, Endian.little);
int _u32(ByteData d, int o) => d.getUint32(o, Endian.little);

/// The header of a WAV file; null when [bytes] are not one this code reads (PCM, mu-law or float samples).
WavInfo? readWavInfo(Uint8List bytes) {
  if (bytes.length < 44) return null;
  final d = ByteData.sublistView(bytes);
  String tag(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
  int? format, channels, rate, bits;
  var o = 12;
  while (o + 8 <= bytes.length) {
    final id = tag(o);
    var size = _u32(d, o + 4);
    if (id == 'fmt ' && o + 8 + 16 <= bytes.length) {
      format = _u16(d, o + 8);
      channels = _u16(d, o + 10);
      rate = _u32(d, o + 12);
      bits = _u16(d, o + 22);
      // extensible: the real format is in the sub-format
      if (format == 0xFFFE && size >= 26 && o + 8 + 26 <= bytes.length) format = _u16(d, o + 8 + 24);
    } else if (id == 'data') {
      if (format == null || channels == null || rate == null || bits == null || channels < 1 || rate < 1) return null;
      // a writer that streams does not know the length: the data runs to the end
      if (o + 8 + size > bytes.length || size == 0xFFFFFFFF) size = bytes.length - (o + 8);
      final ok = (format == 1 && (bits == 16 || bits == 8)) || (format == 7 && bits == 8) || (format == 3 && bits == 32);
      return ok ? WavInfo(format, channels, rate, bits, o + 8, size) : null;
    }
    o += 8 + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

/// The samples of a WAV file as numbers from -1 to 1 (several channels are averaged); null when [bytes] cannot be read.
({Float32List samples, int sampleRate})? decodeWav(Uint8List bytes) {
  final info = readWavInfo(bytes);
  if (info == null) return null;
  final d = ByteData.sublistView(bytes);
  final frames = info.frames;
  final out = Float32List(frames);
  final step = info.bitsPerSample ~/ 8;
  for (var f = 0; f < frames; f++) {
    var sum = 0.0;
    for (var c = 0; c < info.channels; c++) {
      final o = info.dataOffset + (f * info.channels + c) * step;
      sum += switch (info.format) {
        7 => muLawToLinear(bytes[o]) / 32768,
        3 => d.getFloat32(o, Endian.little),
        _ => info.bitsPerSample == 8 ? (bytes[o] - 128) / 128 : d.getInt16(o, Endian.little) / 32768,
      };
    }
    out[f] = sum / info.channels;
  }
  return (samples: out, sampleRate: info.sampleRate);
}

/// A WAV file around mu-law [data] (one byte a sample, mono) at [sampleRate].
Uint8List wavFromMuLaw(Uint8List data, int sampleRate) {
  final padded = data.length.isOdd ? 1 : 0;
  final out = Uint8List(12 + (8 + 18) + (8 + 4) + 8 + data.length + padded);
  final d = ByteData.sublistView(out);
  void tag(int o, String s) => out.setRange(o, o + 4, s.codeUnits);
  tag(0, 'RIFF');
  d.setUint32(4, out.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  d.setUint32(16, 18, Endian.little);
  d.setUint16(20, 7, Endian.little); // mu-law
  d.setUint16(22, 1, Endian.little);
  d.setUint32(24, sampleRate, Endian.little);
  d.setUint32(28, sampleRate, Endian.little); // bytes a second
  d.setUint16(32, 1, Endian.little);
  d.setUint16(34, 8, Endian.little);
  d.setUint16(36, 0, Endian.little); // no extra bytes
  tag(38, 'fact'); // (a compressed format says how many samples it has)
  d.setUint32(42, 4, Endian.little);
  d.setUint32(46, data.length, Endian.little);
  tag(50, 'data');
  d.setUint32(54, data.length, Endian.little);
  out.setRange(58, 58 + data.length, data);
  return out;
}

/// Turns samples into a mu-law WAV file as they arrive: [add] gives them (at [fromRate]), [finish] answers the file. The samples are
/// brought down to [rate] by averaging, so a slow rate does not whistle.
class SpeechWavWriter {
  /// The rate of the file: 8000 is plenty for a voice.
  final int rate;
  final int fromRate;

  final _bytes = BytesBuilder(copy: false);
  final double _ratio;
  double _boundary;
  double _pos = 0;
  double _acc = 0, _weight = 0;

  SpeechWavWriter({this.rate = 8000, this.fromRate = 16000})
      : _ratio = fromRate / rate,
        _boundary = fromRate / rate;

  /// How long the sound is so far.
  Duration get length => Duration(microseconds: _bytes.length * 1000000 ~/ rate);

  int get byteLength => _bytes.length;

  void _emit() {
    final v = _weight == 0 ? 0.0 : _acc / _weight;
    _bytes.addByte(linearToMuLaw((v.clamp(-1.0, 1.0) * 32767).round()));
    _acc = 0;
    _weight = 0;
    _boundary += _ratio;
  }

  void add(Float32List samples) {
    for (final s in samples) {
      var start = _pos;
      final end = _pos + 1;
      while (start < end - 1e-12) {
        final segEnd = math.min(end, _boundary);
        final w = segEnd - start;
        _acc += s * w;
        _weight += w;
        start = segEnd;
        if (segEnd >= _boundary - 1e-9) _emit();
      }
      _pos = end;
    }
  }

  /// The WAV file of everything added. The writer can go on being added to after this.
  Uint8List finish() {
    final data = Uint8List.fromList(_bytes.toBytes());
    return wavFromMuLaw(_weight > 1e-9 ? Uint8List.fromList([...data, linearToMuLaw(((_acc / _weight).clamp(-1.0, 1.0) * 32767).round())]) : data, rate);
  }
}

/// [wav] (any WAV file this reads) as a mu-law WAV at [rate]; null when it cannot be read. For speech made by a voice engine, which
/// writes 16-bit samples.
Uint8List? compressSpeechWav(Uint8List wav, {int rate = 16000}) {
  final decoded = decodeWav(wav);
  if (decoded == null) return null;
  final writer = SpeechWavWriter(rate: math.min(rate, decoded.sampleRate), fromRate: decoded.sampleRate)..add(decoded.samples);
  return writer.finish();
}
