import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'invite.dart';
import 'reconnecting_socket.dart';
import 'relay_credentials.dart';
import 'secure_box.dart';
import 'transport.dart' show SignalChannel;
import '../l10n/language.dart';

/// The way to the signalling server for one session: messages that go to the other devices of the session, sealed with its key so that
/// the server can neither read nor change them.
class SignalingClient implements SignalChannel {
  final SessionInvite invite;

  /// Whether to connect again by itself when the connection drops (a host has to stay reachable; a
  /// phone drops the connection when the app is in the background).
  final bool persistent;
  late final SecureBox _box = SecureBox(invite.messageKey);
  late final ReconnectingSocket _socket;
  final _incoming = StreamController<Map<String, Object?>>.broadcast();
  final IceRequests _ice = IceRequests();

  SignalingClient(this.invite, {this.persistent = false}) {
    final base = invite.server.endsWith('/') ? invite.server.substring(0, invite.server.length - 1) : invite.server;
    _socket = ReconnectingSocket(
      address: () async => Uri.parse('$base/live/${invite.room}'),
      persistent: persistent,
      onFrame: (link, data) => unawaited(_frame(data)),
      // a connection that is not made again ends what comes in: whoever listens knows that nothing more will
      onDown: (retrying) {
        if (!retrying && !_incoming.isClosed) unawaited(_incoming.close());
      },
    );
  }

  /// What the other devices sent, opened. Messages that do not open (another key, or tampered with) are dropped.
  @override
  Stream<Map<String, Object?>> get messages => _incoming.stream;

  Future<void> _frame(String data) async {
    try {
      final outer = jsonDecode(data) as Map;
      if (outer['s'] == 'ice') {
        // the answer of the server itself to a request for relay servers (not one of the sealed messages of the devices)
        _ice.answered(IceReply.parse(outer));
        return;
      }
      final message = await _box.openMessage(outer);
      if (!_incoming.isClosed) _incoming.add(message);
    } catch (_) {
      // not for this session
    }
  }

  Future<void> connect({Duration timeout = const Duration(seconds: 10)}) => _socket.connect(timeout: timeout);

  /// The app is back in front: connections that were cut in the background are not noticed for a
  /// while, so start a fresh one now.
  void wake() => _socket.wake();

  @override
  Future<List<Map<String, Object>>> relayServers() => RelayCredentials.forServer(invite.server, requestIceServers);

  /// Asks the server for the servers of a relay, for a connection that cannot be made directly. Null: no answer (a server that does
  /// not know the question, or no connection now).
  Future<IceReply?> requestIceServers({Duration timeout = const Duration(seconds: 3)}) => _ice.ask(_socket.send, timeout: timeout);

  @override
  Future<void> send(Map<String, Object?> message) async {
    // (all the same length: see padMessage). A connection that is going down loses it; a persistent one is made again
    _socket.send(await _box.sealMessage(message));
  }

  Future<void> close() async {
    await _socket.close();
    if (!_incoming.isClosed) await _incoming.close();
  }

  /// Whether [server] answers as a signalling server: null if it does, else what is wrong. It opens a
  /// connection to a room nobody uses and closes it again.
  static Future<String?> check(String server, {Duration timeout = const Duration(seconds: 8)}) async {
    if (!(server.startsWith('ws://') || server.startsWith('wss://'))) {
      return tr('The address must start with wss:// (or ws:// for a server on your own network)');
    }
    final Uri base;
    try {
      base = Uri.parse(server.endsWith('/') ? server.substring(0, server.length - 1) : server);
      if (base.host.isEmpty) return tr('That is not an address');
    } on FormatException {
      return tr('That is not an address');
    }
    final r = Random.secure();
    final room = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    try {
      final socket = WebSocketChannel.connect(Uri.parse('$base/live/$room'));
      await socket.ready.timeout(timeout);
      await socket.sink.close();
      return null;
    } on TimeoutException {
      return tr('No answer from {host} (is it running, and reachable from here?)', {'host': base.host});
    } catch (e) {
      return tr('Could not connect to {host}: {error}', {'host': base.host, 'error': '$e'.replaceFirst('WebSocketChannelException: ', '')});
    }
  }
}
