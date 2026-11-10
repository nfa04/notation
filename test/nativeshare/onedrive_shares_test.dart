import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/cloud_folder.dart';
import 'package:notes/collab/onedrive_storage.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/nativeshare/native_share_provider.dart';
import 'package:notes/nativeshare/native_share_service.dart';
import 'package:notes/nativeshare/onedrive_shares.dart';
import 'package:notes/nativeshare/share_model.dart';
import 'package:notes/sync/caldav_service.dart';

import '../devicesync/harness.dart';
import 'fake_graph.dart';

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
  late FakeGraph graph;
  late Device aliceDev, bobDev;
  late OneDriveStorage aliceStorage, bobStorage;
  late OneDriveShares aliceOd, bobOd;
  late NativeShareService alice, bob;

  Future<OneDriveStorage> signedIn(Device d, String user, {bool sharing = true}) async {
    final s = OneDriveStorage(clientId: 'client', settings: d.settings, store: _Secret(), graphHost: graph.address, tokenUrl: '${graph.address}/token');
    if (!sharing) await d.settings.remove('onedrive_sharing');
    await s.load();
    if (sharing) await s.setSharing(true);
    await s.oauth.adopt(graph.refreshTokenOf(user));
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
    root = await Directory.systemTemp.createTemp('od_shares_');
    graph = FakeGraph();
    await graph.start();
    aliceDev = await Device.create('alice-laptop', root);
    bobDev = await Device.create('bob-laptop', root);
    aliceStorage = await signedIn(aliceDev, 'alice');
    bobStorage = await signedIn(bobDev, 'bob');
    aliceOd = OneDriveShares(aliceStorage);
    bobOd = OneDriveShares(bobStorage);
    alice = serviceOf(aliceDev, aliceOd);
    bob = serviceOf(bobDev, bobOd);
  });
  tearDown(() async {
    alice.dispose();
    bob.dispose();
    await graph.stop();
    await aliceDev.db.close();
    await bobDev.db.close();
    await root.delete(recursive: true);
  });

  const bobP = SharePerson('bob@example.org', 'Bob');
  const place = 'Notation Shares/Docs (Notation aaaaaa)';

  Future<void> putDoc() => aliceOd.folderAt(place).write('hello.txt', Uint8List.fromList([1, 2, 3]));

  group('the account', () {
    test('sharing is a choice, because it needs the permission for all the files; until then the reason is said', () async {
      final off = await signedIn(aliceDev, 'alice', sharing: false);
      final p = OneDriveShares(off);
      expect(off.oauth.scopes, ['Files.ReadWrite.AppFolder', 'offline_access']);
      expect(p.unsupportedReason, contains('Allow sharing'));
      await off.setSharing(true);
      expect(off.oauth.scopes, ['Files.ReadWrite.All', 'offline_access']);
      expect(off.available, isFalse, reason: 'the sign-in has the other permissions: a new one is needed');
      expect(p.unsupportedReason, isNull, reason: 'not signed in: the service says so on its own');
      await off.oauth.adopt(graph.refreshTokenOf('alice'));
      expect(p.unsupportedReason, isNull);
      expect(await off.oauth.accessToken(), 'tokA');
      expect(off.oauth.grantedScopes, contains('files.readwrite.all'));
      expect(off.canShare, isTrue);
    });

    test('a sign-in that was given less than it needs says to sign in again', () async {
      graph.grantedScope = 'Files.ReadWrite.AppFolder offline_access'; // (the person did not agree to all of it)
      final s = await signedIn(aliceDev, 'alice');
      expect(OneDriveShares(s).unsupportedReason, isNull, reason: 'what was allowed is not known yet');
      await s.oauth.accessToken();
      expect(s.oauth.grantedScopes, {'files.readwrite.appfolder', 'offline_access'});
      expect(s.canShare, isFalse);
      expect(OneDriveShares(s).unsupportedReason, contains('Sign in to OneDrive again'));
      final svc = serviceOf(aliceDev, OneDriveShares(s));
      expect(svc.usable, isEmpty);
      expect(svc.unsupported.single.reason, contains('Sign in to OneDrive again'));
      svc.dispose();
    });
  });

  group('the folder', () {
    test('is shared by e-mail with a role, listed, changed and taken away; the answer carries a link for the person', () async {
      await putDoc();
      final given = await aliceOd.share(place, bobP, ShareRole.viewer);
      expect(given.role, ShareRole.viewer);
      expect(given.link, startsWith('notation://share?p=onedrive&s=SH'));
      final list = await aliceOd.sharesOf(place);
      expect((list.single.person.id, list.single.person.label, list.single.role), ('bob@example.org', 'Bob', ShareRole.viewer));
      await aliceOd.changeRole(list.single, ShareRole.editor);
      expect((await aliceOd.sharesOf(place)).single.role, ShareRole.editor);
      await aliceOd.unshare(list.single);
      expect(await aliceOd.sharesOf(place), isEmpty);
      await aliceOd.removeFolder(place);
      await expectLater(aliceOd.share(place, bobP, ShareRole.viewer), throwsA(isA<NativeShareException>().having((e) => e.message, 'm', contains('not on your OneDrive'))));
    });

    test('is refused with the reason when an administrator forbids sharing', () async {
      await putDoc();
      graph.forbidInvite = true;
      await expectLater(aliceOd.share(place, bobP, ShareRole.viewer), throwsA(isA<NativeShareException>().having((e) => e.message, 'm', contains('does not allow sharing'))));
    });

    test('the person adds the link and then reads and writes as far as the rights go', () async {
      await putDoc();
      final given = await aliceOd.share(place, bobP, ShareRole.viewer);
      expect(await bobOd.incoming(), isEmpty, reason: 'OneDrive cannot be asked what was shared');
      final inn = await bobOd.addLink('Here you go: ${given.link} thanks');
      expect((inn.name, inn.owner, inn.role, inn.pending), ('Docs (Notation aaaaaa)', 'Alice', ShareRole.viewer, false));
      expect(inn.place, startsWith('od:d-alice:'));
      final theirs = bobOd.folderAt(inn.place);
      expect(await theirs.read('hello.txt'), [1, 2, 3]);
      expect(await theirs.list(''), ['hello.txt']);
      expect(await theirs.read('nothing.txt'), isNull);
      await expectLater(theirs.write('x.txt', Uint8List(1)), throwsA(isA<CloudFolderException>()), reason: 'view only');
      await expectLater(theirs.delete('hello.txt'), throwsA(isA<CloudFolderException>()));

      await aliceOd.changeRole((await aliceOd.sharesOf(place)).single, ShareRole.editor);
      await theirs.write('sub/dir/x.txt', Uint8List.fromList([9]));
      expect(await aliceOd.folderAt(place).read('sub/dir/x.txt'), [9]);
      await theirs.delete('sub/dir/x.txt');
      expect(await aliceOd.folderAt(place).read('sub/dir/x.txt'), isNull);

      expect((await bobOd.incoming()).single.id, inn.id, reason: 'it is listed from now on');
      await aliceOd.unshare((await aliceOd.sharesOf(place)).single);
      expect(await bobOd.incoming(), isEmpty, reason: 'withdrawn: the link opens nothing any more');
    });

    test('a link that was meant for somebody else, or for no folder of Notation, is not taken', () async {
      await putDoc();
      final given = await aliceOd.share(place, bobP, ShareRole.viewer);
      final carol = OneDriveShares(await signedIn(bobDev, 'carol'));
      await expectLater(carol.addLink(given.link!), throwsA(isA<NativeShareException>().having((e) => e.message, 'm', contains('invited'))));
      expect(await carol.incoming(), isEmpty);
      await expectLater(bobOd.addLink('hello'), throwsA(isA<NativeShareException>().having((e) => e.message, 'm', contains('not a link'))));
      // a folder that is not named by Notation
      await aliceOd.folderAt('Notation Shares/Holiday').write('a.txt', Uint8List(1));
      final other = await aliceOd.share('Notation Shares/Holiday', bobP, ShareRole.viewer);
      await expectLater(bobOd.addLink(other.link!), throwsA(isA<NativeShareException>().having((e) => e.message, 'm', contains('not a share from Notation'))));
    });

    test('an invitation that does not tell its id is found by the address of the folder', () async {
      await putDoc();
      graph.tellsShareId = false;
      final given = await aliceOd.share(place, bobP, ShareRole.editor);
      expect(given.link, startsWith('notation://share?p=onedrive&u='));
      final inn = await bobOd.addLink(given.link!);
      expect((inn.name, inn.role), ('Docs (Notation aaaaaa)', ShareRole.editor));
      // and the plain web address works too, as the e-mail of Microsoft has it
      expect(OneDriveShares.keyOf('https://1drv.ms/f/s!SH7'), startsWith('u!'));
      expect(OneDriveShares.keyOf('look at https://example.com/x'), isNull);
      expect(OneDriveShares.keyOf('notation://share?p=dropbox&s=x'), isNull);
    });
  });

  test('notes are shared and kept in step between two people through OneDrive, the link being all the person needs', () async {
    final f = await aliceDev.repo.createFolder('Physics');
    final n1 = await aliceDev.note('Waves', 'w');
    await aliceDev.repo.moveNote(n1, f);
    final share = await alice.shareFolder(f, alice.usable.single, bobP, ShareRole.editor);
    final link = share.recipients.single.link!;
    expect(link, startsWith('notation://share?'));

    await bob.refreshIncoming();
    expect(bob.pending, isEmpty);
    final pending = await bob.addLink('see $link');
    expect(pending.share.owner, 'Alice');
    await bob.refreshIncoming();
    expect(bob.pending, hasLength(1), reason: 'listed from the links that were added');
    final inn = await bob.accept(bob.pending.single);
    await bob.syncShare(inn.id);
    expect(bob.statusOf(inn.id).problem, isNull);
    expect(await bobDev.text(n1), 'w');

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await bobDev.edit(n1, 'waves, by bob');
    await bob.syncNow();
    await alice.syncNow();
    expect(await aliceDev.text(n1), 'waves, by bob');

    await alice.stopSharing(alice.given.single);
    await bob.refreshIncoming();
    expect(bob.received.single.state, ShareState.ended);
    expect(await bobDev.text(n1), 'waves, by bob');
  });

  test('with sharing not allowed, the service says so instead of offering it', () async {
    final s = await signedIn(aliceDev, 'alice', sharing: false);
    final svc = serviceOf(aliceDev, OneDriveShares(s));
    expect(svc.usable, isEmpty);
    expect(svc.unsupported.single.reason, contains('Allow sharing'));
    svc.dispose();
  });
}
