import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

/// Tells when the device moved to another network (from the mobile network to Wi-Fi, say). The connections that were made over the
/// old one cannot go on - their address is gone - but they look alive for a while; told at once, the app makes new ones instead of
/// waiting for the old ones to time out.
///
/// Only a network that is lost (or coming back after none) counts: one that is added beside another (Wi-Fi comes up while the mobile
/// network is still there) leaves the connections as they are. [networks] gives the kinds of network the device has now (`wifi`,
/// `mobile`, ...; empty or `none`: no network).
class NetworkWatch {
  final void Function() onChange;

  /// How long to wait for the reports of one change to settle (a hand-over often comes as two or three).
  final Duration settle;

  StreamSubscription<Set<String>>? _sub;
  Set<String>? _last;
  Timer? _timer;

  NetworkWatch(Stream<Set<String>> networks, this.onChange, {this.settle = const Duration(milliseconds: 300)}) {
    _sub = networks.listen(_seen, onError: (Object _) {}); // (a system that cannot tell: no news, the keep-alives still notice)
  }

  /// Like the constructor, but [networks] is called here, in a zone of its own that reports an error as a line in the log. A plugin that
  /// cannot tell (connectivity_plus on Linux asks NetworkManager over the system bus, which a sandbox or a system without NetworkManager
  /// does not have) can fail in its listen callback, and an error from there is not an error of the stream: `onError` never sees it, and
  /// it would be an unhandled exception. The zone is where the stream is made, so it is the one place that catches it.
  NetworkWatch.guarded(Stream<Set<String>> Function() networks, this.onChange, {this.settle = const Duration(milliseconds: 300)}) {
    runZonedGuarded(
      () => _sub = networks().listen(_seen, onError: (Object _) {}),
      (error, _) => debugPrint('Changes of the network are not reported: $error'),
    );
  }

  static bool _none(Set<String> n) => n.isEmpty || (n.length == 1 && n.single == 'none');

  void _seen(Set<String> now) {
    final before = _last;
    _last = now;
    if (before == null) return; // the first report says how things are, not that they changed
    if (_none(now)) return; // nothing to connect over: the network that comes next is what counts
    final lost = _none(before) || before.difference(now).isNotEmpty;
    if (!lost) return;
    _timer?.cancel();
    _timer = Timer(settle, onChange);
  }

  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
  }
}
