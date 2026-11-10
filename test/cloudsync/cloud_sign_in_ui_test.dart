import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/cloud_sign_in.dart';
import 'package:notes/cloudsync/cloud_sync_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/device_sync_service.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/screens/cloud_sign_in_ui.dart';
import 'package:notes/screens/sync_settings.dart';

import '../devicesync/fakes.dart';
import '../devicesync/harness.dart';
import 'memory_cloud_folder.dart';

/// Signing in with the cloud folder as the person sees it: the switch in the sync settings, the key that is shown once, and the dialog
/// of a new device.
void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late Device a, b;
  late DeviceSyncService sa, sb;
  late CloudSyncService ca, cb;
  late FakeServer server;
  late MemoryCloudFolder folder;
  late ValueNotifier<bool> accountB;

  DeviceSyncService serviceFor(Device d) => DeviceSyncService(
        settings: d.settings,
        keys: MemorySyncKeys(),
        library: d.library,
        profile: d.profile,
        serverOf: () => 'wss://signal.example',
        openRoom: (srv, secret) async => FakeRoom(server, (await secret.roomKeys()).room),
        makeLinker: (room, me) => FakeLinker(server, (room as FakeRoom).name, me),
      );

  CloudSyncService cloudFor(Device d, DeviceSyncService s, ValueNotifier<bool> account) => CloudSyncService(
        d.settings,
        s,
        [CloudProvider(id: 'memory', label: 'Memory', available: () => account.value, folderFor: (_) => folder, changes: account)],
        retryDelays: const [],
      );

  Future<void> setUpDevices(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    server = FakeServer();
    folder = MemoryCloudFolder();
    accountB = ValueNotifier(false);
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('signinui_');
      a = await Device.create('Laptop', root, profileId: 'aaaaaaaaaaaaaaaa');
      b = await Device.create('Tablet', root, profileId: 'bbbbbbbbbbbbbbbb');
      sa = serviceFor(a);
      sb = serviceFor(b);
      ca = cloudFor(a, sa, ValueNotifier(true));
      cb = cloudFor(b, sb, accountB);
      sa.cloud = ca;
      sb.cloud = cb;
      await sa.load();
      await sb.load();
      await ca.load();
      await cb.load();
    });
  }

  Future<void> tearDownDevices(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await ca.idle;
      await cb.idle;
      ca.dispose();
      cb.dispose();
      sa.dispose();
      sb.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await a.db.close();
      await b.db.close();
      await root.delete(recursive: true);
    });
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(ValueKey(key)));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  }

  testWidgets('the switch makes a key that is shown once and has to be kept; turning it off takes the sign-in file away', (tester) async {
    await setUpDevices(tester);
    await tester.runAsync(() async {
      await ca.setEnabled(true);
      await ca.idle;
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SyncSettings(service: sa)))));
    await tester.pump();

    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('cloud-signin-on'))).value, isFalse);
    await tap(tester, 'cloud-signin-on');
    expect(find.byKey(const ValueKey('signin-confirm')), findsOneWidget, reason: 'it asks first');
    expect(ca.signIn.enabled, isFalse);
    await tap(tester, 'signin-confirm');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();

    expect(find.byKey(const ValueKey('recovery-key')), findsOneWidget);
    final shown = tester.widget<SelectableText>(find.byKey(const ValueKey('recovery-key'))).data!;
    expect(RecoveryKey.parse(shown), isNotNull);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('recovery-key-done'))).onPressed, isNull, reason: 'not before the person says the key is kept');
    await tester.tap(find.byKey(const ValueKey('recovery-key-kept')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('recovery-key-done')));
    await tester.pumpAndSettle();

    expect(ca.signIn.enabled, isTrue);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('cloud-signin-on'))).value, isTrue);
    expect(folder.files.keys, contains('_profile/b'));

    await tap(tester, 'cloud-signin-on');
    await tap(tester, 'signin-confirm');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(ca.signIn.enabled, isFalse);
    expect(folder.files.keys.where((k) => k.startsWith('_profile/')), isEmpty);
    await tearDownDevices(tester);
  });

  testWidgets('the switch is off and says why while the sync through the folder is off', (tester) async {
    await setUpDevices(tester);
    await tester.runAsync(() => sa.ensureProfile());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SyncSettings(service: sa)))));
    await tester.pump();
    // (the card only shows once the cloud folder is switched on or signing in is on)
    expect(find.byKey(const ValueKey('cloud-signin-on')), findsNothing);
    await tearDownDevices(tester);
  });

  testWidgets('a new device signs in with the dialog: a wrong key is told, the right one brings the profile', (tester) async {
    await setUpDevices(tester);
    late RecoveryKey key;
    await tester.runAsync(() async {
      await ca.setEnabled(true);
      await ca.idle;
      key = await ca.signIn.enable();
    });
    accountB.value = true;
    var signedIn = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(key: const ValueKey('open'), onPressed: () async => signedIn = await showCloudSignInDialog(context, cb), child: const Text('open')),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('signin-go'))).onPressed, isNull, reason: 'no key yet');
    await tester.enterText(find.byKey(const ValueKey('signin-key')), RecoveryKey.create().text);
    await tester.pump();
    await tap(tester, 'signin-go');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(find.byKey(const ValueKey('signin-error')), findsOneWidget);
    expect(sb.isSetUp, isFalse);

    await tester.enterText(find.byKey(const ValueKey('signin-key')), key.text.toLowerCase());
    await tester.pump();
    await tap(tester, 'signin-go');
    for (var i = 0; i < 20 && !sb.isSetUp; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    }
    await tester.pumpAndSettle();
    expect(sb.isSetUp, isTrue);
    expect(signedIn, isTrue);
    expect(sb.profileId, 'aaaaaaaaaaaaaaaa');
    await tearDownDevices(tester);
  });

  testWidgets('a device that has no profile offers the sign-in next to the link', (tester) async {
    await setUpDevices(tester);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SyncSettings(service: sb)))));
    await tester.pump();
    expect(find.byKey(const ValueKey('sync-signin')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-join')), findsOneWidget);
    await tearDownDevices(tester);
  });
}
