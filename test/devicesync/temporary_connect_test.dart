import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/device_sync_service.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_keys.dart';
import 'package:notes/devicesync/sync_link.dart';

import 'fakes.dart';
import 'harness.dart';

/// "Connect temporarily": a browser shows a code, the phone scans it and meets the browser in the room of the code; the two pair there
/// with digits from the code's secret, and the profile's secret goes to the browser only with the yes on the phone.
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
    Future<void> until(bool Function() ok, {int ms = 8000, String? reason}) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (!ok()) {
        if (DateTime.now().isAfter(end)) fail(reason ?? 'timed out');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    phone = await Device.create('Phone', root, profileId: 'aaaaaaaaaaaaaaaa');
    browser = await Device.create('Browser', root, profileId: 'bbbbbbbbbbbbbbbb');
    final phoneKeys = MemorySyncKeys(), browserKeys = MemorySyncKeys();
    DeviceSyncService make(Device d) => DeviceSyncService(
          settings: d.settings,
          keys: d == phone ? phoneKeys : browserKeys,
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
    final sp = make(phone), sb = make(browser);
    await sp.load();
    await sb.load();
    try {
      final note = await phone.note('From the phone', 'hello');

      final code = await sb.startConnect();
      expect(sb.connectOffer, isNotNull);
      await sp.answerConnect(ConnectLink.parse(code.toLink())!);
      await until(() => sb.connectAnswered && sp.requests.isNotEmpty, reason: 'no request/code');
      final profileSecret = SyncSecret((await phoneKeys.profileSecret())!).toText();
      final codeRoom = (await code.secret.roomKeys()).room;

      // the two meet in the room of the code, not in the room of the profile, and nothing of the profile has gone over yet
      expect(rooms[phone]!.name, codeRoom);
      expect(await browserKeys.profileSecret(), isNull);
      expect(server.sent.any((m) => '$m'.contains(profileSecret)), isFalse);

      expect(sb.takeConnect(), isTrue);
      expect(sb.connectOffer, isNull);
      expect(sp.requests.single.code, sb.joinCode);
      sb.confirmJoinCode(true);
      expect(await browserKeys.profileSecret(), isNull); // (the browser's own yes is not enough)
      sp.answer(sp.requests.single.id, true);
      await until(() => sb.joined && sb.isSetUp, reason: 'not joined: ${sb.joinProblem} ${sb.problem}');
      expect(SyncSecret((await browserKeys.profileSecret())!).toText(), profileSecret);
      expect(sb.signalServer, 'wss://signal.example');
      // the phone went back to the room of its profile
      expect(sp.answeringConnect, isFalse);
      await until(() => rooms[phone]!.name != codeRoom, reason: 'the phone stayed in the room of the code');

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

  test('whoever made a code gets nothing of the profile when the phone says no', () async {
    final root = await Directory.systemTemp.createTemp('tempconnect_no_');
    final server = FakeServer();
    final rooms = <Device, FakeRoom>{};
    late Device phone, visitor;
    final phoneKeys = MemorySyncKeys(), visitorKeys = MemorySyncKeys();
    DeviceSyncService make(Device d) => DeviceSyncService(
          settings: d.settings,
          keys: d == phone ? phoneKeys : visitorKeys,
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
        );
    Future<void> until(bool Function() ok, {int ms = 8000, String? reason}) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (!ok()) {
        if (DateTime.now().isAfter(end)) fail(reason ?? 'timed out');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    phone = await Device.create('Phone', root, profileId: 'aaaaaaaaaaaaaaaa');
    visitor = await Device.create('Visitor', root, profileId: 'bbbbbbbbbbbbbbbb');
    final sp = make(phone), sv = make(visitor);
    await sp.load();
    await sv.load();
    try {
      final note = await phone.note('Private', 'secret words');
      final code = await sv.startConnect(); // (a code someone made and sent as a link)
      await sp.answerConnect(code);
      await until(() => sv.connectAnswered && sp.requests.isNotEmpty, reason: 'no request');
      sv.takeConnect();
      sv.confirmJoinCode(true); // (the visitor says the digits match, whatever they are)
      sp.answer(sp.requests.single.id, false);
      await until(() => !sv.joining, reason: 'the join did not end');

      expect(sv.joined, isFalse);
      expect(await visitorKeys.profileSecret(), isNull);
      final profileSecret = SyncSecret((await phoneKeys.profileSecret())!).toText();
      expect(server.sent.any((m) => '$m'.contains(profileSecret)), isFalse);
      expect(await visitor.repo.loadNote(note), isNull);
      expect(sp.peers, isEmpty);
      sp.stopOffering();
      expect(sp.answeringConnect, isFalse);
    } finally {
      sp.dispose();
      sv.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await phone.db.close();
      await visitor.db.close();
      await root.delete(recursive: true);
    }
  });
}
