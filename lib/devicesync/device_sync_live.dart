part of 'device_sync_service.dart';

/// Working on one note live on two devices: of the devices that have a note open, the one with the lowest id hosts a session and
/// the others join it, over a direct connection on which both proved who they are (see [DeviceSyncService.setOpenNotes]).
extension _LiveSessions on DeviceSyncService {
  Future<void> _publishLive(String note) async {
    try {
      await _live?.saveNote(note);
      if (_cloud?.enabled ?? false) await _cloud!.syncNow();
    } catch (e) {
      debugPrint('[live] could not save the note after the session: $e');
    }
  }

  Future<void> _evaluateLive() async {
    final l = live, me = _identity?.id;
    if (_disposed || l == null || me == null) return;
    // a note that is closed here (or no longer offered) is not worked on live any more
    for (final id in l.ownNotes.where((id) => !_shared.contains(id))) {
      unawaited(l.end(id));
    }
    for (final e in _hosts.entries.toList()) {
      if (!l.hasSession(e.key) && !_hostingStarting.contains(e.key)) {
        _hosts.remove(e.key)?.close();
      }
    }
    _joinedHost.removeWhere((note, _) => !l.hasSession(note));
    if (_room == null || !(_room?.connected ?? false)) return;
    // Of the devices that have a note open, the one with the lowest id hosts it, and the others join it. When that changes - the host
    // closed the note, or a device with a lower id opened it - a device that hosts or follows another one leaves that session and
    // goes where the room says, so that there is one session per note.
    for (final note in _shared) {
      final others = [for (final p in _peers.values) if (p.online && p.open.contains(note) && book.find(p.id) != null) p.id];
      if (others.isEmpty) continue; // (alone with it: a session hosted here stays, for whoever opens the note next)
      final host = ([me, ...others]..sort()).first;
      debugPrint('[live] $note: devices with it open: ${others.join(', ')}; host is ${host == me ? 'this device' : host}');
      if (host == me) {
        if (_joinedHost.containsKey(note)) await _leaveLive(note);
        await _hostLive(note);
      } else {
        if (_hosts.containsKey(note) || (_joinedHost.containsKey(note) && _joinedHost[note] != host)) await _leaveLive(note);
        unawaited(_joinLive(note, host));
      }
    }
  }

  /// Leaves the session of [note] this device hosts or follows, to go where the room says.
  Future<void> _leaveLive(String note) async {
    _joinedHost.remove(note);
    _hosts.remove(note)?.close();
    await live?.end(note);
  }

  Future<void> _hostLive(String note) async {
    final l = live;
    if (l == null || _hosts.containsKey(note) || l.hasSession(note) || !_hostingStarting.add(note)) return;
    try {
      final host = _OwnHost(SessionInvite.create(_server ?? ''));
      final started = await l.host(note, host.invite, host.transport);
      if (!started) debugPrint('[live] could not start hosting $note (the editor is not ready, the note is locked, or a session exists already)');
      if (started) {
        _hosts[note] = host;
        _liveWith[note] = {};
      } else {
        host.close();
      }
    } catch (e) {
      debugPrint('[live] could not host $note for the other device: $e');
    } finally {
      _hostingStarting.remove(note);
    }
  }

  /// The secret of the session this device hosts for the person's devices on [note] (for a device that asks for it).
  Future<Uint8List?> _liveSecretFor(String note, String peer) async {
    final host = _hosts[note];
    final reason = !_openNotes.contains(note)
        ? 'the note is not open here'
        : book.find(peer) == null
            ? 'the asking device is not in the book'
            : host == null
                ? 'this device does not host it (hosting starting: ${_hostingStarting.contains(note)}, joined a host: ${_joinedHost[note]}, session: ${live?.hasSession(note)})'
                : !(live?.hasSession(note) ?? false)
                    ? 'the session is gone'
                    : null;
    if (reason != null) {
      debugPrint('[live] $peer asked for the session of $note, but $reason');
      return null;
    }
    if (host == null) return null;
    return host.invite.secret;
  }

  /// A device that asked to work on [link]'s note live proved who it is: it is a guest of the session of that note.
  void _acceptLive(LiveLink link) {
    final host = _hosts[link.noteId];
    if (host == null || !(live?.hasSession(link.noteId) ?? false)) {
      unawaited(link.channel.close());
      return;
    }
    host.accept(link.channel);
    final with_ = _liveWith.putIfAbsent(link.noteId, () => {})..add(link.peerId);
    // a guest that leaves while the session goes on does not have what follows (one that is there when it ends does)
    unawaited(link.channel.closed.then((_) {
      if (!(live?.status(link.noteId)?.ended ?? true)) with_.remove(link.peerId);
    }));
  }

  Future<LiveLink> _connectLive(String peer, String note) async {
    final me = await _ensureIdentity();
    final secret = _roomSecret, linker = _linker, room = _room;
    if (secret == null || linker == null || room == null || book.find(peer) == null) throw StateError(tr('The other device is not reachable now'));
    final channel = await linker.connect(peer);
    final session = SyncSession(
      channel: channel,
      secret: secret,
      roomName: room.name,
      identity: me,
      deviceName: _deviceName,
      book: book,
      profile: _profile,
      library: _library,
      liveNote: note,
    );
    final outcome = await session.run();
    final link = outcome.live;
    if (link == null) throw StateError(outcome.problem ?? tr('The other device did not follow the protocol'));
    return link;
  }

  Future<void> _joinLive(String note, String hostId) async {
    final l = live;
    if (l == null || l.hasSession(note) || !_joiningLive.add(note)) return;
    try {
      final first = await _connectLive(hostId, note);
      final transport = _OwnJoin(first, () => _connectLive(hostId, note));
      final ok = await l.join(note, SessionInvite(_server ?? '', first.secret), transport);
      if (ok) {
        _joinedHost[note] = hostId;
        _liveWith[note] = {hostId};
        _liveFailures.remove(note);
      } else {
        _liveFailed(note);
      }
    } catch (e) {
      debugPrint('[live] could not join $note: $e');
      _liveFailed(note);
    } finally {
      _joiningLive.remove(note);
    }
  }

  /// A try that did not work (the host may not be ready yet): again in a few seconds, a few times.
  void _liveFailed(String note) {
    _room?.check(); // (the connection to the server may be the one that died, after a change of network)
    _callRoll(); // (or the host did: its app was killed, and it has not been noticed yet)
    final n = _liveFailures[note] = (_liveFailures[note] ?? 0) + 1;
    if (n > 5 || _disposed) return;
    _liveRetry?.cancel();
    _liveRetry = Timer(Duration(seconds: 3 * n), () => unawaited(_evaluateLive()));
  }
}

/// The way the devices of the person reach a session this device hosts: each one that proved who it is is handed in.
class _OwnHost implements HostTransport {
  final SessionInvite invite;
  final _incoming = StreamController<PeerChannel>.broadcast();

  _OwnHost(this.invite);

  HostTransport get transport => this;

  void accept(PeerChannel channel) {
    if (_incoming.isClosed) {
      unawaited(channel.close());
    } else {
      _incoming.add(channel);
    }
  }

  @override
  void Function(String event)? onEvent;

  @override
  Stream<PeerChannel> get incoming => _incoming.stream;

  @override
  void wake() {}

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// The way this device reaches the session another device of the person hosts: the line that was made to ask for the secret is
/// the first one; when the line is lost it is made again.
class _OwnJoin implements JoinTransport {
  LiveLink? _first;
  final Future<LiveLink> Function() _again;

  _OwnJoin(this._first, this._again);

  @override
  void Function(String stage)? onStage;

  @override
  Future<PeerChannel> connect() async {
    final first = _first;
    if (first != null) {
      _first = null;
      return first.channel;
    }
    onStage?.call(tr('Connecting to your other device...'));
    return (await _again()).channel;
  }
}
