import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/audio/sound_player.dart';

void main() {
  final posix = !Platform.isWindows;

  test('a sound plays until its program ends, then the player is idle again', () async {
    final player = ProcessSoundPlayer(command: (path, from) async => ['sleep', '0.4']);
    var changes = 0;
    player.addListener(() => changes++);
    await player.play('/some/where/a.wav', length: const Duration(seconds: 5));
    expect(player.playing, isTrue);
    expect(player.path, '/some/where/a.wav');
    expect(player.length, const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(player.playing, isFalse);
    expect(player.path, isNull);
    expect(player.position, Duration.zero);
    expect(changes, greaterThan(1));
    player.dispose();
  }, skip: posix ? false : 'needs sleep');

  test('pausing stops the clock and the program, resuming goes on', () async {
    final player = ProcessSoundPlayer(command: (path, from) async => ['sleep', '5']);
    await player.play('/a.wav');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await player.pause();
    expect(player.playing, isFalse);
    expect(player.paused, isTrue);
    final at = player.position;
    expect(at, greaterThan(const Duration(milliseconds: 200)));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(player.position, at); // time stood still
    await player.resume();
    expect(player.playing, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(player.position, greaterThan(at + const Duration(milliseconds: 200)));
    await player.stop();
    expect(player.path, isNull);
    expect(player.paused, isFalse);
    player.dispose();
  }, skip: posix ? false : 'needs signals');

  test('starting another sound stops the one playing, and the first one ending does not end the second', () async {
    final started = <String>[];
    final player = ProcessSoundPlayer(command: (path, from) async {
      started.add(path);
      return ['sleep', '5'];
    });
    await player.play('/a.wav');
    await player.play('/b.wav');
    await Future<void>.delayed(const Duration(milliseconds: 300)); // the first process has died by now
    expect(player.path, '/b.wav');
    expect(player.playing, isTrue);
    expect(started, ['/a.wav', '/b.wav']);
    await player.stop();
    player.dispose();
  }, skip: posix ? false : 'needs sleep');

  test('with no program to play with it says so', () async {
    final player = ProcessSoundPlayer(command: (path, from) async => null);
    expect(() => player.play('/a.wav'), throwsA(isA<StateError>()));
    player.dispose();
  });
}
