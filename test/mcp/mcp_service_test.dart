import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/l10n/language.dart';
import 'package:notes/l10n/text.dart' as app;
import 'package:notes/mcp/mcp_notes.dart';
import 'package:notes/mcp/mcp_service.dart';
import 'package:notes/mcp/mcp_support.dart';
import 'package:notes/screens/settings_screen.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/sync/caldav_service.dart' show SecretStore;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Secret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

/// A port nobody listens on.
Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  late NoteRepository repo;
  late Map<String, String> stored;
  late _Secret secret;
  final services = <McpService>[];

  McpService make() {
    final s = McpService(
      notes: McpNotes(repository: repo, tasks: TaskRepository(db)),
      read: (k) async => stored[k],
      write: (k, v) async => stored[k] = v,
      secret: secret,
    );
    services.add(s);
    return s;
  }

  setUp(() async {
    HttpOverrides.global = null; // (the test binding answers every request with a 400, and these talk to a real server)
    db = await AppDatabase.open(path: inMemoryDatabasePath);
    repo = NoteRepository(db);
    stored = {};
    secret = _Secret();
  });

  tearDown(() async {
    for (final s in services) {
      s.dispose();
    }
    services.clear();
  });

  Future<int> post(McpService s, String? token, [Object body = const {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}]) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse(s.url));
      if (token != null) request.headers.set('Authorization', 'Bearer $token');
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  test('it is off until the person turns it on, and has a token of its own that is kept', () async {
    final s = make();
    await s.load();
    expect(s.enabled, isFalse);
    expect(s.running, isFalse);
    expect(s.token, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(secret.value, s.token);
    final again = make();
    await again.load();
    expect(again.token, s.token, reason: 'the agents that have it keep working across runs');
  });

  test('turning it on listens on the port, turning it off stops; the choice is kept', () async {
    final s = make();
    await s.load();
    await s.setPort(await freePort());
    await s.setEnabled(true);
    expect(s.running, isTrue);
    expect(stored['mcp_enabled'], '1');
    expect(await post(s, s.token), 200);
    expect(await post(s, 'wrong'), 401);
    expect(await post(s, null), 401);
    final url = s.url;
    expect(url, startsWith('http://127.0.0.1:'));

    await s.stop(); // the app is closed, and started again
    final next = make();
    await next.load();
    expect(next.enabled, isTrue);
    expect(next.running, isTrue, reason: 'it was on, so it is on');
    await next.setEnabled(false);
    expect(next.running, isFalse);
    expect(stored['mcp_enabled'], '0');
    await expectLater(post(next, next.token), throwsA(isA<SocketException>()));
  });

  test('a port that is taken is said, and nothing else breaks', () async {
    final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(taken.close);
    final s = make();
    await s.load();
    await s.setPort(taken.port);
    await s.setEnabled(true);
    expect(s.running, isFalse);
    expect(s.error, contains('${taken.port}'));
    await s.setPort(await freePort()); // another one
    expect(s.running, isTrue);
    expect(s.error, isNull);
  });

  test('ports that are not for this (the system\'s) are refused', () async {
    final s = make();
    await s.load();
    await s.setPort(80);
    expect(s.port, McpService.defaultPort);
    await s.setPort(70000);
    expect(s.port, McpService.defaultPort);
  });

  test('a new token lets out the agents that had the old one', () async {
    final s = make();
    await s.load();
    await s.setPort(await freePort());
    await s.setEnabled(true);
    final old = s.token!;
    expect(await post(s, old), 200);
    await s.regenerateToken();
    expect(s.token, isNot(old));
    expect(secret.value, s.token);
    expect(await post(s, old), 401);
    expect(await post(s, s.token), 200);
  });

  test('reading only is kept, and the server says so', () async {
    final s = make();
    await s.load();
    expect(s.canChange, isTrue);
    await s.setCanChange(false);
    expect(stored['mcp_access'], 'read');
    final next = make();
    await next.load();
    expect(next.canChange, isFalse);
  });

  test('without a keystore the token lives as long as the app does', () async {
    final s = McpService(notes: McpNotes(repository: repo, tasks: TaskRepository(db)), read: (k) async => null, write: (k, v) async {}, secret: _BrokenSecret());
    services.add(s);
    await s.load();
    expect(s.token, isNotNull);
  });

  test('the settings for the agent name the address and carry the token', () async {
    final s = make();
    await s.load();
    expect(s.claudeCodeCommand, 'claude mcp add --transport http notation ${s.url} --header "Authorization: Bearer ${s.token}"');
    final json = jsonDecode(s.jsonSettings) as Map;
    expect(json['mcpServers']['notation'], {'type': 'http', 'url': s.url, 'headers': {'Authorization': 'Bearer ${s.token}'}});
  });

  test('a computer can offer it, a build for the web cannot', () {
    expect(mcpSupported, Platform.isLinux || Platform.isMacOS || Platform.isWindows);
  });

  testWidgets('the settings show the switch; turned on they give the token (hidden until asked for), the access and the port', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    AppLanguage.instance = AppLanguage.inMemory('en');
    addTearDown(() => AppLanguage.instance = AppLanguage.inMemory());
    late McpService s;
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.runAsync(() async {
      s = make();
      await s.load();
      await s.setPort(await freePort());
    });
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
      home: SettingsScreen(theme: AppTheme.inMemory(), mcp: s),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-tab-Extensions')), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mcp-switch')), findsOneWidget);
    expect(find.byKey(const ValueKey('mcp-token')), findsNothing, reason: 'nothing of the token while it is off');

    await tester.runAsync(() => s.setEnabled(true));
    await tester.pumpAndSettle();
    expect(tester.widget<app.Text>(find.byKey(const ValueKey('mcp-token'))).data, isNot(contains(s.token!)));
    await tester.tap(find.byKey(const ValueKey('mcp-token-show')));
    await tester.pumpAndSettle();
    expect(tester.widget<app.Text>(find.byKey(const ValueKey('mcp-token'))).data, s.token);

    await tester.tap(find.byKey(const ValueKey('mcp-token-copy')));
    await tester.tap(find.byKey(const ValueKey('mcp-copy-claude')));
    await tester.pump();
    expect(copied, [s.token, s.claudeCodeCommand]);

    await tester.tap(find.descendant(of: find.byKey(const ValueKey('mcp-access')), matching: find.text('Read only')));
    await tester.pumpAndSettle();
    expect(s.canChange, isFalse);

    final before = s.token;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('mcp-new-token')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(s.token, isNot(before));

    await tester.runAsync(() => s.setEnabled(false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mcp-token')), findsNothing);
  });
}

class _BrokenSecret implements SecretStore {
  @override
  Future<String?> read() async => throw StateError('no keystore');
  @override
  Future<void> write(String value) async => throw StateError('no keystore');
  @override
  Future<void> delete() async {}
}
