import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/folder_sync.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/sync_library.dart' show syncedSetting;
import 'package:notes/nativeshare/native_share_provider.dart';
import 'package:notes/nativeshare/share_model.dart';
import 'package:notes/nativeshare/shared_folder_sync.dart';

import '../devicesync/harness.dart';
import 'fake_share_provider.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late Device alice, bob;
  late FakeShareHub hub;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nativeshare_');
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

  NativeShare given(ShareKind kind, String rootId, {String id = 's1'}) =>
      NativeShare(id: id, providerId: 'fake', direction: ShareDirection.outgoing, kind: kind, rootId: rootId, name: 'Physics', place: place, createdAt: 1);

  NativeShare received(ShareKind kind, String rootId, {ShareRole role = ShareRole.editor, String? target, String id = 's1'}) => NativeShare(
        id: id,
        providerId: 'fake',
        direction: ShareDirection.incoming,
        kind: kind,
        rootId: rootId,
        name: 'Physics',
        place: 'alice@$place',
        role: role,
        owner: 'Alice',
        targetFolderId: target,
        createdAt: 1,
      );

  SharedFolderSync runner(Device d, String user, NativeShare s) => SharedFolderSync(
        share: s,
        provider: hub.as(user),
        library: d.library,
        db: d.db,
        settings: d.settings,
        deviceId: d.identity.id,
        deviceName: d.name,
        retryDelays: const [],
      );

  Future<SharedRunResult> run(Device d, String user, NativeShare s) async {
    final r = await runner(d, user, s).run();
    expect(r.sync.problems, isEmpty);
    return r;
  }

  Future<void> grant(String to, ShareRole role) => hub.as('alice').share(place, SharePerson(to, to), role);

  Future<Set<String>> noteIds(Device d) async => {for (final n in await d.repo.listNotes()) n.id};

  group('a note', () {
    test('goes to the person it is shared with, and edits go both ways', () async {
      final id = await alice.note('Optics', 'light is a wave');
      await grant('bob', ShareRole.editor);
      final out = given(ShareKind.note, id), inn = received(ShareKind.note, id);
      await run(alice, 'alice', out);
      await run(bob, 'bob', inn);
      expect(await bob.text(id), 'light is a wave');

      await bob.edit(id, 'light is a wave and a particle');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await run(bob, 'bob', inn);
      await run(alice, 'alice', out);
      expect(await alice.text(id), 'light is a wave and a particle');

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await alice.edit(id, 'light: both');
      await run(alice, 'alice', out);
      await run(bob, 'bob', inn);
      expect(await bob.text(id), 'light: both');
    });

    test('is put where the person chose, and stays there', () async {
      final id = await alice.note('Optics', 'x');
      final shelf = await bob.repo.createFolder('Shared with me');
      final elsewhere = await bob.repo.createFolder('Elsewhere');
      await grant('bob', ShareRole.editor);
      await run(alice, 'alice', given(ShareKind.note, id));
      final inn = received(ShareKind.note, id, target: shelf);
      await run(bob, 'bob', inn);
      expect((await bob.repo.noteInfo(id))!.folderId, shelf);
      await bob.repo.moveNote(id, elsewhere);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await alice.edit(id, 'changed');
      await run(alice, 'alice', given(ShareKind.note, id));
      await run(bob, 'bob', inn);
      expect(await bob.text(id), 'changed');
      expect((await bob.repo.noteInfo(id))!.folderId, elsewhere, reason: 'the owner\'s next version must not move it back');
    });

    test('a person who may only view never writes, and the owner\'s next version replaces their edit (kept as a copy)', () async {
      final id = await alice.note('Optics', 'v1');
      await grant('bob', ShareRole.viewer);
      final out = given(ShareKind.note, id), inn = received(ShareKind.note, id, role: ShareRole.viewer);
      await run(alice, 'alice', out);
      await run(bob, 'bob', inn);
      expect(await bob.text(id), 'v1');
      await bob.edit(id, 'bob scribbles');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await run(bob, 'bob', inn); // (the service would refuse a write: nothing is tried)
      expect(hub.folderOf('alice', place).files.keys.where((k) => k.contains(bob.identity.id)), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await alice.edit(id, 'v2');
      await run(alice, 'alice', out);
      await run(bob, 'bob', inn);
      expect(await bob.text(id), 'v2');
      expect((await bob.repo.listNotes()).length, 2, reason: 'what bob wrote is kept next to it');
      await run(alice, 'alice', out);
      expect(await alice.text(id), 'v2');
      expect((await alice.repo.listNotes()).length, 1);
    });

    test('nothing else of the library goes with it, and a locked note is not published', () async {
      final id = await alice.note('Optics', 'x');
      await alice.note('Diary', 'private');
      await grant('bob', ShareRole.editor);
      await run(alice, 'alice', given(ShareKind.note, id));
      await run(bob, 'bob', received(ShareKind.note, id));
      expect(await noteIds(bob), {id});
      final files = hub.folderOf('alice', place).files;
      expect(files.values.any((b) => utf8.decode(b, allowMalformed: true).contains('private')), isFalse);
    });

    test('the owner deleting it ends the share and leaves the note with the others', () async {
      final id = await alice.note('Optics', 'x');
      await grant('bob', ShareRole.editor);
      final out = given(ShareKind.note, id), inn = received(ShareKind.note, id);
      await run(alice, 'alice', out);
      await run(bob, 'bob', inn);
      await alice.repo.deleteNote(id);
      await run(alice, 'alice', out);
      final r = await run(bob, 'bob', inn);
      expect(r.ended, isTrue);
      expect(await bob.text(id), 'x', reason: 'what the person has stays');
    });
  });

  group('a folder', () {
    test('goes with what is in it, below it, and only that', () async {
      final f = await alice.repo.createFolder('Physics');
      final g = await alice.repo.createFolder('Optics', parentId: f);
      final n1 = await alice.note('Waves', 'w');
      final n2 = await alice.note('Lenses', 'l');
      final outside = await alice.note('Diary', 'private');
      await alice.repo.moveNote(n1, f);
      await alice.repo.moveNote(n2, g);
      await grant('bob', ShareRole.editor);
      await run(alice, 'alice', given(ShareKind.folder, f));
      final shelf = await bob.repo.createFolder('Shared with me');
      await run(bob, 'bob', received(ShareKind.folder, f, target: shelf));

      expect(await noteIds(bob), {n1, n2});
      expect(await noteIds(bob), isNot(contains(outside)));
      final folders = {for (final x in await bob.repo.listFolders()) x.id: x};
      expect(folders[f]!.parentId, shelf, reason: 'the root is where the person chose, not where the owner keeps it');
      expect(folders[g]!.parentId, f);
      expect((await bob.repo.noteInfo(n2))!.folderId, g);
    });

    test('a note anyone adds to it joins, and one moved out stays with those who have it', () async {
      final f = await alice.repo.createFolder('Physics');
      final n1 = await alice.note('Waves', 'w');
      await alice.repo.moveNote(n1, f);
      await grant('bob', ShareRole.editor);
      final out = given(ShareKind.folder, f), inn = received(ShareKind.folder, f);
      await run(alice, 'alice', out);
      await run(bob, 'bob', inn);

      final fromBob = await bob.note('Bob\'s idea', 'b');
      await bob.repo.moveNote(fromBob, f);
      await run(bob, 'bob', inn);
      await run(alice, 'alice', out);
      expect(await alice.text(fromBob), 'b');

      await alice.repo.moveNote(n1, null);
      await run(alice, 'alice', out);
      await run(bob, 'bob', inn);
      expect(await noteIds(bob), contains(n1), reason: 'moved out is not deleted');
      // and what changes later is not carried: it left the share
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await alice.edit(n1, 'private now');
      await run(alice, 'alice', out);
      await run(bob, 'bob', inn);
      expect(await bob.text(n1), 'w');
    });

    test('a deletion travels to those who have the note', () async {
      final f = await alice.repo.createFolder('Physics');
      final n1 = await alice.note('Waves', 'w');
      await alice.repo.moveNote(n1, f);
      await grant('bob', ShareRole.editor);
      final out = given(ShareKind.folder, f), inn = received(ShareKind.folder, f);
      await run(alice, 'alice', out);
      await run(bob, 'bob', inn);
      expect(await noteIds(bob), contains(n1));
      await alice.repo.deleteNote(n1);
      await run(alice, 'alice', out);
      await run(bob, 'bob', inn);
      expect(await noteIds(bob), isNot(contains(n1)));
    });

    test('the owner deleting the folder ends the share and leaves the notes', () async {
      final f = await alice.repo.createFolder('Physics');
      final n1 = await alice.note('Waves', 'w');
      await alice.repo.moveNote(n1, f);
      await grant('bob', ShareRole.editor);
      final out = given(ShareKind.folder, f), inn = received(ShareKind.folder, f);
      await run(alice, 'alice', out);
      await run(bob, 'bob', inn);
      await alice.repo.deleteFolder(f);
      await run(alice, 'alice', out);
      final r = await run(bob, 'bob', inn);
      expect(r.ended, isTrue);
      expect((await bob.repo.listFolders()).any((x) => x.id == f), isTrue, reason: 'the folder is not deleted here');
    });
  });

  group('what a participant publishes is not trusted', () {
    final key = Uint8List(32);

    /// Puts a manifest in the shared folder as the device [as] (anyone who can write in the folder can).
    Future<void> plant(String as, {List<Map<String, Object?>> notes = const [], List<Map<String, Object?>> folders = const [], List<Map<String, Object?>> tombs = const [], List<Map<String, Object?>> settings = const [], Map<String, Uint8List> files = const {}}) async {
      final folder = hub.folderOf('alice', place);
      final dir = FolderSync.directory(key, as, false);
      folder.files['p/$as'] = Uint8List.fromList(utf8.encode(jsonEncode({'id': as, 'name': 'Mallory'})));
      for (final e in files.entries) {
        folder.files['$dir/n/${e.key}'] = e.value;
      }
      folder.files['$dir/manifest.json'] = Uint8List.fromList(utf8.encode(jsonEncode({
        'v': FolderSync.formatVersion,
        'device': as,
        'name': 'Mallory',
        'm': {'folders': folders, 'notes': notes, 'settings': settings, 'tombs': tombs},
        'notes': {for (final k in files.keys) k.split('.').first: 'n/$k'},
        'images': {},
      })));
    }

    Map<String, Object?> noteLine(String id, {String? folderId}) => {'id': id, 'v': DateTime.now().millisecondsSinceEpoch + 100000, 'c': 1, 'f': folderId, 'star': false, 'del': null};

    test('a note that is here and not part of the share is not overwritten, whatever the manifest says', () async {
      final f = await alice.repo.createFolder('Physics');
      final n1 = await alice.note('Waves', 'w');
      await alice.repo.moveNote(n1, f);
      final secret = await bob.note('Secret', 'bob\'s own');
      await grant('bob', ShareRole.editor);
      final out = given(ShareKind.folder, f), inn = received(ShareKind.folder, f);
      await run(alice, 'alice', out);
      final bytes = (await alice.library.noteBytes(n1))!;
      await plant('mallory', notes: [noteLine(secret, folderId: f), noteLine('newnote', folderId: f)], files: {'$secret.1.uninote': bytes, 'newnote.1.uninote': bytes});
      await run(bob, 'bob', inn);
      expect(await bob.text(secret), 'bob\'s own');
      expect((await bob.repo.noteInfo(secret))!.folderId, isNull, reason: 'it must not be pulled into the shared folder either');
      expect(await noteIds(bob), contains('newnote'), reason: 'a new note in the shared folder is taken');
    });

    test('a note outside the shared folder, and settings, are not taken', () async {
      final f = await alice.repo.createFolder('Physics');
      await grant('bob', ShareRole.editor);
      final out = given(ShareKind.folder, f), inn = received(ShareKind.folder, f);
      await run(alice, 'alice', out);
      final bytes = (await alice.library.noteBytes(await alice.note('x', 'x')))!;
      await plant('mallory',
          notes: [noteLine('offside', folderId: 'not-in-the-share'), noteLine('toplevel')],
          settings: [{'k': 'app_accent', 'v': '123', 'at': DateTime.now().millisecondsSinceEpoch + 100000}],
          files: {'offside.1.uninote': bytes, 'toplevel.1.uninote': bytes});
      await run(bob, 'bob', inn);
      expect(await noteIds(bob), isNot(contains('offside')));
      expect(await noteIds(bob), isNot(contains('toplevel')));
      expect(await bob.settings.get('app_accent'), isNull);
    });

    test('a deletion reaches only what belongs to the share', () async {
      final f = await alice.repo.createFolder('Physics');
      final n1 = await alice.note('Waves', 'w');
      await alice.repo.moveNote(n1, f);
      final mine = await bob.note('Mine', 'keep');
      final myFolder = await bob.repo.createFolder('Keep');
      await grant('bob', ShareRole.editor);
      final out = given(ShareKind.folder, f), inn = received(ShareKind.folder, f);
      await run(alice, 'alice', out);
      await run(bob, 'bob', inn);
      final later = DateTime.now().millisecondsSinceEpoch + 100000;
      await plant('mallory', tombs: [
        {'kind': 'note', 'id': mine, 'at': later},
        {'kind': 'folder', 'id': myFolder, 'at': later},
        {'kind': 'note', 'id': n1, 'at': later},
      ]);
      await run(bob, 'bob', inn);
      expect(await noteIds(bob), contains(mine));
      expect((await bob.repo.listFolders()).any((x) => x.id == myFolder), isTrue);
      expect(await noteIds(bob), isNot(contains(n1)), reason: 'what belongs to the share can be deleted by a participant');
    });

    test('a folder id that is here and not part of the share is not taken over', () async {
      final f = await alice.repo.createFolder('Physics');
      final own = await bob.repo.createFolder('Bob\'s own');
      await grant('bob', ShareRole.editor);
      final out = given(ShareKind.folder, f), inn = received(ShareKind.folder, f);
      await run(alice, 'alice', out);
      await plant('mallory', folders: [{'id': own, 'parent': f, 'name': 'Renamed by mallory', 'color': null, 'sort': 0, 'at': DateTime.now().millisecondsSinceEpoch + 100000}]);
      await run(bob, 'bob', inn);
      final mine = (await bob.repo.listFolders()).firstWhere((x) => x.id == own);
      expect((mine.name, mine.parentId), ('Bob\'s own', null));
    });

    test('a participant file that claims another device\'s id is ignored; a folder without a descriptor-free manifest is not a problem', () async {
      final id = await alice.note('Optics', 'x');
      await grant('bob', ShareRole.editor);
      final out = given(ShareKind.note, id), inn = received(ShareKind.note, id);
      await run(alice, 'alice', out);
      final folder = hub.folderOf('alice', place);
      folder.files['p/someone'] = Uint8List.fromList(utf8.encode(jsonEncode({'id': 'somebody-else', 'name': 'x'})));
      folder.files['p/garbage'] = Uint8List.fromList([1, 2, 3]);
      final r = await run(bob, 'bob', inn);
      expect(r.sync.devices, 1, reason: 'only alice\'s device took part');
    });
  });

  test('two shares of the same device do not take each other\'s state', () async {
    final a = await alice.note('One', '1');
    final b = await alice.note('Two', '2');
    await grant('bob', ShareRole.editor);
    final s1 = given(ShareKind.note, a, id: 's1');
    const place2 = 'Notation Shares/Two (Notation bbbbbb)';
    final s2 = NativeShare(id: 's2', providerId: 'fake', direction: ShareDirection.outgoing, kind: ShareKind.note, rootId: b, name: 'Two', place: place2, createdAt: 1);
    await hub.as('alice').share(place2, const SharePerson('bob', 'bob'), ShareRole.editor);
    await run(alice, 'alice', s1);
    await run(alice, 'alice', s2);
    final r1 = await run(bob, 'bob', received(ShareKind.note, a, id: 's1'));
    final r2 = await run(bob, 'bob', NativeShare(id: 's2', providerId: 'fake', direction: ShareDirection.incoming, kind: ShareKind.note, rootId: b, name: 'Two', place: 'alice@$place2', createdAt: 1));
    expect((r1.sync.taken, r2.sync.taken), (1, 1));
    expect(await noteIds(bob), {a, b});
  });

  test('a share keeps its own books: the sync of the profile is not touched, and nothing of it travels to the devices of the profile', () async {
    final id = await alice.note('Optics', 'x');
    await grant('bob', ShareRole.editor);
    await run(alice, 'alice', given(ShareKind.note, id));
    expect(await alice.settings.get('cloud_published'), isNull);
    expect(await alice.settings.get('cloud_published_hash'), isNull);
    expect(await alice.settings.get('share_s1_cloud_published'), isNotNull);
    expect(syncedSetting('share_s1_cloud_published'), isFalse);
    expect(syncedSetting('share_s1_cloud_published_hash'), isFalse);
  });
}
