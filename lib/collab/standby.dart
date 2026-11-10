import 'dart:async';


import 'invite.dart';
import 'live_marker.dart';
import 'signaling.dart';

/// Waits for people who open a copy of a note this device shared. For each such note that has no live session,
/// the app sits in the room of the copy's invite on the signalling server (nothing is sent but the knocks) and
/// calls [onKnock] when somebody who has the link says hello there. The caller starts the session in that same
/// room, and the person who knocked, who keeps knocking, gets in.
///
/// The room is named by the secret of the invite, so only people with the copy's link can knock; the signalling
/// server sees a connection to an unnamed room and nothing else.
class Standby {
  final LiveMarkers _markers;
  final LiveSource _source;

  /// Called when someone knocks at the room of [noteId].
  final void Function(String noteId) onKnock;

  final SignalingClient Function(SessionInvite invite) _clientFor;
  final Duration retryAfter;

  Standby(this._markers, this._source, this.onKnock, {SignalingClient Function(SessionInvite invite)? clientFor, this.retryAfter = const Duration(seconds: 30)})
      : _clientFor = clientFor ?? ((invite) => SignalingClient(invite, persistent: true)) {
    _markers.addListener(refresh);
    _source.addListener(refresh);
  }

  final Map<String, _Waiting> _waiting = {};
  bool _disposed = false;

  /// The notes the app is waiting at the room of.
  Set<String> get waitingFor => _waiting.keys.toSet();

  /// Makes the rooms that are waited in match the notes: those with copies and no running session.
  void refresh() {
    if (_disposed) return;
    final wanted = <String, SessionInvite>{
      for (final e in _markers.standbyInvites.entries)
        if (_source.hostedLink(e.key) == null) e.key: e.value,
    };
    for (final note in _waiting.keys.toList()) {
      final w = _waiting[note]!;
      if (!wanted.containsKey(note) || wanted[note]!.toLink() != w.invite.toLink()) {
        _waiting.remove(note);
        w.close();
      }
    }
    for (final e in wanted.entries) {
      if (_waiting.containsKey(e.key)) continue;
      final w = _waiting[e.key] = _Waiting(e.value);
      unawaited(_open(e.key, w));
    }
  }

  Future<void> _open(String note, _Waiting w) async {
    if (_disposed || w.closed) return;
    final client = _clientFor(w.invite);
    w.client = client;
    try {
      await client.connect();
      if (w.closed) {
        await client.close();
        return;
      }
      DateTime? last;
      w.sub = client.messages.listen((m) {
        if (m['t'] != 'hello' || w.closed) return;
        final now = DateTime.now();
        if (last != null && now.difference(last!) < const Duration(seconds: 2)) return; // (it knocks every few seconds)
        last = now;
        onKnock(note);
      });
    } catch (_) {
      // no connection (offline, server down): try again later
      await client.close();
      w.client = null;
      if (!w.closed && !_disposed) w.retry = Timer(retryAfter, () => _open(note, w));
    }
  }

  /// The app came back to the front: connections that were cut are made again now.
  void wake() {
    for (final e in _waiting.entries) {
      final w = e.value;
      if (w.client == null) {
        w.retry?.cancel();
        unawaited(_open(e.key, w));
      } else {
        w.client!.wake();
      }
    }
  }

  void dispose() {
    _disposed = true;
    _markers.removeListener(refresh);
    _source.removeListener(refresh);
    for (final w in _waiting.values) {
      w.close();
    }
    _waiting.clear();
  }
}

class _Waiting {
  final SessionInvite invite;
  SignalingClient? client;
  StreamSubscription<Map<String, Object?>>? sub;
  Timer? retry;
  bool closed = false;

  _Waiting(this.invite);

  void close() {
    closed = true;
    retry?.cancel();
    sub?.cancel();
    client?.close();
  }
}
