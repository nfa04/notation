import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../collab/backoff.dart';
import '../collab/reconnecting_socket.dart';
import '../collab/relay_credentials.dart';
import '../collab/secure_box.dart';
import '../collab/transport.dart' show SignalChannel;
import '../l10n/language.dart';
import 'sync_keys.dart';

/// The meeting room of a profile: the devices that are in it can send each other small sealed messages, and nothing else is
/// known of them to the server that keeps the room. (Over it the devices set up their direct connections.)
abstract class SyncRoom implements SignalChannel {
  /// What the other devices sent, opened. What does not open (another secret, or tampered with) is dropped.
  @override
  Stream<Map<String, Object?>> get messages;

  /// The name of the room this device is in (it changes every day, see [SyncSecret.roomKeys]); what the devices sign when they meet.
  String get name;

  /// Whether this device is in the room now.
  bool get connected;

  /// Told when [connected] changes.
  Stream<bool> get connection;

  @override
  Future<void> send(Map<String, Object?> message);

  /// The servers of a relay that the server of the room hands out, for connections between the devices that cannot be made directly
  /// (none when it has none, or does not answer).
  @override
  Future<List<Map<String, Object>>> relayServers() async => const [];

  /// The app is back in front: a connection that was cut in the background is made again now.
  void wake();

  /// Something suggests the connection may be dead (a direct connection between devices broke): it is asked at once, and made
  /// again if it does not answer.
  void check();

  Future<void> close();
}

/// [SyncRoom] on the signalling server: `<server>/sync/<room>`, where the server asks for proof that the device knows the secret
/// of the profile (a signature with a key made from it) before it lets the device in. Messages are sealed with a key from the
/// secret. A persistent room comes back by itself when the connection drops.
class ServerSyncRoom implements SyncRoom {
  final String server;
  final SyncSecret secret;
  final bool persistent;

  /// How often the server is pinged, and after how long without a word from it the connection is taken for dead.
  final Duration pingEvery, deadAfter;

  late final SecureBox _box = SecureBox(secret.messageKey);
  late final ReconnectingSocket _socket;
  RoomKeys? _keys;
  bool _connected = false;
  final _incoming = StreamController<Map<String, Object?>>.broadcast();
  final _connection = StreamController<bool>.broadcast();
  final IceRequests _ice = IceRequests();

  ServerSyncRoom(this.server, this.secret, {this.persistent = true, this.pingEvery = const Duration(seconds: 20), this.deadAfter = const Duration(seconds: 45)}) {
    final base = server.endsWith('/') ? server.substring(0, server.length - 1) : server;
    _socket = ReconnectingSocket(
      address: () async {
        final keys = _keys = await secret.roomKeys(); // (of today: the room changes every day)
        return Uri.parse('$base/sync/${keys.room}');
      },
      persistent: persistent,
      handshake: true,
      refusal: tr('The server did not accept this device'),
      pingEvery: pingEvery,
      deadAfter: deadAfter,
      backoff: Backoff(max: const Duration(seconds: 60)),
      onFrame: (link, data) => unawaited(_frame(link, data)),
      onUp: () => _setConnected(true),
      onDown: (_) => _setConnected(false),
      // at midnight (UTC) the devices all move to the room of the next day
      recycleAfter: () => SyncSecret.untilNextEpoch() + Duration(seconds: 1 + Random().nextInt(20)),
    );
  }

  @override
  Stream<Map<String, Object?>> get messages => _incoming.stream;

  @override
  String get name => _keys?.room ?? '';

  @override
  bool get connected => _connected;

  @override
  Stream<bool> get connection => _connection.stream;

  void _setConnected(bool value) {
    if (_connected == value) return;
    _connected = value;
    if (!_connection.isClosed) _connection.add(value);
  }

  Future<void> _frame(SocketLink link, String data) async {
    try {
      final outer = jsonDecode(data) as Map;
      final control = outer['s'];
      if (control == 'challenge') {
        final keys = _keys!;
        link.send(jsonEncode({'s': 'auth', 'k': base64.encode(keys.publicKey), 'g': base64.encode(await keys.answer(outer['n'] as String))}));
      } else if (control == 'ready') {
        link.ready();
      } else if (control == 'left' && link.isReady) {
        // (the server says only that a connection in the room closed, not whose: the devices ask who is still here)
        _incoming.add(const {'t': 'left'});
      } else if (control == 'ice') {
        _ice.answered(IceReply.parse(outer));
      } else if (outer['p'] is String && link.isReady) {
        _incoming.add(await _box.openMessage(outer));
      }
    } catch (_) {
      // not for this profile
    }
  }

  /// Comes into the room; fails when the server cannot be reached or does not accept the proof.
  Future<void> connect({Duration timeout = const Duration(seconds: 12)}) => _socket.connect(timeout: timeout);

  @override
  void check() => _socket.check();

  @override
  void wake() => _socket.wake();

  @override
  Future<List<Map<String, Object>>> relayServers() => RelayCredentials.forServer(server, () => _ice.ask(_socket.send));

  @override
  Future<void> send(Map<String, Object?> message) async {
    // (a connection that is going down loses it; a persistent one is made again)
    _socket.send(await _box.sealMessage(message));
  }

  @override
  Future<void> close() async {
    await _socket.close();
    _setConnected(false);
    if (!_incoming.isClosed) await _incoming.close();
    if (!_connection.isClosed) await _connection.close();
  }
}
