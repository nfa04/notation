import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';

import 'harness.dart';

/// The library as the syncs see it: what it says of a note, and taking notes in when two syncs bring them at once.
void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late Device x, b, c;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('synclib_');
    x = await Device.create('Laptop', root);
    b = await Device.create('Tablet', root);
    c = await Device.create('Phone', root);
  });
  tearDown(() async {
    for (final d in [x, b, c]) {
      await d.db.close();
    }
    await root.delete(recursive: true);
  });

  /// [to] takes in the note [id] as [from] has it, with the version it has there.
  Future<void> give(Device from, Device to, String id) async {
    final info = (await from.library.noteInfo(id))!;
    await to.library.applyNote(from.identity.id, info, await from.library.noteBytes(id), data: true, meta: true);
  }

  test('what it says of one note is what the whole manifest says of it', () async {
    final n = await x.note('One', 'text');
    await x.note('Two', 'more');
    final whole = (await x.library.manifest()).notes.singleWhere((e) => e.id == n);
    final one = (await x.library.noteInfo(n))!;
    expect(one.toJson(), whole.toJson());
    expect(await x.library.noteInfo('no such note'), isNull);
  });

  test('two devices that changed the same note on their own, taken in at the same moment: one wins, the other is kept as a copy', () async {
    final n = await x.note('Shared', 'v1');
    await give(x, b, n);
    await give(x, c, n);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.edit(n, 'from the tablet');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await c.edit(n, 'from the phone');
    // the folder brings one, a direct sync the other, at once
    await Future.wait([give(b, x, n), give(c, x, n)]);
    final texts = [for (final e in await x.repo.listNotes()) await x.text(e.id)];
    expect(texts, containsAll(['from the tablet', 'from the phone']), reason: 'a version was lost: $texts');
  });

  test('a setting is told as it is, and one that does not travel is not told', () async {
    await x.settings.set('app_accent', 'teal');
    await x.settings.set('sync_server', 'wss://example');
    expect((await x.library.settingValue('app_accent'))?.value, 'teal');
    expect(await x.library.settingValue('sync_server'), isNull);
  });
}
