import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/ai/spaced_repetition.dart';
import 'package:notes/cloudsync/folder_sync.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_keys.dart';
import 'package:notes/devicesync/sync_library.dart';

import '../cloudsync/memory_cloud_folder.dart';
import 'harness.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late SyncSecret secret;
  late String room;
  late Device a, b;
  final t0 = DateTime(2026, 11, 26, 9);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cardsync_');
    secret = SyncSecret.create(Random(5));
    room = (await secret.roomKeys()).room;
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

  Future<void> meet() async {
    final (c1, c2) = await pipe();
    final r = await Future.wait([a.session(c1, secret, room).run(), b.session(c2, secret, room).run()]);
    expect(r[0].ok && r[1].ok, isTrue, reason: '${r[0].problem} ${r[1].problem}');
  }

  /// What the two devices do with cards, whichever way they meet: [sync] makes them meet.
  Future<void> story(Future<void> Function() sync) async {
    final ca = CardRepository(a.db), cb = CardRepository(b.db);
    final png = Uint8List.fromList(List.generate(50, (i) => i * 3));
    final pic = await ca.putPicture(png, width: 10, height: 5);
    await ca.addAll('n1', [
      const Flashcard('Q1', 'A1'),
      ...clozeCards('{{c1::ATP}} comes from {{c2::glucose}}'),
      RegionCard(picture: pic, width: 10, height: 5, masks: const [
        [0.1, 0.1, 0.2, 0.2],
      ], ask: 0).card(),
    ], now: t0);
    await sync();
    expect((await cb.all()).map((c) => c.card.kind).toList()..sort(), ['basic', 'cloze', 'cloze', 'region']);
    expect(await cb.picture(pic), png);

    // answered on both while apart: both answers count on both
    final q1 = CardRepository.idOf('n1', 'Q1');
    await ca.review((await ca.all()).firstWhere((c) => c.id == q1), Recall.good, now: t0);
    await cb.review((await cb.all()).firstWhere((c) => c.id == q1), Recall.again, now: t0.add(const Duration(hours: 1)));
    await sync();
    await sync();
    for (final c in [ca, cb]) {
      expect(await c.log(q1), [(t0, Recall.good), (t0.add(const Duration(hours: 1)), Recall.again)]);
      expect((await c.all()).firstWhere((x) => x.id == q1).schedule.lapses, 1);
    }

    // deleted on the tablet: gone from the laptop, and it does not come back
    await cb.remove(q1);
    await sync();
    await sync();
    expect((await ca.all()).map((c) => c.id), isNot(contains(q1)));
    expect((await cb.all()).map((c) => c.id), isNot(contains(q1)));
    expect((await a.library.manifest()).cards, (await b.library.manifest()).cards);
  }

  test('cards go between two devices that meet: made, answered on both, deleted', () async {
    await story(meet);
  });

  for (final encrypted in [true, false]) {
    test('cards go through a cloud folder (${encrypted ? 'sealed' : 'plain'}), pictures with them', () async {
      final cloud = MemoryCloudFolder();
      Future<void> run(Device d) async {
        final r = await FolderSync(
          folder: cloud,
          library: d.library,
          book: d.book,
          settings: d.settings,
          deviceId: d.identity.id,
          deviceName: d.name,
          key: secret.cloudKey,
          encrypted: encrypted,
        ).run();
        expect(r.problems, isEmpty);
      }

      await story(() async {
        await run(a);
        await run(b);
        await run(a);
      });
    });
  }

  test('a device that does not sync cards is sent none, and its manifest says so', () async {
    expect(SyncManifest.fromJson(const {}).cards, isNull, reason: 'an older device says nothing of cards');
    final plan = await a.library.plan('x', a.identity.id, SyncManifest.fromJson(const {}));
    expect(plan.cardDecks, isEmpty);
    await CardRepository(b.db).addAll('n1', const [Flashcard('Q', 'A')]);
    final theirs = await b.library.manifest();
    expect(theirs.cards, hasLength(1));
    expect(SyncManifest.fromJson(theirs.toJson()).cards, theirs.cards);
    expect((await a.library.plan(b.identity.id, a.identity.id, theirs)).cardDecks, ['n1']);
  });
}
