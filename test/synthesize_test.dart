import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/audio/wav.dart';
import 'package:notes/speech/read_aloud.dart';

void main() {
  final hasEspeak = !Platform.isWindows && (Process.runSync('which', ['espeak-ng']).exitCode == 0);

  test('espeak-ng writes the reading as a small mu-law file, piece by piece', () async {
    final tts = ProcessReadAloud();
    expect(await tts.canSynthesize, isTrue);
    final progress = <int>[];
    final wav = await tts.synthesize('Hello world. This is a test of the voice. ' * 3, onProgress: (done, total) => progress.add(done));
    expect(wav, isNotNull);
    final info = readWavInfo(wav!)!;
    expect(info.format, 7);
    expect(info.sampleRate, 16000);
    expect(info.duration, greaterThan(const Duration(seconds: 2)));
    expect(progress, isNotEmpty);
    expect(progress.last, progress.length);
    // it has sound in it
    final d = decodeWav(wav)!;
    expect(d.samples.any((s) => s.abs() > 0.05), isTrue);
  }, skip: hasEspeak ? false : 'needs espeak-ng');

  test('a cancelled reading gives nothing', () async {
    final cancel = AiCancel()..cancel();
    expect(await ProcessReadAloud().synthesize('Hello world.', cancel: cancel), isNull);
  }, skip: hasEspeak ? false : 'needs espeak-ng');
}
