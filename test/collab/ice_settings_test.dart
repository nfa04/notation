import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/ice_settings.dart';
import 'package:notes/collab/webrtc_transport.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/devicesync/sync_library.dart' show syncedSetting;
import 'package:notes/screens/settings_screen.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/sync/caldav_service.dart' show SecretStore;

class _Secret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

/// The relay for connections that cannot be made directly: a mobile network puts a device behind an address that another device
/// behind another such address cannot be reached at, and only a relay (TURN) gets the two together.
void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory dir;
  late NoteRepository repo;
  late SettingsRepository settings;
  late _Secret secret;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ice_');
    final db = await AppDatabase.open(path: '${dir.path}/n.db');
    repo = NoteRepository(db);
    settings = SettingsRepository(db);
    secret = _Secret();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('without a relay only the STUN servers are used', () async {
    final ice = IceSettings(settings: settings, secret: secret);
    await ice.load();
    expect(ice.hasRelay, isFalse);
    expect(ice.servers, defaultIceServers);
  });

  test('a relay comes with its name and password, after the STUN servers', () async {
    final ice = IceSettings(settings: settings, secret: secret);
    await ice.save(urls: 'turn:turn.example.org:3478, turns:turn.example.org:443', username: 'anna', credential: 'pw');
    expect(ice.hasRelay, isTrue);
    expect(ice.servers.take(defaultIceServers.length), defaultIceServers);
    expect(ice.servers.last, {
      'urls': ['turn:turn.example.org:3478', 'turns:turn.example.org:443'],
      'username': 'anna',
      'credential': 'pw',
    });
    expect(rtcConfig(ice.servers)['iceServers'], ice.servers);
  });

  test('an address without turn: in front is taken for a TURN address; lines, commas and spaces separate them', () {
    expect(IceSettings.parseUrls('turn.example.org:3478\nturns:other.example.org:443  stun:s.example.org:3478;TURN:upper.example.org'),
        ['turn:turn.example.org:3478', 'turns:other.example.org:443', 'stun:s.example.org:3478', 'TURN:upper.example.org']);
    expect(IceSettings.parseUrls('  \n '), isEmpty);
  });

  test('nonsense is told, an empty field is fine', () {
    expect(IceSettings.check(''), isNull);
    expect(IceSettings.check('turn:turn.example.org:3478'), isNull);
    expect(IceSettings.check('turn:'), isNotNull);
    expect(IceSettings.check('https://turn.example.org'), isNotNull);
  });

  test('it is kept: the address and name in the settings, the password only in the keystore; an empty address takes it all away', () async {
    final ice = IceSettings(settings: settings, secret: secret);
    await ice.save(urls: 'turn:turn.example.org:3478', username: 'anna', credential: 'pw');
    expect(secret.value, 'pw');
    expect(await settings.get('ice_relay_user'), 'anna');
    expect((await settings.allWhere((_) => true)).values.map((v) => v.value), isNot(contains('pw')), reason: 'no password in the settings');

    final again = IceSettings(settings: settings, secret: secret);
    await again.load();
    expect((again.urls, again.username, again.credential), ('turn:turn.example.org:3478', 'anna', 'pw'));

    await again.save(urls: '');
    expect(again.hasRelay, isFalse);
    expect(secret.value, isNull);
    final empty = IceSettings(settings: settings, secret: secret);
    await empty.load();
    expect((empty.urls, empty.username, empty.credential), ('', '', ''));
  });

  test('the relay is not one of the settings that travel to the other devices', () async {
    final ice = IceSettings(settings: settings, secret: secret);
    await ice.save(urls: 'turn:turn.example.org:3478', username: 'anna', credential: 'pw');
    // (see syncedSetting: servers, accounts and secrets are per device)
    expect(syncedSetting('ice_relay_urls'), isFalse);
    expect(syncedSetting('ice_relay_user'), isFalse);
  });

  testWidgets('the settings: the relay is entered, checked and kept', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late CollabService collab;
    late IceSettings ice;
    await tester.runAsync(() async {
      ice = IceSettings(settings: settings, secret: secret);
      collab = CollabService(repo, builtInServer: 'wss://built-in.example', supportDirectory: () async => dir, ice: ice);
      await collab.load();
    });
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), collab: collab)));
    await tester.tap(find.byKey(const ValueKey('settings-tab-Sharing and files')));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('relay-urls')));

    await tester.enterText(find.byKey(const ValueKey('relay-urls')), 'https://nonsense');
    await tester.tap(find.byKey(const ValueKey('relay-save')));
    await tester.pump();
    expect(find.byKey(const ValueKey('relay-problem')), findsOneWidget);
    expect(ice.hasRelay, isFalse, reason: 'nothing is kept that is not an address');

    await tester.enterText(find.byKey(const ValueKey('relay-urls')), 'turn:turn.example.org:3478');
    await tester.enterText(find.byKey(const ValueKey('relay-user')), 'anna');
    await tester.enterText(find.byKey(const ValueKey('relay-password')), 'pw');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('relay-save')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('relay-saved')), findsOneWidget);
    expect(find.byKey(const ValueKey('relay-problem')), findsNothing);
    expect(ice.servers.last['urls'], ['turn:turn.example.org:3478']);
    expect(secret.value, 'pw');
  });
}
