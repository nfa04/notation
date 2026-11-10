import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/cloud_sync_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/device_sync_service.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_link.dart';

import '../devicesync/fakes.dart';
import '../devicesync/harness.dart';
import 'memory_cloud_folder.dart';

/// The sync through a cloud folder as the person uses it: switching it on and off, moving it, and how it gets along with the
/// direct sync between the devices and the signalling server.
void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late FakeServer server;
  late Device a, b;
  late DeviceSyncService sa, sb;
  late CloudSyncService ca, cb;

  /// The folders of the service, by name: each name is a folder of its own.
  final folders = <String, MemoryCloudFolder>{};
  MemoryCloudFolder folder(String name) => folders.putIfAbsent(name, MemoryCloudFolder.new);
  final otherFolders = <String, MemoryCloudFolder>{};

  late ValueNotifier<bool> accountA, accountB;

  DeviceSyncService serviceFor(Device d, void Function() settingsChanged) => DeviceSyncService(
        settings: d.settings,
        keys: MemorySyncKeys(),
        library: d.library,
        profile: d.profile,
        serverOf: () => 'wss://signal.example',
        changes: d.repo.changes,
        onSettingsChanged: settingsChanged,
        openRoom: (srv, secret) async => FakeRoom(server, (await secret.roomKeys()).room),
        makeLinker: (room, me) => FakeLinker(server, (room as FakeRoom).name, me),
        heartbeat: const Duration(milliseconds: 300),
        offlineAfter: const Duration(milliseconds: 900),
        changeDelay: const Duration(milliseconds: 150),
        manualFor: const Duration(seconds: 3),
        checkEvery: const Duration(seconds: 30),
        checkFor: const Duration(milliseconds: 1200),
      );

  CloudSyncService cloudFor(Device d, DeviceSyncService s, ValueNotifier<bool> account, {Duration every = const Duration(minutes: 5), Duration lookEvery = const Duration(minutes: 10)}) => CloudSyncService(
        d.settings,
        s,
        [
          CloudProvider(id: 'memory', label: 'Memory', available: () => account.value, folderFor: folder, changes: account),
          CloudProvider(id: 'other', label: 'Other', available: () => true, folderFor: (n) => otherFolders.putIfAbsent(n, MemoryCloudFolder.new), changes: ValueNotifier(0)),
        ],
        changes: d.repo.changes,
        every: every,
        afterChange: const Duration(milliseconds: 200),
        retryDelays: const [],
        lookEvery: lookEvery,
      );

  Future<void> until(bool Function() ok, {int ms = 4000, String? reason}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail(reason ?? 'timed out');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cloudsvc_');
    server = FakeServer();
    folders.clear();
    otherFolders.clear();
    accountA = ValueNotifier(true);
    accountB = ValueNotifier(true);
    a = await Device.create('Laptop', root, profileId: 'aaaaaaaaaaaaaaaa');
    b = await Device.create('Tablet', root, profileId: 'bbbbbbbbbbbbbbbb');
    // (as in the app: a sync that changed settings has the cloud read its choices again)
    sa = serviceFor(a, () => unawaited(ca.load()));
    sb = serviceFor(b, () => unawaited(cb.load()));
    ca = cloudFor(a, sa, accountA);
    cb = cloudFor(b, sb, accountB);
    sa.cloud = ca;
    sb.cloud = cb;
    await sa.load();
    await sb.load();
    await ca.load();
    await cb.load();
    // the tablet joins the laptop's profile, the way the person does it
    final link = await sa.offerLink();
    await sb.joinWith(SyncLink.parse(link.toLink())!);
    await until(() => sa.requests.isNotEmpty && sb.joinCodeNeedsAnswer, reason: 'no request/code');
    sb.confirmJoinCode(true);
    sa.answer(sa.requests.single.id, true);
    await until(() => sb.joined && sb.isSetUp, reason: 'not joined');
    await until(() => sa.activeSyncs == 0 && sb.activeSyncs == 0 && !sa.connected && !sb.connected, ms: 20000, reason: 'the pairing did not settle');
  });

  tearDown(() async {
    folders.values.followedBy(otherFolders.values).forEach((f) => f.hold?.complete());
    ca.dispose();
    cb.dispose();
    sa.dispose();
    sb.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await a.db.close();
    await b.db.close();
    await root.delete(recursive: true);
  });

  /// Both devices sync through the folder, and each has run once.
  Future<void> bothOn() async {
    await ca.setEnabled(true);
    await ca.idle;
    await cb.load(); // (the choice is a setting of the profile; here the tablet hears of it at once)
    if (!cb.enabled) await cb.setEnabled(true);
    await cb.syncNow();
    await cb.idle;
    expect(ca.problem, isNull);
    expect(cb.problem, isNull);
  }

  group('opening a note', () {
    test('a newer copy from the other device is taken in, also when a run is under way as the note is opened', () async {
      await bothOn();
      final id = await a.note('Shared', 'first');
      await ca.syncNow();
      await ca.idle;
      await cb.syncNow();
      await cb.idle;
      expect(await b.text(id), 'first');

      // the laptop changes the note while the tablet is away
      await a.edit(id, 'changed on the laptop');
      await ca.syncNow();
      await ca.idle;

      // the tablet comes back: a run starts, and the note is opened meanwhile (so the run leaves it alone)
      b.busy = {id};
      final f = folder(CloudSyncService.defaultFolder);
      f.hold = Completer<void>();
      unawaited(cb.syncNow());
      await until(() => cb.running);
      final pulled = cb.refreshNote(id);
      f.hold!.complete();
      f.hold = null;
      expect(await pulled.timeout(const Duration(seconds: 4)), isTrue, reason: 'the look gave up because a run was on');
      expect(await b.text(id), 'changed on the laptop');
    });
  });

  group('quick runs', () {
    MemoryCloudFolder shared() => folder(CloudSyncService.defaultFolder);

    /// Both devices have the note [id] and have each looked at what the other published.
    Future<String> settled() async {
      await bothOn();
      final id = await a.note('Shared', 'first');
      await ca.syncNow();
      await ca.idle;
      await cb.syncNow();
      await cb.idle;
      await ca.syncNow();
      await ca.idle;
      await Future<void>.delayed(const Duration(milliseconds: 700)); // (the runs that the saves above started)
      await ca.idle;
      await cb.idle;
      return id;
    }

    test('when no other device published anything, a quick run asks one question and reads nothing', () async {
      await settled();
      final f = shared();
      f.calls = 0;
      await ca.syncNow(quick: true);
      expect(f.calls, 1, reason: 'the stamps of the folder');
      expect(ca.problem, isNull);
    });

    test('"Sync now" reads the other devices whatever the stamps say', () async {
      await settled();
      final f = shared();
      f.calls = 0;
      await ca.syncNow();
      expect(f.calls, greaterThan(1));
    });

    test('a quick run takes in what the other device published since', () async {
      final id = await settled();
      await b.edit(id, 'changed on the tablet');
      await cb.syncNow();
      await cb.idle;
      await ca.syncNow(quick: true);
      expect(await a.text(id), 'changed on the tablet');
    });

    test('every device is read again after the time that a look counts for', () async {
      ca.dispose();
      ca = cloudFor(a, sa, accountA, lookEvery: Duration.zero);
      sa.cloud = ca;
      await ca.load();
      final id = await settled();
      final f = shared();
      f.calls = 0;
      await ca.syncNow(quick: true);
      expect(f.calls, greaterThan(1), reason: 'the look was too old to count');
      expect(await a.text(id), 'first');
    });

    test('a note that was open when the run looked is taken at the next quick run, though nothing was published meanwhile', () async {
      final id = await settled();
      await a.edit(id, 'changed on the laptop');
      await ca.syncNow();
      await ca.idle;
      b.busy = {id};
      await cb.syncNow(quick: true);
      expect(await b.text(id), 'first', reason: 'an open note is left alone');
      b.busy = {};
      await cb.syncNow(quick: true);
      expect(await b.text(id), 'changed on the laptop');
    });

    test('opening notes one after the other does not read the other devices\' manifests again each time', () async {
      final id = await settled();
      final f = shared();
      await ca.refreshNote(id);
      f.calls = 0;
      await ca.refreshNote(id);
      await ca.refreshNote(id);
      expect(f.calls, 0, reason: 'what was read a moment ago, and the stamps of it, are used again');
    });

    test('"Sync now" after that reads what is up there now, not what was kept', () async {
      final id = await settled();
      await ca.refreshNote(id);
      await b.edit(id, 'changed on the tablet');
      await cb.syncNow();
      await cb.idle;
      await ca.syncNow();
      expect(await a.text(id), 'changed on the tablet');
    });

    test('a service that cannot say what changed is asked everything, as before', () async {
      await settled();
      final f = shared();
      f.canStamp = false;
      f.calls = 0;
      await ca.syncNow(quick: true);
      expect(f.calls, greaterThan(1));
    });
  });

  group('changes that are not a save', () {
    /// Both devices sync; a note and a folder exist everywhere; nothing is going on.
    Future<(String, String)> quiet() async {
      await bothOn();
      final note = await a.note('Shared', 'first');
      final folder = await a.repo.createFolder('Uni');
      await ca.syncNow();
      await ca.idle;
      await cb.syncNow();
      await cb.idle;
      await Future<void>.delayed(const Duration(milliseconds: 700)); // (the runs that the saves above started)
      await ca.idle;
      return (note, folder);
    }

    final actions = <String, Future<void> Function(Device d, String note, String folder)>{
      'deleting a note': (d, n, f) => d.repo.deleteNote(n),
      'putting a note in the trash': (d, n, f) => d.repo.trashNote(n),
      'moving a note to a folder': (d, n, f) => d.repo.moveNote(n, f),
      'starring a note': (d, n, f) => d.repo.setFavorite(n, true),
      'making a folder': (d, n, f) => d.repo.createFolder('Another'),
      'renaming a folder': (d, n, f) => d.repo.renameFolder(f, 'Renamed'),
      'deleting a folder': (d, n, f) => d.repo.deleteFolder(f),
    };
    for (final e in actions.entries) {
      test('${e.key} starts a sync by itself, as a save does', () async {
        final (note, folder) = await quiet();
        final last = ca.lastRun;
        await e.value(a, note, folder);
        await until(() => ca.lastRun != last && !ca.running, reason: 'no sync started after ${e.key}');
      });
    }

    test('restoring a note from the trash starts a sync by itself', () async {
      final (note, _) = await quiet();
      await a.repo.trashNote(note);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await ca.idle;
      final last = ca.lastRun;
      await a.repo.restoreNote(note);
      await until(() => ca.lastRun != last && !ca.running, reason: 'no sync started after restoring');
    });

    test('a deletion reaches the other device without anyone pressing "Sync now" on the first', () async {
      final (note, _) = await quiet();
      await a.repo.deleteNote(note);
      await until(() => !ca.running && folder(CloudSyncService.defaultFolder).files.isNotEmpty && ca.lastRun != null);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await ca.idle;
      await cb.syncNow();
      await cb.idle;
      expect((await b.repo.listNotes()).any((n) => n.id == note), isFalse);
    });

    test('what a sync itself deletes does not start another sync', () async {
      final (note, _) = await quiet();
      await a.repo.deleteNote(note);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await ca.idle;
      await cb.syncNow(); // the tablet deletes it
      await cb.idle;
      expect((await b.repo.listNotes()).any((n) => n.id == note), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final last = cb.lastRun;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(cb.lastRun, last, reason: 'no sync of its own after it took the deletion in');
    });
  });

  group('switching it off', () {
    test('takes effect at once, even while a slow run is under way; the run that tells the others follows it', () async {
      await bothOn();
      final f = folder(CloudSyncService.defaultFolder);
      f.hold = Completer<void>();
      unawaited(ca.syncNow());
      await until(() => ca.running);
      await ca.setEnabled(false).timeout(const Duration(seconds: 1), onTimeout: () => fail('the switch waited for the run'));
      expect(ca.enabled, isFalse);
      expect(await a.settings.get(CloudSyncService.kOn), '0');
      f.hold!.complete();
      f.hold = null;
      await ca.idle;
      expect(ca.enabled, isFalse); // (its own runs do not turn it on again)
      expect(await a.settings.get(CloudSyncService.kOn), '0');
    });

    test('the other device hears of it in the folder and stops too', () async {
      await bothOn();
      await ca.setEnabled(false);
      await ca.idle;
      await cb.syncNow();
      await cb.idle;
      await until(() => !cb.enabled, reason: 'the tablet still syncs through the folder');
    });

    test('nothing runs by itself any more: not on a timer, not after a change, not when the app comes to the front', () async {
      ca.dispose();
      ca = cloudFor(a, sa, accountA, every: const Duration(milliseconds: 150));
      sa.cloud = ca;
      await ca.load();
      await bothOn();
      await ca.setEnabled(false);
      await ca.idle;
      final f = folder(CloudSyncService.defaultFolder);
      final calls = f.calls;
      final last = ca.lastRun;
      await a.note('Written after', 'text');
      ca.wake();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(f.calls, calls);
      expect(ca.lastRun, last);
    });

    test('off and on again at once ends on, and it runs', () async {
      await bothOn();
      final before = ca.lastRun;
      await ca.setEnabled(false);
      await ca.setEnabled(true);
      expect(ca.enabled, isTrue);
      await ca.idle;
      await until(() => ca.lastRun != before && !ca.running);
      expect(await a.settings.get(CloudSyncService.kOn), '1');
      expect(ca.enabled, isTrue);
    });

    test('a run that failed does not keep the switch from moving, and what went wrong is shown', () async {
      await bothOn();
      folder(CloudSyncService.defaultFolder).failWriteAfter = 0;
      await a.note('New', 'text');
      await ca.syncNow();
      await ca.idle;
      expect(ca.problem, isNotNull);
      await ca.setEnabled(false);
      expect(ca.enabled, isFalse);
    });

    test('the device stays connected with the automatic sync, with the folder or without it', () async {
      await bothOn();
      await sa.setAuto(true);
      expect(sa.cloudCarries, isTrue);
      await until(() => sa.connected, reason: 'not connected with the folder on');
      await ca.setEnabled(false);
      expect(sa.cloudCarries, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(sa.connected, isTrue);
    });
  });

  group('moving it', () {
    test('a new folder name takes effect at once; the others are told in the old folder and everything goes to the new one', () async {
      final note = await a.note('From the laptop', 'hello');
      await bothOn();
      final old = folder(CloudSyncService.defaultFolder);
      old.hold = Completer<void>();
      unawaited(ca.syncNow());
      await until(() => ca.running);
      await ca.setFolderName('Elsewhere').timeout(const Duration(seconds: 1), onTimeout: () => fail('the name waited for the run'));
      expect(ca.folderName, 'Elsewhere');
      old.hold!.complete();
      old.hold = null;
      await ca.idle;
      expect(folder('Elsewhere').files, isNotEmpty, reason: 'nothing went to the new folder');

      // the tablet still looks in the old folder, learns of the new one there, and follows
      await cb.syncNow();
      await cb.idle;
      await until(() => cb.folderName == 'Elsewhere', reason: 'the tablet did not hear of the new folder');
      await cb.syncNow();
      await cb.idle;
      expect(await b.text(note), 'hello');
    });

    test('another service takes effect at once, and the others are told in the old one', () async {
      await bothOn();
      await ca.setProvider('other').timeout(const Duration(seconds: 1));
      expect(ca.providerId, 'other');
      await ca.idle;
      expect(otherFolders[CloudSyncService.defaultFolder]?.files ?? const {}, isNotEmpty);
      await cb.syncNow();
      await cb.idle;
      await until(() => cb.providerId == 'other', reason: 'the tablet did not hear of the other service');
    });

    test('a name that is only spaces or slashes is not taken', () async {
      await ca.setFolderName('  / ');
      expect(ca.folderName, CloudSyncService.defaultFolder);
      await ca.setFolderName(' a/b ');
      expect(ca.folderName, 'a b');
    });
  });

  group('without the account', () {
    test('the device says what is missing, and meets the others directly to get it', () async {
      accountB.value = false;
      await ca.setEnabled(true);
      await ca.idle;
      // the tablet cannot read the folder: it hears of the choice when the two sync directly ("Sync now" on both)
      await sa.syncNow();
      await sb.syncNow();
      await until(() => cb.enabled, ms: 8000, reason: 'the choice did not come over the direct sync');
      expect(sb.cloudCarries, isFalse); // (it cannot run the folder: the direct way stays)
      await cb.syncNow();
      expect(cb.problem, isNotNull);
      accountB.value = true;
      expect(sb.cloudCarries, isTrue);
    });
  });

  group('the signalling server', () {
    test('the folder sync itself never goes to it', () async {
      await bothOn();
      final joined = server.joined.length;
      final n = await a.note('Note', 'text');
      await ca.syncNow();
      await ca.idle;
      await cb.syncNow();
      await cb.idle;
      expect(await b.text(n), 'text');
      expect(server.joined.length, joined);
    });
  });
}
