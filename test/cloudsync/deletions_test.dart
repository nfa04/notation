import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/folder_sync.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_keys.dart';

import '../devicesync/harness.dart';
import 'memory_cloud_folder.dart';

/// Deleting, trashing and restoring through the cloud folder: what one device throws away the others throw away, in whatever order
/// the devices sync, and nothing that was thrown away comes back by itself.
void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late Device a, b, c;
  late MemoryCloudFolder cloud;
  late SyncSecret secret;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('deletions_');
    secret = SyncSecret.create(Random(5));
    cloud = MemoryCloudFolder();
    a = await Device.create('Laptop', root, profileId: 'aaaaaaaaaaaaaaaa');
    b = await Device.create('Tablet', root, profileId: 'aaaaaaaaaaaaaaaa');
    c = await Device.create('Phone', root, profileId: 'aaaaaaaaaaaaaaaa');
    for (final d in [a, b, c]) {
      for (final other in [a, b, c]) {
        await d.book.add(PairedDevice(id: other.identity.id, name: other.name, publicKey: other.identity.publicKey, addedAt: 1));
      }
    }
  });
  tearDown(() async {
    for (final d in [a, b, c]) {
      await d.db.close();
    }
    await root.delete(recursive: true);
  });

  FolderSync syncOf(Device d, {bool encrypted = true}) => FolderSync(
        folder: cloud,
        library: d.library,
        book: d.book,
        settings: d.settings,
        deviceId: d.identity.id,
        deviceName: d.name,
        key: secret.cloudKey,
        encrypted: encrypted,
      );

  Future<void> run(Device d, {bool encrypted = true}) async {
    final r = await syncOf(d, encrypted: encrypted).run();
    expect(r.problems, isEmpty);
  }

  /// Everybody syncs, a few times over.
  Future<void> settle({int rounds = 3}) async {
    for (var i = 0; i < rounds; i++) {
      for (final d in [a, b, c]) {
        await run(d);
      }
    }
  }

  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 3));

  Future<Set<String>> live(Device d) async => {for (final n in await d.repo.listNotes()) n.id};
  Future<Set<String>> trashed(Device d) async => {for (final n in await d.repo.listTrash()) n.id};
  Future<Set<String>> folders(Device d) async => {for (final f in await d.repo.listFolders()) f.id};

  /// A note on the laptop that every device has.
  Future<String> sharedNote() async {
    final id = await a.note('Shared', 'text');
    await settle();
    expect(await live(b), contains(id));
    expect(await live(c), contains(id));
    return id;
  }

  group('deleting for good', () {
    test('the other devices delete it, and it does not come back, whoever syncs next', () async {
      final id = await sharedNote();
      await tick();
      await a.repo.deleteNote(id);
      await run(a);
      await run(b);
      expect(await live(b), isNot(contains(id)));
      await run(c);
      expect(await live(c), isNot(contains(id)));
      await settle();
      for (final d in [a, b, c]) {
        expect(await live(d), isNot(contains(id)), reason: d.name);
        expect(await trashed(d), isNot(contains(id)), reason: d.name);
      }
    });

    test('the device that deleted it syncs before the others have heard: still no come-back', () async {
      final id = await sharedNote();
      await tick();
      await a.repo.deleteNote(id);
      for (var i = 0; i < 3; i++) {
        await run(a); // (the others publish it still)
      }
      await run(b);
      await run(a);
      await run(c);
      await settle();
      for (final d in [a, b, c]) {
        expect(await live(d), isNot(contains(id)), reason: d.name);
      }
    });

    test('a device that was away for long (the others synced several times meanwhile) deletes it too', () async {
      final id = await sharedNote();
      await tick();
      await a.repo.deleteNote(id);
      for (var i = 0; i < 4; i++) {
        await run(a);
        await run(b);
        await tick();
        await a.note('Another $i', 'more');
        await b.note('Tablet note $i', 'more');
      }
      await run(c);
      expect(await live(c), isNot(contains(id)));
      await settle();
      for (final d in [a, b, c]) {
        expect(await live(d), isNot(contains(id)), reason: d.name);
      }
    });

    test('a note that is open on the other device is deleted once it is closed', () async {
      final id = await sharedNote();
      await tick();
      await a.repo.deleteNote(id);
      await run(a);
      b.busy = {id};
      await run(b);
      expect(await live(b), contains(id), reason: 'open: not taken away under the editor');
      b.busy = {};
      await run(b);
      expect(await live(b), isNot(contains(id)));
      await settle();
      expect(await live(a), isNot(contains(id)));
    });

    test('a note that was edited on the other device after it was deleted is kept (the later change wins)', () async {
      final id = await sharedNote();
      await tick();
      await a.repo.deleteNote(id);
      await run(a);
      await tick();
      await b.edit(id, 'written after the other device threw it away');
      await settle();
      for (final d in [a, b, c]) {
        expect(await live(d), contains(id), reason: d.name);
        expect(await d.text(id), 'written after the other device threw it away');
      }
    });

    test('a device that takes the deletion in keeps the time it was made, so that a later change elsewhere is not taken for an earlier one', () async {
      final id = await sharedNote();
      await tick();
      await a.repo.deleteNote(id);
      final made = (await a.library.manifest()).tombs.singleWhere((t) => t.id == id).at;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await run(a);
      await run(b);
      expect(await live(b), isNot(contains(id)));
      expect((await b.library.manifest()).tombs.singleWhere((t) => t.id == id).at, made);
    });

    test('plain files too', () async {
      final id = await sharedNote();
      await tick();
      await a.repo.deleteNote(id);
      for (final d in [a, b, c, a, b, c]) {
        await run(d, encrypted: false);
      }
      for (final d in [a, b, c]) {
        expect(await live(d), isNot(contains(id)), reason: d.name);
      }
    });

    test('the network drops while the deletion is published: the next run finishes it', () async {
      final id = await sharedNote();
      await tick();
      await a.repo.deleteNote(id);
      cloud.failWriteAfter = 0;
      await syncOf(a).run(); // (fails)
      await settle();
      for (final d in [a, b, c]) {
        expect(await live(d), isNot(contains(id)), reason: d.name);
      }
    });

    test('many notes deleted at once', () async {
      final ids = [for (var i = 0; i < 6; i++) await a.note('Note $i', 'text $i')];
      await settle();
      await tick();
      for (final id in ids.take(4)) {
        await a.repo.deleteNote(id);
      }
      await settle();
      for (final d in [a, b, c]) {
        expect(await live(d), ids.skip(4).toSet(), reason: d.name);
      }
    });

    test('one deleted on each device at the same time', () async {
      final x = await a.note('X', 'x');
      final y = await b.note('Y', 'y');
      final z = await c.note('Z', 'z');
      await settle();
      await tick();
      await a.repo.deleteNote(y);
      await b.repo.deleteNote(z);
      await c.repo.deleteNote(x);
      await settle();
      for (final d in [a, b, c]) {
        expect(await live(d), isEmpty, reason: d.name);
      }
    });
  });

  group('the trash', () {
    test('a note put in the trash is in the trash on the other devices, and brought back too', () async {
      final id = await sharedNote();
      await tick();
      await a.repo.trashNote(id);
      await settle();
      for (final d in [a, b, c]) {
        expect(await trashed(d), contains(id), reason: d.name);
        expect(await live(d), isNot(contains(id)), reason: d.name);
      }
      await tick();
      await b.repo.restoreNote(id);
      await settle();
      for (final d in [a, b, c]) {
        expect(await live(d), contains(id), reason: d.name);
        expect(await trashed(d), isNot(contains(id)), reason: d.name);
      }
    });

    test('emptied from the trash on one device: gone on the others, also from their trash', () async {
      final id = await sharedNote();
      await tick();
      await a.repo.trashNote(id);
      await settle();
      await tick();
      await a.repo.purgeTrash(keep: null);
      await settle();
      for (final d in [a, b, c]) {
        expect(await live(d), isNot(contains(id)), reason: d.name);
        expect(await trashed(d), isNot(contains(id)), reason: d.name);
      }
    });

    test('put in the trash on one device and deleted for good on another', () async {
      final id = await sharedNote();
      await tick();
      await a.repo.trashNote(id);
      await b.repo.deleteNote(id);
      await settle();
      for (final d in [a, b, c]) {
        expect(await live(d), isNot(contains(id)), reason: d.name);
        expect(await trashed(d), isNot(contains(id)), reason: d.name);
      }
    });

    test('put in the trash on one device while another one edited it', () async {
      final id = await sharedNote();
      await tick();
      await a.repo.trashNote(id);
      await b.edit(id, 'edited on the tablet');
      await settle();
      for (final d in [a, b, c]) {
        expect(await d.text(id), 'edited on the tablet', reason: d.name);
      }
      final states = {for (final d in [a, b, c]) await trashed(d).then((t) => t.contains(id))};
      expect(states, hasLength(1), reason: 'the devices agree whether it is in the trash');
    });
  });

  group('folders', () {
    test('a deleted folder is deleted on the other devices, with its subfolders, and its notes stay', () async {
      final top = await a.repo.createFolder('Uni');
      final sub = await a.repo.createFolder('Maths', parentId: top);
      final note = await a.note('Algebra', 'text');
      await a.repo.moveNote(note, sub);
      await settle();
      expect(await folders(b), {top, sub});
      expect(await folders(c), {top, sub});
      await tick();
      await a.repo.deleteFolder(top);
      await settle();
      for (final d in [a, b, c]) {
        expect(await folders(d), isEmpty, reason: d.name);
        expect(await live(d), contains(note), reason: '${d.name}: the note stays');
      }
    });

    test('a subfolder deleted on its own', () async {
      final top = await a.repo.createFolder('Uni');
      final sub = await a.repo.createFolder('Maths', parentId: top);
      await settle();
      await tick();
      await b.repo.deleteFolder(sub);
      await settle();
      for (final d in [a, b, c]) {
        expect(await folders(d), {top}, reason: d.name);
      }
    });

    test('a folder deleted while another device put a note in it', () async {
      final folder = await a.repo.createFolder('Uni');
      final note = await a.note('Algebra', 'text');
      await settle();
      await tick();
      await a.repo.deleteFolder(folder);
      await b.repo.moveNote(note, folder);
      await settle();
      for (final d in [a, b, c]) {
        expect(await live(d), contains(note), reason: '${d.name}: nothing is lost');
      }
      final where = {for (final d in [a, b, c]) (await d.repo.listNotes()).firstWhere((n) => n.id == note).folderId};
      expect(where, hasLength(1), reason: 'the devices agree where it is');
      if (where.single != null) {
        for (final d in [a, b, c]) {
          expect(await folders(d), contains(where.single), reason: '${d.name}: the folder it is in exists');
        }
      }
    });
  });

  group('after a deletion', () {
    test('a note made again with new content is a new note: nothing is taken away from it', () async {
      final id = await sharedNote();
      await tick();
      await a.repo.deleteNote(id);
      await settle();
      await tick();
      final fresh = await b.note('New', 'new text');
      await settle();
      for (final d in [a, b, c]) {
        expect(await live(d), contains(fresh), reason: d.name);
        expect(await live(d), isNot(contains(id)), reason: d.name);
      }
    });

    test('random deleting, trashing, restoring and editing on three devices ends with the same notes everywhere, and what was deleted last stays deleted', () async {
      for (final seed in [for (var i = 1; i <= 12; i++) i]) {
        final rnd = Random(seed * 31);
        final devices = [a, b, c];
        final gone = <String>{}; // deleted for good, and not touched by another device afterwards
        final ids = <String>[];
        for (var i = 0; i < 6; i++) {
          ids.add(await devices[i % 3].note('Note $seed.$i', 'start $i'));
        }
        await settle();
        for (var step = 0; step < 30; step++) {
          final d = devices[rnd.nextInt(3)];
          final known = [for (final id in ids) if (!gone.contains(id) && (await live(d)).contains(id)) id];
          await tick();
          switch (rnd.nextInt(6)) {
            case 0:
              await run(d);
            case 1:
              if (known.isEmpty) break;
              final id = known[rnd.nextInt(known.length)];
              await d.repo.deleteNote(id);
              gone.add(id);
              // (nobody touches it from now on: a later edit elsewhere would rightly bring it back)
              for (final other in devices) {
                other.busy = {};
              }
            case 2:
              if (known.isEmpty) break;
              await d.repo.trashNote(known[rnd.nextInt(known.length)]);
            case 3:
              final trash = (await trashed(d)).where((id) => !gone.contains(id)).toList();
              if (trash.isEmpty) break;
              await d.repo.restoreNote(trash[rnd.nextInt(trash.length)]);
            default:
              await run(d);
          }
        }
        await settle(rounds: 4);
        for (final d in devices) {
          for (final id in gone) {
            expect(await live(d), isNot(contains(id)), reason: 'seed $seed: $id is back on ${d.name}');
            expect(await trashed(d), isNot(contains(id)), reason: 'seed $seed: $id is in the trash of ${d.name}');
          }
        }
        final shown = {for (final d in devices) (await live(d)).toList()..sort()};
        expect(shown.map((l) => l.join(',')).toSet(), hasLength(1), reason: 'seed $seed: the devices show other notes');
        final trashes = {for (final d in devices) (await trashed(d)).toList()..sort()};
        expect(trashes.map((l) => l.join(',')).toSet(), hasLength(1), reason: 'seed $seed: the devices have other trash');
        for (final d in devices) {
          for (final id in [...await live(d), ...await trashed(d)]) {
            await d.repo.deleteNote(id);
          }
          await d.repo.purgeTrash(keep: null);
        }
        for (final d in devices) {
          for (final f in await d.repo.listFolders()) {
            await d.repo.deleteFolder(f.id);
          }
        }
        await settle();
      }
    });
  });
}
