import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/nativeshare/native_share_provider.dart';
import 'package:notes/nativeshare/native_share_service.dart';
import 'package:notes/nativeshare/share_model.dart';
import 'package:notes/nativeshare/shared_folder_sync.dart';

import '../cloudsync/memory_cloud_folder.dart';
import '../devicesync/harness.dart';
import 'fake_share_provider.dart';

/// The quick way of running a share: ask the service what changed (one request) and read only what did.
void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late Device alice, bob;
  late FakeShareHub hub;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('quick_run_');
    alice = await Device.create('alice-laptop', root);
    bob = await Device.create('bob-laptop', root);
    hub = FakeShareHub();
  });
  tearDown(() async {
    await alice.db.close();
    await bob.db.close();
    await root.delete(recursive: true);
  });

  const place = 'Notation Shares/Physics (Notation 3fa9c1)';

  NativeShare given(String rootId) =>
      NativeShare(id: 's1', providerId: 'fake', direction: ShareDirection.outgoing, kind: ShareKind.note, rootId: rootId, name: 'Physics', place: place, createdAt: 1);

  NativeShare received(String rootId) => NativeShare(
        id: 's1',
        providerId: 'fake',
        direction: ShareDirection.incoming,
        kind: ShareKind.note,
        rootId: rootId,
        name: 'Physics',
        place: 'alice@$place',
        role: ShareRole.editor,
        owner: 'Alice',
        createdAt: 1,
      );

  SharedFolderSync runner(Device d, String user, NativeShare s, {Duration maxAge = const Duration(minutes: 10)}) => SharedFolderSync(
        share: s,
        provider: hub.as(user),
        library: d.library,
        db: d.db,
        settings: d.settings,
        deviceId: d.identity.id,
        deviceName: d.name,
        retryDelays: const [],
        maxAge: maxAge,
      );

  MemoryCloudFolder folder() => hub.folderOf('alice', place);

  /// How many requests [job] made to the shared folder.
  Future<int> requests(Future<void> Function() job) async {
    final before = folder().calls;
    await job();
    return folder().calls - before;
  }

  Future<String> sharedNote() async {
    final id = await alice.note('Optics', 'v1');
    await hub.as('alice').share(place, const SharePerson('bob', 'bob'), ShareRole.editor);
    return id;
  }

  group('a quick run', () {
    test('costs one request when nothing changed up there or here', () async {
      final id = await sharedNote();
      final out = given(id);
      await runner(alice, 'alice', out).run(quick: true);
      await runner(alice, 'alice', out).run(quick: true); // (the first looked at what it had written itself)
      final n = await requests(() async {
        final r = await runner(alice, 'alice', out).run(quick: true);
        expect(r.skipped, isTrue);
      });
      expect(n, 1, reason: 'the stamps, nothing else');
    });

    test('takes in what another device published, and is quiet again after that', () async {
      final id = await sharedNote();
      final out = given(id), inn = received(id);
      await runner(alice, 'alice', out).run(quick: true);
      await runner(bob, 'bob', inn).run(quick: true);
      expect(await bob.text(id), 'v1');

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await bob.edit(id, 'v2');
      await runner(bob, 'bob', inn).run(quick: true, force: true); // (something changed here)
      final r = await runner(alice, 'alice', out).run(quick: true);
      expect(r.skipped, isFalse, reason: 'bob wrote in the folder');
      expect(await alice.text(id), 'v2');

      // (each looks at what the other wrote last, until neither writes any more)
      for (var i = 0; i < 2; i++) {
        await runner(alice, 'alice', out).run(quick: true);
        await runner(bob, 'bob', inn).run(quick: true);
      }
      expect((await runner(alice, 'alice', out).run(quick: true)).skipped, isTrue);
      expect((await runner(bob, 'bob', inn).run(quick: true)).skipped, isTrue);
    });

    test('a change made here is published when it is forced, and not read for again from those who published nothing', () async {
      final id = await sharedNote();
      final out = given(id), inn = received(id);
      await runner(alice, 'alice', out).run(quick: true);
      await runner(bob, 'bob', inn).run(quick: true);
      await runner(alice, 'alice', out).run(quick: true);
      await runner(bob, 'bob', inn).run(quick: true);
      await runner(alice, 'alice', out).run(quick: true);

      // nothing changed anywhere, but this run is made (a change here): the participants are not listed or read again
      final idle = await requests(() async => await runner(alice, 'alice', out).run(quick: true, force: true));
      expect(idle, 1, reason: 'the stamps; the participants and the manifest of bob are as they were');

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await alice.edit(id, 'v2');
      final writes = folder().writes;
      await runner(alice, 'alice', out).run(quick: true, force: true);
      expect(folder().writes, greaterThan(writes), reason: 'the change went up');
      await runner(bob, 'bob', inn).run(quick: true);
      expect(await bob.text(id), 'v2');
    });

    test('does not say again that this device takes part', () async {
      final id = await sharedNote();
      final out = given(id);
      await runner(alice, 'alice', out).run(quick: true);
      final file = 'p/${alice.identity.id}';
      expect(folder().files.containsKey(file), isTrue);
      final at = folder().files[file]!;
      folder().files[file] = at; // (the same bytes: a second write would be a new copy)
      final writes = folder().writes;
      await runner(alice, 'alice', out).run(quick: true, force: true);
      await runner(alice, 'alice', out).run(quick: true, force: true);
      expect(folder().writes, writes, reason: 'nothing changed, nothing is written');
    });

    test('says it again when its file is gone', () async {
      final id = await sharedNote();
      final out = given(id);
      await runner(alice, 'alice', out).run(quick: true);
      folder().files.remove('p/${alice.identity.id}');
      await runner(alice, 'alice', out).run(quick: true, force: true);
      expect(folder().files.containsKey('p/${alice.identity.id}'), isTrue);
    });

    test('a person who joins is found, and read', () async {
      final id = await sharedNote();
      final out = given(id), inn = received(id);
      await runner(alice, 'alice', out).run(quick: true);
      await runner(alice, 'alice', out).run(quick: true);
      expect((await runner(alice, 'alice', out).run(quick: true)).skipped, isTrue);
      await runner(bob, 'bob', inn).run(quick: true); // (bob joins: his files appear)
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await bob.edit(id, 'from bob');
      await runner(bob, 'bob', inn).run(quick: true, force: true);
      await runner(alice, 'alice', out).run(quick: true);
      expect(await alice.text(id), 'from bob');
    });

    test('reads everything again after maxAge, whatever the stamps say', () async {
      final id = await sharedNote();
      final out = given(id);
      await runner(alice, 'alice', out, maxAge: Duration.zero).run(quick: true);
      await runner(alice, 'alice', out, maxAge: Duration.zero).run(quick: true);
      final r = await runner(alice, 'alice', out, maxAge: Duration.zero).run(quick: true);
      expect(r.skipped, isFalse);
    });

    test('a service that cannot give stamps is run in full, and still works', () async {
      final id = await sharedNote();
      final out = given(id), inn = received(id);
      folder().canStamp = false;
      await runner(alice, 'alice', out).run(quick: true);
      await runner(bob, 'bob', inn).run(quick: true);
      expect(await bob.text(id), 'v1');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await alice.edit(id, 'v2');
      await runner(alice, 'alice', out).run(quick: true);
      await runner(bob, 'bob', inn).run(quick: true);
      expect(await bob.text(id), 'v2');
    });

    test('the run that is not quick reads everything, as before', () async {
      final id = await sharedNote();
      final out = given(id);
      await runner(alice, 'alice', out).run(quick: true);
      await runner(alice, 'alice', out).run(quick: true);
      final n = await requests(() async => await runner(alice, 'alice', out).run());
      expect(n, greaterThan(2));
      expect(folder().stampCalls, greaterThan(0));
    });
  });

  group('looking for a newer copy of a note that was opened', () {
    test('costs one request when nothing changed, and takes the copy in when something did', () async {
      final id = await sharedNote();
      final out = given(id), inn = received(id);
      await runner(alice, 'alice', out).run(quick: true);
      await runner(bob, 'bob', inn).run(quick: true);
      await runner(bob, 'bob', inn).run(quick: true);
      await runner(alice, 'alice', out).run(quick: true);
      await runner(bob, 'bob', inn).run(quick: true);

      final n = await requests(() async => expect(await runner(bob, 'bob', inn).pullNote(id, quick: true), isFalse));
      expect(n, 1);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await alice.edit(id, 'v2');
      await runner(alice, 'alice', out).run(quick: true, force: true);
      expect(await runner(bob, 'bob', inn).pullNote(id, quick: true), isTrue);
      expect(await bob.text(id), 'v2');
    });
  });

  group('the service', () {
    NativeShareService service(Device d, String user, Stream<String> changes) => NativeShareService(
          db: d.db,
          settings: d.settings,
          library: d.library,
          providers: [hub.as(user)],
          deviceId: () => d.identity.id,
          deviceName: () => d.name,
          identity: () => d.identity,
          changes: changes,
          every: const Duration(hours: 1),
          afterChange: const Duration(milliseconds: 80),
          lookEvery: const Duration(hours: 1),
          retryDelays: const [],
        );

    test('runs only the shares an edit belongs to, and none for a note that is in no share', () async {
      final changes = StreamController<String>.broadcast();
      final svc = service(alice, 'alice', changes.stream);
      await svc.load();
      final shared = await alice.note('Optics', 'x');
      final other = await alice.note('Diary', 'private');
      await svc.shareNote(shared, svc.usable.single, const SharePerson('bob', 'bob'), ShareRole.editor);
      await svc.idle;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await svc.idle;
      final up = hub.folderOf('alice', svc.given.single.place);

      var before = up.calls;
      changes.add(other);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await svc.idle;
      expect(up.calls - before, 0, reason: 'a note that is in no share changes nothing up there');

      await alice.edit(shared, 'y');
      before = up.calls;
      changes.add(shared);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await svc.idle;
      expect(up.calls - before, greaterThan(0), reason: 'the share it belongs to ran');
      expect(up.files.keys.any((k) => k.endsWith('manifest.json')), isTrue);
      svc.dispose();
      await changes.close();
    });

    test('a timer run of a share where nothing changed asks once', () async {
      final svc = service(alice, 'alice', const Stream.empty());
      await svc.load();
      final shared = await alice.note('Optics', 'x');
      final share = await svc.shareNote(shared, svc.usable.single, const SharePerson('bob', 'bob'), ShareRole.editor);
      await svc.syncNow(quick: true);
      await svc.syncNow(quick: true);
      final n = await hub.folderOf('alice', share.place).let((f) async {
        final before = f.calls;
        await svc.syncNow(quick: true);
        return f.calls - before;
      });
      expect(n, 1);
      svc.dispose();
    });
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
