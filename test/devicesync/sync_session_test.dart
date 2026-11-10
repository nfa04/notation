import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:crypto/crypto.dart';
import 'package:notes/collab/compression.dart';
import 'package:notes/collab/secure_box.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_accounts.dart';
import 'package:notes/devicesync/sync_keys.dart';
import 'package:notes/devicesync/sync_session.dart';

import 'harness.dart';

/// The cloud accounts of a device in memory: the newer of each wins.
class _Accounts implements SyncedAccounts {
  final Map<String, AccountBundle> have;
  _Accounts(this.have);

  @override
  Future<List<AccountBundle>> export() async => have.values.toList();

  @override
  Future<int> apply(List<AccountBundle> theirs) async {
    var n = 0;
    for (final t in theirs) {
      if (t.at > (have[t.kind]?.at ?? -1)) {
        have[t.kind] = t;
        n++;
      }
    }
    return n;
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late SyncSecret secret;
  late String room;
  late Device a, b;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('devicesync_');
    secret = SyncSecret.create(Random(3));
    room = (await secret.roomKeys()).room;
    a = await Device.create('Anna laptop', root, profileId: 'aaaaaaaaaaaaaaaa');
    b = await Device.create('Anna tablet', root, profileId: 'bbbbbbbbbbbbbbbb');
  });
  tearDown(() async {
    await a.db.close();
    await b.db.close();
    await root.delete(recursive: true);
  });

  /// Meets [x] and [y] over a direct connection; [x] is the one that offered a link when [offering] is set.
  Future<(SyncOutcome, SyncOutcome)> meet(Device x, Device y, {bool pairing = false, bool approve = true, bool joinerAgrees = true, List<String>? codes, String? bindingX, String? bindingY}) async {
    var (c1, c2) = await pipe();
    if (bindingX != null) c1 = BoundChannel(c1, bindingX);
    if (bindingY != null) c2 = BoundChannel(c2, bindingY);
    final sx = x.session(c1, secret, room, offer: pairing ? PairingOffer((n, code) async {
      codes?.add(code);
      return approve;
    }) : null);
    final sy = y.session(c2, secret, room, join: pairing ? PairingJoin((code) async {
      codes?.add(code);
      return joinerAgrees;
    }, (id, name) async {
      y.profile
        ..id = id
        ..name = name;
    }) : null);
    final r = await Future.wait([sx.run(), sy.run()]);
    return (r[0], r[1]);
  }

  test('what goes over the line is compressed (once both said they can read it), and less goes over it', () async {
    final ids = [for (var i = 0; i < 20; i++) await a.note('Note $i', List.filled(40, 'Lecture notes, week $i: the same words again and again. ').join())];
    for (final d in [a, b]) {
      for (final o in [a, b]) {
        await d.book.add(PairedDevice(id: o.identity.id, name: o.name, publicKey: o.identity.publicKey, addedAt: 1));
      }
    }
    final (c1, c2) = await pipe();
    final counted = _Counting(c1);
    final r = await Future.wait([a.session(counted, secret, room).run(), b.session(c2, secret, room).run()]);
    expect(r[0].ok && r[1].ok, isTrue, reason: '${r[0].problem} ${r[1].problem}');
    for (final id in ids) {
      expect(await b.text(id), startsWith('Lecture notes'));
    }
    // the frames as the other device opens them: the first byte says how the rest is
    final box = SecureBox(secret.messageKey);
    var packed = 0, plainBytes = 0;
    for (final f in counted.frames) {
      final opened = await box.open(f);
      if (opened.first == 0x7B) {
        expect(jsonDecode(utf8.decode(opened))['t'], 'hi', reason: 'only the first message, before the other said it reads packed ones');
        plainBytes += opened.length;
        continue;
      }
      if (opened.first == 0x01) packed++;
      plainBytes += unpackMessageSync(opened).length;
    }
    expect(packed, greaterThan(20), reason: 'the notes were not compressed');
    expect(counted.sent, lessThan(plainBytes * 0.8), reason: 'not much was saved');
  });

  test('a new device is let in by the one that offered the link: same code on both, profile taken over, notes and settings merged', () async {
    final onA = await a.note('From the laptop', 'laptop text');
    final onB = await b.note('From the tablet', 'tablet text');
    final folder = await a.repo.createFolder('Uni');
    await a.repo.moveNote(onA, folder);
    await a.repo.setFavorite(onA, true);
    await a.settings.set('app_accent', '4280391411');
    await a.settings.set('collab_server', 'wss://not-synced.example'); // a setting of this device only

    final codes = <String>[];
    final (ra, rb) = await meet(a, b, pairing: true, codes: codes);
    expect(ra.ok, isTrue, reason: ra.problem);
    expect(rb.ok, isTrue, reason: rb.problem);
    expect(ra.paired && rb.paired, isTrue);
    expect(codes, hasLength(2));
    expect(codes[0], codes[1]);
    expect(codes[0], matches(RegExp(r'^\d{3} \d{3}$')));

    // the profile of the device that offered the link is now this one's
    expect([b.profile.id, b.profile.name], ['aaaaaaaaaaaaaaaa', 'Anna laptop']);
    // both know both devices
    expect(a.book.active.map((d) => d.id).toSet(), {a.identity.id, b.identity.id});
    expect(b.book.active.map((d) => d.id).toSet(), {a.identity.id, b.identity.id});

    // each has the notes of the other, in their places
    expect(await b.text(onA), 'laptop text');
    expect(await a.text(onB), 'tablet text');
    expect((await b.repo.listNotes()).firstWhere((n) => n.id == onA).folderId, folder);
    expect((await b.repo.listNotes()).firstWhere((n) => n.id == onA).favorite, isTrue);
    expect((await b.repo.listFolders()).map((f) => f.name), contains('Uni'));
    expect(await b.settings.get('app_accent'), '4280391411');
    expect(await b.settings.get('collab_server'), isNull);
  });

  test('theme images of folders and notes arrive with them, and a removed folder image goes away', () async {
    await meet(a, b, pairing: true);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final folder = await a.repo.createFolder('Banner');
    final noteId = await a.note('Pretty', 'text');
    final folderPic = File('${a.dir.path}/f.png')..writeAsBytesSync([1, 2, 3, 4]);
    final notePic = File('${a.dir.path}/n.png')..writeAsBytesSync([9, 8, 7]);
    await a.repo.setFolderThemeImage(folder, folderPic.path);
    await a.repo.setNoteThemeImage(noteId, notePic.path);

    var (ra, rb) = await meet(a, b);
    expect(ra.ok && rb.ok, isTrue, reason: '${ra.problem} ${rb.problem}');
    final onB = (await b.repo.listFolders()).firstWhere((f) => f.id == folder).themeImage;
    expect(onB, isNotNull);
    expect(File(onB!).readAsBytesSync(), [1, 2, 3, 4]);
    expect(onB, isNot(folderPic.path)); // (a file of its own on this device)
    final noteImage = (await b.repo.loadNote(noteId))!.themeImage;
    expect(noteImage, isNotNull);
    expect(File(noteImage!).readAsBytesSync(), [9, 8, 7]);

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await a.repo.setFolderThemeImage(folder, null);
    (ra, rb) = await meet(a, b);
    expect(ra.ok && rb.ok, isTrue, reason: '${ra.problem} ${rb.problem}');
    expect((await b.repo.listFolders()).firstWhere((f) => f.id == folder).themeImage, isNull);
    expect(File(onB).existsSync(), isFalse);
  });

  test('a live meeting: a paired device is handed a proven line and the secret of the session; a stranger or a host without a session gets nothing', () async {
    await meet(a, b, pairing: true);
    final sessionSecret = Uint8List.fromList(List.generate(32, (i) => i + 1));

    Future<(SyncOutcome, SyncOutcome)> live(String note, {Device? guest, bool hosting = true}) async {
      final (c1, c2) = await pipe();
      final host = a.session(c1, secret, room, liveSecretFor: (n, peer) async => hosting && n == 'note-1' ? sessionSecret : null);
      final joiner = (guest ?? b).session(c2, secret, room, liveNote: note);
      final r = await Future.wait([host.run(), joiner.run()]);
      return (r[0], r[1]);
    }

    final (ra, rb) = await live('note-1');
    expect(ra.ok && rb.ok, isTrue, reason: '${ra.problem} ${rb.problem}');
    expect(rb.live!.secret, sessionSecret);
    expect(ra.live!.secret, sessionSecret);
    expect(rb.live!.peerId, a.identity.id);
    expect(ra.live!.peerId, b.identity.id);

    // the line carries the live session's own traffic both ways (also what was sent the moment the other side was through)
    final atHost = <int>[], atGuest = <int>[];
    final order = <int>[];
    ra.live!.channel.messages.listen((m) {
      atHost.addAll(m);
      order.add(m.length);
    });
    rb.live!.channel.messages.listen(atGuest.addAll);
    await rb.live!.channel.send(Uint8List.fromList([1, 2, 3]));
    await ra.live!.channel.send(Uint8List.fromList([4, 5]));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(atHost, [1, 2, 3]);
    expect(atGuest, [4, 5]);
    // big and small messages one after the other arrive in the order they were sent (a big one takes longer to be told apart from the
    // meeting's own messages than a small one, and must not be overtaken)
    order.clear();
    atHost.clear();
    for (var i = 0; i < 6; i++) {
      await rb.live!.channel.send(Uint8List(i.isEven ? 300000 : 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(order, [300000, 20, 300000, 20, 300000, 20]);
    await ra.live!.channel.close();
    await rb.live!.channel.close();

    // a note the host has no session on
    final (r2a, r2b) = await live('note-2');
    expect(r2a.end, SyncEnd.refused);
    expect(r2b.end, SyncEnd.refused);
    expect(r2b.live, isNull);

    // a device that is not in the profile (the device list of a is not b's here: a new device)
    final stranger = await Device.create('Stranger', root, profileId: 'cccccccccccccccc');
    addTearDown(() => stranger.db.close());
    final (r3a, r3b) = await live('note-1', guest: stranger);
    expect(r3a.live, isNull);
    expect(r3b.live, isNull);
    expect(r3a.end, SyncEnd.refused);
  });

  test('the network drops at any point of a sync: the next one finishes the job, nothing is taken twice, no copy "from before the sync" appears', () async {
    await meet(a, b, pairing: true);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final ids = <String>[];
    for (var i = 0; i < 4; i++) {
      ids.add(await a.note('From the laptop $i', 'laptop text $i'));
      ids.add(await b.note('From the tablet $i', 'tablet text $i'));
    }
    final folder = await a.repo.createFolder('Uni');
    await a.repo.moveNote(ids.first, folder);
    await a.settings.set('app_accent', '4280391411');

    // cut the line after 3, 6, 9, ... messages; every try is followed by the next try on a good line
    for (var cut = 3; cut < 60; cut += 3) {
      await Future<void>.delayed(const Duration(milliseconds: 3));
      await a.edit(ids.first, 'laptop edit $cut'); // (the laptop keeps working between the tries)
      final (c1, c2) = await pipe();
      final x = a.session(CuttingChannel(c1, cut), secret, room);
      final y = b.session(c2, secret, room);
      final r = await Future.wait([x.run(), y.run()]);
      if (r[0].ok && r[1].ok) break; // the line held until the end
    }
    final (ra, rb) = await meet(a, b);
    expect(ra.ok && rb.ok, isTrue, reason: '${ra.problem} ${rb.problem}');

    for (final id in ids) {
      expect(await a.text(id), await b.text(id), reason: id);
    }
    final titlesA = (await a.repo.listNotes()).map((n) => n.title).toList();
    final titlesB = (await b.repo.listNotes()).map((n) => n.title).toList();
    expect(titlesA.where((t) => t.contains('before the sync')), isEmpty);
    expect(titlesB.where((t) => t.contains('before the sync')), isEmpty);
    expect(titlesA.length, 8);
    expect(titlesB.length, 8);
    expect((await b.repo.listNotes()).firstWhere((n) => n.id == ids.first).folderId, folder);
    expect(await b.settings.get('app_accent'), '4280391411');

    // an edit after that goes over without conflict as well
    await Future<void>.delayed(const Duration(milliseconds: 3));
    await a.edit(ids.first, 'changed later');
    final (rc, rd) = await meet(a, b);
    expect(rc.ok && rd.ok, isTrue);
    expect(await b.text(ids.first), 'changed later');
    expect((await b.repo.listNotes()).where((n) => n.title.contains('before the sync')), isEmpty);
  });

  test('cloud accounts are handed over in a sync: the newer of each wins, a removal travels, and only a paired device gets them', () async {
    final onA = _Accounts({
      's3': const AccountBundle('s3', 100, {'bucket': 'notes', 'secret': 'topsecret'}),
      'dropbox': const AccountBundle('dropbox', 50, {'refresh': 'old'}),
      'nextcloud': const AccountBundle('nextcloud', 300, null), // (removed here after it was set up on the tablet)
    });
    final onB = _Accounts({
      'dropbox': const AccountBundle('dropbox', 80, {'refresh': 'new'}),
      'nextcloud': const AccountBundle('nextcloud', 200, {'url': 'https://cloud.example', 'password': 'pw'}),
    });
    final (c1, c2) = await pipe();
    final x = a.session(c1, secret, room, offer: PairingOffer((n, code) async => true), accounts: onA);
    final y = b.session(c2, secret, room, join: PairingJoin((code) async => true, (id, name) async {}), accounts: onB);
    final r = await Future.wait([x.run(), y.run()]);
    expect(r[0].ok && r[1].ok, isTrue, reason: '${r[0].problem} ${r[1].problem}');
    for (final side in [onA, onB]) {
      expect(side.have['s3']!.data, {'bucket': 'notes', 'secret': 'topsecret'}); // set up on one, now on both
      expect(side.have['dropbox']!.data, {'refresh': 'new'}); // the newer
      expect(side.have['nextcloud']!.data, isNull); // removed later than it was changed
    }
  });

  test('a device that sits in the middle of the connection (it makes the two ends see different certificates) gets nothing', () async {
    await a.note('Private', 'secret notes');
    await meet(a, b, pairing: true); // paired before
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final id = (await a.repo.listNotes()).first.id;
    await a.edit(id, 'changed on the laptop');
    // the proofs were made for the connection each end saw: a relay that passes them on does not make them fit the other one
    final (ra, rb) = await meet(a, b, bindingX: 'fingerprints seen by the laptop', bindingY: 'fingerprints seen by the tablet');
    expect(ra.end, SyncEnd.refused);
    expect(rb.end, SyncEnd.refused);
    expect(await b.text(id), 'secret notes');
  });

  test('pairing through a device in the middle shows different digits on the two screens, and the joiner who sees that takes nothing over', () async {
    await a.note('Private', 'secret notes');
    final codes = <String>[];
    // the codes differ because the ends saw different connections; the person on the new device says so
    final (ra, rb) = await meet(a, b, pairing: true, codes: codes, bindingX: 'one', bindingY: 'two');
    // (the proofs already fail here; with the same binding but a person who sees different digits:)
    expect(ra.ok || rb.ok, isFalse);
    codes.clear();
    final (rc, rd) = await meet(a, b, pairing: true, codes: codes, joinerAgrees: false);
    expect(rd.end, SyncEnd.refused);
    expect(rc.ok, isFalse);
    expect(b.profile.id, 'bbbbbbbbbbbbbbbb'); // not taken over
    expect(b.book.active, isEmpty);
    expect(await b.repo.listNotes(), isEmpty);
  });

  test('the pairing digits depend on the connection too', () async {
    final s = SyncSecret.create(Random(8));
    final x = await DeviceIdentity.create(random: Random(1)), y = await DeviceIdentity.create(random: Random(2));
    String code(String binding) => s.pairingCode(nonceA: 'a', nonceB: 'b', publicKeyA: x.publicKey, publicKeyB: y.publicKey, binding: binding);
    expect(code('same'), code('same'));
    expect(code('same'), isNot(code('other')));
  });

  test('when the person does not let the new device in, it is not added anywhere and gets nothing', () async {
    await a.note('Private', 'secret notes');
    final (ra, rb) = await meet(a, b, pairing: true, approve: false);
    expect(ra.end, SyncEnd.refused);
    expect(rb.end, SyncEnd.refused);
    expect(a.book.find(b.identity.id), isNull);
    expect(b.book.active, isEmpty);
    expect((await b.repo.listNotes()), isEmpty);
  });

  test('a device that is not on the list is refused when nobody offered a link, whatever it knows', () async {
    await a.note('Private', 'secret notes');
    final (ra, rb) = await meet(a, b); // no pairing on either side
    expect(ra.end, SyncEnd.refused);
    expect(rb.end, SyncEnd.refused);
    expect(await b.repo.listNotes(), isEmpty);
  });

  test('a device with another secret is not understood and gets nothing', () async {
    await a.note('Private', 'secret notes');
    final other = SyncSecret.create(Random(99));
    final (c1, c2) = await pipe();
    final sa = a.session(c1, secret, room, step: const Duration(milliseconds: 600));
    final sb = b.session(c2, other, room, step: const Duration(milliseconds: 600));
    final r = await Future.wait([sa.run(), sb.run()]);
    expect(r[0].ok, isFalse);
    expect(r[1].ok, isFalse);
    expect(await b.repo.listNotes(), isEmpty);
  });

  test('paired devices prove themselves with their device keys; a stranger who claims the id of a device does not pass', () async {
    await meet(a, b, pairing: true);
    // a third device that knows the secret and uses the id of the tablet, with a key of its own
    final c = await Device.create('Intruder', root);
    final fake = await DeviceIdentity.fromSeed(b.identity.id, Uint8List.fromList(List.filled(32, 7)));
    final (c1, c2) = await pipe();
    final sa = a.session(c1, secret, room, step: const Duration(seconds: 2));
    final sc = SyncSession(
        channel: c2, secret: secret, roomName: room, identity: fake, deviceName: 'Intruder', book: c.book, profile: c.profile, library: c.library, step: const Duration(seconds: 2));
    final r = await Future.wait([sa.run(), sc.run()]);
    expect(r[0].end, SyncEnd.refused);
    expect(await c.repo.listNotes(), isEmpty);
  });

  test('edits go both ways later; the newer one wins; one changed on both sides is kept twice', () async {
    final shared = await a.note('Shared', 'v1');
    final other = await a.note('Other', 'o1');
    await meet(a, b, pairing: true);
    expect(await b.text(shared), 'v1');

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await a.edit(other, 'o2 from the laptop');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.edit(shared, 'v2 from the tablet');
    var (ra, rb) = await meet(a, b);
    expect(ra.ok && rb.ok, isTrue, reason: '${ra.problem} ${rb.problem}');
    expect(await a.text(shared), 'v2 from the tablet');
    expect(await b.text(other), 'o2 from the laptop');

    // both change the same note
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await a.edit(shared, 'laptop version');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.edit(shared, 'tablet version, later');
    (ra, rb) = await meet(a, b);
    expect(ra.ok && rb.ok, isTrue);
    expect(await a.text(shared), 'tablet version, later');
    expect(await b.text(shared), 'tablet version, later');
    final copies = [for (final d in [a, b]) (await d.repo.listNotes()).where((n) => n.title.contains('from before the sync')).toList()];
    expect(copies[0], hasLength(1)); // the loser, kept on the device where it was changed
    expect(await a.text(copies[0].single.id), 'laptop version');
    expect(copies[1], isEmpty);
    await meet(a, b);
    final onB = (await b.repo.listNotes()).where((n) => n.title.contains('from before the sync')).toList();
    expect(onB, hasLength(1)); // and at the next sync it travels too
  });

  test('a note that was open during a sync (so not exchanged) and is then changed on both sides is kept twice, not overwritten', () async {
    final n = await a.note('Shared', 'v1');
    await meet(a, b, pairing: true);
    expect(await b.text(n), 'v1');

    // the tablet changes it; the laptop has it open, so the sync leaves it alone there
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.edit(n, 'tablet edit');
    a.busy = {n};
    var (ra, rb) = await meet(a, b);
    expect(ra.ok && rb.ok, isTrue, reason: '${ra.problem} ${rb.problem}');
    expect(await a.text(n), 'v1', reason: 'an open note is not replaced');
    a.busy = {};

    // the laptop then changes it too, on top of what it had
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await a.edit(n, 'laptop edit');
    (ra, rb) = await meet(a, b);
    expect(ra.ok && rb.ok, isTrue);
    await meet(a, b); // (the copy travels at the next sync)
    for (final d in [a, b]) {
      final texts = [for (final x in await d.repo.listNotes()) await d.text(x.id)];
      expect(texts, containsAll(['laptop edit', 'tablet edit']), reason: 'an edit was lost on ${d.name}: $texts');
    }
  });

  test('a device that does not sync its notes now turns a sync of the libraries away, quietly; a live meeting it still serves', () async {
    final n = await a.note('Here', 'x');
    await meet(a, b, pairing: true);
    await a.edit(n, 'changed');
    final (c1, c2) = await pipe();
    final r = await Future.wait([
      a.session(c1, secret, room).run(),
      SyncSession(channel: c2, secret: secret, roomName: room, identity: b.identity, deviceName: b.name, book: b.book, profile: b.profile, library: b.library, syncsLibrary: false).run(),
    ]);
    expect(r[1].declined, isTrue);
    expect(r[1].problem, isNull);
    expect(r[0].end, SyncEnd.refused);
    expect(r[0].problem, isNotNull, reason: 'the asking device is told why');
    expect(await b.text(n), 'x', reason: 'nothing was taken');
  });

  test('a device that is renamed is known by its new name on the other device after the next sync; an older name does not come back', () async {
    await meet(a, b, pairing: true);
    expect(b.book.find(a.identity.id)?.name, isNot('Kitchen laptop'));
    await a.book.rename(a.identity.id, 'Kitchen laptop', DateTime.now().millisecondsSinceEpoch);
    final (ra, rb) = await meet(a, b);
    expect(ra.ok && rb.ok, isTrue);
    expect(b.book.find(a.identity.id)?.name, 'Kitchen laptop');
    // a list that still has the old name (from a device that did not sync since) does not undo it
    final old = PairedDevice(id: a.identity.id, name: 'Anna laptop', publicKey: a.identity.publicKey, addedAt: 1);
    await b.book.merge([old]);
    expect(b.book.find(a.identity.id)?.name, 'Kitchen laptop');
  });

  test('deleting and trashing, a moved note and a deleted folder reach the other device; an open note is left alone', () async {
    final gone = await a.note('Gone', 'x');
    final trashed = await a.note('Trashed', 'y');
    final open = await a.note('Open', 'z');
    final folder = await a.repo.createFolder('Old');
    await meet(a, b, pairing: true);
    expect(await b.repo.listNotes(), hasLength(3));

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await a.repo.deleteNote(gone);
    await a.repo.trashNote(trashed);
    await a.repo.deleteFolder(folder);
    await b.edit(open, 'changed on the tablet');
    a.busy = {open}; // open in an editor on the laptop
    final (ra, rb) = await meet(a, b);
    expect(ra.ok && rb.ok, isTrue);
    expect((await b.repo.listNotes()).map((n) => n.id), [open]); // gone, and trashed (not listed any more)
    expect((await b.repo.listTrash()).map((n) => n.id), [trashed]);
    expect((await b.repo.listFolders()), isEmpty);
    expect(await a.text(open), 'z'); // not replaced under the editor

    a.busy = {};
    await meet(a, b);
    expect(await a.text(open), 'changed on the tablet');
  });

  test('a device that was taken out of the profile is not let in again, and is told when it meets one that knows', () async {
    await meet(a, b, pairing: true);
    await a.book.remove(b.identity.id, DateTime.now().millisecondsSinceEpoch + 10);
    final (ra, rb) = await meet(a, b);
    expect(ra.end, SyncEnd.refused);
    expect(rb.end, anyOf(SyncEnd.refused, SyncEnd.failed));
  });

  test('a device that changes its random number or key after seeing the other side\'s is refused (it could otherwise grind the six digits)', () async {
    final (c1, c2) = await pipe();
    final box = SecureBox(secret.messageKey);
    Future<void> say(Map<String, Object?> m) async => c2.send(await box.seal(Uint8List.fromList(utf8.encode(jsonEncode(m)))));
    String commit(String id, String nonce, String key) => base64.encode(sha256.convert(utf8.encode('notation-commit-v1|$id|$nonce|$key')).bytes);
    final mallory = await DeviceIdentity.create(random: Random(77));
    final key = base64.encode(mallory.publicKey);
    final session = a.session(c1, secret, room, offer: PairingOffer((n, code) async => true), step: const Duration(seconds: 2));
    final running = session.run();
    await say({'t': 'hi', 'v': SyncSession.protocol, 'id': mallory.id, 'name': 'Mallory', 'commit': commit(mallory.id, 'nonce-one', key)});
    await say({'t': 'reveal', 'nonce': 'a different nonce chosen after seeing the other one', 'key': key});
    final outcome = await running;
    expect(outcome.end, SyncEnd.refused);
    expect(a.book.find(mallory.id), isNull);
  });
}

/// A link that counts the bytes sent over it.
class _Counting implements PeerChannel {
  final PeerChannel inner;
  int sent = 0;
  final List<Uint8List> frames = [];
  _Counting(this.inner);

  @override
  Future<String> binding() => inner.binding();

  @override
  Stream<Uint8List> get messages => inner.messages;

  @override
  Future<void> send(Uint8List message) {
    sent += message.length;
    frames.add(message);
    return inner.send(message);
  }

  @override
  Future<void> get closed => inner.closed;

  @override
  Future<void> close() => inner.close();
}
