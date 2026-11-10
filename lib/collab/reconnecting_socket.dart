import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'backoff.dart';
import 'keep_alive.dart';

/// One connection of a [ReconnectingSocket].
class SocketLink {
  final WebSocketChannel _channel;
  final Completer<void>? _ready;

  SocketLink._(this._channel, {required bool needsHandshake}) : _ready = needsHandshake ? Completer<void>() : null;

  /// Whether the connection counts as up: at once, or - for a socket with a handshake - once [ready] was called.
  bool get isReady {
    final r = _ready;
    return r == null || r.isCompleted;
  }

  /// Says that the handshake is through (see [ReconnectingSocket.handshake]).
  void ready() {
    final r = _ready;
    if (r != null && !r.isCompleted) r.complete();
  }

  /// Sends [text] on this connection (false when it is going down).
  bool send(String text) {
    try {
      _channel.sink.add(text);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// A WebSocket to a server that is kept up: it is connected again when it drops (with a wait that grows, and a random part, so that
/// the devices that lost the same server do not all come back at once), noticed when it died without closing (a change of network, a
/// phone that slept: it is asked every [pingEvery] and taken for dead after [deadAfter] without a word), and made again at once when
/// the app comes back to the front.
///
/// What is sent over it, and what the frames mean, is for whoever uses it ([SignalingClient], [ServerSyncRoom]): this holds
/// the connection only.
class ReconnectingSocket {
  /// Where to connect, asked for at every connection (the room of a profile changes every day).
  final Future<Uri> Function() address;

  /// Gets every text frame that is not the answer to a ping.
  final void Function(SocketLink link, String frame) onFrame;

  /// Whether to connect again by itself when the connection drops. Without it a connection that dropped stays so ([onDown] with
  /// `retrying` false).
  final bool persistent;

  /// With a handshake the connection counts as up when [onFrame] has called [SocketLink.ready] (a server that asks for proof before
  /// it lets the device in), and not before.
  final bool handshake;

  /// What a connection that was closed before the handshake was through is told as.
  final String refusal;

  /// Called when the connection is up (the handshake, if any, is through).
  final void Function()? onUp;

  /// Called when an up connection is gone; [retrying]: it is made again.
  final void Function(bool retrying)? onDown;

  /// If given, an up connection is closed and made again after this long (the room it is in is not the room to be in then).
  final Duration Function()? recycleAfter;

  final Duration pingEvery, deadAfter;
  final Backoff _backoff;

  ReconnectingSocket({
    required this.address,
    required this.onFrame,
    this.persistent = true,
    this.handshake = false,
    this.refusal = 'The server closed the connection',
    this.onUp,
    this.onDown,
    this.recycleAfter,
    this.pingEvery = const Duration(seconds: 20),
    this.deadAfter = const Duration(seconds: 45),
    Backoff? backoff,
  }) : _backoff = backoff ?? Backoff();

  SocketLink? _link;
  KeepAlive? _alive;
  Timer? _retry, _recycle;
  bool _closing = false, _connecting = false;

  /// Whether the connection is up.
  bool get isUp => _link != null;

  /// Sends [text] on the connection that is up; false when there is none (it is gone, not queued).
  bool send(String text) => _link?.send(text) ?? false;

  /// Connects; throws when the server cannot be reached in [timeout], or does not let the device in. Only a first connection
  /// throws: the ones after a drop are tried again.
  Future<void> connect({Duration timeout = const Duration(seconds: 10)}) async {
    if (_closing) throw StateError('closed');
    final channel = WebSocketChannel.connect(await address());
    final link = SocketLink._(channel, needsHandshake: handshake);
    final through = Completer<void>();
    try {
      await channel.ready.timeout(timeout);
    } catch (_) {
      // (a socket that never got through must not be left half open)
      unawaited(channel.sink.close().then((_) {}, onError: (Object _) {}));
      rethrow;
    }
    channel.stream.listen(
      (data) {
        if (identical(link, _link)) _alive?.heard(pong: data == 'pong');
        if (data is! String || data == 'pong') return;
        try {
          onFrame(link, data);
        } catch (_) {
          // not for this device
        }
      },
      onDone: () {
        if (!through.isCompleted) through.completeError(StateError(refusal));
        _dropped(link);
      },
      onError: (_) {},
    );
    // a frame can complete the handshake only once the listener is there
    final handshaking = link._ready;
    if (handshaking != null) {
      unawaited(handshaking.future.then((_) => through.isCompleted ? null : through.complete()));
      try {
        await through.future.timeout(timeout);
      } catch (e) {
        unawaited(channel.sink.close().then((_) {}, onError: (Object _) {}));
        rethrow;
      }
    } else if (!through.isCompleted) {
      through.complete();
    }
    if (_closing) {
      unawaited(channel.sink.close().then((_) {}, onError: (Object _) {}));
      throw StateError('closed');
    }
    _backoff.reset();
    _link = link;
    // a connection that died without closing (a change of network) is noticed, and made again
    _alive?.stop();
    _alive = KeepAlive(
      every: pingEvery,
      deadAfter: deadAfter,
      ping: () => _link?.send('ping'),
      dead: () {
        if (!identical(_link, link)) return;
        unawaited(channel.sink.close().then((_) {}, onError: (Object _) {}));
        _dropped(link, now: true);
      },
    )..start();
    _recycle?.cancel();
    final after = recycleAfter?.call();
    if (after != null) _recycle = Timer(after, _restart);
    onUp?.call();
  }

  void _dropped(SocketLink link, {bool now = false}) {
    if (!identical(link, _link)) return; // an old one that was replaced
    _link = null;
    _alive?.stop();
    _recycle?.cancel();
    if (_closing) return;
    onDown?.call(persistent);
    if (!persistent) return;
    if (now) {
      unawaited(_reconnect());
    } else {
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(_backoff.next(), _reconnect);
  }

  Future<void> _reconnect() async {
    if (_closing || _connecting) return;
    _connecting = true;
    try {
      await connect();
    } catch (_) {
      if (!_closing) _scheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  /// Closes the connection that is up and makes a new one at once.
  void _restart() {
    if (_closing) return;
    _alive?.stop();
    final old = _link;
    _link = null;
    _recycle?.cancel();
    if (old != null) {
      unawaited(old._channel.sink.close().then((_) {}, onError: (Object _) {}));
      onDown?.call(true);
    }
    _retry?.cancel();
    unawaited(_reconnect());
  }

  /// The app is back in front: a connection that was cut in the background is not noticed for a while, so a fresh one is made now.
  void wake() {
    if (!persistent || _closing) return;
    _restart();
  }

  /// Something suggests the connection may be dead (a direct connection between devices broke): it is asked at once, and made again
  /// if it does not answer. With no connection a new one is tried.
  void check() {
    if (_closing) return;
    if (_link == null) {
      if (persistent) unawaited(_reconnect());
      return;
    }
    _alive?.check();
  }

  Future<void> close() async {
    _closing = true;
    _retry?.cancel();
    _recycle?.cancel();
    _alive?.stop();
    final link = _link;
    _link = null;
    await link?._channel.sink.close();
  }
}
