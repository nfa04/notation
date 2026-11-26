import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/ink/ink_recognizer.dart' show HandwritingStatus;
import 'package:notes/speech/read_aloud.dart';
import 'package:notes/speech/speech_to_text.dart';
import 'package:notes/speech/whisper_timestamps.dart';
import 'package:notes/speech/whisper_tokenizer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeWhisper implements WhisperEngine {
  final windows = <int>[];
  final languagesAsked = <String?>[];
  @override
  Future<String> transcribe(Float32List window, {String? language, void Function(String language)? detected, bool Function()? shouldStop}) async {
    windows.add(window.length);
    languagesAsked.add(language);
    if (language == null) detected?.call('de');
    return 'part ${windows.length}';
  }

  @override
  Future<List<TimedText>> transcribeTimed(Float32List window, {String? language, void Function(String language)? detected, bool Function()? shouldStop}) async {
    windows.add(window.length);
    languagesAsked.add(language);
    if (language == null) detected?.call('de');
    // two stretches: the first 2 seconds of the piece, then up to its end
    final seconds = window.length / 16000;
    return [TimedText(0, 2, 'a${windows.length}'), TimedText(2, seconds, 'b${windows.length}')];
  }

  @override
  Future<void> close() async {}
}

void main() {
  setUpAll(AppDatabase.initFfi);
  timedTests();

  test('the pieces Whisper writes come back as text, bytes and all', () {
    // 'Ä' is two bytes in UTF-8 (C3 84), written as the stand-ins 'Ã' and '\u0084'-> 'Ä' in the byte alphabet
    final tokenizer = WhisperTokenizer.parse('{"model":{"vocab":{"Hello":0,"Ġworld":1,"Ã¤":2,"Ġ":3}}}');
    expect(tokenizer.decode([0, 1]), 'Hello world');
    expect(tokenizer.decode([0, 3, 2]), 'Hello ä');
    expect(tokenizer.decode([0, 50258, 50363, 1]), 'Hello world'); // special tokens are not text
  });

  test('long speech is cut and written piece by piece, silence is left out, the language is found once', () async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    await db.delete('settings');
    final dir = await Directory.systemTemp.createTemp('stt_');
    addTearDown(() => dir.delete(recursive: true));
    final fake = _FakeWhisper();
    final service = SpeechToText(settings: SettingsRepository(db), modelsRoot: () async => dir, engine: (_, _) async => fake);
    await service.load();
    expect(service.status, HandwritingStatus.notInstalled);
    expect(() => service.transcribe(Float32List(16000)), throwsStateError);

    for (final name in service.spec.files.keys) {
      File('${dir.path}/${service.spec.folder}/$name')
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
    }
    await service.load();
    expect(service.installed, isTrue);

    final random = math.Random(2);
    // 70 seconds of talking with a long silence in the middle
    final x = Float32List(70 * 16000);
    for (var i = 0; i < x.length; i++) {
      final quiet = i > 30 * 16000 && i < 45 * 16000;
      x[i] = quiet ? 0 : 0.3 * (random.nextDouble() - 0.5);
    }
    final shown = <String>[];
    final text = await service.transcribe(x, onText: shown.add);
    expect(fake.windows.length, greaterThanOrEqualTo(2));
    expect(fake.windows.every((w) => w <= 29 * 16000), isTrue);
    expect(text, startsWith('part 1 part 2'));
    expect(shown.length, fake.windows.length);
    expect(fake.languagesAsked.first, isNull); // found out from the first piece...
    expect(fake.languagesAsked.skip(1).every((l) => l == 'de'), isTrue); // ...and kept

    fake.windows.clear();
    expect(await service.transcribe(Float32List(5 * 16000)), ''); // silence: nothing is written
    expect(fake.windows, isEmpty);

    await service.setLanguage('en');
    fake.languagesAsked.clear();
    await service.transcribe(x);
    expect(fake.languagesAsked.every((l) => l == 'en'), isTrue);
    await service.select(WhisperSpec.tiny);
    expect(service.installed, isFalse); // another model, not downloaded
  });

  test('text is cut into pieces the speech services take, at the ends of sentences', () {
    final text = List.generate(40, (i) => 'This is sentence number $i of the note.').join(' ');
    final pieces = speechPieces(text, limit: 300);
    expect(pieces.length, greaterThan(3));
    expect(pieces.every((p) => p.length <= 300), isTrue);
    expect(pieces.join(' ').replaceAll(RegExp(r'\s+'), ' '), text);
    expect(speechPieces('   '), isEmpty);
    expect(speechPieces('A' * 5000, limit: 1500).every((p) => p.length <= 1500), isTrue);
    expect(kIsWeb, isFalse);
  });
}

void timedTests() {
  group('timed Whisper', () {
    test('a long recording gets times that continue from piece to piece', () async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      final dir = await Directory.systemTemp.createTemp('stt_t_');
      addTearDown(() => dir.delete(recursive: true));
      final service = SpeechToText(settings: SettingsRepository(db), modelsRoot: () async => dir, engine: (_, _) async => _FakeWhisper());
      await service.load();
      for (final name in service.spec.files.keys) {
        File('${dir.path}/${service.spec.folder}/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync('x');
      }
      await service.load();
      final random = math.Random(3);
      final x = Float32List(70 * 16000);
      for (var i = 0; i < x.length; i++) {
        x[i] = 0.3 * (random.nextDouble() - 0.5);
      }
      final got = await service.transcribeTimed(x);
      expect(got.length, greaterThanOrEqualTo(6));
      for (var i = 1; i < got.length; i++) {
        expect(got[i].start, greaterThanOrEqualTo(got[i - 1].end - 1e-9));
      }
      expect(got.last.end, closeTo(70, 0.01));
    });

    const b = whisperFirstTimestamp;
    // scores where [wanted] is the best token and everything else is low
    List<double> scoresFor(Map<int, double> high) {
      final s = List<double>.filled(51865, -10);
      high.forEach((k, v) => s[k] = v);
      return s;
    }

    test('the first token is a time, not later than a second in', () {
      expect(pickTimedToken(scoresFor({500: 9, b + 10: 5, b + 400: 20}), [], {}), b + 10);
    });

    test('after a pair words must follow; after one time the next time or the end follows', () {
      final s = scoresFor({b + 200: 9, 500: 5, 50257: 4});
      expect(pickTimedToken(s, [b, 500, b + 100, b + 100], {}), 500); // pair complete: no time
      expect(pickTimedToken(s, [b, 500, b + 100], {}), b + 200); // one end time: a start time
      expect(pickTimedToken(scoresFor({500: 9, 50257: 5}), [b, 500, b + 100], {}), 50257); // ...or the end
    });

    test('times never go back', () {
      final s = scoresFor({b + 10: 9, b + 300: 5, 600: 1});
      // after words that started at 4.0 s, a time before that is not allowed
      expect(pickTimedToken(s, [b + 200, 500], {}), b + 300);
    });

    test('where the times together outweigh the best word, a time is written', () {
      final s = List<double>.filled(51865, -20);
      s[500] = 3;
      for (var t = b + 150; t < b + 190; t++) {
        s[t] = 2; // 40 times at 2.0 each: more together than the one word at 3.0
      }
      expect(pickTimedToken(s, [b, 400], {}), greaterThanOrEqualTo(b + 150));
    });

    test('suppressed and marker tokens are never written', () {
      expect(pickTimedToken(scoresFor({600: 9, 50300: 12, 500: 5}), [b, 1], {600}), 500);
    });

    test('tokens become stretches with times', () {
      String decode(List<int> ids) => ids.map((i) => 'w$i').join(' ');
      final tokens = [b, 1, 2, b + 125, b + 125, 3, b + 300]; // 0-2.5 s, 2.5-6 s
      final got = segmentsFromTokens(tokens, decode, windowSeconds: 29);
      expect(got.map((e) => '${e.start}-${e.end} ${e.text}'), ['0.0-2.5 w1 w2', '2.5-6.0 w3']);
      // not closed: ends with the window; times that go back are put in order
      final open = segmentsFromTokens([b + 500, 1, b + 600, b + 100, 2], decode, windowSeconds: 12);
      expect(open.map((e) => '${e.start}-${e.end}'), ['10.0-12.0', '12.0-12.0']);
    });
  });
}
