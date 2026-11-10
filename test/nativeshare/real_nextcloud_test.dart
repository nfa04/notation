@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

/// The same flows as `nextcloud_shares_test.dart`, against a real Nextcloud. Skipped unless it is given one:
///
///     podman run -d -p 127.0.0.1:8089:80 -e SQLITE_DATABASE=nextcloud -e NEXTCLOUD_ADMIN_USER=alice \
///         -e NEXTCLOUD_ADMIN_PASSWORD=alice-test-pw-1 -e NEXTCLOUD_TRUSTED_DOMAINS='127.0.0.1 localhost' nextcloud:stable
///     # then users bob and carol (occ user:add), passwords `<name>-test-pw-1`
///     UNINOTES_NC_URL=http://127.0.0.1:8089 flutter test test/nativeshare/real_nextcloud_test.dart
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
  final url = Platform.environment['UNINOTES_NC_URL'];
  final skip = url == null ? 'no Nextcloud given (set UNINOTES_NC_URL, see the comment at the top)' : null;

  late Directory root;
  late Device aliceDev, bobDev;
  late NextcloudShares aliceNc, bobNc;
  late NativeShareService alice, bob;

  Future<NextcloudShares> connect(Device d, String user) async {
    final caldav = CalDavService(SettingsRepository(d.db), TaskRepository(d.db), secret: _Secret());
    await caldav.save('$url/remote.php/dav', user, '$user-test-pw-1', taskCalendar: null, eventCalendars: {});
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
    if (url == null) return;
    root = await Directory.systemTemp.createTemp('real_nc_');
    aliceDev = await Device.create('alice-laptop', root);
    bobDev = await Device.create('bob-laptop', root);
    aliceNc = await connect(aliceDev, 'alice');
    bobNc = await connect(bobDev, 'bob');
    alice = serviceOf(aliceDev, aliceNc);
    bob = serviceOf(bobDev, bobNc);
    // what an earlier run left
    try {
      await aliceNc.removeFolder('Notation Shares');
    } catch (_) {}
    try {
      await aliceNc.removeFolder('Docs');
    } catch (_) {}
    for (final s in await bobNc.incoming()) {
      await bobNc.leave(s);
    }
  });
  tearDown(() async {
    if (url == null) return;
    alice.dispose();
    bob.dispose();
    await aliceDev.db.close();
    await bobDev.db.close();
    await root.delete(recursive: true);
  });

  const bobP = SharePerson('bob', 'Bob');

  test('people are found, and a folder is shared, listed, changed and unshared', () async {
    expect((await aliceNc.searchPeople('bo')).map((p) => p.id), ['bob']);
    await aliceNc.folderAt('Docs').write('hello.txt', Uint8List.fromList([1, 2, 3]));
    final s = await aliceNc.share('Docs', bobP, ShareRole.viewer);
    expect(s.role, ShareRole.viewer);
    expect((await aliceNc.share('Docs', bobP, ShareRole.editor)).id, s.id, reason: 'already shared: the role is changed');
    expect((await aliceNc.sharesOf('Docs')).single.role, ShareRole.editor);
    await aliceNc.changeRole(s, ShareRole.viewer);
    expect((await aliceNc.sharesOf('Docs')).single.role, ShareRole.viewer);

    var inn = (await bobNc.incoming()).single;
    if (inn.pending) inn = await bobNc.accept(inn); // (on a server where people take in shares by hand)
    expect((inn.name, inn.owner, inn.role), ('Docs', 'alice', ShareRole.viewer)); // (the admin has no display name set)
    final theirs = bobNc.folderAt(inn.place);
    expect(await theirs.read('hello.txt'), [1, 2, 3]);
    expect(await theirs.list(''), contains('hello.txt'));
    await expectLater(theirs.write('x.txt', Uint8List(1)), throwsA(anything), reason: 'view only');

    await aliceNc.changeRole(s, ShareRole.editor);
    await theirs.write('sub/dir/x.txt', Uint8List.fromList([7]));
    expect(await aliceNc.folderAt('Docs').read('sub/dir/x.txt'), [7]);
    await theirs.delete('sub/dir/x.txt');
    expect(await aliceNc.folderAt('Docs').read('sub/dir/x.txt'), isNull);

    await aliceNc.unshare(s);
    expect(await bobNc.incoming(), isEmpty);
    await aliceNc.removeFolder('Docs');
  }, skip: skip);

  test('a folder of notes is shared and kept in step, and stopping leaves the other person their notes', () async {
    final f = await aliceDev.repo.createFolder('Physics');
    final g = await aliceDev.repo.createFolder('Optics', parentId: f);
    final n1 = await aliceDev.note('Waves', 'w');
    final n2 = await aliceDev.note('Lenses', 'l');
    await aliceDev.repo.moveNote(n1, f);
    await aliceDev.repo.moveNote(n2, g);
    await aliceDev.note('Diary', 'private');

    final share = await alice.shareFolder(f, alice.usable.single, bobP, ShareRole.editor);
    await bob.refreshIncoming();
    final shelf = await bobDev.repo.createFolder('Shared with me');
    final inn = await bob.accept(bob.pending.single, targetFolderId: shelf);
    await bob.syncShare(inn.id);
    expect(bob.statusOf(inn.id).problem, isNull);
    expect({for (final n in await bobDev.repo.listNotes()) n.id}, {n1, n2});

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await bobDev.edit(n1, 'waves, by bob');
    await bob.syncNow();
    await alice.syncNow();
    expect(await aliceDev.text(n1), 'waves, by bob');
    expect(alice.statusOf(share.id).problem, isNull);

    await alice.stopSharing(alice.given.single);
    await bob.refreshIncoming();
    expect(bob.received.single.state, ShareState.ended);
    expect(await bobDev.text(n2), 'l');
  }, skip: skip);

  // Needs a server on which bob does not take in new shares by himself:
  //     occ user:setting bob files_sharing default_accept no      (UNINOTES_NC_PENDING=1 says it is so)
  test('a share that waits is listed apart, without its rights, and is accepted into a place', () async {
    await aliceNc.folderAt('Docs').write('hello.txt', Uint8List.fromList([4, 2]));
    await aliceNc.share('Docs', bobP, ShareRole.editor);
    final waiting = (await bobNc.incoming()).single;
    expect((waiting.pending, waiting.roleKnown, waiting.place, waiting.name, waiting.owner), (true, false, '', 'Docs', 'alice'));
    final taken = await bobNc.accept(waiting);
    expect((taken.pending, taken.role, taken.place), (false, ShareRole.editor, 'Docs'));
    expect(await bobNc.folderAt(taken.place).read('hello.txt'), [4, 2]);
    expect((await bobNc.incoming()).single.pending, isFalse);
    await aliceNc.removeFolder('Docs');
  }, skip: url == null ? skip : (Platform.environment['UNINOTES_NC_PENDING'] == '1' ? null : 'bob takes in shares by himself on this server (UNINOTES_NC_PENDING)'));
}
