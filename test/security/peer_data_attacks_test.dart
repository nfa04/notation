// Attacks by a device or a person on the other end of a sync: what they send must never reach outside what they may touch.
// (See test/security/README.md for the list of all attack tests of the app.)
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/sync_library.dart';
import 'package:notes/devicesync/sync_session.dart';
import 'package:notes/data/lock_repository.dart';

import 'package:notes/devicesync/sync_keys.dart';
import 'dart:math';

import '../devicesync/harness.dart';

final _secretA = SyncSecret.create(Random(11));
const _roomA = 'room';

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late Device victim;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('security_');
    victim = await Device.create('Victim', root);
  });
  tearDown(() async {
    await victim.db.close();
    await root.delete(recursive: true);
  });

  Future<List<String>> filesUnder(Directory d) async => [for (final e in await d.list(recursive: true).toList()) if (e is File) e.path];

  group('a folder picture from a peer', () {
    for (final ext in ['../../../escape', '/etc/cron.d/x', 'png/../../x', 'png\u0000.sh', 'a' * 200, '']) {
      test('with the extension "${ext.replaceAll('\u0000', '\\0')}" is written inside the app folder, under a plain name', () async {
        final folder = SyncFolder('f1', null, 'Uni', 0, 0, 1);
        await victim.library.applyFolder(folder, image: (ext: ext, bytes: Uint8List.fromList([1, 2, 3])));
        final written = await filesUnder(root);
        final inside = victim.dir.path;
        for (final path in written) {
          if (path.endsWith('.db') || path.contains('-journal') || path.contains('-wal') || path.contains('-shm')) continue;
          expect(path.startsWith('$inside/'), isTrue, reason: path);
        }
        // nothing outside the device's own folder, anywhere under the test root
        expect(written.where((p) => !p.startsWith('${victim.dir.path}/')), isEmpty);
        expect(await File('${root.path}/escape').exists(), isFalse);
      });
    }

    test('with an id that climbs out of the folder is written inside it', () async {
      await victim.library.applyFolder(SyncFolder('../../../loot', null, 'x', 0, 0, 1), image: (ext: 'png', bytes: Uint8List.fromList([1])));
      expect((await filesUnder(root)).where((p) => !p.startsWith('${victim.dir.path}/')), isEmpty);
    });
  });

  group('a locked note', () {
    test('is not in the manifest, and its bytes are never given, also when a peer asks for it by its id', () async {
      final id = await victim.note('Diary', 'my secret xyzzy');
      await victim.repo.locks.putLock(id, LockRow(mode: 1, salt: Uint8List(16), iterations: 1));
      expect((await victim.library.manifest()).notes.where((n) => n.id == id), isEmpty);
      expect(await victim.library.noteBytes(id), isNull);
      expect(await victim.files.exportBytes(id), isNull);
    });
  });

  group('a device that is not on the list of the profile', () {
    test('gets no note, whichever way it asks', () async {
      final id = await victim.note('Private', 'only for the profile');
      final stranger = await Device.create('Stranger', root);
      final (c1, c2) = await pipe();
      // (the victim has no link on offer; the stranger comes with nothing but the same secret)
      final r = await Future.wait([
        victim.session(c1, _secretA, _roomA).run(),
        stranger.session(c2, _secretA, _roomA).run(),
      ]);
      expect(r[0].end, SyncEnd.refused);
      expect((await stranger.repo.listNotes()), isEmpty);
      expect(await victim.text(id), 'only for the profile');
      await stranger.db.close();
    });
  });
}
