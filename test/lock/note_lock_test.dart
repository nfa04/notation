import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/lock/note_lock_service.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Vault implements PassphraseVault {
  final Map<String, String> kept = {};
  @override
  Future<String?> read(String id) async => kept[id];
  @override
  Future<void> write(String id, String s) async => kept[id] = s;
  @override
  Future<void> delete(String id) async => kept.remove(id);
}

class _Device implements DeviceAuth {
  bool ok = true;
  @override
  Future<bool> available() async => true;
  @override
  Future<bool> authenticate(String reason) async => ok;
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late NoteFileService files;
  late Directory dir;
  late _Vault vault;
  late _Device device;
  late NoteLockService locks;
  final sealedNotes = <String>[];

  NoteLockService service() => NoteLockService(repo, files, deviceAuth: device, vault: vault, iterations: 1000, onSealed: (id) async => sealedNotes.add(id));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('locks');
    repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
    files = NoteFileService(repo, supportDirectory: () async => dir);
    vault = _Vault();
    device = _Device();
    sealedNotes.clear();
    locks = service();
  });
  tearDown(() => dir.delete(recursive: true));

  /// A note with a drawing, a text box, a written document and a picture on disk.
  Future<(String, String)> secretNote() async {
    final id = await repo.createNote(title: 'Diary');
    final pic = '${dir.path}/pic.png';
    await File(pic).writeAsBytes([1, 2, 3, 4]);
    final n = (await repo.loadNote(id))!;
    n.documentText = 'Dear diary, my secret';
    n.strokes = {
      0: [DrawingStroke(id: 's1', color: Colors.red, width: 3, points: [const Offset(1, 1), const Offset(20, 30)], pressures: [10, 200])],
    };
    n.textBoxes = {
      0: [TextBoxWidgetModel(id: 'b', position: const Offset(10, 10), initialText: 'hidden words')],
    };
    n.images = {
      0: [ImageItem(id: 'im', path: pic, position: const Offset(5, 5), size: const Size(40, 30))],
    };
    await repo.saveNote(n);
    return (id, pic);
  }

  group('encrypted', () {
    test('locking takes everything out of the database and the disk; opening brings it back', () async {
      final (id, pic) = await secretNote();
      await locks.lockEncrypted(id, 'correct horse');

      expect(await repo.locks.lockModeOf(id), 2);
      expect(locks.isOpen(id), isFalse);
      final empty = (await repo.loadNote(id))!;
      expect(empty.title, '');
      expect(empty.documentText, '');
      expect(empty.strokes, isEmpty);
      expect(empty.textBoxes, isEmpty);
      expect(empty.images, isEmpty);
      expect(File(pic).existsSync(), isFalse); // the picture file is gone too
      expect(sealedNotes, [id]);
      // nothing of it can be found, read, or written out
      expect(await repo.text.noteText(id), '');
      expect((await repo.text.searchSources()).where((s) => s.noteId == id), isEmpty);
      expect(await files.exportBytes(id), isNull);
      // the block holds no readable text
      final block = (await repo.locks.lockRow(id))!.data!;
      expect(String.fromCharCodes(block).contains('secret'), isFalse);

      expect(await locks.unlock(id, 'wrong'), isFalse);
      expect(locks.isOpen(id), isFalse);
      expect((await repo.loadNote(id))!.strokes, isEmpty);

      expect(await locks.unlock(id, 'correct horse'), isTrue);
      expect(locks.isOpen(id), isTrue);
      final back = (await repo.loadNote(id))!;
      expect(back.title, 'Diary');
      expect(back.documentText, 'Dear diary, my secret');
      expect(back.strokes[0]!.single.pressures, [10, 200]);
      expect(back.textBoxes[0]!.single.controller.text, 'hidden words');
      expect(File(back.images[0]!.single.path).readAsBytesSync(), [1, 2, 3, 4]);
      expect(await files.exportBytes(id), isNotNull); // (it can be written out while it is open)
    });

    test('put away again, with what was changed while it was open', () async {
      final (id, _) = await secretNote();
      await locks.lockEncrypted(id, 'pw');
      await locks.unlock(id, 'pw');
      final n = (await repo.loadNote(id))!;
      n.documentText = 'a new line';
      await repo.saveNote(n);
      await locks.seal(id);
      expect((await repo.loadNote(id))!.documentText, '');
      expect(await repo.locks.lockModeOf(id), 2);
      await locks.unlock(id, 'pw');
      expect((await repo.loadNote(id))!.documentText, 'a new line');
    });

    test('a note left open when the app stopped keeps its newer content, and is put away with the passphrase', () async {
      final (id, _) = await secretNote();
      await locks.lockEncrypted(id, 'pw');
      await locks.unlock(id, 'pw');
      final n = (await repo.loadNote(id))!;
      n.documentText = 'written just before it stopped';
      await repo.saveNote(n);

      final afterRestart = service(); // (no keys in memory, the note still in plain in the database)
      repo.locks.unlocked.clear();
      expect(await afterRestart.unlock(id, 'nope'), isFalse);
      expect(await afterRestart.unlock(id, 'pw'), isTrue);
      expect((await repo.loadNote(id))!.documentText, 'written just before it stopped');
      await afterRestart.seal(id);
      expect((await repo.loadNote(id))!.documentText, '');
      await afterRestart.unlock(id, 'pw');
      expect((await repo.loadNote(id))!.documentText, 'written just before it stopped');
    });

    test('the lock can be taken off only while the note is open, and a new passphrase works', () async {
      final (id, _) = await secretNote();
      await locks.lockEncrypted(id, 'one');
      expect(await locks.removeLock(id), isFalse);
      await locks.unlock(id, 'one');
      expect(await locks.changeSecret(id, 'two'), isTrue);
      await locks.seal(id);
      expect(await locks.unlock(id, 'one'), isFalse);
      expect(await locks.unlock(id, 'two'), isTrue);
      expect(await locks.removeLock(id), isTrue);
      expect(await repo.locks.lockModeOf(id), 0);
      expect((await repo.loadNote(id))!.title, 'Diary');
      expect(await repo.locks.lockRow(id), isNull);
    });
  });

  group('passcode', () {
    test('the note stays as it is but is kept out of sight until the passcode is given', () async {
      final (id, _) = await secretNote();
      await locks.lockWithPasscode(id, '1234');
      expect(await repo.locks.lockModeOf(id), 1);
      expect(locks.isOpen(id), isTrue); // (just locked: open until put away)
      await locks.seal(id);
      expect(locks.isOpen(id), isFalse);
      expect(await repo.text.noteText(id), '');
      expect((await repo.text.searchSources()).where((s) => s.noteId == id), isEmpty);
      expect(await files.exportBytes(id), isNull);
      expect((await repo.listNotes()).singleWhere((n) => n.id == id).lockMode, 1);
      expect((await repo.loadNote(id))!.title, 'Diary'); // (kept: the lists hide it)

      expect(await locks.unlock(id, '0000'), isFalse);
      expect(await locks.unlock(id, '1234'), isTrue);
      expect(await files.exportBytes(id), isNotNull);
      expect(await locks.removeLock(id), isTrue);
      expect(await repo.text.noteText(id), contains('secret'));
    });
  });

  group('the device', () {
    test('opens a note when that was allowed, and not when the device says no or it was not allowed', () async {
      final (a, _) = await secretNote();
      await locks.lockEncrypted(a, 'pw', allowDevice: true);
      expect(await locks.deviceUnlockAllowed(a), isTrue);
      expect(await locks.unlockWithDevice(a, 'open'), isTrue);
      expect(locks.isOpen(a), isTrue);
      await locks.seal(a);
      device.ok = false;
      expect(await locks.unlockWithDevice(a, 'open'), isFalse);
      expect(locks.isOpen(a), isFalse);
      device.ok = true;

      final (b, _) = await secretNote();
      await locks.lockWithPasscode(b, '99');
      await locks.seal(b);
      expect(await locks.deviceUnlockAllowed(b), isFalse);
      expect(await locks.unlockWithDevice(b, 'open'), isFalse);

      // taking the lock off forgets the secret in the keystore
      await locks.unlock(a, 'pw');
      await locks.removeLock(a);
      expect(vault.kept.containsKey(a), isFalse);
    });
  });

  test('the lists hide a locked note\'s picture and the text of other things read it as empty', () async {
    final (id, _) = await secretNote();
    await repo.setNoteThemeImage(id, '${dir.path}/pic.png');
    await locks.lockWithPasscode(id, '1');
    await locks.seal(id);
    expect((await repo.listNotes()).singleWhere((n) => n.id == id).themeImage, isNull);
    final sealedBytes = Uint8List(0);
    expect(sealedBytes, isEmpty);
  });

  group('locks made with fewer iterations', () {
    NoteLockService stronger() => NoteLockService(repo, files, deviceAuth: device, vault: vault, iterations: 2000, onSealed: (id) async => sealedNotes.add(id));

    test('a passcode lock is made again with more iterations the first time it is opened, and opens with the same passcode', () async {
      final id = await repo.createNote(title: 'n');
      await locks.lockWithPasscode(id, '1234');
      await locks.seal(id);
      final before = (await repo.locks.lockRow(id))!;
      expect(before.iterations, 1000);

      final next = stronger();
      expect(await next.unlock(id, '0000'), isFalse);
      expect((await repo.locks.lockRow(id))!.iterations, 1000); // a wrong passcode changes nothing
      expect(await next.unlock(id, '1234'), isTrue);
      final after = (await repo.locks.lockRow(id))!;
      expect(after.iterations, 2000);
      expect(after.salt, isNot(before.salt));
      expect(after.verifier, isNot(before.verifier));

      await next.seal(id);
      expect(await next.unlock(id, '0000'), isFalse);
      expect(await next.unlock(id, '1234'), isTrue);
      expect((await repo.locks.lockRow(id))!.salt, after.salt); // once is enough
    });

    test('an encrypted note keeps its content through the change, and is sealed under the new key', () async {
      final (id, _) = await secretNote();
      await locks.lockEncrypted(id, 'correct horse');
      final before = (await repo.locks.lockRow(id))!;
      expect(before.iterations, 1000);

      final next = stronger();
      expect(await next.unlock(id, 'wrong'), isFalse);
      expect(await next.unlock(id, 'correct horse'), isTrue);
      final during = (await repo.locks.lockRow(id))!;
      expect(during.iterations, 2000);
      expect(during.salt, isNot(before.salt));
      expect((await repo.loadNote(id))!.documentText, 'Dear diary, my secret');

      await next.seal(id);
      expect((await repo.loadNote(id))!.documentText, '');
      // the old service, which only knows 1000 iterations, reads the stored number and still opens it
      expect(await locks.unlock(id, 'correct horse'), isTrue);
      expect((await repo.loadNote(id))!.documentText, 'Dear diary, my secret');
      expect((await repo.locks.lockRow(id))!.iterations, 2000);
    });
  });
}
