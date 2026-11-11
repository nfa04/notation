// Checks, in the real app with the real ONNX Runtime plugin, that a session made with `lowPriority` really runs at a low priority and
// that the long calls do not hold up the screen:
//   flutter test integration_test/session_priority_test.dart -d linux      (macos, windows, or an Android device, the same way)
// The check of the priority reads the threads of the process (/proc on Linux and Android, `ps -M` on macOS); where that cannot be
// read (Windows, iOS) the test only makes sure that the session works.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/llm/onnx_session.dart';

/// A model that multiplies its input by itself [times] times over (one input `x`, one output `y`, [n] x [n] numbers): something that
/// takes a while to run, made without any file to download. (The values grow out of range; the time does not depend on them.)
Uint8List chainOfMatMuls(int n, int times) {
  List<int> varint(int v) {
    final out = <int>[];
    while (v > 0x7f) {
      out.add((v & 0x7f) | 0x80);
      v >>= 7;
    }
    return [...out, v];
  }

  List<int> field(int number, List<int> bytes) => [...varint(number << 3 | 2), ...varint(bytes.length), ...bytes];
  List<int> number(int number, int value) => [...varint(number << 3), ...varint(value)];
  List<int> text(int n, String s) => field(n, s.codeUnits);
  List<int> info(String name) => [
        ...text(1, name),
        ...field(2, field(1, [...number(1, 1), ...field(2, [...field(1, number(1, n)), ...field(1, number(1, n))])])), // float, [n, n]
      ];
  final nodes = <int>[];
  for (var i = 0; i < times; i++) {
    final input = i == 0 ? 'x' : 't${i - 1}';
    final output = i == times - 1 ? 'y' : 't$i';
    nodes.addAll(field(1, [...text(1, input), ...text(1, input), ...text(2, output), ...text(4, 'MatMul')]));
  }
  final graph = [...nodes, ...text(2, 'chain'), ...field(11, info('x')), ...field(12, info('y'))];
  return Uint8List.fromList([...number(1, 8), ...field(7, graph), ...field(8, number(2, 13))]);
}

/// The priority of each thread of this process as the system tells it (nice value on Linux and Android, where 19 is the lowest;
/// scheduling priority on macOS, where the threads of background quality of service have about 4 and normal ones 31), or null when
/// that cannot be read here.
Future<List<int>?> threadPriorities() async {
  if (Platform.isLinux || Platform.isAndroid) {
    final out = <int>[];
    for (final task in Directory('/proc/self/task').listSync()) {
      try {
        final stat = File('${task.path}/stat').readAsStringSync();
        // (after the name, which is in brackets and may hold spaces: state, ppid, ... priority is the 16th and nice the 17th field)
        final rest = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
        out.add(int.parse(rest[16]));
      } on Object {
        // (a thread that ended while it was read)
      }
    }
    return out;
  }
  if (Platform.isMacOS) {
    final r = await Process.run('ps', ['-M', '-o', 'pri', '-p', '$pid']);
    if (r.exitCode != 0) return null;
    return [
      for (final line in r.stdout.toString().split('\n').skip(1))
        // (the column can have a letter after the number, "31T")
        if (RegExp(r'^\s*(\d+)').firstMatch(line) case final m?) int.parse(m.group(1)!),
    ];
  }
  return null;
}

/// How many of the threads yield (see [threadPriorities]).
int yielding(List<int> priorities) => priorities.where((p) => Platform.isMacOS ? p <= 10 : p == 19).length;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late String model;

  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('priority');
    model = '${dir.path}/chain.onnx';
    await File(model).writeAsBytes(chainOfMatMuls(256, 6));
  });

  Future<Float32List> runOnce(OrtSession session, int n) async {
    final x = await OrtValue.fromList(Float32List(n * n), [n, n]);
    final out = await session.run({'x': x});
    final flat = await out['y']!.asFlattenedList();
    await x.dispose();
    for (final v in out.values) {
      await v.dispose();
    }
    return Float32List.fromList([for (final v in flat) (v as num).toDouble()]);
  }

  testWidgets('a session made with lowPriority works and its threads yield; another one does not make more threads that yield', (tester) async {
    final before = await threadPriorities();
    final low = await openOnnxSession(model, options: OrtSessionOptions(intraOpNumThreads: 4, interOpNumThreads: 1, lowPriority: true));
    try {
      expect((await runOnce(low, 256)).length, 256 * 256);
      final afterLow = await threadPriorities();
      debugPrint('thread priorities before: $before, after the low session: $afterLow');
      if (before != null && afterLow != null) {
        // (the four threads of the session: the one that opens it takes part in the work, the three others are started)
        expect(yielding(afterLow) - yielding(before), greaterThanOrEqualTo(3), reason: 'the threads the low session started should yield');
        final normal = await openOnnxSession(model, options: OrtSessionOptions(intraOpNumThreads: 4, interOpNumThreads: 1));
        try {
          expect((await runOnce(normal, 256)).length, 256 * 256);
          expect(yielding((await threadPriorities())!), yielding(afterLow), reason: 'a session without the flag keeps its threads at normal priority');
        } finally {
          await normal.close();
        }
        // (and the thread that made the low session is back at the priority it had, so that the next call is not slowed)
        expect(yielding((await threadPriorities())!), lessThanOrEqualTo(yielding(afterLow)));
      }
    } finally {
      await low.close();
    }
  });

  testWidgets('a long run does not hold up the frames of the screen', (tester) async {
    // something that moves, so that frames are made all the time
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: CircularProgressIndicator()))));
    final stamps = <int>[];
    void onTimings(List<ui.FrameTiming> timings) => stamps.addAll(timings.map((t) => t.timestampInMicroseconds(ui.FramePhase.rasterFinish)));
    SchedulerBinding.instance.addTimingsCallback(onTimings);
    final session = await openOnnxSession(model, options: OrtSessionOptions(intraOpNumThreads: 4, interOpNumThreads: 1, lowPriority: true));
    try {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        stamps.clear();
        // a window nobody sees (a runner with no screen) may make no frames at all, even with nothing running: nothing to judge then
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final quiet = stamps.length;
        stamps.clear();
        final watch = Stopwatch()..start();
        for (var i = 0; i < 12; i++) {
          await runOnce(session, 256);
        }
        watch.stop();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        var longest = 0;
        for (var i = 1; i < stamps.length; i++) {
          longest = longest < stamps[i] - stamps[i - 1] ? stamps[i] - stamps[i - 1] : longest;
        }
        debugPrint('12 runs took ${watch.elapsedMilliseconds} ms; ${stamps.length} frames; the longest wait between two: ${longest ~/ 1000} ms');
        if (quiet < 4) {
          debugPrint('only $quiet frames in half a second with nothing running; the window is not drawn, so the frames cannot be judged here');
          return;
        }
        expect(stamps.length, greaterThan(3), reason: 'frames kept being made while the model ran');
        // (a single call holding up the screen would be a gap of as long as that call; a few frames' time is what a busy machine costs)
        expect(longest ~/ 1000, lessThan(250));
      });
    } finally {
      SchedulerBinding.instance.removeTimingsCallback(onTimings);
      await session.close();
    }
  });
}
