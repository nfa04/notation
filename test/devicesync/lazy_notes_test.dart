import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_keys.dart';

import 'harness.dart';

/// A temporary browser lists the notes of the profile and takes the content of one only when it is asked for.
void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late SyncSecret secret;
  late String room;
  late Device phone, browser;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lazynotes_');
    secret = SyncSecret.create(Random(5));
    room = (await secret.roomKeys()).room;
    phone = await Device.create('Phone', root, profileId: 'aaaaaaaaaaaaaaaa');
    browser = await Device.create('Browser', root, profileId: 'aaaaaaaaaaaaaaaa');
    for (final d in [phone, browser]) {
      for (final o in [phone, browser]) {
        await d.book.add(PairedDevice(id: o.identity.id, name: o.name, publicKey: o.identity.publicKey, addedAt: 1));
      }
    }
  });
  tearDown(() async {
    await phone.db.close();
    await browser.db.close();
    await root.delete(recursive: true);
  });

  Future<void> meet({bool lazy = true}) async {
    final (c1, c2) = await pipe();
    final r = await Future.wait([phone.session(c1, secret, room).run(), browser.session(c2, secret, room, lazyNotes: lazy).run()]);
    expect(r[0].ok && r[1].ok, isTrue, reason: '${r[0].problem} ${r[1].problem}');
  }

  test('notes are listed with title and place but come without content, and the phone keeps its own', () async {
    final one = await phone.note('Lecture 1', 'text of the first');
    final two = await phone.note('Lecture 2', 'text of the second');
    final folder = await phone.repo.createFolder('Uni');
    await phone.repo.moveNote(one, folder);
    await phone.repo.setFavorite(one, true);

    await meet();
    final listed = await browser.repo.listNotes();
    expect(listed.map((n) => n.title).toSet(), {'Lecture 1', 'Lecture 2'});
    expect(listed.firstWhere((n) => n.id == one).folderId, folder);
    expect(listed.firstWhere((n) => n.id == one).favorite, isTrue);
    expect(await browser.library.stubIds(), {one, two});
    expect(await browser.text(one), '');

    // meeting again changes nothing on either side: the empty stub is not taken for a newer note
    await meet();
    expect(await phone.text(one), 'text of the first');
    expect(await phone.text(two), 'text of the second');
    expect(await browser.library.stubIds(), {one, two});
    expect(await browser.text(two), '');
  });

  test('a note that was asked for comes in full; the others stay listed', () async {
    final one = await phone.note('Lecture 1', 'text of the first');
    final two = await phone.note('Lecture 2', 'text of the second');
    await meet();

    browser.library.request(one);
    await meet();
    expect(await browser.text(one), 'text of the first');
    expect(await browser.library.stubIds(), {two});
    expect(browser.library.requested, isEmpty);

    // from now on it follows the phone like any note
    await phone.edit(one, 'first, changed');
    await meet();
    expect(await browser.text(one), 'first, changed');
    expect(await browser.text(two), '');
  });

  test('a listed note follows the phone: a new title shows, the content still waits', () async {
    final one = await phone.note('Old title', 'body');
    await meet();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await phone.edit(one, 'body, edited');
    await phone.repo.renameNote(one, 'New title');
    await meet();
    expect((await browser.repo.listNotes()).single.title, 'New title');
    expect(await browser.library.stubIds(), {one});
    expect(await browser.text(one), '');
    browser.library.request(one);
    await meet();
    expect(await browser.text(one), 'body, edited');
    expect(await phone.text(one), 'body, edited');
  });

  test('without lazyNotes everything is taken, as before', () async {
    final one = await phone.note('Lecture 1', 'text of the first');
    await meet(lazy: false);
    expect(await browser.text(one), 'text of the first');
    expect(await browser.library.stubIds(), isEmpty);
  });
}
