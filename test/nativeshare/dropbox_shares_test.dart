import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/cloud_folder.dart';
import 'package:notes/collab/dropbox_storage.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/nativeshare/dropbox_shares.dart';
import 'package:notes/nativeshare/native_share_provider.dart';
import 'package:notes/nativeshare/native_share_service.dart';
import 'package:notes/nativeshare/share_model.dart';
import 'package:notes/sync/caldav_service.dart';

import '../devicesync/harness.dart';
import 'fake_dropbox.dart';

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
  late FakeDropbox dropbox;
  late Device aliceDev, bobDev;
  late DropboxShares aliceDb, bobDb;
  late NativeShareService alice, bob;

  Future<DropboxStorage> signedIn(Device d, String user, {bool? sharing, bool fullAccess = true}) async {
    final s = DropboxStorage(appKey: 'key', fullAccess: fullAccess, settings: d.settings, store: _Secret(), apiHost: dropbox.address, contentHost: dropbox.address);
    await d.settings.remove('dropbox_sharing');
    await s.load();
    if (sharing != null) await s.setSharing(sharing);
    await s.oauth.adopt(dropbox.refreshTokenOf(user));
    return s;
  }

  NativeShareService serviceOf(Device d, NativeShareProvider p) => NativeShareService(
        db: d.db,
        settings: d.settings,
        library: d.library,
        providers: [p],
        deviceId: () => d.identity.id,
        deviceName: () => d.name,
        every: const Duration(hours: 1),
        afterChange: const Duration(hours: 1),
        retryDelays: const [],
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('db_shares_');
    dropbox = FakeDropbox();
    await dropbox.start();
    aliceDev = await Device.create('alice-laptop', root);
    bobDev = await Device.create('bob-laptop', root);
    aliceDb = DropboxShares(await signedIn(aliceDev, 'alice'));
    bobDb = DropboxShares(await signedIn(bobDev, 'bob'));
    alice = serviceOf(aliceDev, aliceDb);
    bob = serviceOf(bobDev, bobDb);
  });
  tearDown(() async {
    alice.dispose();
    bob.dispose();
    await dropbox.stop();
    await aliceDev.db.close();
    await bobDev.db.close();
    await root.delete(recursive: true);
  });

  const bobP = SharePerson('bob@example.org', 'Bob');
  const place = 'Notation Shares/Docs (Notation aaaaaa)';

  Future<void> putDoc() => aliceDb.folderAt(place).write('hello.txt', Uint8List.fromList([1, 2, 3]));

  group('the account', () {
    test('sharing is on from the start for an app with access to the whole Dropbox, and a choice for the others', () async {
      final full = await signedIn(aliceDev, 'alice');
      expect(full.sharingEnabled, isTrue);
      expect(full.oauth.scopes, contains('sharing.read'));
      expect(await full.oauth.accessToken(), 'tokA');
      expect(full.canShare, isTrue);
      expect(DropboxShares(full).unsupportedReason, isNull);

      final folder = await signedIn(aliceDev, 'alice', fullAccess: false);
      expect(folder.sharingEnabled, isFalse);
      expect(folder.oauth.scopes, isNot(contains('sharing.read')), reason: 'an app that was not registered for it would be refused at the sign-in');
      expect(DropboxShares(folder).unsupportedReason, contains('Allow sharing'));
      await folder.setSharing(true);
      expect(folder.oauth.scopes, contains('sharing.read'));
      expect(folder.available, isFalse, reason: 'a new sign-in is needed for the new permission');
    });

    test('a sign-in that was given less than it needs says to sign in again', () async {
      dropbox.grantedScope = 'files.content.write files.content.read files.metadata.read sharing.write';
      final s = await signedIn(aliceDev, 'alice');
      await s.oauth.accessToken();
      expect(s.canShare, isFalse);
      expect(DropboxShares(s).unsupportedReason, contains('Sign in to Dropbox again'));
    });
  });

  group('the folder', () {
    test('is shared by e-mail with a role, listed, changed and taken away', () async {
      await putDoc();
      final given = await aliceDb.share(place, bobP, ShareRole.viewer);
      expect(given.role, ShareRole.viewer);
      var list = await aliceDb.sharesOf(place);
      expect((list.single.person.id, list.single.role), ('bob@example.org', ShareRole.viewer));
      expect((await aliceDb.share(place, bobP, ShareRole.editor)).role, ShareRole.editor, reason: 'shared already: the role is changed');
      list = await aliceDb.sharesOf(place);
      expect(list.single.role, ShareRole.editor);
      await aliceDb.changeRole(list.single, ShareRole.viewer);
      expect((await aliceDb.sharesOf(place)).single.role, ShareRole.viewer);
      await aliceDb.unshare(list.single);
      expect(await aliceDb.sharesOf(place), isEmpty);
      await aliceDb.unshare(list.single); // (gone already: not an error)
      await aliceDb.removeFolder(place);
      await expectLater(aliceDb.sharesOf(place), throwsA(isA<NativeShareException>()));
    });

    test('a folder that Dropbox shares by a job is waited for', () async {
      await putDoc();
      dropbox.asyncShare = true;
      expect((await aliceDb.share(place, bobP, ShareRole.editor)).role, ShareRole.editor);
    });

    test('an app that may not share says what is wrong', () async {
      await putDoc();
      dropbox.appFolderOnly = true;
      await expectLater(aliceDb.share(place, bobP, ShareRole.viewer), throwsA(isA<NativeShareException>().having((e) => e.message, 'm', contains('access to the whole Dropbox'))));
    });

    test('is found by the other person, waits to be mounted, and is then read and written as far as the rights go', () async {
      await putDoc();
      await aliceDb.share(place, bobP, ShareRole.viewer);
      final waiting = (await bobDb.incoming()).single;
      expect((waiting.name, waiting.owner, waiting.role, waiting.pending, waiting.place), ('docs (notation aaaaaa)', 'Alice', ShareRole.viewer, true, ''));
      final mounted = await bobDb.accept(waiting);
      expect((mounted.pending, mounted.place), (false, 'docs (notation aaaaaa)'));
      final theirs = bobDb.folderAt(mounted.place);
      expect(await theirs.read('hello.txt'), [1, 2, 3]);
      expect(await theirs.list(''.isEmpty ? 'sub' : ''), isEmpty);
      await expectLater(theirs.write('x.txt', Uint8List(1)), throwsA(isA<CloudFolderException>()), reason: 'view only');

      await aliceDb.changeRole((await aliceDb.sharesOf(place)).single, ShareRole.editor);
      await theirs.write('sub/dir/x.txt', Uint8List.fromList([9]));
      expect(await aliceDb.folderAt(place).read('sub/dir/x.txt'), [9]);
      expect((await aliceDb.sharesOf(place)).single.person.id, 'bob@example.org');
      expect((await bobDb.incoming()).single.pending, isFalse);

      await bobDb.leave((await bobDb.incoming()).single);
      expect(await aliceDb.sharesOf(place), isEmpty);
    });
  });

  test('notes are shared and kept in step between two people through Dropbox', () async {
    final f = await aliceDev.repo.createFolder('Physics');
    final g = await aliceDev.repo.createFolder('Optics', parentId: f);
    final n1 = await aliceDev.note('Waves', 'w');
    final n2 = await aliceDev.note('Lenses', 'l');
    await aliceDev.repo.moveNote(n1, f);
    await aliceDev.repo.moveNote(n2, g);
    final share = await alice.shareFolder(f, alice.usable.single, bobP, ShareRole.editor);
    expect(share.recipients.single.link, isNull, reason: 'Dropbox lists what is shared with the person: no link is needed');

    await bob.refreshIncoming();
    expect(bob.pending.single.share.role, ShareRole.editor);
    final inn = await bob.accept(bob.pending.single);
    await bob.syncShare(inn.id);
    expect(bob.statusOf(inn.id).problem, isNull);
    expect({for (final n in await bobDev.repo.listNotes()) n.id}, {n1, n2});

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await bobDev.edit(n1, 'waves, by bob');
    await bob.syncNow();
    await alice.syncNow();
    expect(await aliceDev.text(n1), 'waves, by bob');

    await alice.stopSharing(alice.given.single);
    await bob.refreshIncoming();
    expect(bob.received.single.state, ShareState.ended);
    expect(await bobDev.text(n2), 'l');
  });
}
