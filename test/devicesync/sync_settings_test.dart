import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/device_sync_service.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/profile/user_profile.dart';
import 'package:notes/screens/intro_screen.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_link.dart';
import 'package:notes/screens/sync_settings.dart';

import 'fakes.dart';
import 'harness.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('settings: add a device shows the link, then the profile lists devices and the automatic sync is off until chosen', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late Directory root;
    late Device a;
    late DeviceSyncService service;
    final server = FakeServer();
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('syncui_');
      a = await Device.create('Laptop', root);
      service = DeviceSyncService(
        settings: a.settings,
        keys: MemorySyncKeys(),
        library: a.library,
        profile: a.profile,
        serverOf: () => 'wss://signal.example',
        openRoom: (srv, secret) async => FakeRoom(server, (await secret.roomKeys()).room),
        makeLinker: (room, me) => FakeLinker(server, (room as FakeRoom).name, me),
      );
      await service.load();
    });
    addTearDown(() async {
      service.dispose();
      await a.db.close();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SyncSettings(service: service)))));
    expect(find.byKey(const ValueKey('sync-add')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-join')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-auto')), findsNothing); // nothing to keep in sync yet

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('sync-add')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('sync-qr')), findsOneWidget); // (the same link, as a code to scan)
    final text = tester.widget<SelectableText>(find.byKey(const ValueKey('sync-link'))).data!;
    expect(SyncLink.parse(text), isNotNull);
    expect(text.split('#').first, isNot(contains(SyncLink.parse(text)!.secret.toText())));

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('sync-add-close')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('sync-no-peers')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-status-unknown')), findsNothing); // (no other device to be unsure about)
    expect(find.byKey(const ValueKey('sync-auto')), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('sync-auto'))).value, isFalse); // opt-in
    expect(server.rooms.values.every((r) => r.isEmpty), isTrue); // and nothing says this device is online

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('sync-auto')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(service.auto, isTrue);
    expect(server.rooms.values.any((r) => r.isNotEmpty), isTrue);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('sync-auto')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    expect(service.auto, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  });

  testWidgets('the first screen offers to use the profile of another device, and the join dialog takes a pasted link', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late Directory root;
    late Device a;
    late DeviceSyncService service;
    final server = FakeServer();
    final store = <String, String>{};
    final profile = UserProfile((k) async => store[k], (k, v) async => store[k] = v);
    final features = FeatureSettings((k) async => store[k], (k, v) async => store[k] = v);
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('syncui_');
      a = await Device.create('Tablet', root);
      service = DeviceSyncService(
        settings: a.settings,
        keys: MemorySyncKeys(),
        library: a.library,
        profile: a.profile,
        serverOf: () => 'wss://signal.example',
        openRoom: (srv, secret) async => FakeRoom(server, (await secret.roomKeys()).room),
        makeLinker: (room, me) => FakeLinker(server, (room as FakeRoom).name, me),
      );
      await service.load();
      await profile.load();
      await features.load();
    });
    addTearDown(() async {
      service.dispose();
      await a.db.close();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(MaterialApp(home: IntroScreen(profile: profile, features: features, sync: service)));
    expect(find.byKey(const ValueKey('intro-sync')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('intro-sync')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('sync-join-link')), 'this is not a link');
    await tester.tap(find.byKey(const ValueKey('sync-join-go')));
    await tester.pump();
    expect(find.text('That is not a link to add a device.'), findsOneWidget);
    expect(server.joined, isEmpty); // nothing was connected
    await tester.tap(find.byKey(const ValueKey('sync-join-cancel')));
    await tester.pumpAndSettle();

    // without the service the first screen is as it was
    await tester.pumpWidget(MaterialApp(home: IntroScreen(profile: profile, features: features)));
    expect(find.byKey(const ValueKey('intro-sync')), findsNothing);
  });
}
