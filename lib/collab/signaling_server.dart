import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../devicesync/sync_keys.dart';

/// The signalling server: a meeting point where devices of one session find each other to set up
/// their direct connections. It relays small messages between the devices that are in the same
/// "room" and keeps nothing: no log, no storage, no accounts. The messages are sealed with the
/// session key before they get here, so all it can see is the room name (which tells it nothing),
/// who is connected, and how much they send.
///
/// A device connects with a WebSocket to `/live/<room>`, where room is 32 hex digits. The protocol,
/// and two more implementations (Node, Cloudflare Workers), are in `tool/signaling/`.
class SignalingServer {
  final int port;
  final int maxPeersPerRoom;
  final int maxMessageBytes;

  /// Messages a device may send per second; more than that and it is cut off.
  final int maxMessagesPerSecond;

  /// Rooms that may exist at once (of both kinds); a device that would open one more is turned away.
  final int maxRooms;

  /// What a device is told that asks for the servers of a relay (`{"s":"ice"}`): `{'servers': [...], 'ttl': seconds}`, or
  /// `{'none': reason}`. Not set: this server has no relay.
  final Map<String, Object?> Function()? relay;

  /// A device in a sync room pings every 20 s and says it is here every 45 s: one silent for longer is gone.
  final Duration silentFor;
  HttpServer? _http;
  final Map<String, Set<WebSocket>> _rooms = {};

  /// `/sync/<room>`: the rooms of profile sync, where a device must prove it knows the secret of the profile (see
  /// tool/signaling/README.md) before it is let in, and the devices that have.
  final Map<String, Set<WebSocket>> _syncRooms = {};
  final Map<String, Set<WebSocket>> _syncWaiting = {};
  static const maxUnauthenticatedPerRoom = 16;
  static const authTimeout = Duration(seconds: 8);
  final _rate = Expando<_Rate>();

  SignalingServer({this.port = 8787, this.maxPeersPerRoom = 8, this.maxMessageBytes = 64 * 1024, this.maxMessagesPerSecond = 60, this.maxRooms = 10000, this.relay, this.silentFor = const Duration(seconds: 70)});

  /// The answer to a request for the servers of a relay, to the device that asked and no other.
  String _relayAnswer() => jsonEncode({'s': 'ice', ...(relay?.call() ?? const {'none': 'unconfigured'})});

  static final _roomName = RegExp(r'^[0-9a-f]{32}$');

  int get boundPort => _http!.port;
  int get roomCount => _rooms.length;

  /// Whether a room named [name] would be one too many.
  bool _roomsFull(String name) => !_rooms.containsKey(name) && !_syncRooms.containsKey(name) && !_syncWaiting.containsKey(name) && _rooms.length + _syncRooms.length + _syncWaiting.length >= maxRooms;

  /// The upgrade to a WebSocket, or null (the answer is sent) when it does not work.
  Future<WebSocket?> _upgrade(HttpRequest request) async {
    try {
      return await WebSocketTransformer.upgrade(request);
    } catch (_) {
      return null;
    }
  }

  Future<void> start({InternetAddress? address}) async {
    _http = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    _http!.listen(_handle);
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    for (final room in _rooms.values.toList()) {
      for (final s in room.toList()) {
        await s.close();
      }
    }
    for (final room in [..._syncRooms.values, ..._syncWaiting.values]) {
      for (final s in room.toList()) {
        await s.close();
      }
    }
    _rooms.clear();
    _syncRooms.clear();
    _syncWaiting.clear();
  }

  Future<void> _handle(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    if (segments.length == 2 && segments[0] == 'sync' && _roomName.hasMatch(segments[1]) && WebSocketTransformer.isUpgradeRequest(request)) {
      return _handleSync(request, segments[1]);
    }
    if (segments.length != 2 || segments[0] != 'live' || !_roomName.hasMatch(segments[1]) || !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Notation signalling server');
      await request.response.close();
      return;
    }
    if ((_rooms[segments[1]]?.length ?? 0) >= maxPeersPerRoom) {
      request.response.statusCode = HttpStatus.tooManyRequests;
      await request.response.close();
      return;
    }
    if (_roomsFull(segments[1])) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    // (the room is made once the connection is there: a request that fails to upgrade leaves no empty room behind)
    final socket = await _upgrade(request);
    if (socket == null) return;
    final room = _rooms.putIfAbsent(segments[1], () => {});
    if (room.length >= maxPeersPerRoom) {
      await socket.close(1013, 'full');
      if (room.isEmpty) _rooms.remove(segments[1]);
      return;
    }
    room.add(socket);
    socket.listen(
      (data) {
        if (data is! String || utf8.encode(data).length > maxMessageBytes || !_allowed(socket)) {
          socket.close(WebSocketStatus.policyViolation);
          return;
        }
        if (data == 'ping') {
          socket.add('pong'); // (how a client tells a connection that died without closing from one that is quiet)
          return;
        }
        if (data == '{"s":"ice"}') {
          socket.add(_relayAnswer());
          return;
        }
        for (final other in room.toList()) {
          if (!identical(other, socket) && other.readyState == WebSocket.open) other.add(data);
        }
      },
      onDone: () {
        room.remove(socket);
        if (room.isEmpty) _rooms.remove(segments[1]);
      },
      onError: (_) {},
      cancelOnError: true,
    );
  }

  /// A device of a profile: it gets a random challenge, and is let into the room only with the public key the room is named
  /// after and a signature of the challenge made with the key's private half.
  Future<void> _handleSync(HttpRequest request, String roomName) async {
    if ((_syncWaiting[roomName]?.length ?? 0) >= maxUnauthenticatedPerRoom) {
      request.response.statusCode = HttpStatus.tooManyRequests;
      await request.response.close();
      return;
    }
    if (_roomsFull(roomName)) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    final socket = await _upgrade(request);
    if (socket == null) return;
    final waiting = _syncWaiting.putIfAbsent(roomName, () => {});
    waiting.add(socket);
    final random = Random.secure();
    final nonce = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    socket.add(jsonEncode({'s': 'challenge', 'n': nonce}));
    var authenticated = false;
    final deadline = Timer(authTimeout, () {
      if (!authenticated) socket.close(WebSocketStatus.policyViolation, 'no proof');
    });
    void forget() {
      deadline.cancel();
      waiting.remove(socket);
      if (waiting.isEmpty) _syncWaiting.remove(roomName);
      _heard.remove(socket);
      final room = _syncRooms[roomName];
      if (room != null && room.remove(socket)) {
        if (room.isEmpty) _syncRooms.remove(roomName);
        _left(room);
      }
    }

    socket.listen(
      (data) async {
        if (data is! String || utf8.encode(data).length > maxMessageBytes || !_allowed(socket)) {
          socket.close(WebSocketStatus.policyViolation);
          return;
        }
        if (!authenticated) {
          try {
            final m = jsonDecode(data) as Map;
            if (m['s'] != 'auth') throw const FormatException('not the proof');
            final ok = await RoomKeys.verify(Uint8List.fromList(base64.decode(m['k'] as String)), roomName, nonce, Uint8List.fromList(base64.decode(m['g'] as String)));
            if (!ok) throw const FormatException('wrong proof');
          } catch (_) {
            socket.close(WebSocketStatus.policyViolation, 'no proof');
            return;
          }
          final room = _syncRooms.putIfAbsent(roomName, () => {});
          if (room.length >= maxPeersPerRoom) {
            socket.close(1013, 'full');
            return;
          }
          authenticated = true;
          deadline.cancel();
          waiting.remove(socket);
          room.add(socket);
          _heard[socket] = DateTime.now();
          socket.add(jsonEncode({'s': 'ready'}));
          return;
        }
        _heard[socket] = DateTime.now();
        _dropSilent(roomName);
        if (data == 'ping') {
          socket.add('pong');
          return;
        }
        if (data == '{"s":"ice"}') {
          socket.add(_relayAnswer());
          return;
        }
        for (final other in (_syncRooms[roomName] ?? const <WebSocket>{}).toList()) {
          if (!identical(other, socket) && other.readyState == WebSocket.open) other.add(data);
        }
      },
      onDone: forget,
      onError: (_) {},
      cancelOnError: true,
    );
  }

  /// When each device in a sync room was last heard from.
  final Map<WebSocket, DateTime> _heard = {};


  /// Tells the others in a sync room that a connection closed (not whose: they ask who is still here), so an app that was killed
  /// is not waited for until it misses its signs of life.
  void _left(Set<WebSocket> room) {
    for (final other in room.toList()) {
      if (other.readyState == WebSocket.open) other.add('{"s":"left"}');
    }
  }

  /// Closes the connections of the room that were silent too long (the network of the device vanished: no close ever comes).
  void _dropSilent(String roomName) {
    final room = _syncRooms[roomName];
    if (room == null) return;
    final now = DateTime.now();
    for (final s in room.toList()) {
      final heard = _heard[s];
      if (heard == null || now.difference(heard) <= silentFor) continue;
      room.remove(s);
      _heard.remove(s);
      s.close(WebSocketStatus.goingAway, 'silent');
      _left(room);
    }
  }

  bool _allowed(WebSocket s) {
    final r = _rate[s] ??= _Rate();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (r.second != now) {
      r.second = now;
      r.count = 0;
    }
    return ++r.count <= maxMessagesPerSecond;
  }
}

class _Rate {
  int second = 0;
  int count = 0;
}

/// `dart run tool/signaling_server.dart [--port 8787]`
Future<void> runSignalingServer(List<String> args) async {
  var port = 8787;
  final i = args.indexOf('--port');
  if (i >= 0 && i + 1 < args.length) port = int.parse(args[i + 1]);
  final server = SignalingServer(port: port);
  await server.start();
  stdout.writeln('Notation signalling server listening on port ${server.boundPort} (ws://<this machine>:${server.boundPort}/live/<room>)');
  stdout.writeln('Put it behind a TLS proxy to offer wss://. It stores nothing and sees only sealed messages.');
  await ProcessSignal.sigint.watch().first;
  await server.stop();
}

