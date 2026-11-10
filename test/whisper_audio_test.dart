import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/speech/whisper_audio.dart';

void main() {
  test('the log-mel spectrogram is the one of the reference implementation', () {
    final n = (3.2 * 16000).round();
    final x = Float32List.fromList([
      for (var i = 0; i < n; i++) 0.3 * math.sin(2 * math.pi * 440 * i / 16000) + 0.2 * math.sin(2 * math.pi * 1250 * i / 16000) + 0.1 * math.sin(2 * math.pi * 3000 * i / 16000),
    ]);
    final mel = logMelSpectrogram(x);
    expect(mel.length, 80 * 3000);
    final ref = jsonDecode(File('test/fixtures/whisper_mel_ref.json').readAsStringSync()) as Map;
    final frames = (ref['frames'] as List).cast<int>();
    final values = (ref['values'] as List).cast<List>();
    var worst = 0.0;
    for (var i = 0; i < frames.length; i++) {
      for (var b = 0; b < 80; b++) {
        worst = math.max(worst, (mel[b * 3000 + frames[i]] - (values[i][b] as num)).abs());
      }
    }
    expect(worst, lessThan(0.002));
    expect(mel.reduce(math.max), closeTo(ref['max'] as num, 0.002));
    expect(mel.reduce(math.min), closeTo(ref['min'] as num, 0.002));
  });

  test('long sound is cut where it is quiet, and nothing is lost', () {
    final random = math.Random(3);
    final seconds = 70;
    final x = Float32List(seconds * 16000);
    for (var i = 0; i < x.length; i++) {
      final pause = (i ~/ 16000) % 30 == 26; // a pause at 26 and at 56 s
      x[i] = pause ? 0.0005 * random.nextDouble() : 0.2 * (random.nextDouble() - 0.5);
    }
    final pieces = splitAtQuiet(x);
    expect(pieces.length, 3);
    expect(pieces.fold<int>(0, (s, p) => s + p.length), x.length);
    for (final p in pieces) {
      expect(p.length, lessThanOrEqualTo(29 * 16000));
    }
    // the first cut is in the pause
    expect(pieces.first.length / 16000, inInclusiveRange(26, 27.2));
    expect(loudness(Float32List(1000)), 0);
  });
}
