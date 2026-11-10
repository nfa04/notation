import 'dart:async';

/// What a piece of work for a page of a PDF is for.
enum PageJobKind {
  /// The picture of the page, as it is shown at the normal size.
  picture,

  /// The words of the page and where they are (for selecting, highlighting and finding).
  words,

  /// The part of the page that is on screen, as sharp as the zoom needs it.
  sharp,

  /// A small picture of the page, for the preview beside the scrollbar.
  thumb,
}

/// One piece of work for a page. [urgent] work is something the user waits for (a find, a highlight): it is never dropped and comes
/// before everything else.
class PageJob {
  final int page;
  final PageJobKind kind;
  final bool urgent;

  const PageJob(this.page, this.kind, {this.urgent = false});

  @override
  String toString() => 'PageJob($page, ${kind.name}${urgent ? ', urgent' : ''})';
}

/// The work was dropped: it was no longer wanted (the page went off the screen and out of reach), before it started or while it ran.
class PageJobDropped implements Exception {
  final PageJob job;
  const PageJobDropped(this.job);

  @override
  String toString() => 'PageJobDropped($job)';
}

/// What a running job is told: whether it was called off, and what to do then (stop its render).
class PageJobRun {
  bool _cancelled = false;
  final List<void Function()> _onCancel = [];

  bool get cancelled => _cancelled;

  /// [stop] is called when the job is called off while it runs (at once if it already was).
  void onCancel(void Function() stop) {
    if (_cancelled) {
      stop();
    } else {
      _onCancel.add(stop);
    }
  }

  void _cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final stop in _onCancel) {
      stop();
    }
  }
}

class _Entry {
  final PageJob job;
  final Future<Object?> Function(PageJobRun run) work;
  final Completer<Object?> done = Completer<Object?>();
  final PageJobRun run = PageJobRun();
  double rank = 0;
  _Entry(this.job, this.work);
}

/// The work of reading the pages of a PDF, the most wanted first, and what is no longer wanted dropped.
///
/// Everything that was asked for of PDFium used to wait in line there in the order it was asked for: a fling past twenty pages asked
/// for twenty pictures, and the page it stopped on came last. Here the work waits instead, and each time something can start, [ranker]
/// says what is wanted most now: what is no longer wanted is dropped (and called off if it runs: pdfrx renders in slices and stops
/// between them). One job runs at a time; a second may start beside it when it is wanted much more (a page that came on screen while
/// one far ahead is drawn): pdfrx takes turns between the two.
class PageJobs {
  /// Called once each time the work is looked at; the function it returns ranks each job: lower starts sooner, null drops it.
  final double? Function(PageJob job) Function() ranker;

  /// While this says so, nothing new starts (the pages fly past faster than they could be drawn). It is asked again a moment later.
  final bool Function()? hold;

  /// How soon to look again while [hold] says to wait.
  final Duration holdRetry;

  /// How much better than what runs a job has to rank to start beside it.
  static const _overtake = 1.0;

  PageJobs({required this.ranker, this.hold, this.holdRetry = const Duration(milliseconds: 80)});

  final List<_Entry> _waiting = [];
  final List<_Entry> _running = [];
  Timer? _retry;
  bool _pumpSoon = false;
  bool _disposed = false;

  /// How many jobs wait to start.
  int get waiting => _waiting.length;

  /// Whether a job is being done now.
  bool get busy => _running.isNotEmpty;

  /// The jobs that wait, in no particular order.
  Iterable<PageJob> get jobs => _waiting.map((e) => e.job);

  /// Does [work] for [job] when its turn comes. Fails with [PageJobDropped] if it is no longer wanted before it ends.
  Future<T> add<T>(PageJob job, Future<T> Function(PageJobRun run) work) {
    if (_disposed) return Future.error(PageJobDropped(job));
    final entry = _Entry(job, work);
    _waiting.add(entry);
    _schedule();
    return entry.done.future.then((v) => v as T);
  }

  /// The view changed: what is no longer wanted is dropped (or called off), and what starts next is picked again.
  void reconsider() {
    if (_disposed) return;
    _schedule();
  }

  /// Drops every waiting job that [test] picks, and calls off those of them that run.
  void dropWhere(bool Function(PageJob job) test) {
    for (final e in [..._waiting]) {
      if (test(e.job)) _drop(e);
    }
    for (final e in _running) {
      if (test(e.job)) e.run._cancel();
    }
  }

  /// Drops everything.
  void clear() => dropWhere((_) => true);

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    clear();
  }

  void _drop(_Entry e) {
    _waiting.remove(e);
    if (!e.done.isCompleted) e.done.completeError(PageJobDropped(e.job));
  }

  // (after the current microtasks: whoever asked for the work may still be registering what it is for, which the ranking looks at)
  void _schedule() {
    if (_pumpSoon) return;
    _pumpSoon = true;
    scheduleMicrotask(() {
      _pumpSoon = false;
      _pump();
    });
  }

  void _pump() {
    if (_disposed) return;
    final rank = ranker();
    double? rankOf(_Entry e) => e.job.urgent ? double.negativeInfinity : rank(e.job);
    for (final e in [..._running]) {
      final r = rankOf(e);
      if (r == null) {
        e.run._cancel();
      } else {
        e.rank = r;
      }
    }
    _Entry? best;
    for (final e in [..._waiting]) {
      final r = rankOf(e);
      if (r == null) {
        _drop(e);
      } else {
        e.rank = r;
        if (best == null || r < best.rank) best = e;
      }
    }
    if (best == null) return;
    final working = [for (final e in _running) if (!e.run.cancelled) e];
    if (working.isNotEmpty && (working.length >= 2 || !working.every((e) => best!.rank < e.rank - _overtake))) return;
    if (!best.job.urgent && (hold?.call() ?? false)) {
      _retry?.cancel();
      _retry = Timer(holdRetry, _pump);
      return;
    }
    _start(best);
    if (working.isEmpty && _waiting.isNotEmpty) _schedule(); // (perhaps one more, much more wanted than this one)
  }

  void _start(_Entry e) {
    _waiting.remove(e);
    _running.add(e);
    Future<Object?>.sync(() => e.work(e.run)).then((v) {
      if (!e.done.isCompleted) e.done.complete(v); // (finished although called off: what it made is still good)
    }, onError: (Object error, StackTrace stack) {
      if (e.done.isCompleted) return;
      e.run.cancelled ? e.done.completeError(PageJobDropped(e.job)) : e.done.completeError(error, stack);
    }).whenComplete(() {
      _running.remove(e);
      _pump();
    });
  }
}
