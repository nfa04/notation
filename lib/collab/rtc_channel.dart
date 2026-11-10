import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'framing.dart';
import 'keep_alive.dart';
import 'transport.dart';

/// Where devices find a way to each other through firewalls. Public STUN servers only tell a
/// device its own address; add a TURN server for networks that block direct connections (it
/// relays bytes that are sealed, which it cannot read).
///
/// Cloudflare's, because the default signalling server and relay are on Cloudflare already: a STUN server learns the device's
/// address, and this way no other company does (docs/privacy.md says so; change both together).
const defaultIceServers = [
  {'urls': 'stun:stun.cloudflare.com:3478'},
];

String newPeerId() {
  final r = Random.secure();
  return List.generate(6, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// How the liveness of a link is watched: a question every [every], and a link that was silent for [deadAfter] - not a single frame, of
/// a message or of an answer - is taken for dead.
class Heartbeat {
  final Duration every, deadAfter;
  const Heartbeat({this.every = const Duration(seconds: 10), this.deadAfter = const Duration(seconds: 30)});
}

/// A data channel of a WebRTC connection as a [PeerChannel]: messages are cut into frames that fit
/// and put together again, and sending waits when the connection has a backlog.
class RtcChannel implements PeerChannel, RoutedChannel, WatchedChannel {
  final RTCPeerConnection pc;
  final RTCDataChannel dc;
  final _messages = StreamController<Uint8List>();
  final _closed = Completer<void>();
  final _framer = Framer();
  final _reassembler = Reassembler();

  /// How links are watched (null: not at all). The connection checks itself too - its state turns "disconnected" and "failed" - but
  /// that depends on the platform and can take half a minute or never come (a NAT that forgot the mapping, a device that was asleep);
  /// a question and its answer over the link itself is what says whether messages go through. A device that does not know the
  /// question (an older app) is never taken for dead: see [KeepAlive].
  static Heartbeat? heartbeat = const Heartbeat();

  /// The connections that are open now (see [dropAll]).
  static final Set<RtcChannel> _open = {};

  /// The device moved to another network: every connection was made over the old one and cannot go on, though it may look alive for a
  /// while. They are closed now, so that whoever uses them makes new ones at once.
  static void dropAll() {
    for (final c in _open.toList()) {
      rtcLog('the network changed: a connection is given up');
      unawaited(c.close());
    }
  }

  RtcChannel(this.pc, this.dc) {
    _open.add(this);
    dc.onMessage = (message) {
      if (!message.isBinary) return;
      final control = FrameControl.of(message.binary);
      if (control != null) {
        _alive?.heard(pong: control == FrameControl.pong);
        if (control == FrameControl.ping) _sendControl(FrameControl.pong);
        if (control == FrameControl.pong) _answered();
        return;
      }
      _alive?.heard();
      final whole = _reassembler.add(message.binary);
      if (whole != null && !_messages.isClosed) _messages.add(whole);
    };
    final beat = heartbeat;
    if (beat != null) {
      _alive = KeepAlive(
        every: beat.every,
        deadAfter: beat.deadAfter,
        grace: beat.deadAfter,
        ping: _ask,
        dead: () {
          // (a link that is busy sending a lot has the question waiting behind its data: that it is not answered says nothing)
          if ((dc.bufferedAmount ?? 0) > 0) {
            _alive?.start();
            return;
          }
          rtcLog('the link was silent for ${beat.deadAfter.inSeconds} s: it is given up');
          unawaited(close());
        },
      )..start();
    }
    dc.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelClosed) _finish();
    };
    pc.onConnectionState = (state) {
      _lost?.cancel();
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _finish();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        // "disconnected" need not be the end: a connection cut for a moment can come back by itself. But after a change of network it
        // often stays so for a long time without ever becoming "failed"; a new connection is quicker than waiting for that
        _lost = Timer(lostAfter, () {
          rtcLog('a connection stayed cut for ${lostAfter.inSeconds} s: it is given up');
          unawaited(close());
        });
      }
    };
  }

  KeepAlive? _alive;

  // ---- what the questions measure (see [WatchedChannel])

  final _roundTrips = StreamController<Duration?>.broadcast();
  DateTime? _askedAt;

  @override
  bool get watching => _alive != null;

  @override
  Stream<Duration?> get roundTrips => _roundTrips.stream;

  void _ask() {
    final now = DateTime.now();
    // (one question at a time: one that is still open when the next goes out was not answered)
    if (_askedAt != null && !_roundTrips.isClosed) _roundTrips.add(null);
    _askedAt = now;
    _sendControl(FrameControl.ping);
  }

  void _answered() {
    final at = _askedAt;
    if (at == null || _roundTrips.isClosed) return;
    _askedAt = null;
    _roundTrips.add(DateTime.now().difference(at));
  }

  void _sendControl(FrameControl control) {
    if (_closed.isCompleted) return;
    try {
      unawaited(dc.send(RTCDataChannelMessage.fromBinary(control.frame)).then((_) {}, onError: (Object _) {}));
    } catch (_) {
      // not open (yet), or going down
    }
  }

  /// How long a connection may stay "disconnected" before it counts as gone.
  static const lostAfter = Duration(seconds: 8);
  Timer? _lost;

  void _finish() {
    _lost?.cancel();
    _alive?.stop();
    unawaited(_roundTrips.close());
    _open.remove(this);
    if (_closed.isCompleted) return;
    _closed.complete();
    _messages.close();
  }

  @override
  Stream<Uint8List> get messages => _messages.stream;

  /// The DTLS certificate fingerprints of both ends, from the descriptions the two sides exchanged (sorted, so both ends get
  /// the same text). Throws when a description has none: such a link is not used for anything that needs to be trusted.
  @override
  Future<String> binding() async {
    String? fingerprint(RTCSessionDescription? d) => RegExp(r'a=fingerprint:(\S+) (\S+)').firstMatch(d?.sdp ?? '')?.group(0);
    final mine = fingerprint(await pc.getLocalDescription());
    final theirs = fingerprint(await pc.getRemoteDescription());
    if (mine == null || theirs == null) throw StateError('the connection has no certificate fingerprints');
    return ([mine, theirs]..sort()).join('|');
  }

  /// Direct, or through a TURN relay: read from the pair of candidates the connection settled on. Relayed when either end of that
  /// pair is a relay candidate (the other device may be the one that is relayed, and the relay's bandwidth is used all the same).
  /// Unknown when the report has no such pair (the connection is not settled yet, or the platform reports it differently).
  @override
  Future<LinkRoute> route() async {
    try {
      final reports = await pc.getStats();
      StatsReport? byId(Object? id) {
        for (final r in reports) {
          if (r.id == id) return r;
        }
        return null;
      }

      StatsReport? pair;
      for (final r in reports) {
        if (r.type == 'transport') pair = byId(r.values['selectedCandidatePairId']);
      }
      pair ??= reports.where((r) => r.type == 'candidate-pair' && '${r.values['nominated']}' == 'true' && '${r.values['state']}' == 'succeeded').firstOrNull;
      if (pair == null) return LinkRoute.unknown;
      final local = byId(pair.values['localCandidateId'])?.values['candidateType'];
      final remote = byId(pair.values['remoteCandidateId'])?.values['candidateType'];
      if (local == null && remote == null) return LinkRoute.unknown;
      return local == 'relay' || remote == 'relay' ? LinkRoute.relayed : LinkRoute.direct;
    } catch (_) {
      return LinkRoute.unknown;
    }
  }

  @override
  Future<void> get closed => _closed.future;

  /// How long the buffer may stay full without draining before the link counts as dead.
  static const stalled = Duration(seconds: 60);

  @override
  Future<void> send(Uint8List message) async {
    for (final frame in _framer.split(message)) {
      // a big message (a PDF) must not fill the connection's buffer; a buffer that stops draining is a connection that died without
      // closing, and waiting on it for ever would keep the sync (and the cloud sync, which waits for it) from ever ending
      var buffered = dc.bufferedAmount ?? 0;
      var moved = DateTime.now();
      while (buffered > 1 << 20) {
        if (_closed.isCompleted) throw StateError('the link is closed');
        if (DateTime.now().difference(moved) > stalled) {
          unawaited(close());
          throw StateError('the link stopped sending');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final now = dc.bufferedAmount ?? 0;
        if (now < buffered) moved = DateTime.now();
        buffered = now;
      }
      await dc.send(RTCDataChannelMessage.fromBinary(frame));
    }
  }

  @override
  Future<void> close() async {
    _finish();
    // closing what is closed already throws in the plugin; that is not worth an error
    try {
      await dc.close();
    } catch (_) {}
    try {
      await pc.close();
    } catch (_) {}
  }
}

void rtcLog(String message) => debugPrint('[live] $message');

/// "host", "srflx" (found with STUN) or "relay" (TURN): what kind of route a candidate is.
String candidateKind(String candidate) {
  final m = RegExp(r' typ (\w+)').firstMatch(candidate);
  return m?.group(1) ?? '?';
}

Map<String, Object?> rtcConfig(List<Map<String, Object>> ice) => {'iceServers': ice, 'sdpSemantics': 'unified-plan'};
