// The cloud services are called with a login. If one of them (or someone in the way) sends the app on to another server, the login must
// not go along. (The clients follow redirects with the default settings of Dio on top of dart:io, so this checks what that does.)
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a login header is not sent to the server a redirect leads to', () async {
    final seen = <String, String?>{};
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) async {
      seen['authorization'] = r.headers.value('authorization');
      seen['x-api-key'] = r.headers.value('x-api-key');
      await r.response.close();
    });
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((r) async {
      r.response
        ..statusCode = 302
        ..headers.set('location', 'http://localhost:${target.port}/loot');
      await r.response.close();
    });
    addTearDown(() async {
      await origin.close(force: true);
      await target.close(force: true);
    });
    final dio = Dio(BaseOptions(validateStatus: (s) => s != null && s < 500));
    await dio.get<dynamic>('http://127.0.0.1:${origin.port}/start', options: Options(headers: {'Authorization': 'Bearer secret-token', 'X-Api-Key': 'k'}));
    expect(seen.containsKey('authorization'), isTrue, reason: 'the redirect was followed');
    expect(seen['authorization'], isNull);
  });
}
