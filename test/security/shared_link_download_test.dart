// A link to a shared copy comes from someone else: following it must not reach this device or a private network, and a file bigger than
// allowed must not be held in memory first.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/share_storage.dart';

void main() {
  for (final address in ['https://localhost/x', 'https://127.0.0.1/x', 'https://192.168.1.1/x', 'https://10.0.0.5/x', 'https://[::1]/x', 'https://printer.local/x', 'https://169.254.169.254/latest/meta-data']) {
    test('$address is not fetched', () async {
      await expectLater(downloadShared(Uri.parse(address)), throwsA(isA<StateError>()));
    });
  }

  test('an address that is not secure is refused', () async {
    await expectLater(downloadShared(Uri.parse('http://example.com/x')), throwsA(isA<StateError>()));
  });

  group('against a local server (the tests allow it)', () {
    late HttpServer server;
    late Uri base;
    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((request) async {
        switch (request.uri.path) {
          case '/big':
            request.response.add(List.filled(2 * 1024 * 1024, 1));
          case '/loop':
            request.response
              ..statusCode = 302
              ..headers.set('location', '/loop');
          case '/ok':
            request.response.add([1, 2, 3]);
        }
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('a file is read', () async {
      expect(await downloadShared(base.resolve('/ok'), allowInsecure: true), [1, 2, 3]);
    });

    test('a file bigger than the limit is refused', () async {
      await expectLater(downloadShared(base.resolve('/big'), allowInsecure: true, maxBytes: 1024 * 1024), throwsA(isA<StateError>()));
    });

    test('a link that sends on for ever is given up', () async {
      await expectLater(downloadShared(base.resolve('/loop'), allowInsecure: true), throwsA(isA<StateError>()));
    });
  });
}
