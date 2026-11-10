import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// WebRTC in memory, as far as the linker uses it: an offer names the connection it came from, the answer to it joins the two, and
/// their data channels then carry messages to each other.
class FakeRtcNet {
  final Map<String, FakePeerConnection> _byId = {};
  int _next = 0;

  /// Every connection that was made, in order.
  final List<FakePeerConnection> made = [];

  Future<RTCPeerConnection> create(Map<String, dynamic> configuration) async {
    final pc = FakePeerConnection._(this, 'pc${_next++}');
    _byId[pc.id] = pc;
    made.add(pc);
    return pc;
  }

  int get open => made.where((p) => !p.closed).length;

  /// While set, what is sent over any data channel is lost without a word (a link that died, though nothing says so).
  bool blackhole = false;

  /// While set, the questions about the link (see `FrameControl`) are not delivered, as if the other end were an older app that
  /// ignores them.
  bool dropControl = false;
}

class FakePeerConnection extends RTCPeerConnection {
  final FakeRtcNet _net;
  final String id;
  FakePeerConnection._(this._net, this.id);

  RTCSessionDescription? _local, _remote;
  FakePeerConnection? _other;
  FakeDataChannel? _channel;
  bool closed = false;

  @override
  Future<RTCDataChannel> createDataChannel(String label, RTCDataChannelInit dataChannelDict) async => _channel = FakeDataChannel(label, _net);

  // (an offer says which connection it is, and so does its answer; a fingerprint each, for the binding of a meeting)
  @override
  Future<RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async => RTCSessionDescription('$id\na=fingerprint:sha-256 $id', 'offer');

  @override
  Future<RTCSessionDescription> createAnswer([Map<String, dynamic>? constraints]) async => RTCSessionDescription('$id\na=fingerprint:sha-256 $id', 'answer');

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async => _local = description;

  @override
  Future<RTCSessionDescription?> getLocalDescription() async => _local;

  @override
  Future<RTCSessionDescription?> getRemoteDescription() async => _remote;

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    _remote = description;
    final other = _net._byId[description.sdp!.split('\n').first];
    if (other == null) throw StateError('no such connection');
    _other = other;
    if (description.type == 'answer') {
      // the offer is answered: the two are connected, and the channel the offerer made opens on both sides
      other._other = this;
      final mine = _channel!;
      final theirs = FakeDataChannel(mine.label!, _net);
      mine._twin = theirs;
      theirs._twin = mine;
      other._channel = theirs;
      scheduleMicrotask(() {
        other.onDataChannel?.call(theirs);
        theirs._open();
        mine._open();
      });
    }
  }

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {}

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    _channel?._closeBoth();
    onConnectionState?.call(RTCPeerConnectionState.RTCPeerConnectionStateClosed);
    final other = _other;
    if (other != null && !other.closed) {
      other.onConnectionState?.call(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeDataChannel extends RTCDataChannel {
  @override
  final String? label;
  final FakeRtcNet _net;
  FakeDataChannel(this.label, this._net);

  FakeDataChannel? _twin;
  RTCDataChannelState _state = RTCDataChannelState.RTCDataChannelConnecting;

  @override
  RTCDataChannelState? get state => _state;

  @override
  int? get id => 0;

  @override
  int? get bufferedAmount => 0;

  void _open() {
    _state = RTCDataChannelState.RTCDataChannelOpen;
    onDataChannelState?.call(_state);
  }

  void _closeBoth() {
    for (final c in [this, _twin]) {
      if (c == null || c._state == RTCDataChannelState.RTCDataChannelClosed) continue;
      c._state = RTCDataChannelState.RTCDataChannelClosed;
      c.onDataChannelState?.call(c._state);
    }
  }

  @override
  Future<void> send(RTCDataChannelMessage message) async {
    final twin = _twin;
    if (_state != RTCDataChannelState.RTCDataChannelOpen || twin == null) throw StateError('the channel is not open');
    if (_net.blackhole) return;
    if (_net.dropControl && message.isBinary && message.binary.length == 8 && message.binary[7] == 0) return;
    scheduleMicrotask(() => twin.onMessage?.call(message));
  }

  @override
  Future<void> close() async => _closeBoth();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
