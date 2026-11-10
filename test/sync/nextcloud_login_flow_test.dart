import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/screens/nextcloud_settings.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/nextcloud_login_flow.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../caldav_connect_test.dart' show FakeNextcloud;

/// Answers like a Nextcloud's Login Flow v2: a login page and a poll that says "not yet" until the person has approved.
class FakeLoginFlow {
  late final HttpServer server;
  final requests = <String>[];
  final userAgents = <String>[];

  /// How many polls say "not yet" before the answer.
  int pending;

  /// What the approved login hands over.
  String server_ = '', loginName = 'alice', appPassword = 'secret';
  bool notNextcloud = false;
  int polls = 0;

  /// How many polls (before any answer) the server fails with a 503, and whether the approved answer is nonsense.
  int failing = 0;
  bool garbage = false;

  FakeLoginFlow({this.pending = 1});

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((r) async {
      final body = await utf8.decodeStream(r);
      requests.add('${r.method} ${r.uri.path} $body');
      userAgents.add(r.headers.value('user-agent') ?? '');
      final res = r.response;
      if (notNextcloud) {
        res.statusCode = 404;
        return res.close();
      }
      res.headers.contentType = ContentType.json;
      if (r.method == 'POST' && r.uri.path == '/index.php/login/v2') {
        res.write(jsonEncode({
          'poll': {'token': 'tok123', 'endpoint': '$base/index.php/login/v2/poll'},
          'login': '$base/index.php/login/v2/flow/tok123',
        }));
      } else if (r.method == 'POST' && r.uri.path == '/index.php/login/v2/poll' && body == 'token=tok123') {
        if (failing > 0) {
          failing--;
          polls++;
          res.statusCode = 503;
        } else if (garbage) {
          polls++;
          res.write('{"nothing":"useful"}');
        } else if (polls++ < pending) {
          res.statusCode = 404;
        } else {
          res.write(jsonEncode({'server': server_.isEmpty ? base : server_, 'loginName': loginName, 'appPassword': appPassword}));
        }
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  // (the widget test binding answers every HTTP request with 400; these tests talk to servers of their own)
  setUpAll(() => HttpOverrides.global = null);

  group('the address', () {
    test('is the site, whatever was typed or pasted', () {
      expect(NextcloudLoginFlow.siteOf('cloud.example.com'), 'https://cloud.example.com');
      expect(NextcloudLoginFlow.siteOf('https://cloud.example.com/'), 'https://cloud.example.com');
      expect(NextcloudLoginFlow.siteOf('https://cloud.example.com/remote.php/dav/calendars/me/personal/'), 'https://cloud.example.com');
      expect(NextcloudLoginFlow.siteOf('https://cloud.example.com/index.php/apps/files'), 'https://cloud.example.com');
      expect(NextcloudLoginFlow.siteOf('https://example.com/nextcloud/index.php/apps/calendar'), 'https://example.com/nextcloud');
      expect(NextcloudLoginFlow.siteOf('http://127.0.0.1:8080'), 'http://127.0.0.1:8080');
    });

    test('is null when there is none', () {
      expect(NextcloudLoginFlow.siteOf(''), isNull);
      expect(NextcloudLoginFlow.siteOf('   '), isNull);
      expect(NextcloudLoginFlow.siteOf('ftp://cloud.example.com'), isNull);
    });
  });

  group('against a Nextcloud-like server', () {
    late FakeLoginFlow nc;
    setUp(() async {
      nc = FakeLoginFlow();
      await nc.start();
    });
    tearDown(() => nc.stop());

    test('start gives the page to open and where to ask', () async {
      final flow = await NextcloudLoginFlow().start(nc.base);
      expect(flow.loginPage.toString(), '${nc.base}/index.php/login/v2/flow/tok123');
      expect(flow.pollEndpoint.path, '/index.php/login/v2/poll');
      expect(flow.token, 'tok123');
      expect(nc.userAgents.single, 'Notation', reason: 'the server names the app password after it');
    });

    test('wait asks until the person approved and hands back the account and the app password', () async {
      nc.pending = 2;
      final api = NextcloudLoginFlow(pollEvery: const Duration(milliseconds: 10));
      final result = await api.wait(await api.start(nc.base));
      expect(result!.loginName, 'alice');
      expect(result.appPassword, 'secret');
      expect(result.server, nc.base);
      expect(nc.polls, 3, reason: 'two "not yet", then the login');
      expect(nc.requests.where((r) => r.contains('poll')).every((r) => r.endsWith('token=tok123')), isTrue);
    });

    test('wait stops when asked to, without a result', () async {
      nc.pending = 1000;
      final api = NextcloudLoginFlow(pollEvery: const Duration(milliseconds: 10));
      var calls = 0;
      expect(await api.wait(await api.start(nc.base), cancelled: () => ++calls > 3), isNull);
    });

    test('wait gives up in words when it takes too long', () async {
      nc.pending = 1000;
      final api = NextcloudLoginFlow(pollEvery: const Duration(milliseconds: 10));
      await expectLater(api.wait(await api.start(nc.base), timeout: const Duration(milliseconds: 50)), throwsA(isA<StateError>()));
    });

    test('wait goes on after a look that got a server error, as a phone loses its connection while the person logs in', () async {
      nc.failing = 3;
      final api = NextcloudLoginFlow(pollEvery: const Duration(milliseconds: 5));
      final result = await api.wait(await api.start(nc.base));
      expect(result!.appPassword, 'secret');
      expect(nc.polls, 4, reason: 'three errors, then the login');
    });

    test('wait gives up in words when the server keeps failing', () async {
      nc.failing = 1000;
      final api = NextcloudLoginFlow(pollEvery: const Duration(milliseconds: 5));
      await expectLater(api.wait(await api.start(nc.base), patience: 3), throwsA(isA<StateError>()));
      expect(nc.polls, 4, reason: 'the first look and three more');
    });

    test('wait gives up when the server is gone', () async {
      final api = NextcloudLoginFlow(pollEvery: const Duration(milliseconds: 5));
      final flow = await api.start(nc.base);
      await nc.stop();
      await expectLater(api.wait(flow, patience: 2), throwsA(isA<StateError>()));
      nc = FakeLoginFlow(); // (for the tearDown)
      await nc.start();
    });

    test('wait does not try again after an answer that is not a login: that is no network trouble', () async {
      nc.garbage = true;
      final api = NextcloudLoginFlow(pollEvery: const Duration(milliseconds: 5));
      await expectLater(api.wait(await api.start(nc.base)), throwsA(isA<StateError>()));
      expect(nc.polls, 1);
    });

    test('a server that is not a Nextcloud, or not there, is told in words', () async {
      nc.notNextcloud = true;
      await expectLater(NextcloudLoginFlow().start(nc.base), throwsA(isA<StateError>()));
      await expectLater(NextcloudLoginFlow().start('http://127.0.0.1:1'), throwsA(isA<StateError>()));
      await expectLater(NextcloudLoginFlow().start(''), throwsA(isA<StateError>()));
    });
  });

  group('in the settings', () {
    late FakeLoginFlow login;
    late FakeNextcloud nextcloud;
    late Directory root;
    late CalDavService service;
    late Database db;

    setUpAll(AppDatabase.initFfi);

    setUp(() async {
      login = FakeLoginFlow(pending: 1);
      nextcloud = FakeNextcloud();
      await login.start();
      await nextcloud.start();
      login.server_ = nextcloud.base;
      root = await Directory.systemTemp.createTemp('ncflow_');
      db = await AppDatabase.open(path: '${root.path}/n.db');
      service = CalDavService(SettingsRepository(db), TaskRepository(db), secret: _Secret(), allowInsecure: true);
    });

    tearDown(() async {
      await login.stop();
      await nextcloud.stop();
      await db.close();
      await root.delete(recursive: true);
    });

    testWidgets('"Log in with the browser" opens the login page, waits for the approval and saves the account', (tester) async {
      tester.view.physicalSize = const Size(900, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final opened = <Uri>[];
      login.pending = 100000; // (nobody has approved yet)
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NextcloudSettings(
              service: service,
              loginFlow: NextcloudLoginFlow(pollEvery: const Duration(milliseconds: 50)),
              openPage: (u) async {
                opened.add(u);
                return true;
              },
            ),
          ),
        ),
      ));
      await tester.enterText(find.byType(TextField).first, login.base);
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('nextcloud-browser-login')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('nextcloud-waiting')), findsOneWidget);
      expect(opened.single.path, '/index.php/login/v2/flow/tok123');

      login.pending = 0; // the person approves; the app looks again, takes the app password, and saves the account
      for (var i = 0; i < 60 && !service.isConnected; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(find.byKey(const ValueKey('nextcloud-waiting')), findsNothing);
      // nothing else has to be pressed: the account is saved, with its password readable, and without a task calendar or calendars to show
      expect(service.isConnected, isTrue);
      final saved = await tester.runAsync(() => service.login());
      expect(saved!.username, 'alice');
      expect(saved.password, 'secret');
      expect(saved.serverUrl, '${nextcloud.base}/remote.php/dav');
      expect(service.config!.taskCalendar, isNull);
      expect(service.config!.eventCalendars, isEmpty);
      expect(find.text('Save and sync'), findsNothing);
      expect(find.byKey(const ValueKey('nextcloud-choose-calendars')), findsOneWidget);

      // the calendars are looked up with the saved login, and can be chosen
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('nextcloud-choose-calendars')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump();
      expect(find.text('Save and sync'), findsOneWidget);
      expect(find.text('Personal'), findsWidgets);
    });

    test('an account is not saved when the keystore does not keep the password', () async {
      final lossy = CalDavService(SettingsRepository(db), TaskRepository(db), secret: _LossySecret(), allowInsecure: true);
      await expectLater(lossy.save('${nextcloud.base}/remote.php/dav', 'alice', 'secret', taskCalendar: null, eventCalendars: {}), throwsA(isA<StateError>()));
      expect(lossy.isConnected, isFalse, reason: 'an address and a user without a password would look connected and fail on every request');
      expect(await SettingsRepository(db).get('caldav_url'), isNull);
    });

    testWidgets('without an address it says so and asks the server nothing', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: NextcloudSettings(service: service)))));
      await tester.tap(find.byKey(const ValueKey('nextcloud-browser-login')));
      await tester.pump();
      expect(find.text('Enter the address of your Nextcloud first.'), findsOneWidget);
      expect(login.requests, isEmpty);
    });

    testWidgets('a login that is stopped by the person ends the wait and fills nothing in', (tester) async {
      login.pending = 100000;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NextcloudSettings(
              service: service,
              loginFlow: NextcloudLoginFlow(pollEvery: const Duration(milliseconds: 20)),
              openPage: (u) async => false,
            ),
          ),
        ),
      ));
      await tester.enterText(find.byType(TextField).first, login.base);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('nextcloud-browser-login')));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('nextcloud-login-link')), findsOneWidget, reason: 'no browser could be opened: the address is shown');
      await tester.tap(find.byKey(const ValueKey('nextcloud-stop-waiting')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(find.byKey(const ValueKey('nextcloud-waiting')), findsNothing);
      expect(find.byKey(const ValueKey('nextcloud-browser-login')), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text, isEmpty);
    });
  });
}

class _Secret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

/// A keystore that takes a write and gives nothing back (locked, or gone).
class _LossySecret implements SecretStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String v) async {}
  @override
  Future<void> delete() async {}
}
