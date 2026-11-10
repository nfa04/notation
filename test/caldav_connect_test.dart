import 'dart:convert';
import 'dart:io';

import 'package:caldav/caldav.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/sync/caldav_connect.dart';

/// Answers like Nextcloud's CalDAV, for user "alice" with password "secret".
class FakeNextcloud {
  late final HttpServer server;
  final requests = <String>[];

  /// Where the site root's /.well-known/caldav sends clients. A proxy or a
  /// sub-folder install can make this wrong.
  String wellKnownTarget = 'http://elsewhere.invalid/dav/';

  String get base => 'http://127.0.0.1:${server.port}';

  static const _ns =
      'xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/"';

  Future<void> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen(_handle);
  }

  Future<void> stop() => server.close(force: true);

  String _multi(String responses) => '<?xml version="1.0"?><d:multistatus $_ns>$responses</d:multistatus>';

  String _response(String href, String props) => '<d:response><d:href>$href</d:href>'
      '<d:propstat><d:prop>$props</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';

  String _calendar(String href, String name, List<String> components) => _response(
      href,
      '<d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>$name</d:displayname>'
      '<c:supported-calendar-component-set>${components.map((c) => '<c:comp name="$c"/>').join()}'
      '</c:supported-calendar-component-set><cs:getctag>1</cs:getctag>');

  Future<void> _handle(HttpRequest r) async {
    await r.drain<void>();
    requests.add('${r.method} ${r.uri.path}');
    final res = r.response;

    if (r.uri.path == '/.well-known/caldav') {
      res.statusCode = 301;
      res.headers.set('location', wellKnownTarget);
      return res.close();
    }
    final auth = r.headers.value('authorization');
    if (auth != 'Basic ${base64Encode(utf8.encode('alice:secret'))}') {
      res.statusCode = 401;
      return res.close();
    }

    String? body;
    final path = r.uri.path.replaceAll(RegExp(r'/+$'), '');
    if (r.method == 'PROPFIND') {
      switch (path) {
        case '/remote.php/dav':
          body = _multi(_response('/remote.php/dav/',
              '<d:current-user-principal><d:href>/remote.php/dav/principals/users/alice/</d:href></d:current-user-principal>'));
        case '/remote.php/dav/principals/users/alice':
          body = _multi(_response('/remote.php/dav/principals/users/alice/',
              '<c:calendar-home-set><d:href>/remote.php/dav/calendars/alice/</d:href></c:calendar-home-set>'
              '<d:displayname>Alice</d:displayname>'));
        case '/remote.php/dav/calendars/alice':
          body = _multi(
              _response('/remote.php/dav/calendars/alice/', '<d:resourcetype><d:collection/></d:resourcetype>') +
                  _calendar('/remote.php/dav/calendars/alice/personal/', 'Personal', ['VEVENT', 'VTODO']) +
                  _calendar('/remote.php/dav/calendars/alice/contact_birthdays/', 'Birthdays', ['VEVENT']));
      }
    }
    if (body == null) {
      res.statusCode = 404;
      return res.close();
    }
    res.statusCode = 207;
    res.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
    res.write(body);
    await res.close();
  }
}

void main() {
  group('candidate addresses', () {
    test('the site address gets the Nextcloud path first, then itself', () {
      expect(candidateEndpoints('https://cloud.example.com'),
          ['https://cloud.example.com/remote.php/dav', 'https://cloud.example.com']);
    });

    test('trailing slashes and a missing scheme are fixed', () {
      expect(candidateEndpoints('cloud.example.com//').first, 'https://cloud.example.com/remote.php/dav');
    });

    test('links pasted from the browser or a calendar are cut back to the site', () {
      for (final typed in [
        'https://cloud.example.com/remote.php/dav/calendars/me/personal/',
        'https://cloud.example.com/index.php/apps/calendar/dayGridMonth/now',
        'https://cloud.example.com/apps/calendar',
        'https://cloud.example.com/settings/user/security',
      ]) {
        expect(candidateEndpoints(typed).first, 'https://cloud.example.com/remote.php/dav', reason: typed);
      }
    });

    test('a sub-folder install keeps its folder', () {
      expect(candidateEndpoints('https://example.com/nextcloud/index.php/apps/calendar').first,
          'https://example.com/nextcloud/remote.php/dav');
    });

    test('the full dav address is not tried twice', () {
      expect(candidateEndpoints('https://c.example/remote.php/dav'), ['https://c.example/remote.php/dav']);
    });
  });

  group('against a Nextcloud-like server', () {
    late FakeNextcloud nc;
    setUp(() async {
      nc = FakeNextcloud();
      await nc.start();
    });
    tearDown(() => nc.stop());

    Future<List<String>> calendarNames(String typed, {String password = 'secret'}) async {
      final c = await connectToServer(typed, 'alice', password, allowInsecure: true);
      addTearDown(c.client.close);
      return [for (final cal in await c.client.getCalendars()) cal.displayName];
    }

    test('connects from the site address, ignoring a wrong .well-known', () async {
      final c = await connectToServer(nc.base, 'alice', 'secret', allowInsecure: true);
      addTearDown(c.client.close);
      expect(c.endpoint, '${nc.base}/remote.php/dav');
      expect((await c.client.getCalendars()).map((c) => c.displayName), ['Personal', 'Birthdays']);
      expect(nc.requests.where((r) => r.contains('well-known')), isEmpty);
    });

    test('connects from a long pasted link', () async {
      expect(await calendarNames('${nc.base}/index.php/apps/calendar/dayGridMonth/now'), ['Personal', 'Birthdays']);
      expect(await calendarNames('${nc.base}/remote.php/dav/calendars/alice/personal/'), ['Personal', 'Birthdays']);
    });

    test('knows which calendars hold tasks', () async {
      final c = await connectToServer(nc.base, 'alice', 'secret', allowInsecure: true);
      addTearDown(c.client.close);
      final byName = {for (final cal in await c.client.getCalendars()) cal.displayName: cal.supportedComponents};
      expect(byName['Personal'], containsAll(['VEVENT', 'VTODO']));
      expect(byName['Birthdays'], isNot(contains('VTODO')));
    });

    test('a wrong password is reported as such, not as a discovery problem', () async {
      await expectLater(
          connectToServer(nc.base, 'alice', 'wrong', allowInsecure: true), throwsA(isA<AuthenticationException>()));
    });

    test('a wrong address lists every address that was tried', () async {
      final other = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => other.close(force: true));
      other.listen((r) async {
        await r.drain<void>();
        r.response.statusCode = 404;
        await r.response.close();
      });
      final base = 'http://127.0.0.1:${other.port}';
      try {
        await connectToServer(base, 'alice', 'secret', allowInsecure: true);
        fail('should not connect');
      } on CalDavConnectError catch (e) {
        expect(e.attempts, hasLength(2));
        expect(e.attempts.first, contains('$base/remote.php/dav'));
        expect(e.attempts.last, startsWith('$base:'));
        expect(e.toString(), contains('404'));
      }
    });

    test('plain http is refused unless allowed', () async {
      await expectLater(connectToServer(nc.base, 'alice', 'secret'), throwsA(isA<FormatException>()));
    });
  });
}
