import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/cloud_sync_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/device_sync_service.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/screens/sync_now_button.dart';

import '../cloudsync/memory_cloud_folder.dart';
import 'fakes.dart';
import 'harness.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late Device a;
  late DeviceSyncService service;
  late CloudSyncService cloud;
  late MemoryCloudFolder folder;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('syncnow_');
    a = await Device.create('Laptop', root);
    final server = FakeServer();
    folder = MemoryCloudFolder();
    service = DeviceSyncService(
      settings: a.settings,
      keys: MemorySyncKeys(),
      library: a.library,
      profile: a.profile,
      serverOf: () => 'wss://signal.example',
      openRoom: (srv, secret) async => FakeRoom(server, (await secret.roomKeys()).room),
      makeLinker: (room, me) => FakeLinker(server, (room as FakeRoom).name, me),
    );
    cloud = CloudSyncService(
      a.settings,
      service,
      [CloudProvider(id: 'memory', label: 'Memory', available: () => true, folderFor: (_) => folder, changes: ValueNotifier(0))],
      every: const Duration(minutes: 5),
      afterChange: const Duration(minutes: 5),
      retryDelays: const [],
    );
    service.cloud = cloud;
    await service.load();
    await cloud.load();
  });
  tearDown(() async {
    cloud.dispose();
    service.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await a.db.close();
    await root.delete(recursive: true);
  });

  Future<void> show(WidgetTester tester) => tester.pumpWidget(MaterialApp(home: Scaffold(appBar: AppBar(actions: [SyncNowButton(sync: service)]))));

  testWidgets('a device that is not in a sync profile has no button', (tester) async {
    await show(tester);
    expect(find.byKey(const ValueKey('sync-now-top')), findsNothing);
  });

  testWidgets('without the cloud sync it looks for the other devices directly', (tester) async {
    await tester.runAsync(() async {
      await service.offerLink(); // (the profile is made)
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await show(tester);
    expect(find.byKey(const ValueKey('sync-now-top')), findsOneWidget);
    expect(service.lookingForDevices, isFalse);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('sync-now-top')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(service.lookingForDevices, isTrue);
    expect(folder.calls, 0, reason: 'the folder is not used while the cloud sync is off');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('sync-now-top'))).onPressed, isNull, reason: 'not again while it looks');
    expect(find.textContaining('Looking for your other devices'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with the cloud sync on it syncs through the folder', (tester) async {
    await tester.runAsync(() async {
      await service.offerLink();
      await cloud.setEnabled(true);
      await cloud.idle;
      folder.calls = 0;
    });
    final before = cloud.lastRun;
    await show(tester);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('sync-now-top')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await cloud.idle;
    });
    await tester.pump();
    // (a device on its own has nothing to ask the folder: that a run happened is what shows)
    expect(cloud.lastRun, isNot(before), reason: 'a run through the folder was made');
    expect(service.lookingForDevices, isFalse, reason: 'and no direct connection was tried');
    expect(cloud.running, isFalse);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('sync-now-top'))).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });
}
