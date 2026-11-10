import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/cloud_sync_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/device_sync_service.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_keys.dart';
import 'package:notes/screens/sync_settings.dart';

import '../devicesync/fakes.dart';
import '../devicesync/harness.dart';
import 'memory_cloud_folder.dart';

/// The settings of the sync, as the person sees them: which switches there are depending on how the devices are kept in sync.
void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late Device a;
  late DeviceSyncService service;
  late CloudSyncService cloud;
  late FakeServer server;
  late MemoryCloudFolder folder;

  /// A device that is part of a profile, with an account for the cloud folder; the settings on the screen.
  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    server = FakeServer();
    folder = MemoryCloudFolder();
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('cloudui_');
      a = await Device.create('Laptop', root);
      final keys = MemorySyncKeys();
      await keys.setProfileSecret(Uint8List.fromList(List.filled(SyncSecret.length, 3)));
      service = DeviceSyncService(
        settings: a.settings,
        keys: keys,
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
        retryDelays: const [],
      );
      service.cloud = cloud;
      await service.load();
      await cloud.load();
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SyncSettings(service: service)))));
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await cloud.idle;
      cloud.dispose();
      service.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await a.db.close();
      await root.delete(recursive: true);
    });
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(ValueKey(key)));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
  }

  bool switchOn(WidgetTester tester, String key) => tester.widget<SwitchListTile>(find.byKey(ValueKey(key))).value;

  testWidgets('the direct switches and working together are there with the cloud folder on or off; on, the screen says the folder syncs too', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('sync-auto')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-live')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-by-cloud')), findsNothing);

    await tap(tester, 'cloud-on');
    expect(cloud.enabled, isTrue);
    expect(find.byKey(const ValueKey('sync-by-cloud')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-live')), findsOneWidget);
    expect(switchOn(tester, 'sync-live'), isTrue); // (working together is on until switched off)
    expect(find.byKey(const ValueKey('sync-auto')), findsOneWidget);

    await tester.runAsync(() => cloud.idle);
    await tap(tester, 'cloud-on');
    expect(cloud.enabled, isFalse);
    expect(switchOn(tester, 'cloud-on'), isFalse);
    expect(find.byKey(const ValueKey('sync-by-cloud')), findsNothing);
    await close(tester);
  });

  testWidgets('the cloud switch moves at once, also while a run hangs', (tester) async {
    await open(tester);
    await tap(tester, 'cloud-on');
    await tester.runAsync(() => cloud.idle);
    folder.hold = Completer<void>();
    await tester.runAsync(() async {
      await a.note('Hung', 'x'); // (a run with nothing to put in the folder asks it for nothing, so it could not hang)
      unawaited(cloud.syncNow());
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(cloud.running, isTrue);
    await tap(tester, 'cloud-on');
    expect(switchOn(tester, 'cloud-on'), isFalse);
    folder.hold!.complete();
    folder.hold = null;
    await close(tester);
  });

  testWidgets('working together can be switched off, and that is remembered', (tester) async {
    await open(tester);
    await tap(tester, 'cloud-on');
    await tap(tester, 'sync-live');
    expect(service.liveTogether, isFalse);
    expect(switchOn(tester, 'sync-live'), isFalse);
    expect(await tester.runAsync(() => a.settings.get('sync_live')), '0');
    await close(tester);
  });

  testWidgets('without the cloud folder: while the automatic sync is on, looking from time to time is not offered (it is part of it)', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('sync-check')), findsOneWidget);
    expect(switchOn(tester, 'sync-check'), isFalse);
    await tap(tester, 'sync-auto');
    expect(service.auto, isTrue);
    expect(find.byKey(const ValueKey('sync-check')), findsNothing);
    await tap(tester, 'sync-auto');
    expect(find.byKey(const ValueKey('sync-check')), findsOneWidget);
    expect(switchOn(tester, 'sync-check'), isFalse); // (it never turned itself on)
    await close(tester);
  });
}
