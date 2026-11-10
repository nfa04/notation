import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/cloud_folder.dart';
import 'package:notes/collab/nextcloud_storage.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/nativeshare/native_share_provider.dart';
import 'package:notes/nativeshare/native_share_service.dart';
import 'package:notes/nativeshare/nextcloud_shares.dart';
import 'package:notes/nativeshare/share_model.dart';
import 'package:notes/sync/caldav_service.dart';

import '../devicesync/harness.dart';
import 'fake_nextcloud_users.dart';

class _Secret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late FakeNextcloudUsers cloud;
  late Device aliceDev, bobDev;
  late NextcloudShares aliceNc, bobNc;
  late NativeShareService alice, bob;

  Future<NextcloudShares> connect(Device d, String user) async {
    final caldav = CalDavService(SettingsRepository(d.db), TaskRepository(d.db), secret: _Secret());
    await caldav.save('${cloud.address}/remote.php/dav', user, cloud.passwords[user]!, taskCalendar: null, eventCalendars: {});
    return NextcloudShares(NextcloudStorage(caldav));
  }

  NativeShareService serviceOf(Device d, NextcloudShares nc) => NativeShareService(
        db: d.db,
        settings: d.settings,
        library: d.library,
        providers: [nc],
        deviceId: () => d.identity.id,
        deviceName: () => d.name,
        every: const Duration(hours: 1),
        afterChange: const Duration(hours: 1),
        retryDelays: const [],
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nc_shares_');
    cloud = FakeNextcloudUsers();
    await cloud.start();
    aliceDev = await Device.create('alice-laptop', root);
    bobDev = await Device.create('bob-laptop', root);
    aliceNc = await connect(aliceDev, 'alice');
    bobNc = await connect(bobDev, 'bob');
    alice = serviceOf(aliceDev, aliceNc);
    bob = serviceOf(bobDev, bobNc);
  });
  tearDown(() async {
    alice.dispose();
    bob.dispose();
    await cloud.stop();
    await aliceDev.db.close();
    await bobDev.db.close();
    await root.delete(recursive: true);
  });

  const bobP = SharePerson('bob', 'Bob');

  group('the Share API', () {
    test('finds people by the start of their name, not the person asking', () async {
      expect((await aliceNc.searchPeople('bo')).map((p) => (p.id, p.label)), [('bob', 'Bob')]);
      expect((await aliceNc.searchPeople('A')).map((p) => p.id), isEmpty, reason: 'not alice herself');
      expect(await aliceNc.searchPeople('  '), isEmpty);
    });

    test('shares a folder with a role, lists it, changes it, takes it away', () async {
      cloud.dirs['alice']!.add('/Docs');
      final s = await aliceNc.share('Docs', bobP, ShareRole.viewer);
      expect(cloud.shares.single['perms'], 1);
      expect(s.role, ShareRole.viewer);
      final again = await aliceNc.share('Docs', bobP, ShareRole.editor); // already shared: the role is changed
      expect(again.id, s.id);
      expect(cloud.shares.single['perms'], 15);
      expect((await aliceNc.sharesOf('Docs')).single.role, ShareRole.editor);
      await aliceNc.changeRole(s, ShareRole.viewer);
      expect((await aliceNc.sharesOf('Docs')).single.role, ShareRole.viewer);
      await aliceNc.unshare(s);
      expect(await aliceNc.sharesOf('Docs'), isEmpty);
      await aliceNc.unshare(s); // (gone already: not an error)
    });

    test('tells in one request what changed in a folder and in each thing in it', () async {
      final mine = aliceNc.folderAt('Docs');
      await mine.write('a/b.txt', Uint8List.fromList([1, 2, 3]));
      await mine.write('c/d.txt', Uint8List.fromList([4]));
      final before = (await mine.stamps(''))!;
      expect(before.keys.toSet(), {'', 'a', 'c'}, reason: 'the folder itself and what is directly in it');
      cloud.log.clear();
      expect((await mine.stamps(''))!, before, reason: 'asked again, nothing changed');
      expect(cloud.log.length, 1, reason: 'one request');

      await mine.write('a/b.txt', Uint8List.fromList([9, 9]));
      final after = (await mine.stamps(''))!;
      expect(after[''], isNot(before['']), reason: 'something below changed');
      expect(after['a'], isNot(before['a']));
      expect(after['c'], before['c'], reason: 'the other directory did not');

      expect(await mine.stamps('nowhere'), isEmpty);
    });

    test('says what the server said when it refuses', () async {
      await expectLater(aliceNc.share('Nowhere', bobP, ShareRole.viewer), throwsA(isA<NativeShareException>().having((e) => e.message, 'm', contains("doesn't exist"))));
      cloud.dirs['alice']!.add('/Docs');
      await expectLater(aliceNc.share('Docs', const SharePerson('nobody', 'Nobody'), ShareRole.viewer), throwsA(isA<NativeShareException>()));
    });

    test('the other person sees it under the name it got, and reads and writes as far as the rights go', () async {
      cloud.dirs['alice']!.add('/Docs');
      cloud.dirs['bob']!.add('/Docs'); // (bob has a "Docs" already: it comes as "Docs (2)")
      await aliceNc.share('Docs', bobP, ShareRole.viewer);
      final inn = (await bobNc.incoming()).single;
      expect((inn.place, inn.role, inn.owner, inn.pending), ('Docs (2)', ShareRole.viewer, 'Alice', false));

      await aliceNc.folderAt('Docs').write('a/b.txt', Uint8List.fromList([1, 2, 3]));
      final theirs = bobNc.folderAt(inn.place);
      expect(await theirs.read('a/b.txt'), [1, 2, 3]);
      expect(await theirs.list('a'), ['b.txt']);
      await expectLater(theirs.write('c.txt', Uint8List(1)), throwsA(isA<CloudFolderException>()), reason: 'view only');
      await expectLater(theirs.delete('a/b.txt'), throwsA(isA<CloudFolderException>()));

      await aliceNc.changeRole(ProviderShare('${cloud.shares.single['id']}', bobP, ShareRole.viewer), ShareRole.editor);
      await theirs.write('a/c.txt', Uint8List.fromList([9]));
      expect(cloud.files['alice']!['/Docs/a/c.txt'], [9]);
      await theirs.delete('a/b.txt');
      expect(cloud.files['alice']!.containsKey('/Docs/a/b.txt'), isFalse);
    });

    test('a share that waits is accepted, and is then somewhere', () async {
      cloud.pendingShares = true;
      cloud.dirs['alice']!.add('/Docs');
      await aliceNc.share('Docs', bobP, ShareRole.editor);
      final waiting = (await bobNc.incoming()).single;
      expect((waiting.pending, waiting.place, waiting.roleKnown), (true, '', false));
      expect(cloud.log.where((l) => l.contains('/shares/pending')), isNotEmpty);
      final accepted = await bobNc.accept(waiting);
      expect((accepted.pending, accepted.place, accepted.role), (false, 'Docs', ShareRole.editor));
    });

    test('leaving takes it from the list of the person, and removing the folder takes it from everyone', () async {
      cloud.dirs['alice']!.add('/Docs');
      await aliceNc.share('Docs', bobP, ShareRole.editor);
      await bobNc.leave((await bobNc.incoming()).single);
      expect(await bobNc.incoming(), isEmpty);
      await aliceNc.share('Docs', bobP, ShareRole.editor);
      await aliceNc.removeFolder('Docs');
      expect(cloud.dirs['alice']!, isNot(contains('/Docs')));
      expect(await bobNc.incoming(), isEmpty);
    });

    test('a server that allows no more new shares for now says to wait', () async {
      cloud.dirs['alice']!.add('/Docs');
      cloud.rateLimited = true;
      await expectLater(aliceNc.share('Docs', bobP, ShareRole.viewer), throwsA(isA<NativeShareException>().having((e) => e.message, 'm', contains('Try again in a few minutes'))));
    });

    test('a wrong password is said as such', () async {
      final caldav = CalDavService(SettingsRepository(aliceDev.db), TaskRepository(aliceDev.db), secret: _Secret());
      await caldav.save('${cloud.address}/remote.php/dav', 'alice', 'wrong', taskCalendar: null, eventCalendars: {});
      await expectLater(NextcloudShares(NextcloudStorage(caldav)).searchPeople('b'), throwsA(isA<NativeShareException>().having((e) => e.message, 'm', contains('did not accept the login'))));
    });
  });

  test('a folder of notes is shared and kept in step between two people on the same Nextcloud, through the real provider', () async {
    final f = await aliceDev.repo.createFolder('Physics');
    final g = await aliceDev.repo.createFolder('Optics', parentId: f);
    final n1 = await aliceDev.note('Waves', 'w');
    final n2 = await aliceDev.note('Lenses', 'l');
    await aliceDev.repo.moveNote(n1, f);
    await aliceDev.repo.moveNote(n2, g);
    await aliceDev.note('Diary', 'private');

    final share = await alice.shareFolder(f, alice.usable.single, bobP, ShareRole.editor);
    expect(share.place, startsWith('Notation Shares/Physics (Notation '));
    expect(cloud.files['alice']!.keys.where((k) => k.contains('private')), isEmpty);

    await bob.refreshIncoming();
    final shelf = await bobDev.repo.createFolder('Shared with me');
    final inn = await bob.accept(bob.pending.single, targetFolderId: shelf);
    expect(inn.kind, ShareKind.folder);
    await bob.syncShare(inn.id);
    expect(bob.statusOf(inn.id).problem, isNull);
    expect({for (final n in await bobDev.repo.listNotes()) n.id}, {n1, n2});
    expect((await bobDev.repo.listFolders()).firstWhere((x) => x.id == f).parentId, shelf);

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await bobDev.edit(n1, 'waves, by bob');
    await bob.syncNow();
    await alice.syncNow();
    expect(await aliceDev.text(n1), 'waves, by bob');

    // the owner stops: the other person keeps the notes
    await alice.stopSharing(alice.given.single);
    await bob.refreshIncoming();
    expect(bob.received.single.state, ShareState.ended);
    expect(await bobDev.text(n2), 'l');
  });

  test('quick runs through the real provider: an idle share costs one request, and a change by the other person still arrives', () async {
    final id = await aliceDev.note('Waves', 'w');
    final share = await alice.shareNote(id, alice.usable.single, bobP, ShareRole.editor);
    await bob.refreshIncoming();
    final inn = await bob.accept(bob.pending.single);
    for (var i = 0; i < 3; i++) {
      await alice.syncNow(quick: true);
      await bob.syncNow(quick: true);
    }
    cloud.log.clear();
    await alice.syncNow(quick: true);
    await bob.syncNow(quick: true);
    final dav = cloud.log.where((l) => l.contains('/remote.php/dav/')).toList();
    expect(dav.length, 2, reason: 'one PROPFIND for each person: $dav');
    expect(dav.every((l) => l.startsWith('PROPFIND')), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await bobDev.edit(id, 'waves, by bob');
    await bob.syncShare(inn.id); // (what a change here does)
    await alice.syncNow(quick: true);
    expect(await aliceDev.text(id), 'waves, by bob', reason: share.place);
  });

  test('an ordinary shared folder is not mistaken for a share of Notation', () async {
    cloud.dirs['carol']!.add('/Holiday photos');
    cloud.shares.add({'id': 99, 'owner': 'carol', 'path': '/Holiday photos', 'with': 'bob', 'perms': 1, 'target': '/Holiday photos', 'state': 0});
    await bob.refreshIncoming();
    expect(bob.pending, isEmpty);
  });
}
