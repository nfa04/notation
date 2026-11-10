import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/signaling_server.dart';

void main() {
  test('a server with its rooms all in use turns away a new room, and keeps no empty one for a request that fails', () async {
    final server = SignalingServer(port: 0, maxRooms: 2);
    await server.start(address: InternetAddress.loopbackIPv4);
    addTearDown(server.stop);
    final base = 'ws://127.0.0.1:${server.boundPort}';
    String room(int n) => n.toRadixString(16).padLeft(32, '0');

    // a plain request for a room (not an upgrade) makes no room
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final plain = await (await client.getUrl(Uri.parse('http://127.0.0.1:${server.boundPort}/live/${room(9)}'))).close();
    expect(plain.statusCode, HttpStatus.notFound);
    await plain.drain<void>();
    expect(server.roomCount, 0);

    final a = await WebSocket.connect('$base/live/${room(1)}');
    final b = await WebSocket.connect('$base/live/${room(2)}');
    addTearDown(() => a.close());
    addTearDown(() => b.close());
    expect(server.roomCount, 2);
    await expectLater(WebSocket.connect('$base/live/${room(3)}'), throwsA(isA<WebSocketException>()));
    // a room that exists can still be joined
    final c = await WebSocket.connect('$base/live/${room(1)}');
    await c.close();
    // and when one empties, there is space again
    await b.close();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final d = await WebSocket.connect('$base/live/${room(3)}');
    await d.close();
  });
}
