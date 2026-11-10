import 'dart:async';
import 'dart:typed_data';

/// What a link goes over: straight between the two devices, or through a relay (TURN), which carries every byte of it and costs the
/// bandwidth of whoever runs the relay. Found out from the connection itself, never from what the other device says.
enum LinkRoute { unknown, direct, relayed }

/// A [PeerChannel] that can tell what it goes over (a separate interface: links in memory cannot, and need not say so).
abstract interface class RoutedChannel {
  /// [LinkRoute.unknown] when it cannot be found out (yet).
  Future<LinkRoute> route();
}

/// A [PeerChannel] that watches its own link with a question and an answer now and then (and closes itself when the answers stop). Whoever
/// uses it need not ask questions of its own: the link is watched once, and what it measured is handed on.
abstract interface class WatchedChannel {
  /// Whether it watches its link (it may be made not to).
  bool get watching;

  /// The time each answer took, as it comes; null for a question that was not answered before the next one went out.
  Stream<Duration?> get roundTrips;
}

/// The route of [channel], unknown for a channel that cannot tell.
Future<LinkRoute> routeOf(PeerChannel channel) => channel is RoutedChannel ? (channel as RoutedChannel).route() : Future.value(LinkRoute.unknown);

/// A link to one other device that carries whole messages (already cut up and put together, if
/// the wire needs it). What goes over it is sealed, so the transport never sees what it carries.
abstract class PeerChannel {
  /// Messages as they arrive.
  Stream<Uint8List> get messages;

  Future<void> send(Uint8List message);

  /// What ties the messages to the connection they travel on, as both ends see it: for a WebRTC link the certificate
  /// fingerprints of both ends. A device in the middle of a link that is set up through a server (it sits in the signalling and
  /// terminates the encryption on both sides) makes the two ends see different values, which whatever signs it then shows.
  /// Empty for links that cannot be intercepted (in memory).
  Future<String> binding();

  /// Completes when the link is gone (closed here, closed there, or lost).
  Future<void> get closed;

  Future<void> close();
}

/// A way to send small messages to the other devices of a session or a profile without a direct connection yet, as the devices set
/// one up: a signalling server, or the room of a profile on it. It is a datagram service - a message sent while the connection to the
/// server is down is gone, and nothing tells the sender - so whatever is built on it sends again what matters until it is answered.
abstract class SignalChannel {
  /// What the other devices sent, opened.
  Stream<Map<String, Object?>> get messages;

  Future<void> send(Map<String, Object?> message);

  /// The servers of a relay that the server hands out, for connections that cannot be made directly (none when it has none, or does
  /// not answer).
  Future<List<Map<String, Object>>> relayServers();
}

/// Makes direct connections to other devices over a [SignalChannel]. The device that connects offers, the other answers.
abstract class PeerLinker {
  /// Connections that other devices made to this one.
  Stream<PeerChannel> get incoming;

  /// Connects to the device [peerId]; fails when it cannot be reached.
  Future<PeerChannel> connect(String peerId, {Duration timeout});

  Future<void> close();
}

/// What the host listens with: a [PeerChannel] for each device that connects.
abstract class HostTransport {
  /// Told, in words, what happens with devices that connect ("Ben: finding a route...").
  void Function(String event)? onEvent;

  Stream<PeerChannel> get incoming;

  /// The app came back to the front: check the connection to whatever helps devices find this one.
  void wake() {}

  Future<void> close();
}

/// What a joining device connects with.
abstract class JoinTransport {
  /// Told, in words, how far the connection has got ("Looking for the host...").
  void Function(String stage)? onStage;

  /// Connects to the host of the session; fails if there is no host.
  Future<PeerChannel> connect();
}

/// How the guests of a session reach the devices that would take over from the host (its successors), each on a link of its own beside
/// the one to the host: so that what is known of a successor is what the others measured, and a successor can be reached at once.
abstract class WarmNet {
  /// Waits for links to this device ([site]) as a successor.
  Future<HostTransport> listen(String site);

  /// Connects to the successor [site]; fails when it cannot be reached.
  Future<PeerChannel> reach(String site);
}

/// [WarmNet] in memory, for tests: one place where every device of a session listens and reaches.
class LoopbackWarmNet implements WarmNet {
  final LoopbackHub _hub = LoopbackHub();
  final Map<String, StreamController<PeerChannel>> _listening = {};

  /// How many links were made (for the tests).
  int reached = 0;

  @override
  Future<HostTransport> listen(String site) async {
    // (not a broadcast: a link made before the listener subscribes is kept for it, not dropped)
    final c = StreamController<PeerChannel>();
    _listening[site] = c;
    return _WarmListener(c.stream, () {
      if (identical(_listening[site], c)) _listening.remove(site);
      return c.close();
    });
  }

  @override
  Future<PeerChannel> reach(String site) async {
    final c = _listening[site];
    if (c == null) throw StateError('$site is not listening');
    final a = _Pipe(_hub), b = _Pipe(_hub);
    a.other = b;
    b.other = a;
    reached++;
    c.add(b);
    return a;
  }

  /// Whether [site] listens (for the tests).
  bool listens(String site) => _listening.containsKey(site);

  /// Makes [site]'s place another listener's (an impostor, for the tests): links to [site] go to what is returned.
  Stream<PeerChannel> takeOver(String site) {
    final c = StreamController<PeerChannel>.broadcast();
    _listening[site] = c;
    return c.stream;
  }
}

class _WarmListener implements HostTransport {
  @override
  void Function(String event)? onEvent;
  @override
  final Stream<PeerChannel> incoming;
  final Future<void> Function() _close;
  _WarmListener(this.incoming, this._close);
  @override
  void wake() {}
  @override
  Future<void> close() => _close();
}

/// In-memory transports that connect a host and guests in one program: for tests, and a model
/// for what a real one does.
class LoopbackHub {
  final _incoming = StreamController<PeerChannel>.broadcast();
  bool hostPresent = false;

  /// While set, messages are taken and never delivered, and sending says nothing of it: a link that died without closing (the
  /// sender cannot tell that what it handed over did not arrive).
  bool blackhole = false;

  late final HostTransport host = _LoopbackHost(this);
  late final JoinTransport guest = _LoopbackJoin(this);

  final List<_Pipe> _pipes = [];

  /// Breaks every link, as when the devices lose their connection.
  Future<void> cut() async {
    for (final p in List.of(_pipes)) {
      await p.close();
    }
    _pipes.clear();
  }

  /// Messages are delivered after a microtask, like a real link: never inside the call that sends.
  int sent = 0;
}

class _Pipe implements PeerChannel {
  final _in = StreamController<Uint8List>();
  final _closed = Completer<void>();
  _Pipe? other;
  final LoopbackHub hub;

  _Pipe(this.hub);

  @override
  Stream<Uint8List> get messages => _in.stream;

  @override
  Future<void> send(Uint8List message) async {
    if (_closed.isCompleted) throw StateError('the link is closed');
    hub.sent++;
    if (hub.blackhole) return;
    final target = other!;
    scheduleMicrotask(() {
      if (!target._in.isClosed) target._in.add(Uint8List.fromList(message));
    });
  }

  @override
  Future<String> binding() async => 'loopback';

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> close() async {
    if (_closed.isCompleted) return;
    _closed.complete();
    await _in.close();
    final o = other;
    if (o != null && !o._closed.isCompleted) {
      scheduleMicrotask(() => o.close());
    }
  }
}

class _LoopbackHost implements HostTransport {
  @override
  void Function(String event)? onEvent;
  final LoopbackHub hub;
  _LoopbackHost(this.hub) {
    hub.hostPresent = true;
  }

  @override
  Stream<PeerChannel> get incoming => hub._incoming.stream;

  @override
  void wake() {}

  @override
  Future<void> close() async {
    hub.hostPresent = false;
  }
}

class _LoopbackJoin implements JoinTransport {
  @override
  void Function(String stage)? onStage;
  final LoopbackHub hub;
  _LoopbackJoin(this.hub);

  @override
  Future<PeerChannel> connect() async {
    if (!hub.hostPresent) throw StateError('nobody is hosting this session');
    final a = _Pipe(hub), b = _Pipe(hub);
    a.other = b;
    b.other = a;
    hub._pipes.addAll([a, b]);
    hub._incoming.add(b);
    return a;
  }
}
