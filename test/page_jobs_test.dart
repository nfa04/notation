import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/pdf/page_jobs.dart';

void main() {
  /// Jobs ranked by how far their page is from [near]; pages outside [reach] are dropped.
  PageJobs jobsNear(int Function() near, {int reach = 3, bool Function()? hold}) => PageJobs(
        ranker: () {
          final at = near();
          return (job) {
            final d = (job.page - at).abs();
            return d > reach ? null : d.toDouble();
          };
        },
        hold: hold,
        holdRetry: const Duration(milliseconds: 5),
      );

  test('one job at a time, the most wanted first, ranked when it starts and not when it was asked for', () async {
    var near = 0;
    final jobs = jobsNear(() => near);
    final started = <int>[];
    final gate = Completer<void>();
    Future<int> work(int page) async {
      started.add(page);
      if (page == 0) await gate.future;
      return page;
    }

    final results = [for (final p in [0, 1, 2, 3]) jobs.add(PageJob(p, PageJobKind.picture), (_) => work(p))];
    await Future<void>.delayed(Duration.zero);
    expect(started, [0], reason: 'only one runs');
    near = 3; // the view moved while page 0 was drawn
    gate.complete();
    expect(await Future.wait(results), [0, 1, 2, 3]);
    expect(started, [0, 3, 2, 1], reason: 'nearest to where the view is now first');
  });

  test('work that is no longer wanted is dropped before it starts', () async {
    var near = 0;
    final jobs = jobsNear(() => near, reach: 1);
    final gate = Completer<void>();
    final started = <int>[];
    final first = jobs.add(PageJob(0, PageJobKind.picture), (_) async {
      started.add(0);
      await gate.future;
      return 0;
    });
    final far = jobs.add(PageJob(1, PageJobKind.picture), (_) async {
      started.add(1);
      return 1;
    });
    await Future<void>.delayed(Duration.zero);
    near = 10;
    jobs.reconsider();
    await expectLater(far, throwsA(isA<PageJobDropped>().having((e) => e.job.page, 'page', 1)));
    gate.complete();
    expect(await first, 0, reason: 'what had started finishes');
    expect(started, [0]);
    expect(jobs.waiting, 0);
  });

  test('urgent work is never dropped and goes first', () async {
    final jobs = jobsNear(() => 0, reach: 0);
    final order = <String>[];
    final gate = Completer<void>();
    final running = jobs.add(PageJob(0, PageJobKind.picture), (_) async {
      order.add('picture 0');
      await gate.future;
    });
    await Future<void>.delayed(Duration.zero); // (it has started)
    final near =jobs.add(PageJob(0, PageJobKind.words), (_) async => order.add('words 0'));
    final urgent = jobs.add(PageJob(40, PageJobKind.words, urgent: true), (_) async => order.add('words 40'));
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await Future.wait([running, near, urgent]);
    expect(order, ['picture 0', 'words 40', 'words 0']);
  });

  test('nothing new starts while held, and it starts by itself once let go', () async {
    var held = true;
    final jobs = jobsNear(() => 0, hold: () => held);
    var ran = false;
    final job = jobs.add(PageJob(1, PageJobKind.picture), (_) async => ran = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(ran, isFalse);
    held = false;
    await job.timeout(const Duration(seconds: 2));
    expect(ran, isTrue);
  });

  test('urgent work starts even while held', () async {
    final jobs = jobsNear(() => 0, hold: () => true);
    expect(await jobs.add(PageJob(9, PageJobKind.words, urgent: true), (_) async => 'done').timeout(const Duration(seconds: 2)), 'done');
  });

  test('a running job that is no longer wanted is called off', () async {
    var near = 0;
    final jobs = jobsNear(() => near, reach: 1);
    final stopped = Completer<void>();
    final running = jobs.add(PageJob(0, PageJobKind.picture), (run) async {
      run.onCancel(stopped.complete);
      await stopped.future; // (a render that stops between its slices)
      throw StateError('render returned nothing');
    });
    await Future<void>.delayed(Duration.zero);
    near = 10;
    jobs.reconsider();
    await expectLater(running, throwsA(isA<PageJobDropped>()), reason: 'called off, not failed');
    expect(jobs.busy, isFalse);
  });

  test('a job wanted much more starts beside the one running, no more than two at once', () async {
    var near = 6;
    final jobs = jobsNear(() => near, reach: 10);
    final gate = Completer<void>();
    final started = <int>[];
    Future<int> work(int p) async {
      started.add(p);
      await gate.future;
      return p;
    }

    final far = jobs.add(PageJob(0, PageJobKind.picture), (_) => work(0)); // 6 pages away
    await Future<void>.delayed(Duration.zero);
    near = 0; // page 0 is on screen now: what runs is wanted most; page 1 is not wanted much more than it
    final next = jobs.add(PageJob(1, PageJobKind.picture), (_) => work(1));
    await Future<void>.delayed(Duration.zero);
    expect(started, [0]);
    near = 9; // page 9 comes on screen while page 0 (9 away) is drawn
    final onScreen = jobs.add(PageJob(9, PageJobKind.picture), (_) => work(9));
    final alsoNear = jobs.add(PageJob(8, PageJobKind.picture), (_) => work(8));
    await Future<void>.delayed(Duration.zero);
    expect(started, [0, 9], reason: 'one beside the other, not a third');
    gate.complete();
    await Future.wait([far, next, onScreen, alsoNear]);
  });

  test('a job that fails fails alone', () async {
    final jobs = jobsNear(() => 0);
    final bad = jobs.add<int>(PageJob(0, PageJobKind.picture), (_) async => throw StateError('broken page'));
    final good = jobs.add(PageJob(1, PageJobKind.picture), (_) async => 1);
    await expectLater(bad, throwsStateError);
    expect(await good, 1);
  });

  test('dropWhere, clear and dispose drop what waits', () async {
    final jobs = jobsNear(() => 0, hold: () => true);
    final a = jobs.add(PageJob(1, PageJobKind.picture), (_) async => 1);
    final b = jobs.add(PageJob(2, PageJobKind.thumb), (_) async => 2);
    final c = jobs.add(PageJob(3, PageJobKind.picture), (_) async => 3);
    jobs.dropWhere((j) => j.kind == PageJobKind.thumb);
    await expectLater(b, throwsA(isA<PageJobDropped>()));
    expect(jobs.waiting, 2);
    jobs.clear();
    await expectLater(a, throwsA(isA<PageJobDropped>()));
    await expectLater(c, throwsA(isA<PageJobDropped>()));
    jobs.dispose();
    await expectLater(jobs.add(PageJob(1, PageJobKind.picture), (_) async => 1), throwsA(isA<PageJobDropped>()));
  });
}
