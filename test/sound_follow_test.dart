import 'dart:io';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/audio/sound_marks.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/audio_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'audio_ui_test.dart' show FakePlayer;
import 'lecture_test.dart' show FakeMic;

/// Following the sound as it plays: the lines written at that moment light up, and a tap on a line goes to its moment.
void main() {
  setUpAll(AppDatabase.initFfi);

  group('the timeline of a recording', () {
    Map<String, SoundPoint> marks() => {
          'a': const SoundPoint('r1', 5000),
          'b': const SoundPoint('r1', 6000),
          'c': const SoundPoint('r1', 20000),
          'other': const SoundPoint('r2', 7000),
        };

    test('knows only the marks of its own recording', () {
      final t = SoundTimeline('r1', marks());
      expect(t.offsetsMs, [5000, 6000, 20000]);
      expect(SoundTimeline('r2', marks()).offsetsMs, [7000]);
      expect(SoundTimeline('nope', marks()).isEmpty, isTrue);
      expect(SoundTimeline('r1', const {}).isEmpty, isTrue);
    });

    test('nothing is lit before the first line was written', () {
      final t = SoundTimeline('r1', marks());
      expect(t.idsAt(Duration.zero), isEmpty);
      expect(t.idsAt(const Duration(milliseconds: 4999)), isEmpty);
    });

    test('the latest line is lit, with those written a few seconds before it', () {
      final t = SoundTimeline('r1', marks());
      expect(t.idsAt(const Duration(milliseconds: 5000)), {'a'});
      expect(t.idsAt(const Duration(milliseconds: 5999)), {'a'});
      expect(t.idsAt(const Duration(milliseconds: 6000)), {'a', 'b'});
      expect(t.idsAt(const Duration(seconds: 21)), {'c'}, reason: 'the earlier ones are more than three seconds before');
      expect(t.idsAt(const Duration(seconds: 21), span: const Duration(seconds: 20)), {'a', 'b', 'c'});
    });

    test('a long stretch of speaking after the last line points at nothing', () {
      final t = SoundTimeline('r1', marks());
      expect(t.idsAt(const Duration(seconds: 36)), {'c'});
      expect(t.idsAt(const Duration(seconds: 51)), isEmpty);
      expect(t.idsAt(const Duration(seconds: 51), hold: const Duration(minutes: 5)), {'c'});
    });

    test('lines written at the same moment are lit together, in any order they were given', () {
      final t = SoundTimeline('r', {'z': const SoundPoint('r', 1000), 'y': const SoundPoint('r', 1000), 'x': const SoundPoint('r', 1000)});
      expect(t.idsAt(const Duration(seconds: 1)), {'x', 'y', 'z'});
    });

    test('a position far beyond the sound, or a negative one, does not fail', () {
      final t = SoundTimeline('r1', marks());
      expect(t.idsAt(const Duration(days: 3)), isEmpty);
      expect(t.idsAt(const Duration(seconds: -4)), isEmpty);
    });

    test('where to start for a line: two seconds before it, not before the start', () {
      final t = SoundTimeline('r1', marks());
      expect(t.startFor('a'), const Duration(seconds: 3));
      expect(t.startFor('a', lead: Duration.zero), const Duration(seconds: 5));
      expect(t.startFor('a', lead: const Duration(minutes: 1)), Duration.zero);
      expect(t.startFor('other'), isNull, reason: 'it belongs to another recording');
      expect(t.startFor('unknown'), isNull);
    });

    test('many marks are asked quickly', () {
      final many = {for (var i = 0; i < 20000; i++) 'e$i': SoundPoint('r', i * 100)};
      final t = SoundTimeline('r', many);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 20000; i++) {
        t.idsAt(Duration(milliseconds: i * 100));
      }
      expect(sw.elapsedMilliseconds, lessThan(1500));
      expect(t.idsAt(const Duration(seconds: 1000)), hasLength(31), reason: 'the line at 1000 s and the 30 written in the three seconds before it');
    });
  });

  group('in the editor', () {
    late NoteRepository repo;
    late AudioRepository audio;
    late Directory dir;
    late String id;
    late FakeMic mic;
    late FakePlayer player;

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      mic = FakeMic();
      player = FakePlayer();
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        await db.delete('note_audio');
        repo = NoteRepository(db);
        dir = await Directory.systemTemp.createTemp('follow_ui');
        audio = AudioRepository(db, root: () async => dir);
        id = await repo.createNote();
      });
      addTearDown(() => dir.delete(recursive: true));
      await tester.pumpWidget(MaterialApp(
        home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, audio: audio, soundPlayer: () => player, lectureMic: () => mic),
      ));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    Future<void> real(WidgetTester tester, [int ms = 250]) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms ~/ 4)));
        await tester.pump();
      }
    }

    Future<void> line(WidgetTester tester, Offset from) async {
      final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
      final g = await tester.startGesture(origin + from, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
      for (var i = 1; i <= 12; i++) {
        await g.moveTo(origin + from + Offset(i * 12.0, i * 2.0));
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();
    }

    /// Records two lines (at 5 s and at 15 s) and plays the recording from its panel; the player is then at the start.
    Future<void> recordAndPlay(WidgetTester tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('lecture-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      mic.heard = const Duration(seconds: 5);
      await line(tester, const Offset(300, 300));
      mic.heard = const Duration(seconds: 15);
      await line(tester, const Offset(300, 500));
      mic.heard = const Duration(seconds: 20);
      await tester.tap(find.byKey(const ValueKey('lecture-button')));
      await real(tester, 400);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      expect((await tester.runAsync(() => audio.marksOf(id)))!, hasLength(2));

      await tester.tap(find.byKey(const ValueKey('audio-button')));
      await tester.pump();
      await real(tester, 300);
      await tester.pumpAndSettle();
      final sound = (await tester.runAsync(() => audio.list(id)))!.single;
      await tester.tap(find.byKey(ValueKey('audio-play-${sound.id}')));
      await real(tester, 400);
      await tester.pumpAndSettle();
      expect(player.playing, isTrue);
      // the panel is put away, the note is in view
      await tester.tap(find.byKey(const ValueKey('audio-button'))); // (a panel beside the note: the button puts it away)
      await tester.pumpAndSettle();
    }

    /// A tap on the page at [at] (from its corner), with the time for the tap to be over and its work to be done.
    Future<void> tapPaper(WidgetTester tester, Offset at) async {
      await tester.tapAt(tester.getTopLeft(find.byKey(const ValueKey('page-0'))) + at);
      await tester.pump(const Duration(milliseconds: 500));
      await real(tester, 300);
    }

    Future<void> moveTo(WidgetTester tester, Duration to) async {
      player.position = to;
      player.notifyListeners();
      await tester.pump();
    }

    testWidgets('the line written at the moment of the sound lights up, and goes out when the moment has passed', (tester) async {
      await recordAndPlay(tester);
      expect(find.byKey(const ValueKey('follow-0')), findsNothing, reason: 'nothing was written yet at the start');

      await moveTo(tester, const Duration(seconds: 6));
      expect(find.byKey(const ValueKey('follow-0')), findsOneWidget);
      final first = tester.renderObject<RenderBox>(find.byKey(const ValueKey('follow-0')));
      expect(first.hasSize, isTrue);

      await moveTo(tester, const Duration(seconds: 16));
      expect(find.byKey(const ValueKey('follow-0')), findsOneWidget, reason: 'now the second line');

      await moveTo(tester, const Duration(seconds: 60));
      expect(find.byKey(const ValueKey('follow-0')), findsNothing, reason: 'a long time after the last line');
    });

    testWidgets('the light is on the line that was written, and moves to the next', (tester) async {
      await recordAndPlay(tester);
      Rect lit() {
        final painter = (tester.widget<CustomPaint>(find.byKey(const ValueKey('follow-0'))).painter)!;
        // (the painter keeps the rectangles it draws)
        return (painter as dynamic).rects.first as Rect;
      }

      await moveTo(tester, const Duration(seconds: 6));
      final a = lit();
      await moveTo(tester, const Duration(seconds: 16));
      final b = lit();
      expect(a.center.dy, lessThan(b.center.dy), reason: 'the second line was written lower on the page');
      expect(a.center.dy, closeTo(310, 40));
      expect(b.center.dy, closeTo(510, 40));
    });

    testWidgets('stopping the sound puts the light out; so does another sound that has no marks', (tester) async {
      await recordAndPlay(tester);
      await moveTo(tester, const Duration(seconds: 6));
      expect(find.byKey(const ValueKey('follow-0')), findsOneWidget);
      await player.stop();
      await tester.pump();
      expect(find.byKey(const ValueKey('follow-0')), findsNothing);

      // a sound that is not the recording
      await player.play('/somewhere/else.wav');
      player.position = const Duration(seconds: 6);
      player.notifyListeners();
      await real(tester, 200);
      expect(find.byKey(const ValueKey('follow-0')), findsNothing);
    });

    testWidgets('the page of the line that lights up is brought into view when the sound gets to it', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('lecture-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      mic.heard = const Duration(seconds: 5);
      await line(tester, const Offset(300, 300));
      // the next page (a drag in the Select mode scrolls)
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(1450, 700), const Offset(0, -3000));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('page-1')), findsOneWidget);
      mic.heard = const Duration(seconds: 15);
      final top = tester.getTopLeft(find.byKey(const ValueKey('page-1')));
      final g = await tester.startGesture(top + const Offset(300, 500), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
      for (var i = 1; i <= 12; i++) {
        await g.moveTo(top + Offset(300.0 + i * 12, 500.0 + i * 2));
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();
      mic.heard = const Duration(seconds: 20);
      await tester.tap(find.byKey(const ValueKey('lecture-button')));
      await real(tester, 400);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      expect((await tester.runAsync(() => audio.marksOf(id)))!, hasLength(2));

      await tester.tap(find.byKey(const ValueKey('audio-button')));
      await tester.pump();
      await real(tester, 300);
      await tester.pumpAndSettle();
      final sound = (await tester.runAsync(() => audio.list(id)))!.single;
      await tester.tap(find.byKey(ValueKey('audio-play-${sound.id}')));
      await real(tester, 400);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('audio-button'))); // (a panel beside the note: the button puts it away)
      await tester.pumpAndSettle();

      final scroll = tester.stateList<ScrollableState>(find.ancestor(of: find.byKey(const ValueKey('page-1')), matching: find.byType(Scrollable))).firstWhere((s) => s.widget.axis == Axis.vertical);
      final scrolledAway = scroll.position.pixels;
      expect(scrolledAway, greaterThan(500), reason: 'the view is on the second page');

      await moveTo(tester, const Duration(seconds: 6)); // the first line, on page 0
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, lessThan(scrolledAway), reason: 'the view went back to the first page');
      final onFirst = scroll.position.pixels;

      await moveTo(tester, const Duration(seconds: 7)); // (still the same line: the view is left where it is)
      scroll.position.jumpTo(onFirst + 40);
      await moveTo(tester, const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, onFirst + 40, reason: 'a person who scrolls meanwhile is not pulled back while the line stays');

      await moveTo(tester, const Duration(seconds: 16)); // the line on page 1
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, greaterThan(onFirst + 500), reason: 'the second page is brought into view');
    });

    testWidgets('the bar of the playing sound shows ticks where lines were written', (tester) async {
      await recordAndPlay(tester);
      await tester.tap(find.byKey(const ValueKey('audio-button')));
      await tester.pump();
      await real(tester, 300);
      await tester.pumpAndSettle();
      final sound = (await tester.runAsync(() => audio.list(id)))!.single;
      // (the fake player knows no length until it is told)
      player.length = const Duration(seconds: 20);
      player.notifyListeners();
      await tester.pump();
      expect(find.byKey(ValueKey('audio-ticks-${sound.id}')), findsOneWidget);
    });

    testWidgets('a pause keeps the light where it is', (tester) async {
      await recordAndPlay(tester);
      await moveTo(tester, const Duration(seconds: 6));
      await player.pause();
      await tester.pump();
      expect(find.byKey(const ValueKey('follow-0')), findsOneWidget);
    });

    testWidgets('a tap on a line goes to its moment, and starts a sound that was paused', (tester) async {
      await recordAndPlay(tester);
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      await moveTo(tester, const Duration(seconds: 6)); // (so that the recording is known)
      await player.pause();
      await tester.pump();

      await tapPaper(tester, const Offset(300 + 6 * 12.0, 500 + 6 * 2.0));
      expect(player.position, const Duration(seconds: 13), reason: 'two seconds before the line');
      expect(player.playing, isTrue);
      expect(player.paused, isFalse);
    });

    testWidgets('a tap on empty paper leaves the sound alone', (tester) async {
      await recordAndPlay(tester);
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      await moveTo(tester, const Duration(seconds: 6));
      await tapPaper(tester, const Offset(700, 800));
      expect(player.position, const Duration(seconds: 6));
    });

    testWidgets('a tap does not move a sound that cannot be moved within', (tester) async {
      await recordAndPlay(tester);
      player.canSeek = false;
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      await moveTo(tester, const Duration(seconds: 6));
      await tapPaper(tester, const Offset(300 + 6 * 12.0, 500 + 6 * 2.0));
      expect(player.position, const Duration(seconds: 6));
    });

    testWidgets('with no sound playing a tap on a line only picks it', (tester) async {
      await recordAndPlay(tester);
      await player.stop();
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      await tapPaper(tester, const Offset(300 + 6 * 12.0, 500 + 6 * 2.0));
      expect(player.playing, isFalse);
      expect(find.byKey(const ValueKey('play-from-here')), findsOneWidget, reason: 'it is picked, as always');
    });
  });
}
