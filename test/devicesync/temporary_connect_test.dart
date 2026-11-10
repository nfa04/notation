import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/device_sync_service.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_keys.dart';
import 'package:notes/devicesync/sync_link.dart';

import 'fakes.dart';
import 'harness.dart';

/// "Connect temporarily": a browser shows a code, the phone scans it and hands the browser a link of its profile through the room of
/// the code, and the usual pairing goes on from there.
void main() {
  setUpAll(AppDatabase.initFfi);

  test('the code of a browser is a link that reads back', () {
    final code = ConnectLink('wss://signal.example', SyncSecret.create());
    final back = ConnectLink.parse('scan: ${code.toLink()} ok')!;
    expect(back.server, 'wss://signal.example');
    expect(back.secret.bytes, code.secret.bytes);
    expect(SyncLink.parse(code.toLink()), isNull);
    expect(ConnectLink.parse('notation://connect?s=https://x#abc'), isNull);
    expect(ConnectLink.parse('notation://connect?s=wss://x'), isNull);
  });

  test('the phone answers the code, the browser joins, signs in for good measure and knows what no device has yet', () async {
    final root = await Directory.systemTemp.createTemp('tempconnect_');
    final server = FakeServer();
    final rooms = <Device, FakeRoom>{};
    late Device phone, browser;
    DeviceSyncService make(Device d) => DeviceSyncService(
          settings: d.settings,
          keys: MemorySyncKeys(),
          library: d.library,
          profile: d.profile,
          serverOf: () => 'wss://signal.example',
          changes: d.repo.changes,
          openRoom: (srv, secret) async => rooms[d] = FakeRoom(server, (await secret.roomKeys()).room),
          makeLinker: (room, me) => FakeLinker(server, (room as FakeRoom).name, me),
          heartbeat: const Duration(milliseconds: 300),
          resync: const Duration(seconds: 30),
          changeDelay: const Duration(milliseconds: 150),
          offerFor: const Duration(seconds: 30),
          rollCallWait: const Duration(milliseconds: 300),
          temporaryLife: const Duration(seconds: 2),
        );
    Future<void> until(bool Function() ok, {int ms = 8000, String? reason}) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (!ok()) {
        if (DateTime.now().isAfter(end)) fail(reason ?? 'timed out');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    phone = await Device.create('Phone', root, profileId: 'aaaaaaaaaaaaaaaa');
    browser = await Device.create('Browser', root, profileId: 'bbbbbbbbbbbbbbbb');
    final sp = make(phone), sb = make(browser);
    await sp.load();
    await sb.load();
    try {
      final note = await phone.note('From the phone', 'hello');

      final code = await sb.startConnect();
      expect(sb.connectOffer, isNotNull);
      await sp.answerConnect(ConnectLink.parse(code.toLink())!);
      await until(() => sb.connectArrived != null, reason: 'the link did not arrive');

      final link = sb.takeConnectedLink()!;
      expect(sb.connectOffer, isNull); // the room of the code is left
      await sb.joinWith(link);
      await until(() => sp.requests.isNotEmpty && sb.joinCodeNeedsAnswer, reason: 'no request/code');
      expect(sp.requests.single.code, sb.joinCode);
      sb.confirmJoinCode(true);
      sp.answer(sp.requests.single.id, true);
      await until(() => sb.joined && sb.isSetUp, reason: 'not joined: ${sb.joinProblem} ${sb.problem}');

      expect(await browser.text(note), 'hello');
      expect(sb.temporary, isTrue);
      expect(sb.auto, isTrue); // nobody presses "Sync now" in a browser that is used for a while
      expect(sb.unsynced, isFalse);

      // a change that no other device has: the tab must not be closed lightly
      await sp.setAuto(true);
      await browser.edit(note, 'changed in the browser');
      await until(() => sb.unsynced, reason: 'a change is not noticed');
      await until(() => !sb.unsynced, reason: 'the sync did not clear it');
      expect(await phone.text(note), 'changed in the browser');

      // the phone keeps the browser in its list only as a visit: while it is there it stays, an hour (here two seconds) after it
      // went, the phone takes it out
      expect(sp.peers.single.temporary, isTrue);
      await sp.expireTemporaryDevices();
      expect(sp.peers, hasLength(1));
      await sb.signOutTemporary();
      await until(() => !sp.peers.single.online, reason: 'the browser still looks online');
      await Future<void>.delayed(const Duration(seconds: 3));
      await sp.expireTemporaryDevices();
      expect(sp.peers, isEmpty);
    } finally {
      sp.dispose();
      sb.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await phone.db.close();
      await browser.db.close();
      await root.delete(recursive: true);
    }
  });
}
