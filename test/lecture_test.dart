import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/audio/lecture_recorder.dart';
import 'package:notes/audio/sound_marks.dart';
import 'package:notes/audio/wav.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/audio_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/speech/mic_recorder.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'audio_ui_test.dart' show FakePlayer;

/// A microphone that has heard as much as the test says.
class FakeMic extends ChangeNotifier implements MicRecorder {
  FakeMic({this.permitted = true});
  final bool permitted;
  Duration heard = Duration.zero;
  bool _on = false;
  bool disposed = false;
  @override
  bool get recording => _on;
  @override
  double get level => 0.2;
  @override
  Duration get length => heard;
  @override
  Future<bool> allowed() async => permitted;
  /// When set, the microphone opens only when it completes (a real one takes a moment).
  Completer<void>? opening;
  @override
  Future<void> start() async {
    await opening?.future;
    _on = true;
  }
  @override
  Float32List take() => Float32List(0);
  @override
  Future<Float32List> stop() async {
    _on = false;
    return Float32List(16000 * 2); // two seconds of silence are left in the buffer
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the marks', () {
    test('what was there at the start is not marked; what comes after is, once, at the moment it was seen', () {
      final c = MarkCollector()..begin({0: ['a', 'b']});
      expect(c.observe({0: ['a', 'b']}, const Duration(seconds: 1)), 0);
      expect(c.observe({0: ['a', 'b', 'c'], 1: ['d']}, const Duration(seconds: 5)), 2);
      expect(c.observe({0: ['a', 'b', 'c', 'e'], 1: ['d']}, const Duration(seconds: 9, milliseconds: 500)), 1);
      expect([for (final m in c.marks) (m.elementId, m.page, m.offsetMs)], [('c', 0, 5000), ('d', 1, 5000), ('e', 0, 9500)]);
      c.begin({});
      expect(c.marks, isEmpty);
    });
  });

  group('the recorder', () {
    test('records while the person writes, marks the new lines and gives the sound and the marks at the end', () async {
      final mic = FakeMic();
      final rec = LectureRecorder(mic: mic, every: const Duration(milliseconds: 10));
      expect(await rec.start({0: ['old']}), isTrue);
      expect(rec.recording, isTrue);
      mic.heard = const Duration(seconds: 3);
      rec.observe({0: ['old', 'new1']});
      mic.heard = const Duration(seconds: 8);
      rec.observe({0: ['old', 'new1', 'new2']});
      final result = (await rec.finish())!;
      expect(rec.recording, isFalse);
      expect(mic.disposed, isTrue);
      expect(result.length, const Duration(seconds: 8));
      expect([for (final m in result.marks) (m.elementId, m.offsetMs)], [('new1', 3000), ('new2', 8000)]);
      expect(readWavInfo(result.wav)!.duration, greaterThan(const Duration(seconds: 1)));
    });

    test('without the microphone nothing starts; a recording of no length is nothing', () async {
      final denied = LectureRecorder(mic: FakeMic(permitted: false));
      expect(await denied.start({}), isFalse);
      expect(denied.recording, isFalse);
      expect(await denied.finish(), isNull);

      final short = LectureRecorder(mic: FakeMic());
      await short.start({});
      expect(await short.finish(), isNull);
    });

    test('cancelling throws the sound away', () async {
      final mic = FakeMic();
      final rec = LectureRecorder(mic: mic);
      await rec.start({});
      await rec.cancel();
      expect(rec.recording, isFalse);
      expect(mic.disposed, isTrue);
    });
  });

  group('kept with the sound', () {
    late Database db;
    late Directory dir;
    late AudioRepository audio;
    final wav = wavFromMuLaw(Uint8List.fromList(List.filled(8000, 0xFF)), 8000);

    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      dir = await Directory.systemTemp.createTemp('lecture');
      audio = AudioRepository(db, root: () async => dir);
      await db.delete('note_audio');
      await db.delete('notes');
      await db.insert('notes', {'id': 'n1', 'created_at': 1, 'updated_at': 1});
    });
    tearDown(() => dir.delete(recursive: true));

    test('where each line was written, the later recording winning, and gone with the sound', () async {
      final first = await audio.add('n1', wav, createdAt: DateTime(2026, 3, 1));
      final second = await audio.add('n1', wav, createdAt: DateTime(2026, 3, 2));
      await audio.saveMarks('n1', first.id, const [SoundMark('a', 0, 1000), SoundMark('b', 0, 2000)]);
      await audio.saveMarks('n1', second.id, const [SoundMark('b', 1, 500)]);
      var marks = await audio.marksOf('n1');
      expect(marks['a']!.offsetMs, 1000);
      expect((marks['b']!.audioId, marks['b']!.offsetMs), (second.id, 500));
      await audio.saveMarks('n1', second.id, const [SoundMark('c', 0, 700)]); // saved again: replaces
      expect((await audio.marksOf('n1')).keys, unorderedEquals(['a', 'b', 'c']));
      await audio.remove(second);
      marks = await audio.marksOf('n1');
      expect((marks['b']!.audioId, marks['b']!.offsetMs), (first.id, 2000));
      expect(marks.containsKey('c'), isFalse);
    });
  });

  group('in the editor', () {
    late NoteRepository repo;
    late AudioRepository audio;
    late Directory dir;
    late String id;
    late FakeMic mic;
    late FakePlayer player;
    var micsMade = 0;

    Future<void> open(WidgetTester tester) async {
      micsMade = 0;
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      mic = FakeMic();
      player = FakePlayer();
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        await db.delete('note_audio');
        repo = NoteRepository(db);
        dir = await Directory.systemTemp.createTemp('lecture_ui');
        audio = AudioRepository(db, root: () async => dir);
        id = await repo.createNote();
      });
      addTearDown(() => dir.delete(recursive: true));
      await tester.pumpWidget(MaterialApp(
        home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, audio: audio, soundPlayer: () => player, lectureMic: () {
          micsMade++;
          return mic;
        }),
      ));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    /// Lets the real work (files, the database) go on for a while: each step of it needs a turn of the real loop and then a turn of the fake one.
    Future<void> real(WidgetTester tester, [int ms = 250]) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms ~/ 4)));
        await tester.pump();
      }
    }

    testWidgets('a line written while the sound is recorded is tied to its moment, and can be played from there', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('lecture-button')));
      await tester.pumpAndSettle();
      expect(mic.recording, isTrue);

      // a line, written after five seconds of the lecture
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      mic.heard = const Duration(seconds: 5);
      final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
      final g = await tester.startGesture(origin + const Offset(300, 300), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
      for (var i = 1; i <= 12; i++) {
        await g.moveTo(origin + Offset(300.0 + i * 12, 300.0 + i * 3));
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();
      mic.heard = const Duration(seconds: 12);

      await tester.tap(find.byKey(const ValueKey('lecture-button')));
      // (the saving is real work: on a slow machine it takes longer than a fixed wait, so it is waited for)
      for (var i = 0; i < 40 && find.textContaining('Kept the sound with 1 line').evaluate().isEmpty; i++) {
        await real(tester, 400);
      }
      await tester.pumpAndSettle();
      expect(mic.recording, isFalse);
      expect(find.textContaining('Kept the sound with 1 line'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));

      final sounds = (await tester.runAsync(() => audio.list(id)))!;
      expect(sounds, hasLength(1));
      expect(sounds.single.title, startsWith('Lecture '));
      final marks = (await tester.runAsync(() => audio.marksOf(id)))!;
      expect(marks, hasLength(1));
      expect(marks.values.single.offsetMs, 5000);

      // select the line with the lasso: the button to play from there is offered
      await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
      await tester.pumpAndSettle();
      final lasso = await tester.startGesture(origin + const Offset(280, 280), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
      for (final p in [const Offset(280, 280), const Offset(480, 280), const Offset(480, 360), const Offset(280, 360), const Offset(280, 285)]) {
        await lasso.moveTo(origin + p);
        await tester.pump();
      }
      await lasso.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('play-from-here')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('play-from-here')));
      await real(tester, 400);
      await tester.pumpAndSettle();
      expect(player.played, hasLength(1));
      expect(player.position, const Duration(seconds: 3), reason: 'two seconds before the line, so that its first words are heard');
    });

    testWidgets('pressing the button twice quickly starts one recording, not a second one that goes on unseen', (tester) async {
      await open(tester);
      mic.opening = Completer();
      // (two presses before the microphone is open)
      await tester.tap(find.byKey(const ValueKey('lecture-button')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('lecture-button')));
      await tester.pump();
      mic.opening!.complete();
      await tester.pumpAndSettle();
      expect(mic.recording, isTrue);
      expect(micsMade, 1);
    });

    testWidgets('lines that were there before the recording are not tied to it', (tester) async {
      await open(tester);
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
      final g = await tester.startGesture(origin + const Offset(300, 300), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(origin + Offset(300.0 + i * 10, 300));
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('lecture-button')));
      await tester.pumpAndSettle();
      mic.heard = const Duration(seconds: 4);
      await tester.tap(find.byKey(const ValueKey('lecture-button')));
      await real(tester, 400);
      await tester.pumpAndSettle();
      expect(find.textContaining('Kept the sound with 0 lines'), findsOneWidget);
      expect((await tester.runAsync(() => audio.marksOf(id)))!, isEmpty);
    });
  });
}
