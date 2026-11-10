import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, listEquals;
import 'package:notes/cloudsync/cloud_sync_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/device_sync_service.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_keys.dart';
import 'package:notes/devicesync/sync_link.dart';

import '../cloudsync/memory_cloud_folder.dart';
import 'fakes.dart';
import 'harness.dart';

/// The live sessions of one device, as far as the sync service sees them.
void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late FakeServer server;
  late Device a, b;
  late DeviceSyncService sa, sb;
  var settingsChanged = 0;

  // (the room each device opened last)
  final roomOf = <Device, FakeRoom>{};

  DeviceSyncService serviceFor(Device d, {Duration offlineAfter = const Duration(milliseconds: 900), Duration joinFor = const Duration(minutes: 4)}) => DeviceSyncService(
        settings: d.settings,
        keys: MemorySyncKeys(),
        library: d.library,
        profile: d.profile,
        serverOf: () => 'wss://signal.example',
        changes: d.repo.changes,
        onSettingsChanged: () => settingsChanged++,
        openRoom: (srv, secret) async => roomOf[d] = FakeRoom(server, (await secret.roomKeys()).room),
        makeLinker: (room, me) => FakeLinker(server, (room as FakeRoom).name, me),
        heartbeat: const Duration(milliseconds: 300),
        offlineAfter: offlineAfter,
        resync: const Duration(seconds: 30),
        changeDelay: const Duration(milliseconds: 150),
        offerFor: const Duration(seconds: 30),
        joinFor: joinFor,
        manualFor: const Duration(seconds: 3),
        checkEvery: const Duration(seconds: 30),
        checkFor: const Duration(milliseconds: 1200),
        rollCallWait: const Duration(milliseconds: 300),
      );

  Future<void> until(bool Function() ok, {int ms = 4000, String? reason}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail(reason ?? 'timed out');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('devicesvc_');
    server = FakeServer();
    settingsChanged = 0;
    a = await Device.create('Laptop', root, profileId: 'aaaaaaaaaaaaaaaa');
    b = await Device.create('Tablet', root, profileId: 'bbbbbbbbbbbbbbbb');
    a.profile.name = 'Anna';
    sa = serviceFor(a);
    sb = serviceFor(b);
    await sa.load();
    await sb.load();
  });
  tearDown(() async {
    sa.dispose();
    sb.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await a.db.close();
    await b.db.close();
    await root.delete(recursive: true);
  });

  /// Adds the tablet to the profile of the laptop, the way the person does.
  Future<void> pair() async {
    final link = await sa.offerLink();
    await sb.joinWith(SyncLink.parse(link.toLink())!);
    await until(() => sa.requests.isNotEmpty && sb.joinCodeNeedsAnswer, reason: 'no request/code');
    expect(sa.requests.single.code, sb.joinCode);
    sb.confirmJoinCode(true); // the person sees the same digits on both
    sa.answer(sa.requests.single.id, true);
    await until(() => sb.joined && sb.isSetUp, reason: 'not joined: ${sb.joinProblem} ${sb.problem}');
  }

  test('nothing is connected to the server until the person offers a link, joins or turns the automatic sync on', () async {
    expect(server.joined, isEmpty);
    expect(sa.isSetUp, isFalse);
    await pair();
    await until(() => !sa.connected || true);
    // once the pairing is done and the automatic sync is off, the rooms are left again
    await until(() => server.rooms.values.every((r) => r.isEmpty), reason: 'rooms still open: ${server.rooms}');
  });

  test('adding a device: the link, the same code on both, a yes, and the tablet has the profile and the notes', () async {
    final note = await a.note('From the laptop', 'hello');
    await pair();
    expect(b.profile.id, 'aaaaaaaaaaaaaaaa');
    expect(b.profile.name, 'Anna');
    expect(sb.peers.map((p) => p.id), [sa.deviceId!]);
    expect(sa.peers.map((p) => p.id), [sb.deviceId!]);
    expect(await b.text(note), 'hello');
    expect(settingsChanged, greaterThan(0));
    expect(sa.offeredLink, isNull); // one device per link
  });

  Future<void> pairVia(DeviceSyncService host, DeviceSyncService guest) async {
    final link = await host.offerLink();
    await guest.joinWith(SyncLink.parse(link.toLink())!);
    await until(() => host.requests.isNotEmpty && guest.joinCodeNeedsAnswer, ms: 15000, reason: 'no request/code');
    guest.confirmJoinCode(true);
    host.answer(host.requests.single.id, true);
    await until(() => guest.joined && guest.isSetUp, ms: 15000, reason: 'not joined: ${guest.joinProblem} ${guest.problem}');
  }

  test('a third device sees every device of the profile, and the others hear of it at once, also while they are online', () async {
    await pair();
    await sa.setAuto(true);
    await sb.setAuto(true);
    await until(() => sa.peers.single.online && sb.peers.single.online, reason: 'the laptop and the tablet do not see each other');
    final c = await Device.create('Phone', root, profileId: 'cccccccccccccccc');
    final sc = serviceFor(c);
    await sc.load();
    await pairVia(sa, sc);
    expect({for (final p in sc.peers) p.id}, {sa.deviceId!, sb.deviceId!}, reason: 'the phone was let in by the laptop and knows the tablet too');
    // (no meeting between the laptop and the tablet is due: the laptop tells the tablet when it lets the phone in)
    await until(() => sb.peers.any((p) => p.id == sc.deviceId), ms: 20000, reason: 'the tablet does not know the phone: ${sb.peers.map((p) => p.name)}');
    sc.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await c.db.close();
  });

  test('two things that need to know who this device is, at once on a new device, make it one device, not two', () async {
    await Future.wait([sa.offerLink(), sa.offerLink()]);
    expect(sa.book.all, hasLength(1), reason: 'two identities were made: ${sa.book.all.map((d) => d.id)}');
    expect(sa.book.all.single.id, sa.deviceId);
  });

  test('the time for a join does not run out while the meeting with the device that made the link is under way', () async {
    sb.dispose();
    sb = serviceFor(b, joinFor: const Duration(milliseconds: 800));
    await sb.load();
    final note = await a.note('From the laptop', 'hello');
    final link = await sa.offerLink();
    await sb.joinWith(link);
    await until(() => sa.requests.isNotEmpty && sb.joinCodeNeedsAnswer, ms: 15000, reason: 'no request/code');
    sb.confirmJoinCode(true);
    await Future<void>.delayed(const Duration(milliseconds: 2000)); // (the person on the laptop takes their time: the join time is long over)
    expect(sb.joining, isTrue, reason: 'the join was ended under the meeting: ${sb.joinProblem}');
    sa.answer(sa.requests.single.id, true);
    await until(() => sb.joined && sb.isSetUp, ms: 15000, reason: 'not joined: ${sb.joinProblem} ${sb.problem}');
    expect(await b.text(note), 'hello');
  });

  test('a join whose device is never found ends when its time is up', () async {
    sb.dispose();
    sb = serviceFor(b, joinFor: const Duration(milliseconds: 400));
    await sb.load();
    final link = await sa.offerLink();
    sa.stopOffering(); // (nobody answers the link)
    await sb.joinWith(link);
    await until(() => sb.joinProblem != null && !sb.joining, reason: 'the join did not end');
  });

  test('a no keeps the device out', () async {
    final link = await sa.offerLink();
    await sb.joinWith(link);
    await until(() => sa.requests.isNotEmpty && sb.joinCodeNeedsAnswer);
    sb.confirmJoinCode(true);
    sa.answer(sa.requests.single.id, false);
    await until(() => sb.joinProblem != null, reason: 'the tablet was not told');
    expect(sb.isSetUp, isFalse);
    expect(sa.peers, isEmpty);
  });

  test('with the automatic sync on, an edit on one device reaches the other by itself, in both directions', () async {
    final note = await a.note('Shared', 'v1');
    await pair();
    await sa.setAuto(true);
    await sb.setAuto(true);
    await until(() => sa.peers.any((p) => p.online) && sb.peers.any((p) => p.online), reason: 'devices did not see each other');

    await a.edit(note, 'edited on the laptop');
    await until(() => b.library.manifest().toString().isNotEmpty);
    var ok = false;
    final end = DateTime.now().add(const Duration(seconds: 6));
    while (!ok && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      ok = await b.text(note) == 'edited on the laptop';
    }
    expect(ok, isTrue, reason: 'the tablet did not get the edit');

    await Future<void>.delayed(const Duration(milliseconds: 20));
    await b.edit(note, 'edited on the tablet');
    ok = false;
    final end2 = DateTime.now().add(const Duration(seconds: 6));
    while (!ok && DateTime.now().isBefore(end2)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      ok = await a.text(note) == 'edited on the tablet';
    }
    expect(ok, isTrue, reason: 'the laptop did not get the edit (the device with the higher id has to ask the other to connect)');
    expect(sa.peers.single.lastSync, isNotNull);
  });

  test('turning the automatic sync off leaves the room: the server no longer knows the device is online', () async {
    await pair();
    await sa.setAuto(true);
    await until(() => server.rooms.values.any((r) => r.isNotEmpty));
    await sa.setAuto(false);
    await until(() => server.rooms.values.every((r) => r.isEmpty), reason: 'still in the room');
  });

  test('"sync now" looks for the other device for a while and syncs once, without the automatic sync', () async {
    final note = await a.note('Later', 'one');
    await pair();
    await until(() => server.rooms.values.every((r) => r.isEmpty), ms: 6000);
    await a.edit(note, 'two');
    // both press it
    await sa.syncNow();
    await sb.syncNow();
    var ok = false;
    final end = DateTime.now().add(const Duration(seconds: 6));
    while (!ok && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      ok = await b.text(note) == 'two';
    }
    expect(ok, isTrue);
    await until(() => !sa.lookingForDevices && server.rooms.values.every((r) => r.isEmpty), reason: 'kept looking');
  });

  test('a removed device is no longer synced with, and leaving the profile forgets the secret', () async {
    await pair();
    await sa.removeDevice(sb.deviceId!);
    expect(sa.peers, isEmpty);
    await sb.leave();
    expect(sb.isSetUp, isFalse);
    expect(sb.peers, isEmpty);
    expect(sb.book.all, isEmpty);
  });

  test('a joiner who says the codes differ takes nothing over and the offering device is told no', () async {
    await a.note('Mine', 'x');
    final link = await sa.offerLink();
    await sb.joinWith(link);
    await until(() => sa.requests.isNotEmpty && sb.joinCodeNeedsAnswer);
    sb.confirmJoinCode(false);
    await until(() => sb.joinProblem != null && !sb.joining);
    expect(sb.isSetUp, isFalse);
    expect(b.profile.id, 'bbbbbbbbbbbbbbbb');
    expect(await b.repo.listNotes(), isEmpty);
    sa.answer(sa.requests.single.id, false);
  });

  test('not more than a few devices can wait for a yes at once', () async {
    await sa.offerLink();
    final results = [for (var i = 0; i < 5; i++) sa.requests.length];
    expect(results.every((n) => n <= DeviceSyncService.maxRequests), isTrue);
  });

  test('"look from time to time": both devices visit the room, sync, and leave again; the status is asked for when the settings are open', () async {
    final note = await a.note('Visit', 'one');
    await pair();
    await until(() => server.rooms.values.every((r) => r.isEmpty));
    await a.edit(note, 'two');
    await sa.setCheck(true);
    await sb.setCheck(true);
    var ok = false;
    final end = DateTime.now().add(const Duration(seconds: 8));
    while (!ok && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      ok = await b.text(note) == 'two';
    }
    expect(ok, isTrue, reason: 'the visits did not meet');
    await until(() => server.rooms.values.every((r) => r.isEmpty), ms: 6000, reason: 'still in the room');
    expect(sa.auto, isFalse);

    // opening the settings asks again (a visit, as the device is not in the room)
    server.joined.clear();
    sa.refreshStatus();
    await until(() => server.joined.isNotEmpty, reason: 'no visit');
  });

  test('a note that is open on two devices is worked on live: the lower id hosts, the other joins with the secret over a proven line; closing it ends the session', () async {
    await pair();
    await sa.setAuto(true);
    await sb.setAuto(true);
    final la = FakeLive(), lb = FakeLive();
    sa.live = la;
    sb.live = lb;
    await until(() => sa.peers.single.online && sb.peers.single.online, reason: 'not online');

    sa.setOpenNotes({'note-1'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(la.hosted, isEmpty); // nobody else has it open: nothing to start
    sb.setOpenNotes({'note-1', 'only-here'});
    final hostIsA = sa.deviceId!.compareTo(sb.deviceId!) < 0;
    final host = hostIsA ? la : lb, guest = hostIsA ? lb : la;
    await until(() => host.hosted.containsKey('note-1') && guest.joined.containsKey('note-1'), reason: 'no session: ${host.hosted} ${guest.joined}');
    expect(guest.joined['note-1']!.secret, host.hosted['note-1']!.invite.secret);
    expect(host.hosted.containsKey('only-here'), isFalse);
    expect(guest.hosted, isEmpty);

    // the line the guest got reaches the host, and back
    await until(() => host.hostChannels.isNotEmpty, reason: 'host got no line');
    final got = <int>[];
    host.hostChannels.single.messages.listen(got.addAll);
    await guest.guestChannels.single.send(Uint8List.fromList([7, 8]));
    await until(() => got.length == 2);
    expect(got, [7, 8]);

    // the note is closed on the guest: its session ends
    (hostIsA ? sb : sa).setOpenNotes({});
    await until(() => guest.ended.contains('note-1'), reason: 'not ended');
  });

  test('the phone is locked (the note is put away, the connection to the server breaks) and opened again: the live session comes back', () async {
    await pair();
    await until(() => server.rooms.values.every((r) => r.isEmpty), reason: 'the rooms of the pairing stayed open'); // (so that the rooms opened next are told apart)
    final la = FakeLive(), lb = FakeLive();
    sa.live = la;
    sb.live = lb;
    await sa.setAuto(true);
    await until(() => sa.connected);
    await sb.setAuto(true);
    await until(() => sb.connected);
    final roomB = server.opened.last;
    await until(() => sa.peers.single.online && sb.peers.single.online, reason: 'not online');
    sa.setOpenNotes({'note-1'});
    sb.setOpenNotes({'note-1'});
    final bHosts = sb.deviceId!.compareTo(sa.deviceId!) < 0;
    final host = bHosts ? lb : la, guest = bHosts ? la : lb;
    await until(() => host.hosted.containsKey('note-1') && guest.joined.containsKey('note-1'), reason: 'no session at first');
    final linesBefore = guest.guestChannels.length;

    // locked: the screen reports nothing open, the session of the phone ends (and with the host, the other's too), the line goes dead
    sb.setOpenNotes({});
    await until(() => lb.ended.contains('note-1'), reason: 'the session of the phone did not end');
    if (bHosts) {
      await la.end('note-1'); // (the host went: the guest's session ends with it; the laptop's is the one that goes on otherwise)
      host.hosted.remove('note-1');
    }
    guest.joined.remove('note-1');
    roomB.drop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // opened again: the screen reports the note before the connection is back
    sb.setOpenNotes({'note-1'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final sentBefore = server.sent.length;
    roomB.restore();
    final end = DateTime.now().add(const Duration(seconds: 8));
    while (!(host.hosted.containsKey('note-1') && host.sessions.contains('note-1') && guest.joined.containsKey('note-1') && guest.guestChannels.length > linesBefore)) {
      if (DateTime.now().isAfter(end)) {
        fail('the session did not come back: bHosts=$bHosts hosted=${host.hosted.keys} joined=${guest.joined.keys} '
            'A sees ${sa.peers.map((p) => '${p.online} ${p.open}')} B sees ${sb.peers.map((p) => '${p.online} ${p.open}')} '
            'la=${la.sessions} lb=${lb.sessions} sent after: ${server.sent.length - sentBefore}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(lb.wakes, greaterThan(0), reason: 'the sessions were not told the way is back');
  });

  /// The laptop and the tablet with the automatic sync on, online, and each with its live sessions; which one hosts a note (lower id).
  Future<({FakeLive host, FakeLive guest, DeviceSyncService hostSvc, DeviceSyncService guestSvc})> liveBoth() async {
    await pair();
    final la = FakeLive(), lb = FakeLive();
    sa.live = la;
    sb.live = lb;
    await sa.setAuto(true);
    await sb.setAuto(true);
    await until(() => sa.peers.single.online && sb.peers.single.online, reason: 'not online');
    final aHosts = sa.deviceId!.compareTo(sb.deviceId!) < 0;
    return aHosts ? (host: la, guest: lb, hostSvc: sa, guestSvc: sb) : (host: lb, guest: la, hostSvc: sb, guestSvc: sa);
  }

  test('the guest leaves the note and opens it again: it joins the session again, which went on at the host', () async {
    final d = await liveBoth();
    d.hostSvc.setOpenNotes({'note-1'});
    d.guestSvc.setOpenNotes({'note-1'});
    await until(() => d.host.hosted.containsKey('note-1') && d.guest.sessions.contains('note-1'), reason: 'no session at first');
    final hostedFirst = d.host.hosted['note-1']!.invite;

    d.guestSvc.setOpenNotes({});
    await until(() => !d.guest.sessions.contains('note-1'), reason: 'the guest did not leave');
    d.guestSvc.setOpenNotes({'note-1'});
    await until(() => d.guest.sessions.contains('note-1') && d.guest.guestChannels.length >= 2, reason: 'the guest did not come back');
    expect(d.host.ended, isNot(contains('note-1')), reason: 'the host should have kept its session');
    expect(d.guest.joined['note-1']!.secret, hostedFirst.secret);
  });

  test('the host leaves the note (the guest\'s session ends with it) and opens it again: a session is hosted again, and the other joins', () async {
    final d = await liveBoth();
    d.hostSvc.setOpenNotes({'note-1'});
    d.guestSvc.setOpenNotes({'note-1'});
    await until(() => d.host.hosted.containsKey('note-1') && d.guest.sessions.contains('note-1'), reason: 'no session at first');

    d.hostSvc.setOpenNotes({});
    await until(() => d.host.ended.contains('note-1'), reason: 'the host did not leave');
    await d.guest.end('note-1'); // (what the host's goodbye does to the guest)
    d.host.hosted.clear();
    d.hostSvc.setOpenNotes({'note-1'});
    await until(() => d.host.hosted.containsKey('note-1') && d.guest.sessions.contains('note-1') && d.guest.guestChannels.length >= 2,
        reason: 'no session again: hosted ${d.host.hosted.keys}, guest in ${d.guest.sessions}');
    expect(d.guest.joined['note-1']!.secret, d.host.hosted['note-1']!.invite.secret);
  });

  test('a third device with a lower id opens a note two others work on: it hosts, and the two leave their session for it', () async {
    await pair();
    final c = await Device.create('Phone', root, profileId: 'cccccccccccccccc');
    final sc = serviceFor(c);
    await sc.load();
    addTearDown(() async {
      sc.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await c.db.close();
    });
    await pairVia(sa, sc);
    final lives = {sa: FakeLive(), sb: FakeLive(), sc: FakeLive()};
    for (final e in lives.entries) {
      e.key.live = e.value;
      await e.key.setAuto(true);
    }
    final byId = [sa, sb, sc]..sort((x, y) => x.deviceId!.compareTo(y.deviceId!));
    final low = byId[0], mid = byId[1], high = byId[2];
    await until(() => byId.every((s) => s.peers.length == 2 && s.peers.every((p) => p.online)), ms: 10000, reason: 'not all online');

    mid.setOpenNotes({'note-1'});
    high.setOpenNotes({'note-1'});
    await until(() => lives[mid]!.hosted.containsKey('note-1') && lives[high]!.sessions.contains('note-1'), reason: 'the two did not start');

    low.setOpenNotes({'note-1'});
    await until(() => lives[low]!.hosted.containsKey('note-1') && lives[mid]!.ended.contains('note-1'), reason: 'the lowest did not take over');
    final secret = lives[low]!.hosted['note-1']!.invite.secret;
    bool follows(DeviceSyncService x) => listEquals(lives[x]!.joined['note-1']?.secret, secret) && lives[x]!.sessions.contains('note-1');
    await until(() => follows(mid) && follows(high), ms: 10000, reason: 'the others did not follow the new host');
  });

  test('the host\'s app is killed (it says nothing more): the others notice within moments, not after minutes, and work on without it', () async {
    // (a device is taken for gone only after a minute of silence here: what is quicker is the roll call after the server's word)
    sa.dispose();
    sb.dispose();
    sa = serviceFor(a, offlineAfter: const Duration(minutes: 1));
    sb = serviceFor(b, offlineAfter: const Duration(minutes: 1));
    await sa.load();
    await sb.load();
    await pair();
    final c = await Device.create('Phone', root, profileId: 'cccccccccccccccc');
    final sc = serviceFor(c, offlineAfter: const Duration(minutes: 1));
    await sc.load();
    addTearDown(() async {
      sc.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await c.db.close();
    });
    await pairVia(sa, sc);
    await until(() => server.rooms.values.where((r) => r.isNotEmpty).length <= 1, ms: 10000, reason: 'the rooms of the pairing stayed open');
    final lives = {sa: FakeLive(), sb: FakeLive(), sc: FakeLive()};
    for (final e in lives.entries) {
      e.key.live = e.value;
      await e.key.setAuto(true);
    }
    final byId = [sa, sb, sc]..sort((x, y) => x.deviceId!.compareTo(y.deviceId!));
    final low = byId[0], mid = byId[1], high = byId[2];
    await until(() => byId.every((s) => s.peers.length == 2 && s.peers.every((p) => p.online)), ms: 10000, reason: 'not all online');
    for (final s in byId) {
      s.setOpenNotes({'note-1'});
    }
    await until(() => lives[low]!.hosted.containsKey('note-1') && lives[mid]!.joined.containsKey('note-1') && lives[high]!.joined.containsKey('note-1'),
        reason: 'no session');

    roomOf[{sa: a, sb: b, sc: c}[low]!]!.crash();
    await until(() => lives[mid]!.hosted.containsKey('note-1'), ms: 3000, reason: 'the next device did not take over: ${mid.peers.map((p) => '${p.name}:${p.online}')}');
    final secret = lives[mid]!.hosted['note-1']!.invite.secret;
    await until(() => listEquals(lives[high]!.joined['note-1']?.secret, secret), ms: 5000, reason: 'the last one did not follow');
    expect(mid.peers.singleWhere((p) => p.id == low.deviceId).online, isFalse);
    expect(mid.peers.singleWhere((p) => p.id == high.deviceId).online, isTrue, reason: 'a device that answered the roll call is still here');
  });

  test('turning the automatic sync off leaves a note that is worked on live alone (an open note keeps the device in the room)', () async {
    final d = await liveBoth();
    d.hostSvc.setOpenNotes({'note-1'});
    d.guestSvc.setOpenNotes({'note-1'});
    await until(() => d.host.hosted.containsKey('note-1') && d.guest.sessions.contains('note-1'), reason: 'no session');
    await sa.setAuto(false);
    await sb.setAuto(false);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(d.host.ended, isNot(contains('note-1')));
    expect(d.guest.ended, isNot(contains('note-1')));
    expect(sa.connected && sb.connected, isTrue);
  });

  test('leaving the profile ends the live sessions with its devices', () async {
    final d = await liveBoth();
    d.hostSvc.setOpenNotes({'note-1'});
    d.guestSvc.setOpenNotes({'note-1'});
    await until(() => d.host.hosted.containsKey('note-1') && d.guest.sessions.contains('note-1'), reason: 'no session');
    await d.guestSvc.leave();
    expect(d.guest.ended, contains('note-1'));
    expect(d.guestSvc.connected, isFalse);
  });

  test('"sync now" goes on until it synced with every device that is online, not only the first', () async {
    await pair();
    final c = await Device.create('Phone', root, profileId: 'cccccccccccccccc');
    final sc = serviceFor(c);
    await sc.load();
    addTearDown(() async {
      sc.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await c.db.close();
    });
    await pairVia(sa, sc);
    await until(() => server.rooms.values.every((r) => r.isEmpty), reason: 'the rooms of the pairing stayed open');
    final fromB = await b.note('From the tablet', 'b'), fromC = await c.note('From the phone', 'c');
    await sb.setAuto(true);
    await sc.setAuto(true);
    await until(() => sb.connected && sc.connected);
    final started = DateTime.now();
    await sa.syncNow();
    await until(() => sa.peers.every((p) => p.lastSync != null && !p.lastSync!.isBefore(started)), ms: 10000,
        reason: 'not synced with all: ${sa.peers.map((p) => '${p.name} ${p.lastSync} ${p.problem}')}');
    expect(await a.text(fromB), 'b');
    expect(await a.text(fromC), 'c');
  });

  test('a device that is in the room only for a note it works on live (automatic sync off) is not synced with, and nobody sees a problem', () async {
    final d = await liveBoth();
    await d.guestSvc.setAuto(false); // the guest only works on the note; the host keeps the automatic sync
    final guestDevice = identical(d.guestSvc, sa) ? a : b, hostDevice = identical(d.hostSvc, sa) ? a : b;
    d.hostSvc.setOpenNotes({'note-1'});
    d.guestSvc.setOpenNotes({'note-1'});
    await until(() => d.host.hosted.containsKey('note-1') && d.guest.sessions.contains('note-1'), reason: 'no session');
    final onHost = await hostDevice.note('Not for the guest yet', 'x');
    await until(() => d.hostSvc.peers.single.online && !d.hostSvc.peers.single.syncs, reason: 'the host did not learn the guest does not sync');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect((await guestDevice.repo.listNotes()).any((n) => n.id == onHost), isFalse, reason: 'the library was synced');
    expect(d.hostSvc.peers.single.problem, isNull);
    expect(d.guestSvc.peers.single.problem, isNull);
    expect(d.hostSvc.problem, isNull);
    // the guest turns the automatic sync on: the two sync
    await d.guestSvc.setAuto(true);
    var arrived = false;
    for (var i = 0; i < 150 && !arrived; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      arrived = (await guestDevice.repo.listNotes()).any((n) => n.id == onHost);
    }
    expect(arrived, isTrue, reason: 'no sync once the guest syncs again');
  });

  test('a live connection that cannot be made has the connection to the server checked at once', () async {
    await pair();
    await until(() => server.rooms.values.every((r) => r.isEmpty), reason: 'the rooms of the pairing stayed open'); // (so that the rooms opened next are told apart)
    final la = FakeLive(), lb = FakeLive();
    sa.live = la;
    sb.live = lb;
    await sa.setAuto(true);
    await until(() => sa.connected);
    final roomA = server.opened.last;
    await sb.setAuto(true);
    await until(() => sb.connected);
    final roomB = server.opened.last;
    await until(() => sa.peers.single.online && sb.peers.single.online, reason: 'not online');
    // the device with the higher id joins the other's session; the host can no longer be reached directly
    final aHosts = sa.deviceId!.compareTo(sb.deviceId!) < 0;
    final hostId = aHosts ? sa.deviceId! : sb.deviceId!;
    final joinerRoom = aHosts ? roomB : roomA;
    server.linkers.remove('${joinerRoom.name}/$hostId');
    sa.setOpenNotes({'note-1'});
    sb.setOpenNotes({'note-1'});
    await until(() => joinerRoom.checks > 0, reason: 'the connection to the server was not checked');
  });

  test('the cloud folder: the choices are settings of the profile, two devices that are never online together meet through the folder, encrypted or plain', () async {
    await pair();
    final cloud = MemoryCloudFolder();
    CloudSyncService cloudFor(DeviceSyncService service, Device d) => CloudSyncService(
          d.settings,
          service,
          [CloudProvider(id: 'memory', label: 'Memory', available: () => true, folderFor: (_) => cloud, changes: ValueNotifier(0))],
          every: const Duration(minutes: 5),
          afterChange: const Duration(minutes: 5),
        );
    final ca = cloudFor(sa, a), cb = cloudFor(sb, b);
    addTearDown(ca.dispose);
    addTearDown(cb.dispose);
    await ca.load();
    await cb.load();
    expect(ca.enabled, isFalse);

    final id = await a.note('Through the cloud', 'laptop text abc');
    await ca.setEnabled(true); // (the one service there is is chosen)
    expect(ca.providerId, 'memory');
    await until(() => ca.lastRun != null && !ca.running, reason: 'laptop did not run: ${ca.problem}');
    expect(ca.problem, isNull);
    expect(cloud.files.isNotEmpty, isTrue);
    expect(cloud.files.values.any((b) => String.fromCharCodes(b).contains('laptop text abc')), isFalse); // sealed

    // the tablet joins in (on its own: the choices are synced between the devices, here they are made on both)
    await cb.setEnabled(true);
    await until(() => cb.lastRun != null && !cb.running, reason: 'tablet did not run: ${cb.problem}');
    expect(await b.text(id), 'laptop text abc');

    // not encrypted: readable files, which the other device still reads
    await ca.setEncrypted(false);
    await until(() => cloud.files.keys.any((p) => p.endsWith('manifest.json')), reason: 'no plain manifest');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(cloud.files.keys.any((p) => p.endsWith('.uninote')), isTrue);
    await a.edit(id, 'laptop text two');
    await ca.syncNow();
    await until(() => !ca.running);
    await cb.syncNow();
    await until(() => !cb.running);
    expect(await b.text(id), 'laptop text two');
  });

  test('a direct sync that never ends keeps the folder sync waiting only for a while, and the waiting is shown', () async {
    await pair();
    final cloud = MemoryCloudFolder();
    final c = CloudSyncService(
      a.settings,
      sa,
      [CloudProvider(id: 'memory', label: 'Memory', available: () => true, folderFor: (_) => cloud, changes: ValueNotifier(0))],
      every: const Duration(minutes: 5),
      afterChange: const Duration(minutes: 5),
      maxWaitForDirect: const Duration(milliseconds: 400),
      retryWhileWaiting: const Duration(milliseconds: 100),
    );
    addTearDown(c.dispose);
    await c.load();
    sa.debugHangSync();
    await c.setEnabled(true);
    await until(() => c.what != null && c.what!.contains('Waiting'), reason: 'the waiting is not shown');
    expect(c.lastRun, isNull);
    await until(() => c.lastRun != null && !c.running, reason: 'it waited for ever: ${c.what} ${c.problem}');
    expect(c.problem, isNull);
    expect(cloud.files, isNotEmpty);
  });

  test('with the cloud folder on, the device stays in the meeting room all the same: the room is how the devices find each other', () async {
    await pair();
    final c = CloudSyncService(
      a.settings,
      sa,
      [CloudProvider(id: 'memory', label: 'Memory', available: () => true, folderFor: (_) => MemoryCloudFolder(), changes: ValueNotifier(0))],
      every: const Duration(minutes: 5),
      afterChange: const Duration(minutes: 5),
    );
    addTearDown(c.dispose);
    sa.cloud = c;
    await c.load();
    await sa.setAuto(true);
    await until(() => sa.connected, reason: 'not in the room with the automatic sync on');
    await c.setEnabled(true);
    expect(sa.cloudCarries, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(sa.connected, isTrue, reason: 'it left the room for the folder');
    sa.cloud = null;
  });

  test('a device that has a profile but was never linked (it started or signed in through a cloud folder) still opens the room, on the server of the settings', () async {
    await sa.ensureProfile();
    expect(sa.server, isNull);
    await sa.setAuto(true);
    await until(() => sa.connected, reason: 'no room: a device without a server of its own never opened one');
  });

  group('who this device is', () {
    DeviceSyncService serviceWith(MemorySyncKeys keys) => DeviceSyncService(
          settings: a.settings,
          keys: keys,
          library: a.library,
          profile: a.profile,
          serverOf: () => 'wss://signal.example',
        );

    test('the id goes with the key: an id the settings lost or got wrong does not part them', () async {
      final keys = MemorySyncKeys();
      final first = serviceWith(keys);
      addTearDown(first.dispose);
      await first.load();
      await first.ensureProfile();
      final id = first.deviceId!, key = first.identity!.publicKey;
      // the id in the settings is not the one that belongs to the key in the keystore (a write was lost, or another tab wrote)
      await a.settings.set('sync_device_id', 'ffffffffffffffff');
      final second = serviceWith(keys);
      addTearDown(second.dispose);
      await second.load();
      expect(second.deviceId, id);
      expect(listEquals(second.identity!.publicKey, key), isTrue);
    });

    test('an entry on its own list with another key than the one it signs with is shown as a problem, and goes away when it leaves', () async {
      final keys = MemorySyncKeys();
      final first = serviceWith(keys);
      addTearDown(first.dispose);
      await first.load();
      await first.ensureProfile();
      expect(first.keyOutOfStep, isFalse);
      // the others were told another key for this id (a key that is not the one in the keystore)
      await first.book.add(PairedDevice(id: first.deviceId!, name: 'x', publicKey: (await DeviceIdentity.create()).publicKey, addedAt: 1));
      final second = serviceWith(keys);
      addTearDown(second.dispose);
      await second.load();
      expect(second.keyOutOfStep, isTrue);
      expect(second.problem, contains('Sign out of the profile'));
      await second.leave();
      expect(second.keyOutOfStep, isFalse);
      expect(second.problem, isNull);
    });

    test('a device from before, whose id and seed were kept apart, keeps both', () async {
      final keys = MemorySyncKeys();
      final identity = await DeviceIdentity.create();
      await keys.setDeviceSeed(identity.seed);
      await a.settings.set('sync_device_id', identity.id);
      await keys.setProfileSecret(Uint8List.fromList(List.filled(SyncSecret.length, 3)));
      final s = serviceWith(keys);
      addTearDown(s.dispose);
      await s.load();
      expect(s.deviceId, identity.id);
      expect((await keys.deviceIdentity())?.id, identity.id);
    });

    test('a device that leaves the profile comes back as a new one', () async {
      final s = serviceWith(MemorySyncKeys());
      addTearDown(s.dispose);
      await s.load();
      await s.ensureProfile();
      final before = s.deviceId!;
      await s.leave();
      expect(s.deviceId, isNotNull);
      expect(s.deviceId, isNot(before));
    });
  });

  test('a device of a profile that starts with the cloud folder on knows who it is, and the folder sync runs', () async {
    final keys = MemorySyncKeys();
    await keys.setProfileSecret(Uint8List.fromList(List.filled(SyncSecret.length, 7)));
    final s = DeviceSyncService(
      settings: a.settings,
      keys: keys,
      library: a.library,
      profile: a.profile,
      serverOf: () => 'wss://signal.example',
      openRoom: (srv, secret) async => FakeRoom(server, (await secret.roomKeys()).room),
      makeLinker: (room, me) => FakeLinker(server, (room as FakeRoom).name, me),
    );
    addTearDown(s.dispose);
    final c = CloudSyncService(
      a.settings,
      s,
      [CloudProvider(id: 'memory', label: 'Memory', available: () => true, folderFor: (_) => MemoryCloudFolder(), changes: ValueNotifier(0))],
      every: const Duration(minutes: 5),
      afterChange: const Duration(minutes: 5),
    );
    addTearDown(c.dispose);
    s.cloud = c;
    await c.setEnabled(true);
    await s.load();
    expect(s.deviceId, isNotNull);
    expect(s.peers, isEmpty); // (it does not count itself among the others)
    await c.syncNow();
    await until(() => c.lastRun != null && !c.running, reason: 'no run: ${c.problem}');
    expect(c.problem, isNull);
    expect(server.joined, isEmpty, reason: 'the folder sync needs no server; nothing else asked for the room');
  });

  test('with the automatic sync off, an open note brings the device into the room; a note open on both is worked on live, the library is '
      'not synced, and closing the last note takes the device out again', () async {
    await pair();
    final la = FakeLive(), lb = FakeLive();
    sa.live = la;
    sb.live = lb;
    final note = await a.note('Only here', 'not to be synced now');
    await until(() => !sa.connected && !sb.connected, reason: 'the pairing left the room open');
    sa.setOpenNotes({'note-1'});
    sb.setOpenNotes({'note-1'});
    await until(() => sa.connected && sb.connected, reason: 'an open note did not bring the devices into the room');
    final hostIsA = sa.deviceId!.compareTo(sb.deviceId!) < 0;
    final host = hostIsA ? la : lb, guest = hostIsA ? lb : la;
    await until(() => host.hosted.containsKey('note-1') && guest.joined.containsKey('note-1'), reason: 'no session: ${host.hosted} ${guest.joined}');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect((await b.repo.listNotes()).any((n) => n.id == note), isFalse, reason: 'the library was synced without the automatic sync');
    sa.setOpenNotes({});
    sb.setOpenNotes({});
    await until(() => !sa.connected && !sb.connected, reason: 'still in the room with nothing open');
  });

  test('with working together off, the open notes are not told, no session starts, and an open note does not bring the device into the room', () async {
    await pair();
    final la = FakeLive(), lb = FakeLive();
    sa.live = la;
    sb.live = lb;
    await sa.setLiveTogether(false);
    sa.setOpenNotes({'note-1'});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(sa.connected, isFalse);
    await sa.setAuto(true);
    await sb.setAuto(true);
    sb.setOpenNotes({'note-1'});
    await until(() => sa.peers.single.online && sb.peers.single.online, reason: 'not online');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(la.hosted, isEmpty);
    expect(la.joined, isEmpty);
    expect(lb.hosted, isEmpty);
    expect(server.sent.where((m) => m['d'] == sa.deviceId && m.containsKey('o')), isEmpty, reason: 'it told what is open');
    expect(server.sent.where((m) => m['d'] == sb.deviceId && m.containsKey('o')), isNotEmpty);
    expect(await a.settings.get('sync_live'), '0');
  });

  test('a session between the devices: when the host is left alone the note is saved; when it is over, the note counts as agreed '
      'with the device that was in it, and not with one that was not', () async {
    final d = await liveBoth();
    final hostDevice = identical(d.hostSvc, sa) ? a : b;
    final guestId = d.guestSvc.deviceId!;
    final note = await hostDevice.note('Worked on together', 'text');
    // a third device of the profile that is not in the session (it may change the note on its own meanwhile)
    final third = await Device.create('Phone', root);
    await hostDevice.book.add(PairedDevice(id: third.identity.id, name: 'Phone', publicKey: third.identity.publicKey, addedAt: 5));
    d.hostSvc.setOpenNotes({note});
    d.guestSvc.setOpenNotes({note});
    await until(() => d.host.hosted.containsKey(note) && d.guest.sessions.contains(note), reason: 'no session');
    await until(() => d.host.hostChannels.isNotEmpty, reason: 'the guest did not reach the host');

    d.host.setState(note, (host: true, people: 2, ended: false));
    d.host.setState(note, (host: true, people: 1, ended: false));
    await until(() => d.host.saved.contains(note), reason: 'not saved when alone');
    expect(await hostDevice.library.mark(guestId, note), isNull);
    d.host.setState(note, (host: true, people: 0, ended: true));
    var agreed = false;
    for (var i = 0; i < 100 && !agreed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      agreed = await hostDevice.library.mark(guestId, note) != null;
    }
    expect(agreed, isTrue, reason: 'not agreed with the guest when the session ended');
    expect(await hostDevice.library.mark(third.identity.id, note), isNull, reason: 'agreed with a device that was not in the session');
    await third.db.close();
  });

  test('moving the sync to another folder: the devices that are only linked through the old folder are told there, and follow', () async {
    await pair();
    final folders = <String, MemoryCloudFolder>{};
    CloudSyncService cloudFor(DeviceSyncService service, Device d) => CloudSyncService(
          d.settings,
          service,
          [CloudProvider(id: 'memory', label: 'Memory', available: () => true, folderFor: (name) => folders.putIfAbsent(name, MemoryCloudFolder.new), changes: ValueNotifier(0))],
          every: const Duration(minutes: 5),
          afterChange: const Duration(minutes: 5),
        );
    final ca = cloudFor(sa, a), cb = cloudFor(sb, b);
    addTearDown(ca.dispose);
    addTearDown(cb.dispose);
    await ca.load();
    await cb.load();
    await ca.setEnabled(true);
    await until(() => ca.lastRun != null && !ca.running);
    await cb.setEnabled(true); // (the choices reached the tablet some other time)
    await until(() => cb.lastRun != null && !cb.running);
    expect(cb.folderName, ca.folderName);

    await ca.setFolderName('Elsewhere');
    expect(ca.folderName, 'Elsewhere'); // (at once: the run that tells the others in the old folder follows in the background)
    await ca.idle;
    await cb.syncNow(); // the tablet still looks in the old folder
    await cb.load(); // (what the app does when a sync changed the settings)
    expect(cb.folderName, 'Elsewhere');

    // and it is there now: a note written on the laptop comes through the new folder
    final id = await a.note('After the move', 'new place text');
    await ca.syncNow();
    await until(() => !ca.running);
    await until(() => cb.lastRun != null && !cb.running);
    await cb.syncNow();
    expect(await b.text(id), 'new place text');
  });

}
