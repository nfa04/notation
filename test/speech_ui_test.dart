import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/audio/wav.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/screens/speech_recorder.dart';
import 'package:notes/speech/mic_recorder.dart';
import 'package:notes/speech/speech_to_text.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Mic extends ChangeNotifier implements MicRecorder {
  Float32List heard = Float32List(0);
  bool _on = false;
  @override
  bool get recording => _on;
  @override
  double get level => 0.3;
  @override
  Duration get length => Duration(milliseconds: heard.length * 1000 ~/ 16000);
  @override
  Future<bool> allowed() async => true;
  @override
  Future<void> start() async {
    _on = true;
    notifyListeners();
  }

  @override
  Float32List take() {
    final h = heard;
    heard = Float32List(0);
    return h;
  }

  @override
  Future<Float32List> stop() async {
    _on = false;
    notifyListeners();
    return take();
  }
}

class _Engine implements WhisperEngine {
  @override
  Future<String> transcribe(Float32List window, {String? language, void Function(String language)? detected, bool Function()? shouldStop}) async => 'We meet on Friday.';
  @override
  Future<void> close() async {}
}

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('a recording is written down and handed back as text', (tester) async {
    late SpeechToText speech;
    final mic = _Mic();
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      final dir = await Directory.systemTemp.createTemp('stt_ui_');
      addTearDown(() => dir.delete(recursive: true));
      speech = SpeechToText(settings: SettingsRepository(db), modelsRoot: () async => dir, engine: (_, _) async => _Engine());
      await speech.load();
      for (final name in speech.spec.files.keys) {
        File('${dir.path}/${speech.spec.folder}/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync('x');
      }
      await speech.load();
    });
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(onPressed: () async => result = await showSpeechRecorder(context, speech: speech, mic: mic), child: const Text('go')),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('speech-use')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('speech-use'))).onPressed, isNull); // nothing to use yet

    await tester.tap(find.byKey(const ValueKey('speech-record')));
    await tester.pump();
    expect(mic.recording, isTrue);
    final random = math.Random(1);
    mic.heard = Float32List.fromList([for (var i = 0; i < 16000 * 4; i++) 0.3 * (random.nextDouble() - 0.5)]); // four seconds of sound
    await tester.tap(find.byKey(const ValueKey('speech-stop')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pump();
    expect(find.text('We meet on Friday.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('speech-use')));
    await tester.pumpAndSettle();
    expect(result, 'We meet on Friday.');
    await tester.runAsync(speech.unload); // (it would let go of the model by itself after a while)
  });

  for (final keep in [true, false]) {
    testWidgets('the sound of a recording is ${keep ? '' : 'not '}handed back when the person chose ${keep ? 'to keep' : 'not to keep'} it', (tester) async {
      late SpeechToText speech;
      final mic = _Mic();
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        final dir = await Directory.systemTemp.createTemp('stt_ui3_');
        addTearDown(() => dir.delete(recursive: true));
        speech = SpeechToText(settings: SettingsRepository(db), modelsRoot: () async => dir, engine: (_, _) async => _Engine());
        await speech.load();
        for (final name in speech.spec.files.keys) {
          File('${dir.path}/${speech.spec.folder}/$name')
            ..createSync(recursive: true)
            ..writeAsStringSync('x');
        }
        await speech.load();
      });
      SpeechRecording? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showSpeechRecording(context, speech: speech, mic: mic, offerKeep: true, keepByDefault: false),
            child: const Text('go'),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('speech-keep'))).value, isFalse); // as the caller asked
      if (keep) {
        await tester.tap(find.byKey(const ValueKey('speech-keep')));
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('speech-record')));
      await tester.pump();
      mic.heard = Float32List.fromList([for (var i = 0; i < 16000 * 4; i++) 0.3 * math.sin(i / 20)]); // four seconds of a tone
      await tester.tap(find.byKey(const ValueKey('speech-stop')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('speech-use')));
      await tester.pumpAndSettle();
      expect(result!.text, 'We meet on Friday.');
      if (keep) {
        final info = readWavInfo(result!.audio!)!;
        expect(info.sampleRate, 8000);
        expect(info.duration, const Duration(seconds: 4));
        expect(result!.length, const Duration(seconds: 4));
      } else {
        expect(result!.audio, isNull);
      }
      await tester.runAsync(speech.unload);
    });
  }

  testWidgets('without the model there is a download, not a recorder', (tester) async {
    late SpeechToText speech;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      final dir = await Directory.systemTemp.createTemp('stt_ui2_');
      addTearDown(() => dir.delete(recursive: true));
      speech = SpeechToText(settings: SettingsRepository(db), modelsRoot: () async => dir, download: (url, path, progress) async {});
      await speech.load();
    });
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => TextButton(onPressed: () => showSpeechRecorder(context, speech: speech, mic: _Mic()), child: const Text('go'))),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('speech-download')), findsOneWidget);
    expect(find.byKey(const ValueKey('speech-record')), findsNothing);
  });
}
