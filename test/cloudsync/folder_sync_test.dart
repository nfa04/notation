import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/cloud_folder.dart';
import 'package:notes/cloudsync/folder_sync.dart';
import 'package:notes/collab/secure_box.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_library.dart';
import 'package:notes/devicesync/sync_keys.dart';

import '../devicesync/harness.dart';
import 'memory_cloud_folder.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late Device a, b;
  late MemoryCloudFolder cloud;
  late SyncSecret secret;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('foldersync_');
    secret = SyncSecret.create(Random(5));
    cloud = MemoryCloudFolder();
    a = await Device.create('Laptop', root, profileId: 'aaaaaaaaaaaaaaaa');
    b = await Device.create('Tablet', root, profileId: 'aaaaaaaaaaaaaaaa');
    for (final d in [a, b]) {
      for (final other in [a, b]) {
        await d.book.add(PairedDevice(id: other.identity.id, name: other.name, publicKey: other.identity.publicKey, addedAt: 1));
      }
    }
  });
  tearDown(() async {
    await a.db.close();
    await b.db.close();
    await root.delete(recursive: true);
  });

  FolderSync syncOf(Device d, {bool encrypted = true, MemoryCloudFolder? folder}) => FolderSync(
        folder: folder ?? cloud,
        library: d.library,
        book: d.book,
        settings: d.settings,
        deviceId: d.identity.id,
        deviceName: d.name,
        key: secret.cloudKey,
        encrypted: encrypted,
      );

  Future<FolderSyncResult> run(Device d, {bool encrypted = true}) async {
    final r = await syncOf(d, encrypted: encrypted).run();
    expect(r.problems, isEmpty);
    return r;
  }

  test('a big PDF is written once: a change to the note writes only the note, and the other device does not fetch the PDF again', () async {
    final pdf = File('${root.path}/big.pdf')..writeAsBytesSync(List.generate(600 * 1024, (i) => (i * 7919 + i ~/ 13) & 255));
    final id = await a.note('Paper', 'first');
    await a.db.update('notes', {'pdf_name': 'big.pdf', 'pdf_path': pdf.path, 'pdf_page_count': 1}, where: 'id = ?', whereArgs: [id]);
    await run(a);
    final aDir = FolderSync.directory(secret.cloudKey, a.identity.id, true);
    List<String> blobsOfA() => cloud.files.keys.where((k) => k.startsWith('$aDir/b/')).toList();
    final blobs = blobsOfA();
    expect(blobs, hasLength(1), reason: 'the PDF is a file of its own');
    expect(cloud.files.keys.where((k) => k.startsWith('$aDir/n/')).map((k) => cloud.files[k]!.length).single, lessThan(100 * 1024), reason: 'the note file is without the PDF');

    await run(b);
    final got = (await b.repo.loadNote(id))!;
    expect(got.documentText, 'first');
    expect(File(got.pdfPath!).readAsBytesSync(), pdf.readAsBytesSync(), reason: 'the PDF is whole on the other device');

    // a change: the PDF is not written again, and B (which has it) does not read it
    await a.edit(id, 'second');
    final before = cloud.writes;
    await run(a);
    expect(cloud.writes - before, 2, reason: 'the note and the manifest');
    expect(blobsOfA(), blobs);
    final reads = <String>[];
    final spy = _ReadSpy(cloud, reads);
    final r = await FolderSync(folder: spy, library: b.library, book: b.book, settings: b.settings, deviceId: b.identity.id, deviceName: b.name, key: secret.cloudKey, encrypted: true).run();
    expect(r.problems, isEmpty);
    expect(await b.text(id), 'second');
    expect(reads.where((p) => p.contains('/b/')), isEmpty, reason: 'B has the PDF');
  });

  test('the notes changed last are taken in first, from every device, and the trash last', () async {
    final ids = <String>[];
    for (var i = 0; i < 6; i++) {
      ids.add(await a.note('Note $i', 'text $i'));
    }
    // the times: note 3 is the newest, then 0, 5, 1, 4, 2 (not the order they were made in); note 5 is in the trash
    final at = {3: 6000, 0: 5000, 5: 4000, 1: 3000, 4: 2000, 2: 1000};
    for (final e in at.entries) {
      await a.db.update('notes', {'updated_at': 1700000000000 + e.value, if (e.key == 5) 'deleted_at': 1700000000000 + 4000}, where: 'id = ?', whereArgs: [ids[e.key]]);
    }
    await run(a);

    final order = <String>[];
    final spy = _Recording(b, order);
    final r = await FolderSync(
      folder: cloud,
      library: spy,
      book: b.book,
      settings: b.settings,
      deviceId: b.identity.id,
      deviceName: b.name,
      key: secret.cloudKey,
      encrypted: true,
    ).run();
    expect(r.problems, isEmpty);
    expect(order, [ids[3], ids[0], ids[1], ids[4], ids[2], ids[5]]);
  });

  test('an account that is missing on this device is reported once, not once for every note and device', () async {
    for (var i = 0; i < 12; i++) {
      await a.note('Note $i', 'text $i');
    }
    final gone = _NoAccountFolder();
    final r = await FolderSync(
      folder: gone,
      library: a.library,
      book: a.book,
      settings: a.settings,
      deviceId: a.identity.id,
      deviceName: a.name,
      key: secret.cloudKey,
      encrypted: true,
    ).run();
    // one for the other device it could not read, one for what it could not publish
    expect(r.problems, hasLength(2), reason: r.problems.join('\n'));
    expect(r.problems.every((p) => p.contains('keystore')), isTrue);
    expect(gone.requests, lessThan(10), reason: 'it stops at the first failure and does not try every note');
  });

  bool anyFileHolds(String text) => cloud.files.values.any((bytes) => latin1.decode(bytes).contains(text));

  test('a device added through another device is learnt of through the folder, from sealed manifests only', () async {
    final c = await Device.create('Phone', root, profileId: 'aaaaaaaaaaaaaaaa');
    PairedDevice entry(Device d) => PairedDevice(id: d.identity.id, name: d.name, publicKey: d.identity.publicKey, addedAt: 2);
    // the phone was let in by the laptop: only the laptop (and the phone) know it, and the phone knows the laptop and the tablet
    await a.book.add(entry(c));
    for (final d in [a, b, c]) {
      await c.book.add(entry(d));
    }
    await run(a);
    await run(c);
    expect(b.book.find(c.identity.id), isNull);
    await run(b); // reads the manifests of the laptop and the phone
    expect(b.book.find(c.identity.id)?.name, 'Phone');
    await c.db.close();
  });

  test('encrypted: a file in the folder that is not sealed with the key of the profile is not taken, whatever it says', () async {
    await run(a); // the laptop publishes (sealed)
    final dir = FolderSync.directory(secret.cloudKey, a.identity.id, true);
    final stranger = await Device.create('Stranger', root);
    // someone who can write to the folder (not to the profile) puts a plain manifest where the laptop's sealed one is
    final forged = jsonEncode({
      'v': FolderSync.formatVersion,
      'device': a.identity.id,
      'name': 'Laptop',
      'devices': [PairedDevice(id: stranger.identity.id, name: 'Stranger', publicKey: stranger.identity.publicKey, addedAt: 9).toJson()],
      'm': {
        'folders': [],
        'notes': [
          {'id': 'planted', 'v': DateTime.now().millisecondsSinceEpoch, 'c': 1, 'f': null, 'star': false, 'del': null},
        ],
        'settings': [],
        'tombs': [],
      },
      'notes': {'planted': 'n/planted'},
      'images': {},
    });
    cloud.files['$dir/m'] = Uint8List.fromList(utf8.encode(forged));
    cloud.files['$dir/n/planted'] = (await a.library.noteBytes((await a.repo.listNotes()).isEmpty ? await a.note('x', 'y') : (await a.repo.listNotes()).first.id))!;
    final r = await syncOf(b).run();
    expect(r.problems, isNotEmpty, reason: 'it should say the file cannot be read');
    expect((await b.repo.listNotes()).any((n) => n.id == 'planted'), isFalse, reason: 'a planted note was taken');
    expect(b.book.find(stranger.identity.id), isNull, reason: 'a planted device was let in');
    await stranger.db.close();
  });

  test('plain files do not add devices: anyone who reaches the folder can write them', () async {
    final c = await Device.create('Phone', root, profileId: 'aaaaaaaaaaaaaaaa');
    await a.book.add(PairedDevice(id: c.identity.id, name: c.name, publicKey: c.identity.publicKey, addedAt: 2));
    await run(a, encrypted: false);
    await run(b, encrypted: false);
    expect(b.book.find(c.identity.id), isNull);
    expect(anyFileHolds('Phone'), isFalse, reason: 'the names of the devices are not written in the clear');
    await c.db.close();
  });

  test('one note that will not upload does not keep the others from travelling, and goes up on the next run', () async {
    final n1 = await a.note('One', 'first text');
    final n2 = await a.note('Two', 'second text');
    cloud.failWriteAfter = 0; // the first file written is lost
    final first = await syncOf(a).run();
    expect(first.problems, hasLength(1), reason: 'it is told');
    expect(first.put, greaterThan(1), reason: 'the other note and the manifest went up');

    await run(b);
    final got = [for (final id in [n1, n2]) (await b.repo.listNotes()).any((n) => n.id == id)];
    expect(got.where((x) => x), hasLength(1), reason: 'the note that went up arrived, the other is not there yet');

    await run(a); // tried again
    await run(b);
    expect(await b.text(n1), 'first text');
    expect(await b.text(n2), 'second text');
  });

  test('encrypted: notes, folders, settings and deletions travel through the folder, which holds nothing readable', () async {
    final onA = await a.note('Secret plan', 'the laptop text xyzzy');
    final folder = await a.repo.createFolder('Uni');
    await a.repo.moveNote(onA, folder);
    await a.repo.setFavorite(onA, true);
    await a.settings.set('app_accent', '4280391411');
    final onB = await b.note('From the tablet', 'the tablet text plugh');

    await run(a);
    await run(b); // the tablet takes in the laptop's, and publishes its own
    await run(a);

    expect(await b.text(onA), 'the laptop text xyzzy');
    expect(await a.text(onB), 'the tablet text plugh');
    final moved = (await b.repo.listNotes()).firstWhere((n) => n.id == onA);
    expect([moved.folderId, moved.favorite], [folder, true]);
    expect(await b.settings.get('app_accent'), '4280391411');

    // nothing in the folder can be read: not the texts, not the titles, not the note ids, not the device ids
    for (final secretText in ['xyzzy', 'plugh', 'Secret plan', 'Uni', onA, a.identity.id, 'manifest']) {
      expect(anyFileHolds(secretText), isFalse, reason: secretText);
    }
    expect(cloud.files.keys.any((p) => p.contains(onA) || p.contains(a.identity.id)), isFalse);

    // a deletion and a change travel too
    await Future<void>.delayed(const Duration(milliseconds: 3));
    await a.edit(onA, 'changed on the laptop');
    await b.repo.trashNote(onB);
    await run(a);
    await run(b);
    await run(a);
    expect(await b.text(onA), 'changed on the laptop');
    expect((await a.repo.listNotes()).where((n) => n.id == onB), isEmpty); // (in the trash there too)
  });

  test('encrypted: a sealed file put under another name by whoever runs the storage is refused, a file from before the tie is still read', () async {
    final n1 = await a.note('One', 'text one xyzzy');
    final n2 = await a.note('Two', 'text two plugh');
    await run(a);
    final notes = cloud.files.keys.where((k) => k.contains('/n/')).toList()..sort();
    expect(notes.length, 2);
    final first = cloud.files[notes[0]]!, second = cloud.files[notes[1]]!;
    cloud.files[notes[0]] = second;
    cloud.files[notes[1]] = first;
    final r = await syncOf(b).run();
    expect(r.problems, isNotEmpty);
    expect((await b.repo.listNotes()).where((n) => n.id == n1 || n.id == n2), isEmpty);

    // back in place it is read; so is a file that was sealed without the tie (as the app did before)
    cloud.files[notes[0]] = first;
    cloud.files[notes[1]] = await sealApart(secret.cloudKey, await openApart(secret.cloudKey, second, aad: utf8.encode('notation-cloud-file-v1|${notes[1]}')));
    final again = await syncOf(b).run();
    expect(again.problems, isEmpty);
    expect(await b.text(n1) + await b.text(n2), contains('xyzzy'));
  });

  test('plain: the manifest is JSON and the notes are .uninote files anyone can open', () async {
    final onA = await a.note('Readable', 'plain text qwerty');
    await run(a, encrypted: false);
    final manifest = cloud.files.entries.firstWhere((e) => e.key.endsWith('/manifest.json'));
    expect(jsonDecode(utf8.decode(manifest.value)), isA<Map>());
    expect(cloud.files.keys.any((p) => p.endsWith('.uninote') && p.contains(onA)), isTrue);
    await run(b, encrypted: false);
    expect(await b.text(onA), 'plain text qwerty');
  });

  test('a device reads the other kind of files too; switching the kind rewrites the files and removes the old ones', () async {
    final onA = await a.note('Switch', 'before the switch');
    await run(a, encrypted: false);
    await run(b, encrypted: true); // (the tablet seals, the laptop does not: it still reads)
    expect(await b.text(onA), 'before the switch');

    await Future<void>.delayed(const Duration(milliseconds: 3));
    await a.edit(onA, 'after the switch');
    await run(a, encrypted: true);
    expect(cloud.files.keys.where((p) => p.contains('d-${a.identity.id}')), isEmpty); // the plain files of the laptop are gone
    expect(anyFileHolds('after the switch'), isFalse);
    await run(b, encrypted: true);
    expect(await b.text(onA), 'after the switch');
  });

  test('a note changed on both devices is kept twice; nothing is lost and a second round changes nothing', () async {
    final id = await a.note('Shared', 'start');
    await run(a);
    await run(b);
    await Future<void>.delayed(const Duration(milliseconds: 3));
    await a.edit(id, 'laptop version');
    await b.edit(id, 'tablet version');
    // (a third round: what one device agreed with the other is in its manifest, and the other's agreement comes back a round later)
    for (var i = 0; i < 3; i++) {
      await run(a);
      await run(b);
    }
    final texts = <String>{
      for (final n in await a.repo.listNotes()) await a.text(n.id),
    };
    expect(texts, containsAll(['laptop version', 'tablet version']));
    final writes = cloud.writes;
    await run(a);
    await run(b);
    expect(cloud.writes, writes); // (nothing changed: nothing is written)
    expect((await a.repo.listNotes()).length, (await b.repo.listNotes()).length);
  });

  test('the network drops while publishing: what other devices read stays complete, and the next run finishes', () async {
    for (var i = 0; i < 4; i++) {
      await a.note('Note $i', 'text $i');
    }
    await run(a);
    await run(b);
    await Future<void>.delayed(const Duration(milliseconds: 3));
    for (final n in await a.repo.listNotes()) {
      await a.edit(n.id, 'second ${n.title}');
    }
    // every point in the middle of the publishing
    for (var cut = 0; cut < 5; cut++) {
      cloud.failWriteAfter = cut;
      final r = await syncOf(a).run();
      // (what went up in an earlier cut stays published, so a later cut may fall after the last write)
      cloud.failWriteAfter = null;
      expect(r.problems.length, cut == 0 ? 1 : lessThanOrEqualTo(1));
      // the tablet reads in between: it sees the old state or the new one, never a torn one
      final rb = await syncOf(b).run();
      expect(rb.problems, isEmpty);
      for (final n in await b.repo.listNotes()) {
        final text = await b.text(n.id);
        expect(text == 'text ${n.title.split(' ').last}' || text == 'second ${n.title}', isTrue, reason: text);
      }
    }
    await run(a);
    await run(b);
    for (final n in await a.repo.listNotes()) {
      expect(await b.text(n.id), 'second ${n.title}');
    }
    expect((await b.repo.listNotes()).where((n) => n.title.contains('before the sync')), isEmpty);
  });

  test('a folder picture goes with its folder', () async {
    final folder = await a.repo.createFolder('Banner');
    final pic = File('${a.dir.path}/f.png')..writeAsBytesSync([1, 2, 3, 4]);
    await a.repo.setFolderThemeImage(folder, pic.path);
    await run(a);
    await run(b);
    final onB = (await b.repo.listFolders()).firstWhere((f) => f.id == folder).themeImage;
    expect(onB, isNotNull);
    expect(File(onB!).readAsBytesSync(), Uint8List.fromList([1, 2, 3, 4]));
  });

  test('opening a note: a newer copy in the folder is taken in for that note alone, also when the note is open; not when the person already changed it', () async {
    final id = await a.note('Open me', 'first text');
    final other = await a.note('Other note', 'other first');
    await run(a);
    await run(b);
    expect(await b.text(id), 'first text');

    await Future<void>.delayed(const Duration(milliseconds: 3));
    await a.edit(id, 'second text');
    await a.edit(other, 'other second');
    await run(a);

    b.library.busy = () => {id}; // (an editor has it open: a run leaves it alone)
    expect(await syncOf(b).pullNote(id, allow: () => false), isFalse, reason: 'the person changed it meanwhile');
    expect(await b.text(id), 'first text');
    expect(await syncOf(b).pullNote(id), isTrue);
    expect(await b.text(id), 'second text');
    expect(await b.text(other), 'other first', reason: 'only the note that was opened');
    expect(await syncOf(b).pullNote(id), isFalse, reason: 'nothing newer now');
    expect(await syncOf(b).pullNote('no-such-note'), isFalse);
  });

  test('another folder (or service) gets everything: what was published somewhere else does not count as published here', () async {
    final id = await a.note('Moves house', 'text in the first folder');
    final first = MemoryCloudFolder(), second = MemoryCloudFolder();
    FolderSync at(MemoryCloudFolder f, String place) => FolderSync(
        folder: f,
        library: a.library,
        book: a.book,
        settings: a.settings,
        deviceId: a.identity.id,
        deviceName: a.name,
        key: secret.cloudKey,
        encrypted: true,
        place: place);
    await at(first, 'memory/Notation').run();
    expect(first.files, isNotEmpty);
    expect(second.files, isEmpty);

    await at(second, 'memory/Other').run();
    expect(second.files.length, first.files.length, reason: 'the whole of it is in the other folder');

    // the tablet reads the new folder and has the note
    await FolderSync(folder: second, library: b.library, book: b.book, settings: b.settings, deviceId: b.identity.id, deviceName: b.name, key: secret.cloudKey, encrypted: true).run();
    expect(await b.text(id), 'text in the first folder');
  });

  test('many rounds of changes on both devices (not on the same note at the same time) end with the same notes on both', () async {
    for (final seed in [1, 2, 3]) {
      final random = Random(seed);
      final folder = MemoryCloudFolder();
      final x = await Device.create('X$seed', root, profileId: 'bbbbbbbbbbbbbbbb');
      final y = await Device.create('Y$seed', root, profileId: 'bbbbbbbbbbbbbbbb');
      for (final d in [x, y]) {
        for (final other in [x, y]) {
          await d.book.add(PairedDevice(id: other.identity.id, name: other.name, publicKey: other.identity.publicKey, addedAt: 1));
        }
      }
      Future<void> go(Device d) async {
        final r = await syncOf(d, folder: folder).run();
        expect(r.problems, isEmpty, reason: 'seed $seed');
      }

      final ids = <String>[];
      for (var round = 0; round < 8; round++) {
        final touched = <String>{};
        for (final d in [x, y]) {
          for (var k = 0; k < 3; k++) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
            final live = [for (final n in await d.repo.listNotes()) n.id];
            final free = [for (final id in live) if (!touched.contains(id)) id];
            final pick = random.nextInt(10);
            if (pick < 3 || free.isEmpty) {
              ids.add(await d.note('Note r$round', 'text ${random.nextInt(1000)}'));
              touched.add(ids.last);
            } else if (pick < 8) {
              final id = free[random.nextInt(free.length)];
              touched.add(id);
              await d.edit(id, 'edited ${random.nextInt(1000)}');
            } else {
              final id = free[random.nextInt(free.length)];
              touched.add(id);
              await d.repo.trashNote(id);
            }
          }
        }
        await go(x);
        await go(y);
        await go(x);
        await go(y);
      }
      Future<Map<String, String>> state(Device d) async => {for (final n in await d.repo.listNotes()) n.id: await d.text(n.id)};
      expect(await state(x), await state(y), reason: 'seed $seed: both devices have the same notes');
      expect((await x.repo.listNotes()).any((n) => n.title.contains('before the sync')), isFalse, reason: 'seed $seed: no conflict copies without conflicts');
      await x.db.close();
      await y.db.close();
    }
  });

  group('speed', () {
    test('many notes go up and come down a few at a time, not one by one, and arrive complete', () async {
      cloud.latency = const Duration(milliseconds: 20);
      final ids = [for (var i = 0; i < 12; i++) await a.note('Note $i', 'text $i')];
      final up = await syncOf(a).run();
      expect(up.problems, isEmpty);
      expect(cloud.maxInFlight, inInclusiveRange(2, 4), reason: 'several at once, but no more than asked for');

      cloud.maxInFlight = 0;
      final down = await syncOf(b).run();
      expect(down.problems, isEmpty);
      expect(down.taken, 12);
      expect(cloud.maxInFlight, inInclusiveRange(2, 4));
      for (var i = 0; i < ids.length; i++) {
        expect(await b.text(ids[i]), 'text $i');
      }
    });

    test('a run with nothing to do asks the folder for the manifests of the others and nothing else', () async {
      await a.note('One', 'x');
      for (var round = 0; round < 3; round++) {
        // (the devices note what the other has agreed to; after a few rounds nothing changes any more)
        await run(a);
        await run(b);
      }
      cloud.calls = 0;
      cloud.listings = 0;
      await run(a);
      await run(b);
      expect(cloud.listings, 0, reason: 'files nobody needs are looked for when something was written, not every time');
      expect(cloud.calls, 2, reason: 'one manifest read by each');
    });

    test('files nobody needs any more are still taken away when something was written', () async {
      final id = await a.note('One', 'x');
      await run(a);
      final before = cloud.files.keys.where((k) => k.contains('/n/')).toSet();
      expect(before, hasLength(1));
      await a.edit(id, 'y');
      await run(a);
      final after = cloud.files.keys.where((k) => k.contains('/n/')).toSet();
      expect(after, hasLength(1), reason: 'the old version is gone');
      expect(after, isNot(equals(before)));
    });

    test('one note that cannot go up does not keep the others from going, and is tried again', () async {
      final ids = [for (var i = 0; i < 6; i++) await a.note('Note $i', 'text $i')];
      cloud.failWriteAfter = 2;
      final first = await syncOf(a).run();
      expect(first.problems, hasLength(1));
      final second = await syncOf(a).run();
      expect(second.problems, isEmpty);
      final down = await syncOf(b).run();
      expect(down.taken, ids.length);
    });
  });
}

/// A folder whose account has gone from this device: every request says so.
class _NoAccountFolder implements CloudFolder {
  @override
  Future<Map<String, String>?> stamps(String dir) async => null;

  int requests = 0;

  CloudAccountMissing _fail() {
    requests++;
    return const CloudAccountMissing('The password of the account is not in the keystore of this device.');
  }

  @override
  String get label => 'Gone';

  @override
  Future<List<String>> list(String dir) async => throw _fail();

  @override
  Future<Uint8List?> read(String path) async => throw _fail();

  @override
  Future<void> write(String path, Uint8List bytes) async => throw _fail();

  @override
  Future<void> delete(String path) async => throw _fail();
}

/// The library of a device that writes down the order in which the notes of the others are taken in.
class _Recording extends SyncLibrary {
  final List<String> order;

  _Recording(Device d, this.order) : super(d.db, d.repo, d.files, d.settings, busy: () => d.busy);

  @override
  Future<void> applyNote(String peer, SyncNote info, Uint8List? bytes, {required bool data, required bool meta, String? title, bool lazy = false}) {
    order.add(info.id);
    return super.applyNote(peer, info, bytes, data: data, meta: meta, title: title, lazy: lazy);
  }
}

class _ReadSpy extends MemoryCloudFolder {
  final MemoryCloudFolder inner;
  final List<String> reads;
  _ReadSpy(this.inner, this.reads);

  @override
  Future<Uint8List?> read(String path) {
    reads.add(path);
    return inner.read(path);
  }

  @override
  Future<List<String>> list(String dir) => inner.list(dir);

  @override
  Future<void> write(String path, Uint8List bytes) => inner.write(path, bytes);

  @override
  Future<void> delete(String path) => inner.delete(path);

  @override
  Future<Map<String, String>?> stamps(String dir) => inner.stamps(dir);
}
