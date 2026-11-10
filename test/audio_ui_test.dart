import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/audio/sound_player.dart';
import 'package:notes/audio/wav.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/audio_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/audio_panel.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/speech/read_aloud.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakePlayer extends ChangeNotifier implements SoundPlayer {
  @override
  String? path;
  @override
  bool playing = false, paused = false;
  @override
  Duration position = Duration.zero, length = Duration.zero;
  @override
  bool canSeek = true;
  final played = <String>[];
  var stopped = 0;

  @override
  Future<void> play(String path, {Duration from = Duration.zero, Duration? length}) async {
    this.path = path;
    playing = true;
    paused = false;
    position = from;
    this.length = length ?? Duration.zero;
    played.add(path);
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    playing = false;
    paused = true;
    notifyListeners();
  }

  @override
  Future<void> resume() async {
    playing = true;
    paused = false;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration to) async {
    position = to;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stopped++;
    path = null;
    playing = paused = false;
    notifyListeners();
  }
}

class FakeVoice extends ChangeNotifier implements ReadAloud {
  FakeVoice({this.can = true});
  final bool can;
  String? read;

  @override
  bool get speaking => false;
  @override
  bool get preparing => false;
  @override
  Future<bool> get available async => true;
  @override
  Future<void> speak(String text, {String language = 'en', double rate = 1}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<bool> get canSynthesize async => can;
  @override
  Future<Uint8List?> synthesize(String text, {String language = 'en', double rate = 1, void Function(int done, int total)? onProgress, AiCancel? cancel}) async {
    read = text;
    onProgress?.call(1, 2);
    onProgress?.call(2, 2);
    return wavFromMuLaw(Uint8List.fromList(List.filled(16000, 0xFF)), 8000);
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  late Directory dir;
  late AudioRepository audio;
  late NoteRepository notes;
  late String id;
  final wav = wavFromMuLaw(Uint8List.fromList(List.filled(8000 * 65, 0xFF)), 8000); // 65 seconds

  Future<void> prepare(WidgetTester tester) async {
    await tester.runAsync(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      dir = await Directory.systemTemp.createTemp('audio_ui_');
      audio = AudioRepository(db, root: () async => dir);
      notes = NoteRepository(db);
      id = await notes.createNote(title: 'Lecture');
    });
    addTearDown(() => tester.runAsync(() async {
          await db.close();
          await dir.delete(recursive: true);
        }));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pumpAndSettle();
  }

  testWidgets('sounds are listed with length and size; play, pause, seek, name and delete', (tester) async {
    await prepare(tester);
    late NoteAudio first, second;
    await tester.runAsync(() async {
      first = await audio.add(id, wav, title: 'Whole lecture');
      second = await audio.add(id, wav, kind: AudioKind.speech, createdAt: DateTime.now().add(const Duration(seconds: 1)));
    });
    final player = FakePlayer();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AudioPanel(noteId: id, audio: audio, player: player, canMakeReading: Future.value(false)))));
    await settle(tester);

    expect(find.descendant(of: find.byKey(ValueKey('audio-${first.id}')), matching: find.text('Whole lecture')), findsOneWidget);
    expect(find.textContaining('0:00 / 1:05'), findsNWidgets(2));
    expect(find.textContaining('Reading,'), findsOneWidget); // no title: the kind and the time

    await tester.tap(find.byKey(ValueKey('audio-play-${first.id}')));
    await settle(tester);
    expect(player.played.single, endsWith('${first.id}.wav'));
    expect(find.byType(Slider), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('audio-play-${first.id}')));
    await settle(tester);
    expect(player.paused, isTrue);
    await tester.tap(find.byKey(ValueKey('audio-play-${first.id}')));
    await settle(tester);
    expect(player.playing, isTrue);
    expect(player.played.length, 1); // resumed, not started again
    player.position = const Duration(seconds: 20);
    player.notifyListeners();
    await tester.pump();
    expect(find.textContaining('0:20 / 1:05'), findsOneWidget);

    // another sound takes over
    await tester.tap(find.byKey(ValueKey('audio-play-${second.id}')));
    await settle(tester);
    expect(player.played.length, 2);
    expect(find.byType(Slider), findsOneWidget);

    // name it
    await tester.tap(find.byKey(ValueKey('audio-menu-${second.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('audio-rename-${second.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('audio-name-field')), 'Chapter 3 read aloud');
    await tester.tap(find.byKey(const ValueKey('audio-name-ok')));
    await settle(tester);
    await settle(tester); // (the panel looks again after the change)
    expect(find.text('Chapter 3 read aloud'), findsOneWidget);

    // delete the one that plays: it stops
    await tester.tap(find.byKey(ValueKey('audio-menu-${second.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('audio-delete-${second.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('audio-delete-ok')));
    for (var i = 0; i < 8; i++) {
      await settle(tester); // (a few real steps: the file, the row, the list)
    }
    expect(player.stopped, 1);
    expect(find.text('Chapter 3 read aloud'), findsNothing);
    expect(await tester.runAsync(() => audio.list(id)), hasLength(1));
  });

  testWidgets('with no sound it says so; the reading button is off when the voice cannot write a file', (tester) async {
    await prepare(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AudioPanel(noteId: id, audio: audio, player: FakePlayer(), canMakeReading: Future.value(false), onMakeReading: (_, _) async {})),
    ));
    await settle(tester);
    expect(find.textContaining('No sound is kept'), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('audio-make-reading'))).onPressed, isNull);
    expect(find.byKey(const ValueKey('audio-cannot')), findsOneWidget);
  });

  testWidgets('the note is read into a sound file from the editor, and the sound is listed', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await prepare(tester);
    await tester.runAsync(() async {
      final note = (await notes.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'a', position: const Offset(60, 60), initialText: 'The mitochondria is the powerhouse of the cell.')];
      await notes.saveNote(note);
    });
    final voice = FakeVoice();
    final player = FakePlayer();
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: notes, audio: audio, readAloud: voice, soundPlayer: () => player)));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('audio-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await settle(tester);
    expect(find.textContaining('No sound is kept'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('audio-make-reading')));
    for (var i = 0; i < 10 && (await tester.runAsync(() => audio.list(id)))!.isEmpty; i++) {
      await settle(tester); // (the text is gathered, the voice makes the file, the file is kept: each takes real time)
    }
    await settle(tester);
    await settle(tester);
    expect(voice.read, contains('mitochondria'));
    final sounds = (await tester.runAsync(() => audio.list(id)))!;
    expect(sounds.single.kind, AudioKind.speech);
    expect(sounds.single.title, 'Lecture read aloud');
    expect(find.text('Lecture read aloud'), findsOneWidget);
    // playing it
    await tester.tap(find.byKey(ValueKey('audio-play-${sounds.single.id}')));
    await settle(tester);
    expect(player.played.single, endsWith('${sounds.single.id}.wav'));
  });
}
