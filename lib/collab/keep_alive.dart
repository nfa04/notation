import 'dart:async';

/// Keeps a connection to the signalling server honest: it is pinged every [every], and when nothing at all came back for [deadAfter]
/// it is taken for dead. A connection can die without closing (the phone changed from the mobile network to Wi-Fi, or was asleep):
/// it then looks open for minutes, while nothing goes through.
///
/// A server that never answered a ping (an old one) is never taken for dead: nothing is known of it.
class KeepAlive {
  final Duration every, deadAfter;

  /// How long a connection that is asked after a long silence of this side has to answer (see [start]).
  final Duration grace;
  final void Function() ping;

  /// Called once when the connection is taken for dead; the keep-alive stops then.
  final void Function() dead;

  KeepAlive({required this.ping, required this.dead, this.every = const Duration(seconds: 20), this.deadAfter = const Duration(seconds: 45), this.grace = const Duration(seconds: 5)});

  Timer? _timer;
  DateTime _heard = DateTime.now();
  bool _answers = false;

  bool get running => _timer != null;

  DateTime _tick = DateTime.now();

  /// While a connection that was asked has time to answer, silence does not count (the question decides).
  DateTime _graceEnds = DateTime.fromMillisecondsSinceEpoch(0);

  void start() {
    stop();
    _heard = _tick = DateTime.now();
    _timer = Timer.periodic(every, (_) {
      final now = DateTime.now();
      final gap = now.difference(_tick);
      _tick = now;
      if (gap > every * 2.5) {
        // This side did not run for a while (the app was in the background, the device asleep), so that nothing was heard says nothing
        // of the connection: it is asked, and has [grace] to answer.
        check(within: grace);
        return;
      }
      if (_answers && now.isAfter(_graceEnds) && now.difference(_heard) > deadAfter) {
        _die();
        return;
      }
      ping();
    });
  }

  /// Something came over the connection ([pong]: the answer to a ping).
  void heard({bool pong = false}) {
    _heard = DateTime.now();
    if (pong) _answers = true;
  }

  /// Asks now whether the connection still works (another connection just broke, say): without an answer [within], it is dead.
  void check({Duration within = const Duration(seconds: 5)}) {
    if (!_answers || _timer == null) return;
    final asked = DateTime.now();
    _graceEnds = asked.add(within);
    ping();
    Timer(within, () {
      if (_timer != null && _heard.isBefore(asked)) _die();
    });
  }

  void _die() {
    stop();
    dead();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
