import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../l10n/language.dart';
import 'invite.dart';
import 'rtc_channel.dart';
import 'signaling.dart';
import 'transport.dart';
import 'webrtc_linker.dart';

export 'rtc_channel.dart';

/// The host's side: waits on the signalling server for devices that say hello, and sets up a direct connection with each (the
/// negotiation itself is [WebRtcLinker]'s). Everything sent over the signalling server is sealed.
class WebRtcHost implements HostTransport {
  final SessionInvite invite;
  final List<Map<String, Object>> iceServers;
  final SignalingClient _signal;
  late final WebRtcLinker _linker;
  final _incoming = StreamController<PeerChannel>.broadcast();
  final String _me = newPeerId();

  /// The devices a connection is being made to (they say hello again until they hear from us).
  final Set<String> _connecting = {};
  StreamSubscription<Map<String, Object?>>? _sub;

  /// [signal] and [create] replace the signalling client and the WebRTC plugin (for tests).
  WebRtcHost(this.invite, {this.iceServers = defaultIceServers, SignalingClient? signal, Future<RTCPeerConnection> Function(Map<String, dynamic>)? create})
      : _signal = signal ?? SignalingClient(invite, persistent: true) {
    _linker = WebRtcLinker(_signal, _me, iceServers: iceServers, create: create, onProgress: _progress);
  }

  @override
  void Function(String event)? onEvent;

  @override
  void wake() => _signal.wake();

  void _event(String text) {
    rtcLog('host: $text');
    onEvent?.call(text);
  }

  void _progress(String id, LinkStep step, [String? detail]) {
    switch (step) {
      case LinkStep.offered:
        _event(tr('{id}: offer sent, waiting for its answer', {'id': id}));
      case LinkStep.answered:
        _event(tr('{id}: answered', {'id': id}));
      case LinkStep.routing:
        _event(tr('{id}: route {state}', {'id': id, 'state': detail ?? ''}));
      case LinkStep.open:
        _event(tr('{id}: connected', {'id': id}));
      case LinkStep.answering || LinkStep.failed:
        break;
    }
  }

  @override
  Stream<PeerChannel> get incoming => _incoming.stream;

  Future<void> start() async {
    await _signal.connect();
    _sub = _signal.messages.listen(_onSignal);
  }

  Future<void> _onSignal(Map<String, Object?> m) async {
    final from = m['from'];
    if (m['t'] != 'hello' || from is! String || from == _me) return;
    if (!_connecting.add(from)) return; // it asks again until it hears from us; the linker sends what is lost
    _event(tr('A device is asking to connect ({id})', {'id': from}));
    try {
      final channel = await _linker.connect(from, label: 'live', timeout: const Duration(seconds: 45));
      if (_incoming.isClosed) {
        unawaited(channel.close());
      } else {
        _incoming.add(channel);
      }
    } catch (e) {
      // (the device asks again, or gives up)
      rtcLog('host: no connection to $from: $e');
    } finally {
      _connecting.remove(from);
    }
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    await _signal.close();
    await _linker.close();
    await _incoming.close();
  }
}

/// A guest's side: says hello on the signalling server until the host answers with an offer, then
/// completes the connection.
class WebRtcJoin extends JoinTransport {
  final SessionInvite invite;
  final List<Map<String, Object>> iceServers;
  final Duration timeout;

  /// How long to wait for the host to answer at all. A host that is there answers the first hello at once; one that is not (its app
  /// was closed, and a file still points to it) should not cost the whole [timeout].
  final Duration hostSilence;

  /// Replace the signalling client and the WebRTC plugin (for tests).
  final SignalingClient Function(SessionInvite invite)? _signalFor;
  final Future<RTCPeerConnection> Function(Map<String, dynamic>)? _create;

  WebRtcJoin(
    this.invite, {
    this.iceServers = defaultIceServers,
    this.timeout = const Duration(seconds: 30),
    this.hostSilence = const Duration(seconds: 8),
    SignalingClient Function(SessionInvite invite)? signal,
    Future<RTCPeerConnection> Function(Map<String, dynamic>)? create,
  })  : _signalFor = signal,
        _create = create;

  String _last = 'starting';

  void _stage(String text) {
    _last = text;
    rtcLog('guest: $text');
    onStage?.call(text);
  }

  @override
  Future<PeerChannel> connect() async {
    // (persistent: a connection to the server that drops while the host and this device find each other - a phone changing network -
    // is made again, and the host's messages are sent again, so that is no reason to start over)
    final signal = _signalFor?.call(invite) ?? SignalingClient(invite, persistent: true);
    _stage(tr('Contacting the signalling server...'));
    try {
      await signal.connect();
    } catch (_) {
      await signal.close();
      rethrow;
    }
    final me = newPeerId();
    var hostSeen = false;
    final failed = Completer<PeerChannel>();
    final linker = WebRtcLinker(signal, me, iceServers: iceServers, create: _create, onProgress: (peer, step, [detail]) {
      switch (step) {
        case LinkStep.answering:
          hostSeen = true;
          _stage(tr('The host answered; setting up the connection...'));
        case LinkStep.answered:
          _stage(tr('Finding a route to the host...'));
        case LinkStep.routing:
          _stage(tr('Finding a route to the host ({state})...', {'state': detail ?? ''}));
        case LinkStep.open:
          _stage(tr('Connected to the host'));
        case LinkStep.failed:
          if (!failed.isCompleted) failed.completeError(StateError(_noRoute()));
        case LinkStep.offered:
          break;
      }
    });
    final channelReady = Completer<PeerChannel>();
    final sub = linker.incoming.listen((channel) {
      if (!channelReady.isCompleted) {
        channelReady.complete(channel);
      } else {
        unawaited(channel.close());
      }
    });
    unawaited(failed.future.then((_) {}, onError: (Object e) {
      if (!channelReady.isCompleted) channelReady.completeError(e);
    }));

    // the host may not be there yet, or may not have heard: ask again every few seconds
    _stage(tr('Looking for the host...'));
    final hello = Timer.periodic(const Duration(seconds: 3), (_) => signal.send({'t': 'hello', 'from': me}));
    unawaited(signal.send({'t': 'hello', 'from': me}));
    final silence = Timer(hostSilence, () {
      if (!hostSeen && !channelReady.isCompleted) channelReady.completeError(StateError(tr('The host did not answer. Is it still in the session, and online?')));
    });
    var done = false;
    try {
      final channel = await channelReady.future.timeout(timeout, onTimeout: () {
        throw StateError(hostSeen ? _noRoute() : tr('The host did not answer. Is it still in the session, and online?'));
      });
      done = true;
      return channel;
    } finally {
      hello.cancel();
      silence.cancel();
      await sub.cancel();
      // the direct connection is up and the server is not needed any more; one that did not come up is closed
      if (done) {
        await linker.release();
      } else {
        await linker.close();
      }
      await signal.close();
    }
  }

  String _noRoute() => tr('No connection could be made to the host (last step: {step}). Networks that block direct connections need a TURN server.', {'step': _last});
}

/// [WarmNet] on WebRTC: each successor waits in a room of its own on the signalling server, made from the session's invite and its site
/// (see [SessionInvite.derive]), so that a guest that says hello there reaches that successor, and the host's room is not touched.
class WebRtcWarmNet implements WarmNet {
  final SessionInvite invite;
  final List<Map<String, Object>> iceServers;
  WebRtcWarmNet(this.invite, {this.iceServers = defaultIceServers});

  SessionInvite _roomOf(String site) => invite.derive('successor:$site');

  @override
  Future<HostTransport> listen(String site) async {
    final host = WebRtcHost(_roomOf(site), iceServers: iceServers);
    await host.start();
    return host;
  }

  @override
  Future<PeerChannel> reach(String site) => WebRtcJoin(_roomOf(site), iceServers: iceServers, timeout: const Duration(seconds: 30)).connect();
}
