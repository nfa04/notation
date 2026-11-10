import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../l10n/language.dart';
import 'rtc_channel.dart';
import 'transport.dart';

/// How far a connection that is being made has got.
enum LinkStep {
  /// This device sent its offer (it connects).
  offered,

  /// An offer came in and is being answered (it is connected to).
  answering,

  /// The offer is answered.
  answered,

  /// The way through the networks is being looked for; the detail is the state of the search.
  routing,

  /// The connection is open.
  open,

  /// No way was found; the connection is given up.
  failed,
}

typedef LinkProgress = void Function(String peer, LinkStep step, [String? detail]);

/// One connection while it is made, from either end.
class _Link {
  final String key, peer, connection;
  final RTCPeerConnection pc;

  /// What was sent, kept to be sent again (see [WebRtcLinker]): the offer (by the device that connects), the answer (by the one that
  /// is connected to) and the candidates of either.
  Map<String, Object?>? offer, answer;
  final List<Map<String, Object?>> candidates = [];

  /// The description the other side offered, to tell an offer that comes again from a new one.
  String? remoteSdp;
  bool answered = false, routed = false, open = false;
  Timer? resend, giveUp;
  final _failed = Completer<void>();

  _Link(this.key, this.peer, this.connection, this.pc);

  /// Completes (with an error) when the way through the networks is known to be none.
  Future<void> get failure => _failed.future;

  void fail(Object error) {
    if (!_failed.isCompleted) _failed.completeError(error);
  }

  void stop() {
    resend?.cancel();
    giveUp?.cancel();
    // (nobody may be waiting for the failure: it is not an error of nobody)
    _failed.future.then((_) {}, onError: (Object _) {});
  }
}

/// [PeerLinker] on WebRTC: the device that connects makes the offer, the other answers, and both exchange their connection
/// candidates, all as messages on a [SignalChannel] that are each addressed to one device.
///
/// Two devices can have more than one connection at a time - a sync of the libraries while a note is worked on live, two notes live
/// at once - so each connection has an id of its own (`c#` in the messages), and making one never touches the others. (An older app
/// sends no id: its one connection to a device is replaced by its next, as it was.)
///
/// **The signalling channel loses messages.** A phone that changes network drops its connection to the server for a few seconds,
/// and what was sent meanwhile is gone without anyone being told. So nothing here depends on a message getting through once: the
/// device that connects sends its offer and its candidates again every [resendEvery] until the connection is open or a route is
/// found, and a device that gets an offer it has answered already answers again (with its candidates) instead of starting over.
/// Connections that never open are closed after [setupTimeout], and one for which every route failed is given up at once.
class WebRtcLinker implements PeerLinker {
  final SignalChannel room;
  final String me;
  final List<Map<String, Object>> iceServers;
  final Future<RTCPeerConnection> Function(Map<String, dynamic> configuration) _create;
  final _incoming = StreamController<PeerChannel>.broadcast();

  /// How often the offer and the candidates are sent again while a connection is made.
  final Duration resendEvery;

  /// How long a connection that was offered to this device may take to open before it is closed.
  final Duration setupTimeout;

  /// Told how the connections that are made go (the screen shows it).
  final LinkProgress? onProgress;

  /// The connections, by `<device>/<connection id>`.
  final Map<String, _Link> _links = {};
  final Map<String, List<RTCIceCandidate>> _early = {};
  late final StreamSubscription<Map<String, Object?>> _sub;
  final _random = Random.secure();
  bool _closed = false;

  /// The connection last offered to each device: an older app answers without the id (it does not know of them).
  final Map<String, String> _lastOffered = {};

  WebRtcLinker(
    this.room,
    this.me, {
    this.iceServers = defaultIceServers,
    Future<RTCPeerConnection> Function(Map<String, dynamic>)? create,
    this.resendEvery = const Duration(seconds: 4),
    this.setupTimeout = const Duration(seconds: 45),
    this.onProgress,
  }) : _create = create ?? createPeerConnection {
    _sub = room.messages.listen(_onMessage);
  }

  @override
  Stream<PeerChannel> get incoming => _incoming.stream;

  static String _key(String peer, String connection) => '$peer/$connection';

  /// How many connections are open or being made now (for the tests).
  int get connectionCount => _links.length;

  /// For how many connections candidates are kept that came before their offer (for the tests).
  @visibleForTesting
  int get earlyCandidateKeys => _early.length;

  static const _maxEarly = 64;

  /// What a device that is in the room (and so knows the secret, but may not be of the profile) can make this one hold: connections that
  /// are being made or are open, and candidates kept for offers that have not come. Past that, new offers are not answered.
  static const _maxLinks = 32, _maxEarlyKeys = 32;

  /// The longest id of a device or of a connection, and the longest description of a connection, that is taken.
  static const _maxIdLength = 64, _maxSdpLength = 64 * 1024;

  void _progress(String peer, LinkStep step, [String? detail]) {
    try {
      onProgress?.call(peer, step, detail);
    } catch (e) {
      rtcLog('link: the progress report failed: $e');
    }
  }

  /// Sends a signalling message; the signalling channel dropping it is no error here (it is sent again).
  void _signal(Map<String, Object?> message) {
    unawaited(Future<void>.sync(() => room.send(message)).then((_) {}, onError: (Object e) => rtcLog('link: a message could not be sent: $e')));
  }

  void _sendCandidates(_Link link) {
    for (final c in link.candidates) {
      _signal(c);
    }
  }

  Future<void> _addCandidate(String key, RTCPeerConnection pc, Map<String, Object?> m) async {
    final c = RTCIceCandidate(m['c'] as String, m['mid'] as String?, (m['idx'] as num?)?.toInt());
    if (await pc.getRemoteDescription() == null) {
      _keepEarly(key, c);
    } else {
      await pc.addCandidate(c);
    }
  }

  void _keepEarly(String key, RTCIceCandidate c) {
    if (!_early.containsKey(key) && _early.length >= _maxEarlyKeys) _early.remove(_early.keys.first); // (the oldest goes)
    final early = _early.putIfAbsent(key, () => []);
    if (early.length < _maxEarly) early.add(c);
  }

  Future<void> _flushEarly(String key, RTCPeerConnection pc) async {
    for (final c in _early.remove(key) ?? const <RTCIceCandidate>[]) {
      try {
        await pc.addCandidate(c);
      } catch (e) {
        rtcLog('link: a candidate of $key did not fit: $e'); // (one of an earlier try: the others are still good)
      }
    }
  }

  /// Closes a connection, whatever state it is in: closing one that is closed already throws in the plugin, and nobody waits
  /// for the answer here, so the error would be an unhandled one.
  static Future<void> _closeQuietly(RTCPeerConnection? pc) async {
    try {
      await pc?.close();
    } catch (_) {
      // closed already
    }
  }

  Future<_Link> _newLink(String peer, String connection) async {
    final key = _key(peer, connection);
    final replaced = _links.remove(key);
    if (replaced != null) {
      replaced.stop();
      unawaited(_closeQuietly(replaced.pc)); // (only an older app's one connection, which has no id, is ever replaced)
    }
    final relay = await room.relayServers(); // (of the server of the room; kept for as long as it works, so this is quick)
    final pc = await _create(rtcConfig([...iceServers, ...relay]));
    if (_closed) {
      unawaited(_closeQuietly(pc));
      throw StateError('the linker is closed');
    }
    final link = _Link(key, peer, connection, pc);
    _links[key] = link;
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      final message = <String, Object?>{
        't': 'ice',
        'from': me,
        'to': peer,
        if (connection.isNotEmpty) 'c#': connection,
        'c': c.candidate,
        'mid': c.sdpMid,
        'idx': c.sdpMLineIndex,
      };
      if (link.candidates.length < _maxEarly) link.candidates.add(message);
      _signal(message);
    };
    pc.onIceConnectionState = (state) {
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          link.routed = true;
          link.resend?.cancel(); // (a route is found: nothing more to send until it is open)
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          if (!link.open) {
            _progress(peer, LinkStep.failed);
            link.fail(StateError(tr('No connection could be made to the other device. Networks that block direct connections need a TURN server.')));
          }
        default:
          break;
      }
      _progress(peer, LinkStep.routing, '$state'.replaceFirst('RTCIceConnectionState', ''));
    };
    return link;
  }

  /// A connection is closed: it is forgotten (unless another took its place meanwhile).
  void _forget(_Link link) {
    link.stop();
    if (identical(_links[link.key], link)) _links.remove(link.key);
    _early.remove(link.key);
    _lastOffered.removeWhere((_, k) => k == link.key);
  }

  /// A connection that nobody opened in time is closed; this is what keeps connections that were offered to this device and
  /// abandoned by the other (it went away, its offer came too late) from piling up.
  void _giveUpAfter(_Link link, Duration after) {
    link.giveUp = Timer(after, () {
      if (link.open) return;
      rtcLog('link: ${link.key} did not open in ${after.inSeconds} s: it is given up');
      _progress(link.peer, LinkStep.failed);
      _forget(link);
      unawaited(_closeQuietly(link.pc));
    });
    // a route for which every way failed does not wait for the time
    link.failure.then((_) {}, onError: (Object _) {
      if (link.open) return;
      _forget(link);
      unawaited(_closeQuietly(link.pc));
    });
  }

  Future<void> _onMessage(Map<String, Object?> m) async {
    if (_closed || m['to'] != me) return;
    final from = m['from'] as String?;
    if (from == null || from == me) return;
    final connection = m['c#'] is String ? m['c#'] as String : '';
    if (from.length > _maxIdLength || connection.length > _maxIdLength) return;
    final sdp = m['sdp'];
    if (sdp is String && sdp.length > _maxSdpLength) return;
    var key = _key(from, connection);
    if (connection.isEmpty && m['t'] != 'offer' && !_links.containsKey(key) && _lastOffered[from] != null) key = _lastOffered[from]!;
    try {
      switch (m['t']) {
        case 'offer':
          await _onOffer(from, connection, key, m);
        case 'answer':
          final link = _links[key];
          if (link == null || link.answered) return; // (an answer that comes twice is for the first one)
          link.answered = true;
          _progress(from, LinkStep.answered);
          try {
            await link.pc.setRemoteDescription(RTCSessionDescription(m['sdp'] as String, m['type'] as String));
          } catch (_) {
            link.answered = false;
            rethrow;
          }
          await _flushEarly(key, link.pc);
        case 'ice':
          final link = _links[key];
          if (link != null) {
            await _addCandidate(key, link.pc, m);
          } else {
            // the offerer sends its first candidates while its offer is still on the way: they can be here before it is, and
            // are kept for the connection that the offer makes
            _keepEarly(key, RTCIceCandidate(m['c'] as String, m['mid'] as String?, (m['idx'] as num?)?.toInt()));
          }
      }
    } catch (e) {
      rtcLog('link: a message from $from could not be used: $e');
    }
  }

  /// The offers being answered now, by connection: the same offer that comes again while it is being answered is the same offer.
  final Map<String, String> _answering = {};

  /// Connections being set up for offers (not in [_links] yet).
  int _starting = 0;

  Future<void> _onOffer(String from, String connection, String key, Map<String, Object?> m) async {
    final sdp = m['sdp'] as String;
    if (_answering[key] == sdp) return;
    _answering[key] = sdp;
    try {
      await _answer(from, connection, key, sdp, m['type'] as String);
    } finally {
      if (_answering[key] == sdp) _answering.remove(key);
    }
  }

  Future<void> _answer(String from, String connection, String key, String sdp, String type) async {
    final known = _links[key];
    if (known != null && known.remoteSdp == sdp) {
      // the offer again: the answer (or its candidates) did not get through, or the other device just asks again
      final answer = known.answer;
      if (answer != null) _signal(answer);
      _sendCandidates(known);
      return;
    }
    if (known == null && _links.length + _starting >= _maxLinks) {
      rtcLog('link: too many connections at once: the offer of $from is not answered');
      return;
    }
    // the other device connects; this one answers
    _starting++; // (offers come in together: the ones being set up count already)
    final _Link link;
    try {
      link = await _newLink(from, connection);
    } finally {
      _starting--;
    }
    link.remoteSdp = sdp;
    _progress(from, LinkStep.answering);
    final pc = link.pc;
    pc.onDataChannel = (dc) {
      final channel = RtcChannel(pc, dc);
      unawaited(channel.closed.then((_) => _forget(link)));
      void opened() {
        if (link.open) return;
        link.open = true;
        link.stop();
        _progress(from, LinkStep.open);
        if (!_incoming.isClosed) {
          _incoming.add(channel);
        } else {
          unawaited(channel.close());
        }
      }

      if (dc.state == RTCDataChannelState.RTCDataChannelOpen) {
        opened();
      } else {
        final previous = dc.onDataChannelState; // (the channel notices by it that the connection is gone)
        dc.onDataChannelState = (state) {
          previous?.call(state);
          if (state == RTCDataChannelState.RTCDataChannelOpen) opened();
        };
      }
    };
    _giveUpAfter(link, setupTimeout);
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
      link.answered = true;
      await _flushEarly(link.key, pc);
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      link.answer = {'t': 'answer', 'from': me, 'to': from, if (connection.isNotEmpty) 'c#': connection, 'sdp': answer.sdp, 'type': answer.type};
      _signal(link.answer!);
      _progress(from, LinkStep.answered);
      // (the candidates that were found before the answer went out were sent already, but before the offerer could use them)
      _sendCandidates(link);
    } catch (e) {
      _forget(link);
      unawaited(_closeQuietly(pc));
      rethrow;
    }
  }

  @override
  Future<PeerChannel> connect(String peerId, {Duration timeout = const Duration(seconds: 30), String label = 'sync'}) async {
    final connection = [for (var i = 0; i < 8; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    final link = await _newLink(peerId, connection);
    final key = link.key;
    final pc = link.pc;
    _lastOffered[peerId] = key;
    try {
      final dc = await pc.createDataChannel(label, RTCDataChannelInit()..ordered = true);
      final channel = RtcChannel(pc, dc);
      unawaited(channel.closed.then((_) => _forget(link)));
      final opened = Completer<PeerChannel>();
      final previous = dc.onDataChannelState; // (the channel notices by it that the connection is gone)
      dc.onDataChannelState = (state) {
        previous?.call(state);
        if (state == RTCDataChannelState.RTCDataChannelOpen && !opened.isCompleted) {
          link.open = true;
          link.stop();
          _progress(peerId, LinkStep.open);
          opened.complete(channel);
        }
      };
      link.failure.then((_) {}, onError: (Object e) {
        if (!opened.isCompleted) opened.completeError(e);
      });
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      link.offer = {'t': 'offer', 'from': me, 'to': peerId, 'c#': connection, 'sdp': offer.sdp, 'type': offer.type};
      _signal(link.offer!);
      _progress(peerId, LinkStep.offered);
      // until a route is found the offer and the candidates go out again: the server that carries them may have dropped them
      link.resend = Timer.periodic(resendEvery, (_) {
        if (link.open || link.routed) return;
        _signal(link.offer!);
        _sendCandidates(link);
      });
      try {
        return await opened.future.timeout(timeout, onTimeout: () {
          throw StateError(tr('No connection could be made to the other device. Networks that block direct connections need a TURN server.'));
        });
      } catch (e) {
        await channel.close();
        rethrow;
      }
    } catch (e) {
      _forget(link);
      unawaited(_closeQuietly(pc));
      rethrow;
    }
  }

  /// Stops listening and forgets the connections without closing them: they were handed to whoever uses them, which closes them.
  Future<void> release() async {
    _closed = true;
    await _sub.cancel();
    for (final link in _links.values) {
      link.stop();
    }
    _links.clear();
    _early.clear();
    await _incoming.close();
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _sub.cancel();
    final all = _links.values.toList();
    _links.clear();
    _early.clear();
    for (final link in all) {
      link.stop();
      await _closeQuietly(link.pc);
    }
    await _incoming.close();
  }
}
