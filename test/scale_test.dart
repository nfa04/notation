import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/folder_sync.dart';
import 'package:notes/collab/compression.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_keys.dart';

import 'cloudsync/memory_cloud_folder.dart';
import 'devicesync/harness.dart';

/// How the storage and the cloud-folder sync behave with a big library, in the shapes libraries really take: every note in the top
/// level, every note in one folder, very many small folders, and a chain of folders one in the other.
///
/// What is asserted is what does not depend on the machine: how many requests a run makes and how many files it writes, and that the
/// other device ends with the same folders and the same place for every note. The times and sizes are printed (run with
/// `SCALE_N=5000` for a bigger library; the default is small enough for the normal run).
void main() {
  setUpAll(AppDatabase.initFfi);

  final n = int.tryParse(Platform.environment['SCALE_N'] ?? '') ?? 1200;

  /// A shape: the folders as (id, parent) with parents first, and the folder each note is in (null: none).
  final shapes = <String, ({List<(String, String?)> folders, String? Function(int note, Random rnd, List<String> ids) place, List<(String, String)> then})>{
    'flat: no folders': (folders: const [], place: (i, r, f) => null, then: const []),
    'one folder holds every note': (folders: const [('big', null)], place: (i, r, f) => 'big', then: const []),
    'very split: a folder for every three notes': (
      folders: [for (var i = 0; i < n ~/ 3; i++) ('f$i', i == 0 || i % 4 == 0 ? null : 'f${Random(i).nextInt(i)}')],
      place: (i, r, f) => f[r.nextInt(f.length)],
      then: const [],
    ),
    'a chain of 150 folders, one in the other': (
      folders: [for (var i = 0; i < 150; i++) ('c$i', i == 0 ? null : 'c${i - 1}')],
      place: (i, r, f) => f[r.nextInt(f.length)],
      then: const [],
    ),
    // made top level one by one and then moved into each other, so that the deepest folder comes first in the lists, and deeper than the
    // sync's first sort level
    'a chain of 120 folders made backwards': (
      folders: [for (var i = 0; i < 120; i++) ('b$i', null)],
      place: (i, r, f) => f[r.nextInt(f.length)],
      then: [for (var i = 0; i < 119; i++) ('b$i', 'b${i + 1}')],
    ),
  };

  for (final shape in shapes.entries) {
    test('${shape.key}: $n notes', () async {
      await (() async {
        final root = await Directory.systemTemp.createTemp('scale_');
        final secret = SyncSecret.create(Random(5));
        final cloud = MemoryCloudFolder();
        final a = await Device.create('Laptop', root, profileId: 'aaaaaaaaaaaaaaaa');
        final b = await Device.create('Tablet', root, profileId: 'aaaaaaaaaaaaaaaa');
        addTearDown(() async {
          await a.db.close();
          await b.db.close();
          await root.delete(recursive: true);
        });
        for (final d in [a, b]) {
          for (final o in [a, b]) {
            await d.book.add(PairedDevice(id: o.identity.id, name: o.name, publicKey: o.identity.publicKey, addedAt: 1));
          }
        }
        final rnd = Random(1);
        final base = DateTime.now().millisecondsSinceEpoch - 90 * 86400000;
        final folders = shape.value.folders;
        final folderIds = [for (final f in folders) f.$1];
        final sw = Stopwatch()..start();
        final noteIds = <String>[];
        final noteFolder = <String, String?>{};
        await a.db.transaction((txn) async {
          final batch = txn.batch();
          for (var i = 0; i < folders.length; i++) {
            batch.insert('folders', {'id': folders[i].$1, 'parent_id': folders[i].$2, 'name': 'Folder $i', 'sort_order': i, 'created_at': base, 'updated_at': base + i});
          }
          for (final m in shape.value.then) {
            batch.update('folders', {'parent_id': m.$2}, where: 'id = ?', whereArgs: [m.$1]);
          }
          for (var i = 0; i < n; i++) {
            final t = base + i * 1000000;
            final id = 'n$i-${rnd.nextInt(1 << 30).toRadixString(16)}';
            final folder = shape.value.place(i, rnd, folderIds);
            noteIds.add(id);
            noteFolder[id] = folder;
            batch.insert('notes', {
              'id': id,
              'folder_id': folder,
              'title': 'Note $i',
              'document_text': List.generate(300, (_) => 'word${rnd.nextInt(5000)}').join(' '),
              'created_at': t,
              'updated_at': t,
            });
          }
          await batch.commit(noResult: true);
        });
        // what a library that has been synced for a while carries: 30 versions each note grew from, and what the other device has agreed
        await a.db.transaction((txn) async {
          final batch = txn.batch();
          for (final id in noteIds) {
            final v = (await txn.query('notes', columns: ['updated_at'], where: 'id = ?', whereArgs: [id])).single['updated_at'] as int;
            batch.insert('sync_lineage', {'id': id, 'cur': v, 'anc': jsonEncode([for (var k = 1; k <= 30; k++) v - k * 3600000])});
            batch.insert('sync_marks', {'peer': b.identity.id, 'kind': 'note', 'id': id, 'version': v, 'meta': '${noteFolder[id] ?? ''}|0|0'});
          }
          await batch.commit(noResult: true);
        });
        debugPrint('[${shape.key}] seeded ${folders.length} folders and $n notes in ${sw.elapsedMilliseconds} ms');

        Future<T> timed<T>(String what, Future<T> Function() f) async {
          sw
            ..reset()
            ..start();
          final r = await f();
          debugPrint('[${shape.key}] $what: ${sw.elapsedMilliseconds} ms');
          return r;
        }

        final manifest = await timed('manifest()', a.library.manifest);
        final json = utf8.encode(jsonEncode(manifest.toJson()));
        final packed = await packMessage(Uint8List.fromList(json));
        debugPrint('[${shape.key}] manifest ${json.length ~/ 1024} KB, ${packed.length ~/ 1024} KB packed');
        expect((await timed('listNotes', a.repo.listNotes)).length, n);
        expect((await timed('listFolders', a.repo.listFolders)).length, folders.length);
        expect((await timed('searchSources', a.repo.text.searchSources)).length, 2 * n);

        FolderSync syncOf(Device d) => FolderSync(
            folder: cloud, library: d.library, book: d.book, settings: d.settings, deviceId: d.identity.id, deviceName: d.name, key: secret.cloudKey, encrypted: true);

        var r = await timed('A publishes everything', () => syncOf(a).run());
        expect(r.problems, isEmpty);
        expect(r.put, n + 1, reason: 'a file for every note and the manifest, nothing for folders');
        r = await timed('B takes everything', () => syncOf(b).run());
        expect(r.problems, isEmpty);
        expect(r.taken, n + folders.length);

        // the same folders, and every note in the same place
        Future<Map<String, String?>> parents(Device d) async => {for (final f in await d.repo.listFolders()) f.id: f.parentId};
        expect(await parents(b), await parents(a), reason: 'the folders must arrive as they are, whatever they are in');
        final placed = {for (final x in await b.db.query('notes', columns: ['id', 'folder_id'])) x['id'] as String: x['folder_id'] as String?};
        expect(placed, noteFolder);

        // idle runs ask for one file (the manifest of the other device), whatever the size
        for (final d in [a, b]) {
          cloud.calls = 0;
          r = await timed('${d.name} idle run', () => syncOf(d).run());
          expect(r.put, 0);
          expect(cloud.calls, 1);
        }
        // a change to one note: its file and the manifest are written; the other device reads the manifest and that one file
        await a.edit(noteIds.first, 'changed');
        cloud.calls = 0;
        final writes = cloud.writes;
        r = await timed('A after one edit', () => syncOf(a).run());
        expect(cloud.writes - writes, 2);
        expect(cloud.calls, lessThan(10));
        cloud.calls = 0;
        r = await timed('B after that', () => syncOf(b).run());
        expect(r.taken, 1);
        expect(cloud.calls, lessThan(10));

        if (folders.isNotEmpty) {
          // the folder with the most notes is deleted: its notes stay, in no folder, on both devices
          final counts = <String, int>{};
          for (final f in noteFolder.values) {
            if (f != null) counts[f] = (counts[f] ?? 0) + 1;
          }
          final biggest = counts.entries.reduce((x, y) => y.value > x.value ? y : x).key;
          final inside = [for (final e in noteFolder.entries) if (e.value == biggest) e.key];
          await timed('delete the folder with ${inside.length} notes', () => a.repo.deleteFolder(biggest));
          expect((await syncOf(a).run()).problems, isEmpty);
          expect((await syncOf(b).run()).problems, isEmpty);
          for (final d in [a, b]) {
            expect((await d.repo.listFolders()).any((f) => f.id == biggest), isFalse);
            expect((await d.repo.listNotes()).length, n, reason: 'no note is lost with its folder');
            for (final id in inside.take(20)) {
              expect((await d.repo.listNotes()).firstWhere((x) => x.id == id).folderId, isNull);
            }
          }
        }
      })();
    }, timeout: const Timeout(Duration(minutes: 15)));
  }
}
