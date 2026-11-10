import 'dart:math';

/// How long to wait before the next try after tries that failed: the wait doubles from [base] up to [max], and half of it is random
/// ("equal jitter"). Without the random part every device that lost the same server (or the same host) tries again at the very
/// same moment, and the server that has just come back is knocked over by all of them at once.
class Backoff {
  final Duration base, max;
  final Random _random;
  int _failures = 0;

  Backoff({this.base = const Duration(seconds: 1), this.max = const Duration(seconds: 30), Random? random}) : _random = random ?? Random();

  /// How many tries failed since the last [reset].
  int get failures => _failures;

  /// The wait before the next try; counts one more failure.
  Duration next() {
    final capMs = min(max.inMilliseconds, base.inMilliseconds * (1 << min(_failures, 20)));
    _failures++;
    final half = capMs ~/ 2;
    return Duration(milliseconds: half + _random.nextInt(capMs - half + 1));
  }

  /// A try worked: the next failure starts from the short wait again.
  void reset() => _failures = 0;
}
