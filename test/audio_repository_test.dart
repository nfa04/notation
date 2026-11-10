import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/audio/wav.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/audio_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  late Directory dir;
  late AudioRepository audio;
  final wav = wavFromMuLaw(Uint8List.fromList(List.filled(8000, 0xFF)), 8000); // one second of silence

  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath);
    dir = await Directory.systemTemp.createTemp('audio_repo_');
    audio = AudioRepository(db, root: () async => dir);
    await db.insert('notes', {'id': 'n1', 'created_at': 1, 'updated_at': 1});
    await db.insert('notes', {'id': 'n2', 'created_at': 1, 'updated_at': 1});
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('a sound is kept as a file and a row, with its length read from the file', () async {
    final a = await audio.add('n1', wav, title: 'Lecture', createdAt: DateTime(2026, 3, 1));
    expect(a.duration, const Duration(seconds: 1));
    expect(a.bytes, wav.length);
    final listed = await audio.list('n1');
    expect(listed.single.title, 'Lecture');
    expect(listed.single.kind, AudioKind.recording);
    expect(await audio.bytesOf(listed.single), wav);
    expect(await audio.list('n2'), isEmpty);
    expect(await audio.counts(), {'n1': 1});
  });

  test('sounds are listed in the order they were made; renaming and removing', () async {
    final b = await audio.add('n1', wav, title: 'B', createdAt: DateTime(2026, 3, 2));
    final a = await audio.add('n1', wav, title: 'A', kind: AudioKind.speech, createdAt: DateTime(2026, 3, 1));
    expect((await audio.list('n1')).map((x) => x.title), ['A', 'B']);
    await audio.rename(a, '  Reading  ');
    expect((await audio.list('n1')).first.title, 'Reading');
    final file = (await audio.fileOf(b))!;
    await audio.remove(b);
    expect(await file.exists(), isFalse);
    expect((await audio.list('n1')).map((x) => x.id), [a.id]);
  });

  test('deleting a note deletes its rows, and the files that are left over are cleared away', () async {
    final a = await audio.add('n1', wav);
    final kept = await audio.add('n2', wav);
    await db.delete('notes', where: 'id = ?', whereArgs: ['n1']);
    expect(await audio.list('n1'), isEmpty);
    expect(await audio.purgeOrphans(), 1);
    expect(await audio.fileOf(a), isNull);
    expect(await audio.fileOf(kept), isNotNull);
    expect(await audio.purgeOrphans(), 0);
  });

  test('two notes can bring a sound with the same id, and neither takes the other\'s', () async {
    await audio.add('n1', wav, id: 'same', title: 'one');
    await audio.add('n2', wav, id: 'same', title: 'two');
    expect((await audio.list('n1')).single.title, 'one');
    expect((await audio.list('n2')).single.title, 'two');
    await audio.removeAllFor('n1');
    expect(await audio.list('n1'), isEmpty);
    expect((await audio.bytesOf((await audio.list('n2')).single)), wav);
  });

  test('a sound that comes with a note file keeps its id', () async {
    final a = await audio.add('n1', wav, id: 'fixed-id', title: 'x');
    expect(a.id, 'fixed-id');
    await audio.add('n1', wav, id: 'fixed-id', title: 'y'); // the same again replaces it
    expect((await audio.list('n1')).single.title, 'y');
  });

  test('changes are announced', () async {
    var n = 0;
    final sub = audio.changes.listen((_) => n++);
    final a = await audio.add('n1', wav);
    await audio.rename(a, 'x');
    await audio.remove(a);
    await Future<void>.delayed(Duration.zero);
    expect(n, 3);
    await sub.cancel();
  });
}
