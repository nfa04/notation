import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/capture/capture_service.dart' show fetchPage;
import 'package:notes/util/public_host.dart';

void main() {
  test('addresses of this device and of private networks are told from public ones', () {
    for (final a in ['127.0.0.1', '10.1.2.3', '172.16.0.1', '172.31.255.255', '192.168.1.1', '169.254.169.254', '100.64.0.1', '0.0.0.0', '::1', '::', 'fe80::1', 'fd00::1', '::ffff:127.0.0.1', '::ffff:192.168.0.5']) {
      expect(isPrivateAddress(InternetAddress(a)), isTrue, reason: a);
    }
    for (final a in ['8.8.8.8', '172.32.0.1', '172.15.0.1', '100.128.0.1', '2606:4700::1111', '::ffff:8.8.8.8']) {
      expect(isPrivateAddress(InternetAddress(a)), isFalse, reason: a);
    }
  });

  test('a page is only fetched from a public host, however the name is written', () async {
    Future<List<InternetAddress>> dns(String host) async => [InternetAddress(host == 'sneaky.example' ? '10.0.0.7' : '93.184.216.34')];
    for (final u in ['http://localhost/', 'http://127.0.0.1:8080/', 'http://[::1]/', 'http://printer.local/', 'http://sneaky.example/', 'https://192.168.0.1/admin']) {
      await expectLater(checkPublicHost(Uri.parse(u), lookup: dns), throwsStateError, reason: u);
    }
    await checkPublicHost(Uri.parse('https://example.org/a'), lookup: dns);
  });

  test('fetching a page on this device is refused before anything is sent', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => target.close(force: true));
    target.listen((r) => r.response..write('secret')..close());
    // (the first address is the local one already: refused before anything is sent)
    await expectLater(fetchPage(Uri.parse('http://127.0.0.1:${target.port}/')), throwsStateError);
  });
}
