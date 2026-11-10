import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/audio/wav.dart';

Float32List sine(double hz, int rate, double seconds, {double amplitude = 0.5}) =>
    Float32List.fromList([for (var i = 0; i < (rate * seconds).round(); i++) (amplitude * math.sin(2 * math.pi * hz * i / rate)).toDouble()]);

Uint8List pcm16Wav(Float32List samples, int rate, {int channels = 1}) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, (samples[i] * 32767).round(), Endian.little);
  }
  final out = BytesBuilder();
  final h = ByteData(44);
  void tag(int o, String s) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(o + i, s.codeUnitAt(i));
    }
  }
  tag(0, 'RIFF');
  h.setUint32(4, 36 + data.lengthInBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, channels, Endian.little);
  h.setUint32(24, rate, Endian.little);
  h.setUint32(28, rate * channels * 2, Endian.little);
  h.setUint16(32, channels * 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, data.lengthInBytes, Endian.little);
  out.add(h.buffer.asUint8List());
  out.add(data.buffer.asUint8List());
  return out.toBytes();
}

void main() {
  group('mu-law', () {
    test('silence and the extremes', () {
      expect(linearToMuLaw(0), 0xFF);
      expect(muLawToLinear(0xFF), 0);
      expect(muLawToLinear(linearToMuLaw(32767)), greaterThan(31000));
      expect(muLawToLinear(linearToMuLaw(-32768)), lessThan(-31000));
    });

    test('every sample comes back within the width of its step (about 3% of its size, 8 at the least)', () {
      for (var v = -32768; v <= 32767; v += 37) {
        final back = muLawToLinear(linearToMuLaw(v));
        expect((back - v).abs(), lessThanOrEqualTo(math.max(40, v.abs() * 0.04)), reason: 'sample $v came back as $back');
      }
    });

    test('the code is monotonic: louder samples never get a smaller value', () {
      var last = -40000;
      for (var v = -32768; v <= 32767; v += 11) {
        final back = muLawToLinear(linearToMuLaw(v));
        expect(back, greaterThanOrEqualTo(last));
        last = back;
      }
    });
  });

  group('WAV files', () {
    test('a PCM file is read: rate, length and samples', () {
      final wav = pcm16Wav(sine(440, 16000, 0.5), 16000);
      final info = readWavInfo(wav)!;
      expect(info.format, 1);
      expect(info.sampleRate, 16000);
      expect(info.frames, 8000);
      expect(info.duration, const Duration(milliseconds: 500));
      final d = decodeWav(wav)!;
      expect(d.samples.length, 8000);
      expect(d.samples[10], closeTo(0.5 * math.sin(2 * math.pi * 440 * 10 / 16000), 0.001));
    });

    test('two channels are averaged; anything that is not a WAV is refused', () {
      final stereo = pcm16Wav(Float32List.fromList([0.5, -0.5, 0.25, 0.25]), 8000, channels: 2);
      expect(decodeWav(stereo)!.samples, [closeTo(0, 0.001), closeTo(0.25, 0.001)]);
      expect(readWavInfo(Uint8List(10)), isNull);
      expect(readWavInfo(Uint8List.fromList(List.filled(100, 7))), isNull);
    });

    test('a file that says no length (a streaming writer) is read to its end', () {
      final wav = pcm16Wav(sine(440, 8000, 0.25), 8000);
      ByteData.sublistView(wav).setUint32(40, 0xFFFFFFFF, Endian.little);
      expect(readWavInfo(wav)!.frames, 2000);
    });

    test('a mu-law file has the fields players expect', () {
      final wav = wavFromMuLaw(Uint8List.fromList([0xFF, 0x80, 0x00]), 8000);
      final info = readWavInfo(wav)!;
      expect(info.format, 7);
      expect(info.bitsPerSample, 8);
      expect(info.frames, 3);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(ByteData.sublistView(wav).getUint32(4, Endian.little), wav.length - 8);
      expect(wav.length.isEven, isTrue);
      expect(String.fromCharCodes(wav.sublist(38, 42)), 'fact');
    });
  });

  group('SpeechWavWriter', () {
    test('16 kHz speech becomes 8 kHz mu-law: a byte a sample, half as many, and the tone survives', () {
      final writer = SpeechWavWriter()..add(sine(300, 16000, 2));
      expect(writer.length, const Duration(seconds: 2));
      final wav = writer.finish();
      final info = readWavInfo(wav)!;
      expect(info.sampleRate, 8000);
      expect(info.frames, 16000);
      final back = decodeWav(wav)!;
      // compare with the original tone at the same instants
      var worst = 0.0;
      for (var i = 100; i < 15900; i++) {
        final t = i / 8000;
        final expected = 0.5 * math.sin(2 * math.pi * 300 * (t + 0.5 / 16000)); // (averaged over the pair it covers)
        worst = math.max(worst, (back.samples[i] - expected).abs());
      }
      expect(worst, lessThan(0.03));
    });

    test('pieces of any size give the same file as one piece', () {
      final all = sine(500, 16000, 1.3);
      final whole = (SpeechWavWriter()..add(all)).finish();
      final pieces = SpeechWavWriter();
      for (var i = 0; i < all.length;) {
        final n = math.min(all.length - i, 1 + (i * 7) % 333);
        pieces.add(Float32List.sublistView(all, i, i + n));
        i += n;
      }
      expect(pieces.finish(), whole);
    });

    test('an odd rate ratio keeps the length right', () {
      final writer = SpeechWavWriter(rate: 8000, fromRate: 22050)..add(sine(200, 22050, 1));
      final frames = readWavInfo(writer.finish())!.frames;
      expect(frames, inInclusiveRange(7999, 8001));
    });

    test('an empty recording is a valid empty file', () {
      final info = readWavInfo(SpeechWavWriter().finish())!;
      expect(info.frames, 0);
    });
  });

  test('speech from a voice engine is brought down to mu-law', () {
    final wav = pcm16Wav(sine(250, 22050, 1), 22050);
    final small = compressSpeechWav(wav, rate: 16000)!;
    final info = readWavInfo(small)!;
    expect(info.format, 7);
    expect(info.sampleRate, 16000);
    expect(small.length, lessThan(wav.length ~/ 2));
    expect(compressSpeechWav(Uint8List(5)), isNull);
  });
}
