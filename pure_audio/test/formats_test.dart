import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:pure_audio/src/byte_source.dart';
import 'package:pure_audio/src/pcm.dart';


void main() {
  test('the sniffer tells the kinds of file apart and refuses the rest', () async {
    Future<String> kind(List<int> head) => sniffAudio(MemoryByteSource(Uint8List.fromList([...head, ...List.filled(64, 0)])));
    expect(await kind([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WAVE'.codeUnits]), 'wav');
    expect(await kind('fLaC'.codeUnits), 'flac');
    expect(await kind('OggS'.codeUnits), 'ogg');
    expect(await kind([0x1A, 0x45, 0xDF, 0xA3]), 'matroska');
    expect(await kind([0, 0, 0, 0x20, ...'ftyp'.codeUnits]), 'mp4');
    expect(await kind([...'ID3'.codeUnits, 4]), 'mp3');
    expect(await kind([0xFF, 0xFB, 0x90, 0x00]), 'mp3');
    expect(await kind([0xFF, 0xF1, 0x50, 0x80]), 'adts');
    expect(() => kind('hello there, I am a text file'.codeUnits), throwsA(isA<Exception>()));
  });

  test('a sound is turned into 16 kHz mono and keeps its length and its tone', () async {
    for (final rate in [8000, 16000, 22050, 44100, 48000]) {
      final tone = Float64List.fromList([for (var i = 0; i < rate * 2; i++) 0.5 * math.sin(2 * math.pi * 1000 * i / rate)]);
      final r = Resampler(rate, 16000);
      final out = <double>[];
      for (var i = 0; i < tone.length; i += 4096) {
        out.addAll(r.push(Float64List.sublistView(tone, i, math.min(tone.length, i + 4096))));
      }
      out.addAll(r.finish());
      expect(out.length, closeTo(32000, 12), reason: 'rate $rate');
      // the tone is still 1 kHz with its amplitude: compare to a pure tone in the middle
      var err = 0.0;
      for (var i = 4000; i < 8000; i++) {
        err = math.max(err, (out[i] - 0.5 * math.sin(2 * math.pi * 1000 * i / 16000)).abs());
      }
      expect(err, lessThan(rate == 16000 ? 1e-6 : 0.02), reason: 'rate $rate');
    }
  });
}
