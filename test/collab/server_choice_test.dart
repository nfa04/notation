import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/signaling_server.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/settings_screen.dart';
import 'package:notes/style/app_theme.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late Directory dir;
  late SignalingServer server;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('server_choice_');
    repo = NoteRepository(await AppDatabase.open(path: '${dir.path}/n.db'));
    server = SignalingServer(port: 0);
    await server.start(address: InternetAddress.loopbackIPv4);
  });
  tearDown(() async {
    await server.stop();
    dir.deleteSync(recursive: true);
  });

  CollabService service({String builtIn = ''}) => CollabService(repo, builtInServer: builtIn, supportDirectory: () async => dir);

  test('the person\'s own server is used when set, else the built-in one, else none', () async {
    final s = service(builtIn: 'wss://built-in.example');
    await s.load();
    expect((s.server, s.customServer, s.hasBuiltInServer), ('wss://built-in.example', null, true));
    await s.setServer('mine.example.org');
    expect((s.server, s.customServer), ('wss://mine.example.org', 'wss://mine.example.org'));
    await s.setServer('https://other.example.org/live');
    expect(s.server, 'wss://other.example.org/live');
    await s.setServer('http://192.168.1.5:8787');
    expect(s.server, 'ws://192.168.1.5:8787');
    await s.setServer('');
    expect(s.server, 'wss://built-in.example'); // back to the built-in one
    expect(s.customServer, isNull);

    final none = service();
    await none.load();
    expect((none.server, none.hasBuiltInServer), (null, false));
    // and it is kept
    await s.setServer('ws://kept:1');
    final again = service(builtIn: 'wss://built-in.example');
    await again.load();
    expect(again.server, 'ws://kept:1');
  });

  test('a server can be tried: one that answers, one that does not, and nonsense', () async {
    final s = service();
    await s.load();
    expect(await s.testServer('ws://127.0.0.1:${server.boundPort}'), isNull);
    expect(await s.testServer('127.0.0.1:1'), contains('Could not connect')); // (taken as wss://, and nothing there)
    expect(await s.testServer('ws://127.0.0.1:1'), contains('Could not connect'));
    expect(await s.testServer('ws://'), isA<String>()); // not an address
  });

  testWidgets('the settings: with a built-in server there is a choice, and a custom one is tested before it is used', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late CollabService s;
    await tester.runAsync(() async {
      s = service(builtIn: 'wss://built-in.example');
      await s.load();
    });
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), collab: s)));
    await tester.tap(find.byKey(const ValueKey('settings-tab-Sharing and files')));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('collab-which')));
    expect(find.text('Using the built-in server.'), findsOneWidget);
    expect(find.byKey(const ValueKey('collab-server')), findsNothing);

    await tester.tap(find.text('My own server'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('collab-server')), 'ws://127.0.0.1:${server.boundPort}');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('collab-test')));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pumpAndSettle();
    expect(find.text('The server answers.'), findsOneWidget);
    expect(s.server, 'ws://127.0.0.1:${server.boundPort}');

    await tester.runAsync(() async {
      await tester.tap(find.text('Built-in server'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(s.server, 'wss://built-in.example');
  });

  testWidgets('without a built-in server the settings ask for one', (tester) async {
    late CollabService s;
    await tester.runAsync(() async {
      s = service();
      await s.load();
    });
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), collab: s)));
    await tester.tap(find.byKey(const ValueKey('settings-tab-Sharing and files')));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('collab-no-builtin')));
    expect(find.byKey(const ValueKey('collab-server')), findsOneWidget);
    expect(find.byKey(const ValueKey('collab-which')), findsNothing);
  });
}
