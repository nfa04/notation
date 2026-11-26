import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pure_audio/pure_audio.dart';
import 'package:test/test.dart';

const fixtures = 'test/fixtures';

/// Decodes a fixture with our decoders: one list of samples per channel.
Future<(PcmSource, List<Float64List>)> decodeFixture(String file) async {
  final source = await openAudio(MemoryByteSource(File('$fixtures/$file').readAsBytesSync()));
  final channels = [for (var c = 0; c < source.channels; c++) <double>[]];
  await for (final block in source.blocks()) {
    for (var c = 0; c < channels.length; c++) {
      channels[c].addAll(block[c]);
    }
  }
  return (source, [for (final c in channels) Float64List.fromList(c)]);
}

/// What ffmpeg made of the fixture: interleaved samples in -1..1 (16 bit).
Float64List reference(String file) {
  final raw = gzip.decode(File('$fixtures/${file.substring(0, file.lastIndexOf('.'))}.ref.gz').readAsBytesSync());
  final d = ByteData.sublistView(Uint8List.fromList(raw));
  return Float64List.fromList([for (var i = 0; i + 1 < raw.length; i += 2) d.getInt16(i, Endian.little) / 32768]);
}

/// The signal to noise ratio (dB) of [got] against [ref] (one channel of it) after the best shift (the delay of the codec is
/// searched for between 0 and 2400 samples).
({double snr, int lag}) compareChannel(Float64List got, Float64List ref, int channels, int channel) {
  final one = [for (var i = channel; i < ref.length; i += channels) ref[i]];
  var best = double.infinity, lag = 0;
  for (var l = 0; l < 2400; l++) {
    var e = 0.0;
    for (var i = 0; i < 12000 && i + l < got.length && i < one.length; i += 3) {
      final d = got[i + l] - one[i];
      e += d * d;
    }
    if (e < best) {
      best = e;
      lag = l;
    }
  }
  var s = 0.0, n = 0.0;
  for (var i = 0; i < one.length && i + lag < got.length; i++) {
    final d = got[i + lag] - one[i];
    s += one[i] * one[i];
    n += d * d;
  }
  return (snr: 10 * math.log(s / (n + 1e-30)) / math.ln10, lag: lag);
}

/// Registers a test that decodes [file] and expects at least [minSnr] dB against the reference on every channel.
void expectMatchesReference(String file, {double minSnr = 60}) {
  test('$file decodes to what the reference decoder makes of it', () async {
    final (source, got) = await decodeFixture(file);
    final ref = reference(file);
    for (var c = 0; c < got.length; c++) {
      final r = compareChannel(got[c], ref, got.length, c);
      expect(r.snr, greaterThan(minSnr), reason: '$file channel $c (shift ${r.lag})');
    }
    expect(source.channels, got.length);
  });
}
