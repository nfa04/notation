import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/ink/ink_recognizer.dart' show HandwritingStatus;
import 'package:notes/speech/read_aloud.dart';
import 'package:notes/speech/speech_to_text.dart';
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
  Future<void> close() async {}
}

void main() {
  setUpAll(AppDatabase.initFfi);

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
