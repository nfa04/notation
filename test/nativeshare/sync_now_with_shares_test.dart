import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/device_sync_service.dart';
import 'package:notes/devicesync/sync_devices.dart' show MemorySyncKeys;
import 'package:notes/nativeshare/native_share_provider.dart';
import 'package:notes/nativeshare/native_share_service.dart';
import 'package:notes/screens/sync_now_button.dart';

import '../devicesync/fakes.dart';
import '../devicesync/harness.dart';
import 'fake_share_provider.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late Device a;
  late DeviceSyncService sync;
  late NativeShareService shares;
  late FakeShareHub hub;

  Future<void> make(WidgetTester tester) async {
    hub = FakeShareHub();
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('syncnow_shares_');
      a = await Device.create('Laptop', root);
      final server = FakeServer();
      sync = DeviceSyncService(
        settings: a.settings,
        keys: MemorySyncKeys(),
        library: a.library,
        profile: a.profile,
        serverOf: () => 'wss://signal.example',
        openRoom: (srv, secret) async => FakeRoom(server, (await secret.roomKeys()).room),
        makeLinker: (room, me) => FakeLinker(server, (room as FakeRoom).name, me),
      );
      await sync.load();
      await sync.offerLink(); // (the profile is made)
      await Future<void>.delayed(const Duration(milliseconds: 50));
      shares = NativeShareService(
        db: a.db,
        settings: a.settings,
        library: a.library,
        providers: [hub.as('alice')],
        deviceId: () => sync.deviceId,
        deviceName: () => 'Laptop',
        every: const Duration(hours: 1),
        afterChange: const Duration(hours: 1),
        retryDelays: const [],
      );
      await shares.load();
      final noteId = await a.note('Optics', 'x');
      await shares.shareNote(noteId, shares.usable.single, const SharePerson('bob', 'Bob'), ShareRole.editor);
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(appBar: AppBar(actions: [SyncNowButton(sync: sync, shares: shares)]))));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    shares.dispose();
    sync.dispose();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await a.db.close();
      await root.delete(recursive: true);
    });
  }

  Future<void> tap(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('sync-now-top')));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
  }

  testWidgets('"Sync now" brings the shares up to date too', (tester) async {
    await make(tester);
    final folder = hub.folderOf('alice', shares.given.single.place);
    final before = folder.calls;
    await tap(tester);
    expect(folder.calls, greaterThan(before), reason: 'the share was run');
    await finish(tester);
  });

  testWidgets('and says so when a share cannot be reached', (tester) async {
    await make(tester);
    hub.down = true;
    await tap(tester);
    expect(find.textContaining('down'), findsOneWidget);
    await finish(tester);
  });
}
