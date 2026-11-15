import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/llm/accelerator_plans.dart';
import 'package:notes/llm/warm_session.dart';

/// An answer in the tests: only what it stands for is looked at.
class _Shape implements OrtValue {
  final String what;
  _Shape(this.what);
  @override
  Future<void> dispose() async {}
  @override
  List<int> get shape => const [1];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late List<String> log;
  late Completer<void> plan; // the accelerator finishes its plan when this completes

  WarmSession make({bool processorWorks = true, bool acceleratorWorks = true, Duration grace = const Duration(milliseconds: 30)}) => WarmSession.test(
        grace: grace,
        accelerated: () async => WarmEngine((_) async {
          log.add('accelerator starts');
          await plan.future;
          if (!acceleratorWorks) throw StateError('refused');
          log.add('accelerator done');
          return <String, OrtValue>{};
        }, () async => log.add('accelerator closed')),
        processor: () async => WarmEngine((_) async {
          if (!processorWorks) throw StateError('no operator');
          log.add('processor');
          return <String, OrtValue>{};
        }, () async => log.add('processor closed')),
      );

  Future<Map<String, OrtValue>> go(WarmSession s, String key) => s.run(() async => <String, OrtValue>{}, key: key);

  setUp(() {
    log = [];
    plan = Completer<void>();
  });

  test('a size without a plan is read on the processor while the accelerator makes the plan, then the accelerator is used', () async {
    final s = make();
    await go(s, 'a');
    expect(log, ['accelerator starts', 'processor']);
    expect(s.compiling, 'a');
    plan.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(s.ready, {'a'});
    expect(s.compiling, isNull);
    log.clear();
    await go(s, 'a');
    expect(log, ['accelerator starts', 'accelerator done']); // (the plan is there: no processor)
  });

  test('a plan that is on disk is used at once, with no reading on the processor', () async {
    plan.complete();
    final s = make();
    await go(s, 'a');
    expect(log, ['accelerator starts', 'accelerator done']);
  });

  test('another size meanwhile is read on the processor, and gets its own plan afterwards, one at a time', () async {
    final s = make();
    await go(s, 'a');
    log.clear();
    await go(s, 'b'); // (a is still being planned)
    expect(log, ['processor']);
    plan.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    log.clear();
    await go(s, 'b'); // (nothing is being planned: b is tried, and its plan is quick here)
    expect(log, ['accelerator starts', 'accelerator done']);
    expect(s.ready, {'a', 'b'});
  });

  test('an accelerator that refuses is given up, and the processor does it', () async {
    final s = make(acceleratorWorks: false);
    plan.complete();
    await go(s, 'a');
    expect(log, ['accelerator starts', 'processor']);
    log.clear();
    await go(s, 'a');
    expect(log, ['processor']);
  });

  test('when the processor cannot run the model at all, the plan is waited for', () async {
    final s = make(processorWorks: false);
    Timer(const Duration(milliseconds: 100), plan.complete);
    await go(s, 'a');
    expect(log, ['accelerator starts', 'accelerator done']);
  });

  group('an answer of the wrong shape (MIGraphX: the first run of a session answered with the plan of another size)', () {
    // (accept is asked of the accelerator's answers only: [bad] of them are refused, the later ones taken)
    bool Function(Map<String, OrtValue>) refusing(int bad) {
      var seen = 0;
      return (_) => ++seen > bad;
    }

    test('is run again on the accelerator, and only the right answer makes the size ready', () async {
      plan.complete();
      final s = make();
      await s.run(() async => <String, OrtValue>{}, key: 'a', accept: refusing(1));
      expect(log, ['accelerator starts', 'accelerator done', 'accelerator starts', 'accelerator done']);
      expect(s.ready, {'a'});
      expect(s.loaded, 'a');
    });

    test('when the second run has to make the plan, the processor reads meanwhile (the size is not taken as ready)', () async {
      var runs = 0;
      final stale = Completer<void>();
      final session = WarmSession.test(
        grace: const Duration(milliseconds: 30),
        accelerated: () async => WarmEngine((_) async {
          runs++;
          if (runs == 1) {
            stale.complete();
            return <String, OrtValue>{}; // (at once: the plan on disk, of another size)
          }
          await plan.future; // (making the plan of this size)
          return <String, OrtValue>{};
        }, () async {}),
        processor: () async => WarmEngine((_) async {
          log.add('processor');
          return <String, OrtValue>{};
        }, () async {}),
      );
      await session.run(() async => <String, OrtValue>{}, key: 'a', accept: refusing(1));
      expect(stale.isCompleted, isTrue);
      expect(log, ['processor']);
      expect(session.ready, isEmpty);
      expect(session.compiling, 'a');
      plan.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(session.ready, {'a'});
    });

    test('refused twice, the accelerator is given up and the processor reads', () async {
      plan.complete();
      final s = make();
      await s.run(() async => <String, OrtValue>{}, key: 'a', accept: refusing(2));
      expect(log.last, 'processor');
      expect(s.ready, isEmpty);
      log.clear();
      await s.run(() async => <String, OrtValue>{}, key: 'a', accept: refusing(0));
      expect(log, ['processor']);
    });
  });

  test('while a plan is being made, a size that has its plan is read on the processor (it would wait behind the plan)', () async {
    final s = make();
    plan.complete();
    await go(s, 'a'); // (a is ready)
    plan = Completer<void>();
    await go(s, 'b'); // (b is being planned)
    expect(s.compiling, 'b');
    log.clear();
    await go(s, 'a');
    expect(log, ['processor']);
    plan.complete();
  });

  group('the sizes whose plan is on disk', () {
    WarmSession planned(List<String> noted, {bool oneSize = false, int stale = 0}) {
      var runs = 0;
      return WarmSession.test(
        grace: const Duration(seconds: 1),
        onPlanned: noted.add,
        oneSize: oneSize,
        accelerated: () async => WarmEngine((_) async => {'run': _Shape(++runs <= stale ? 'stale' : 'right')}, () async {}),
        processor: () async => WarmEngine((_) async => <String, OrtValue>{}, () async {}),
      );
    }

    Future<void> at(WarmSession s, String key) => s.run(() async => <String, OrtValue>{}, key: key, accept: (o) => (o['run']! as _Shape).what == 'right');

    test('the first run of a session is not taken as a plan of its own (it may be the first plan made, of another size)', () async {
      final noted = <String>[];
      final s = planned(noted);
      await at(s, 'a');
      await at(s, 'a');
      expect(noted, isEmpty);
      await at(s, 'b');
      await at(s, 'a');
      expect(noted, ['b', 'a']);
    });

    test('a run after an answer of the wrong shape is', () async {
      final noted = <String>[];
      final s = planned(noted, stale: 1);
      await at(s, 'a');
      expect(noted, ['a']);
    });

    test('a model of one size has its plan after the first run', () async {
      final noted = <String>[];
      final s = planned(noted, oneSize: true);
      await at(s, '');
      expect(noted, ['']);
    });
  });

  test('AcceleratorPlans keeps the sizes by model, and forgets them for a new download of the file', () async {
    final dir = Directory.systemTemp.createTempSync('plans');
    AcceleratorPlans.folderForTests = Directory('${dir.path}/plans');
    addTearDown(() {
      AcceleratorPlans.folderForTests = null;
      dir.deleteSync(recursive: true);
    });
    final model = File('${dir.path}/vision-gpu.onnx')..writeAsStringSync('one');
    expect(await AcceleratorPlans.sizes(model.path), isEmpty);
    await AcceleratorPlans.add(model.path, '8x24');
    await AcceleratorPlans.add(model.path, '8x8');
    await AcceleratorPlans.add(model.path, '8x24');
    expect(await AcceleratorPlans.sizes(model.path), {'8x8', '8x24'});
    model.writeAsStringSync('another download');
    expect(await AcceleratorPlans.sizes(model.path), isEmpty);
    await AcceleratorPlans.add(model.path, '8x6');
    expect(await AcceleratorPlans.sizes(model.path), {'8x6'});
    expect((jsonDecode(File('${dir.path}/plans/notation-plans.json').readAsStringSync()) as Map).length, 1); // (the old list is dropped)
  });

  test('closing does not wait for a plan that is being made', () async {
    final s = make();
    await go(s, 'a');
    await s.close().timeout(const Duration(seconds: 1));
    expect(log, contains('processor closed'));
  });
}
