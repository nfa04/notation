import 'dart:math';

import 'transport.dart';

/// How good a link is, in the three steps a person (and later the choice of a host) cares about.
enum LinkBand { unknown, good, fair, poor }

/// How long answers may take before a link is called fair or poor: by the median, the slowest twentieth, and the larger questions.
class LinkTiming {
  final Duration fairMedian, poorMedian, fairP95, fairData, poorData;

  /// The least time a question is waited for before it counts as not answered (it is never less than two of the intervals between
  /// questions: see [CollabSession]).
  final Duration lostAfter;
  const LinkTiming({
    this.lostAfter = Duration.zero,
    this.fairMedian = const Duration(milliseconds: 250),
    this.poorMedian = const Duration(milliseconds: 800),
    this.fairP95 = const Duration(milliseconds: 1000),
    this.fairData = const Duration(seconds: 1),
    this.poorData = const Duration(seconds: 3),
  });

  /// So lenient that only lost answers and broken links count: for tests of what is done with the bands, on a machine of any speed.
  static const lenient = LinkTiming(
    lostAfter: Duration(minutes: 1),
    fairMedian: Duration(minutes: 1),
    poorMedian: Duration(minutes: 2),
    fairP95: Duration(minutes: 1),
    fairData: Duration(minutes: 1),
    poorData: Duration(minutes: 2),
  );
}

/// What is measured on one link between two devices of a session: the time a sealed question takes to be answered (and how much it
/// varies), how many questions were not answered, and how often the link broke. Measured here, from the answers that came back:
/// nothing in it is what the other side says about itself.
///
/// Time is handed in by the caller, so that the numbers can be checked without waiting.
class LinkStats {
  /// The times past which a link is fair or poor (the same on every device, so that all agree on the words).
  static LinkTiming timing = const LinkTiming();

  /// How many of the latest answers (and of the latest questions, for the loss) count.
  final int window;

  LinkStats({this.window = 20});

  /// What the link goes over, as the connection itself reports it. A link through a relay costs the relay's bandwidth, so it is never
  /// called better than fair, and whoever is chosen for a job that carries much (hosting) is chosen among the direct ones first.
  LinkRoute route = LinkRoute.unknown;

  bool get relayed => route == LinkRoute.relayed;

  final List<Duration> _rtts = [];

  /// Larger questions, now and then: a link can answer a tiny one at once and still carry little.
  final List<Duration> _dataRtts = [];
  final List<bool> _outcomes = []; // true: answered
  final Map<int, ({DateTime at, bool data})> _open = {};
  final List<DateTime> _drops = [];
  int _seq = 0;
  LinkBand _reported = LinkBand.unknown;

  /// A question is sent: its number goes along, and comes back with the answer.
  int probe(DateTime now, {bool data = false}) {
    final n = ++_seq;
    _open[n] = (at: now, data: data);
    return n;
  }

  /// The answer to question [n] came. An answer to a question that is given up on (or never asked) says nothing.
  void answered(int n, DateTime now) {
    final q = _open.remove(n);
    if (q == null) return;
    final rtt = now.difference(q.at);
    _push(q.data ? _dataRtts : _rtts, rtt, q.data ? 6 : window);
    _push(_outcomes, true, window);
  }

  /// An answer that took [rtt], measured by somebody else who asked (a link that watches itself, see [WatchedChannel]).
  void record(Duration rtt) {
    _push(_rtts, rtt, window);
    _push(_outcomes, true, window);
  }

  /// A question somebody else asked was not answered.
  void missed() => _push(_outcomes, false, window);

  /// Questions asked longer than [after] ago and still open were not answered.
  void expire(DateTime now, Duration after) {
    final late = [for (final e in _open.entries) if (now.difference(e.value.at) > after) e.key]..sort();
    for (final n in late) {
      _open.remove(n);
      _push(_outcomes, false, window);
    }
  }

  /// The link broke (or was found dead).
  void dropped(DateTime now) {
    _drops.add(now);
    _open.clear(); // (what was asked on the old link will not be answered on a new one)
    if (_drops.length > 50) _drops.removeAt(0);
  }

  static void _push<T>(List<T> list, T value, int max) {
    list.add(value);
    if (list.length > max) list.removeAt(0);
  }

  int get samples => _rtts.length;

  Duration? get median => _quantile(_rtts, 0.5);
  Duration? get p95 => _quantile(_rtts, 0.95);
  Duration? get dataMedian => _quantile(_dataRtts, 0.5);

  /// How much the time varies: the median distance from the median (one slow answer does not move it).
  Duration? get jitter {
    final m = median;
    if (m == null) return null;
    final off = [for (final r in _rtts) (r - m).abs()];
    return _quantile(off, 0.5);
  }

  /// The share of the latest questions that were not answered (0 when nothing was asked yet).
  double get loss => _outcomes.isEmpty ? 0 : _outcomes.where((ok) => !ok).length / _outcomes.length;

  int dropsWithin(Duration span, DateTime now) => _drops.where((d) => now.difference(d) <= span).length;

  int get dropsTotal => _drops.length;

  static Duration? _quantile(List<Duration> values, double q) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    return sorted[min(sorted.length - 1, (q * sorted.length).floor())];
  }

  /// The link in a word. Little is known until a few answers came; a link that broke lately, or that goes through a relay, is never
  /// better than fair.
  ///
  /// A link gets worse at once, but better only by a margin ([recovery]): one that sits at the edge between two bands does not flip
  /// between them with every answer (who is chosen to take over depends on the bands, and should not change with every flicker).
  LinkBand band(DateTime now) {
    final b = _capped(now, 1);
    final held = _held;
    if (held != LinkBand.unknown && b != LinkBand.unknown && b.index < held.index) {
      // better than before: only as far as the stricter measure says
      final strict = _capped(now, recovery);
      _held = strict.index < held.index && strict != LinkBand.unknown ? strict : held;
    } else {
      _held = b;
    }
    return _held;
  }

  /// How much better than the limit a link must be to be called better than it was (the limits are multiplied by this).
  static const double recovery = 0.7;

  LinkBand _held = LinkBand.unknown;

  LinkBand _capped(DateTime now, double scale) {
    final b = _band(now, scale);
    return b == LinkBand.good && relayed ? LinkBand.fair : b;
  }

  LinkBand _band(DateTime now, double scale) {
    final m = median, p = p95;
    if (m == null || samples < 3) {
      // nothing answered but things were asked: that is not "unknown"
      return _outcomes.length >= 3 && loss >= 0.5 ? LinkBand.poor : LinkBand.unknown;
    }
    final d = dataMedian ?? Duration.zero;
    final drops = dropsWithin(const Duration(minutes: 10), now);
    final t = timing;
    Duration x(Duration limit) => limit * scale;
    if (loss >= 0.3 * scale || m > x(t.poorMedian) || d > x(t.poorData) || drops >= 3) return LinkBand.poor;
    if (loss >= 0.1 * scale || m > x(t.fairMedian) || p! > x(t.fairP95) || d > x(t.fairData) || drops >= 1) {
      return LinkBand.fair;
    }
    return LinkBand.good;
  }

  /// Whether the band is another one than the last time this was asked (so that whoever listens is only told of a change).
  bool bandChanged(DateTime now) {
    final b = band(now);
    if (b == _reported) return false;
    _reported = b;
    return true;
  }

  LinkBand get reported => _reported;
}
