import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/folder_sync.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_keys.dart';

import '../devicesync/harness.dart';
import 'memory_cloud_folder.dart';

/// The sync through a cloud folder must never keep a note twice unless it really was changed on two devices at once: a note that
/// was taken in and changed further, a note that ends up the same on both, a run that is cut short - none of these is a conflict.
void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late Device a, b, c;
  late MemoryCloudFolder cloud;
  late SyncSecret secret;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('duplicates_');
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

  /// A moment, so that the next edit has a later time than the one before (times are in milliseconds).
  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 3));

  Future<void> edit(Device d, String id, String text) async {
    await tick();
    await d.edit(id, text);
  }

  Future<int> copies(Device d) async => (await d.repo.listNotes()).where((n) => n.title.contains('from before the sync')).length;

  Future<int> notes(Device d) async => (await d.repo.listNotes()).length;

  Future<void> noCopies(List<Device> devices) async {
    for (final d in devices) {
      expect(await copies(d), 0, reason: 'a copy was kept on ${d.name}');
    }
  }

  group('a note taken in and changed further is not a conflict', () {
    test('changed on the other device before this one ran again', () async {
      final id = await a.note('Shared', 'first');
      await run(a);
      await run(b); // the tablet takes it in (and publishes it as it got it)
      await edit(b, id, 'changed on the tablet');
      await run(b);
      await run(a); // the laptop never saw the tablet publish "first": it must still know its own copy is the older one
      expect(await a.text(id), 'changed on the tablet');
      await noCopies([a, b]);
    });

    test('changed on the other device before it even published what it took in', () async {
      final id = await a.note('Shared', 'first');
      await run(a);
      b.busy = {id}; // (open on the tablet while its run takes the rest; nothing to take here, but nothing published of it either)
      await run(b);
      b.busy = {};
      await run(b);
      await edit(b, id, 'changed on the tablet');
      await run(b);
      await run(a);
      expect(await a.text(id), 'changed on the tablet');
      await noCopies([a, b]);
    });

    test('back and forth, each device changing it right after taking it in, the other never running in between', () async {
      final id = await a.note('Shared', 'v1');
      await run(a);
      for (var i = 2; i < 8; i++) {
        final (from, to) = i.isEven ? (a, b) : (b, a);
        await run(to); // takes in the other's change...
        await edit(to, id, 'v$i'); // ...changes it at once...
        await run(to); // ...and publishes it
        expect(from, isNot(to));
      }
      await run(a);
      await run(b);
      expect(await a.text(id), 'v7');
      expect(await b.text(id), 'v7');
      await noCopies([a, b]);
    });

    test('three devices: the phone has the laptop\'s version, the tablet changes it, the phone takes that without a copy', () async {
      final id = await a.note('Shared', 'first');
      await run(a);
      await run(c); // the phone has it from the laptop
      await run(b);
      await edit(b, id, 'changed on the tablet');
      await run(b);
      await run(c); // the phone never agreed anything with the tablet about this note
      expect(await c.text(id), 'changed on the tablet');
      await run(a);
      expect(await a.text(id), 'changed on the tablet');
      await noCopies([a, b, c]);
    });

    test('three devices in a chain: laptop -> tablet -> phone, each changing it, the first one taking the last version', () async {
      final id = await a.note('Shared', 'laptop');
      await run(a);
      await run(b);
      await edit(b, id, 'tablet');
      await run(b);
      await run(c);
      await edit(c, id, 'phone');
      await run(c);
      for (final d in [a, b, c]) {
        await run(d);
      }
      for (final d in [a, b, c]) {
        expect(await d.text(id), 'phone');
      }
      await noCopies([a, b, c]);
    });

    test('a newer copy taken in when the note is opened, then changed and published: the other device takes it without a copy', () async {
      final id = await a.note('Shared', 'first');
      await run(a);
      await run(b);
      await edit(a, id, 'second, on the laptop');
      await run(a);
      b.busy = {id}; // open on the tablet
      expect(await syncOf(b).pullNote(id), isTrue);
      await edit(b, id, 'third, on the tablet');
      b.busy = {};
      await run(b);
      await run(a);
      expect(await a.text(id), 'third, on the tablet');
      await noCopies([a, b]);
    });

    test('a run cut short after taking the note in: the next one does not take its own change for a conflict', () async {
      final id = await a.note('Shared', 'first');
      await run(a);
      await run(b);
      await edit(a, id, 'second');
      await run(a);
      var calls = 0;
      await syncOf(b).run(stop: () => ++calls > 2); // stops before publishing
      await edit(b, id, 'third, on the tablet');
      await run(b);
      await run(a);
      expect(await a.text(id), 'third, on the tablet');
      await noCopies([a, b]);
    });

    test('the kind of files is changed on one device in between', () async {
      final id = await a.note('Shared', 'first');
      await run(a);
      await run(b);
      await edit(b, id, 'changed on the tablet');
      await run(b, encrypted: false);
      await run(a);
      expect(await a.text(id), 'changed on the tablet');
      await noCopies([a, b]);
    });

    test('moved to a folder on one device, changed on the other: both changes stay, no copy', () async {
      final id = await a.note('Shared', 'first');
      final folder = await a.repo.createFolder('Uni');
      await run(a);
      await run(b);
      await tick();
      await a.repo.moveNote(id, folder);
      await edit(b, id, 'changed on the tablet');
      await run(a);
      await run(b);
      await run(a);
      for (final d in [a, b]) {
        expect(await d.text(id), 'changed on the tablet');
        expect((await d.repo.listNotes()).firstWhere((n) => n.id == id).folderId, folder);
      }
      await noCopies([a, b]);
    });
  });

  group('the same note on both devices is not a conflict', () {
    test('both changed it to the same text (one wrote what the other had, as after a live session)', () async {
      final id = await a.note('Shared', 'first');
      await run(a);
      await run(b);
      await edit(a, id, 'worked on together');
      await edit(b, id, 'worked on together');
      for (var i = 0; i < 2; i++) {
        await run(a);
        await run(b);
      }
      await noCopies([a, b]);
      expect(await notes(a), 1);
      expect(await notes(b), 1);
    });

    test('a live session ended with the note the same on both, saved at different times, and agreed: no copy either way', () async {
      final id = await a.note('Shared', 'first');
      await run(a);
      await run(b);
      await edit(a, id, 'after the session');
      await edit(b, id, 'after the session');
      await a.library.markNoteAgreed(id, [b.identity.id]);
      await b.library.markNoteAgreed(id, [a.identity.id]);
      await edit(b, id, 'after the session, and a bit more on the tablet');
      await run(b);
      await run(a);
      expect(await a.text(id), 'after the session, and a bit more on the tablet');
      await noCopies([a, b]);
    });
  });

  group('a real conflict is kept once, and only once', () {
    test('changed on both: one copy, on both devices, and more rounds make no more', () async {
      final id = await a.note('Shared', 'start');
      await run(a);
      await run(b);
      await edit(a, id, 'laptop version');
      await edit(b, id, 'tablet version');
      for (var i = 0; i < 4; i++) {
        await run(a);
        await run(b);
      }
      expect(await notes(a), 2);
      expect(await notes(b), 2);
      final texts = {for (final n in await a.repo.listNotes()) await a.text(n.id)};
      expect(texts, {'laptop version', 'tablet version'});
    });

    test('three devices change it at once: every version is there once, everywhere', () async {
      final id = await a.note('Shared', 'start');
      for (final d in [a, b, c]) {
        await run(d);
      }
      for (final d in [a, b, c]) {
        await run(d);
      }
      await edit(a, id, 'laptop version');
      await edit(b, id, 'tablet version');
      await edit(c, id, 'phone version');
      for (var i = 0; i < 4; i++) {
        for (final d in [a, b, c]) {
          await run(d);
        }
      }
      for (final d in [a, b, c]) {
        final texts = [for (final n in await d.repo.listNotes()) await d.text(n.id)]..sort();
        expect(texts, ['laptop version', 'phone version', 'tablet version'], reason: 'on ${d.name}');
      }
    });

    test('the copy that was kept, changed afterwards, is not copied again', () async {
      final id = await a.note('Shared', 'start');
      await run(a);
      await run(b);
      await edit(a, id, 'laptop version');
      await edit(b, id, 'tablet version');
      for (var i = 0; i < 2; i++) {
        await run(a);
        await run(b);
      }
      final copy = (await b.repo.listNotes()).firstWhere((n) => n.id != id).id;
      await edit(b, copy, 'the copy, tidied up');
      await edit(a, id, 'the note, changed further');
      for (var i = 0; i < 3; i++) {
        await run(a);
        await run(b);
      }
      expect(await notes(a), 2);
      expect(await notes(b), 2);
    });
  });

  group('housekeeping', () {
    test('a copy that was deleted stays deleted: it is not made again on any device', () async {
      final id = await a.note('Shared', 'start');
      await run(a);
      await run(b);
      await edit(a, id, 'laptop version');
      await edit(b, id, 'tablet version');
      for (var i = 0; i < 2; i++) {
        await run(a);
        await run(b);
      }
      final copy = (await a.repo.listNotes()).firstWhere((n) => n.id != id).id;
      await a.repo.deleteNote(copy); // (for good: the other devices are told)
      for (var i = 0; i < 3; i++) {
        await run(a);
        await run(b);
      }
      expect(await notes(a), 1);
      expect(await notes(b), 1);
    });

    test('a database from before the lineage of notes gets the table when it is opened', () async {
      final path = '${root.path}/old.db';
      var db = await AppDatabase.open(path: path);
      await db.execute('DROP TABLE sync_lineage');
      await db.execute('PRAGMA user_version = 30');
      await db.close();
      db = await AppDatabase.open(path: path);
      expect(await db.query('sync_lineage'), isEmpty);
      await db.close();
    });
  });

  // Many rounds with three devices that change any note they have whenever they like, so that real conflicts happen. Every change adds
  // to the end of the text, so "grew from" is "starts with". In the end all devices have the same notes, no version is there twice,
  // and nothing that was ever published is lost: each text a device had after one of its runs is still there, or one that grew from it.
  for (final seed in [for (var i = 1; i <= 20; i++) i]) {
    test('random rounds with conflicts: the same notes everywhere, nothing twice, nothing lost (seed $seed)', () async {
      final rnd = Random(seed * 7919);
      final devices = [a, b, c];
      final published = <String>{};
      var n = 0;
      for (var step = 0; step < 80; step++) {
        final d = devices[rnd.nextInt(3)];
        final what = rnd.nextInt(10);
        final have = await d.repo.listNotes();
        if (what < 4) {
          await run(d, encrypted: rnd.nextInt(8) != 0);
          for (final x in await d.repo.listNotes()) {
            published.add(await d.text(x.id));
          }
        } else if (what < 5 || have.isEmpty) {
          await d.note('Note ${n++}', 'n$n${d.name[0]}');
        } else {
          final id = have[rnd.nextInt(have.length)].id;
          await edit(d, id, '${await d.text(id)}+${d.name[0]}$step');
        }
      }
      for (var i = 0; i < 3; i++) {
        for (final d in devices) {
          await run(d);
        }
      }
      final contents = <Device, Map<String, String>>{
        for (final d in devices) d: {for (final x in await d.repo.listNotes()) x.id: await d.text(x.id)},
      };
      expect(contents[b], contents[a], reason: 'the tablet ends with other notes than the laptop');
      expect(contents[c], contents[a], reason: 'the phone ends with other notes than the laptop');
      final texts = contents[a]!.values.toList();
      expect(texts.toSet().length, texts.length, reason: 'a version is there twice: ${texts..sort()}');
      for (final t in published) {
        expect(texts.any((x) => x.startsWith(t)), isTrue, reason: 'lost: "$t"');
      }
    });
  }

  // Many rounds with three devices, in a random order, where a device only ever changes a note when it has the latest version of it:
  // there is never a real conflict, so no copy may ever be kept, and in the end all devices have the same notes.
  for (final seed in [for (var i = 1; i <= 30; i++) i]) {
    test('random rounds without real conflicts never keep a copy (seed $seed)', () async {
      final rnd = Random(seed);
      final devices = [a, b, c];
      final latest = <String, String>{}; // note -> its newest text anywhere
      var n = 0;
      for (var step = 0; step < 60; step++) {
        final d = devices[rnd.nextInt(3)];
        final what = rnd.nextInt(10);
        if (what < 4) {
          await run(d, encrypted: rnd.nextInt(8) != 0);
        } else if (what < 6 || latest.isEmpty) {
          final text = 'note ${n++} from ${d.name}';
          final id = await d.note('Note $n', text);
          latest[id] = text;
        } else {
          // a note this device has in its newest version (if it has one)
          final mine = [
            for (final id in latest.keys)
              if ((await d.repo.listNotes()).any((x) => x.id == id) && await d.text(id) == latest[id]) id,
          ];
          if (mine.isEmpty) continue;
          final id = mine[rnd.nextInt(mine.length)];
          final text = '${latest[id]} +${d.name[0]}$step';
          await edit(d, id, text);
          latest[id] = text;
        }
        for (final x in devices) {
          expect(await copies(x), 0, reason: 'step $step: a copy was kept on ${x.name}');
        }
      }
      for (var i = 0; i < 2; i++) {
        for (final d in devices) {
          await run(d);
        }
      }
      for (final d in devices) {
        expect(await copies(d), 0, reason: 'at the end: a copy was kept on ${d.name}');
        expect(await notes(d), latest.length, reason: d.name);
        for (final e in latest.entries) {
          expect(await d.text(e.key), e.value, reason: '${d.name}, ${e.key}');
        }
      }
    });
  }
}
