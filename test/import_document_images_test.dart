import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('a note file never replaces a picture the device already has under that name', () async {
    final dir = await Directory.systemTemp.createTemp('doc_images_');
    addTearDown(() => dir.delete(recursive: true));
    final notes = NoteRepository(await AppDatabase.open(path: '${dir.path}/n.db'));
    final service = NoteFileService(notes, supportDirectory: () async => dir);
    final images = Directory('${dir.path}/images')..createSync();
    final file = File('${images.path}/n-doc-1.png');
    final theirs = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
    final mine = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 9, 9, 9]);

    final id = await notes.createNote(title: 'Pictures');
    final note = (await notes.loadNote(id))!..documentText = 'A picture: ![dot](image:n-doc-1.png)';
    await notes.saveNote(note);
    file.writeAsBytesSync(theirs);
    final bytes = (await service.exportBytes(id))!;

    // the same picture is there already: nothing to say
    final same = await service.importBytes(bytes);
    expect(same.warnings, isEmpty);
    expect(file.readAsBytesSync(), theirs);

    // another picture has that name: it stays, and the person is told
    file.writeAsBytesSync(mine);
    final clash = await service.importBytes(bytes);
    expect(file.readAsBytesSync(), mine);
    expect(clash.warnings, hasLength(1));

    // none there: the picture of the file is put in place
    file.deleteSync();
    final fresh = await service.importBytes(bytes);
    expect(fresh.warnings, isEmpty);
    expect(file.readAsBytesSync(), theirs);
  });
}
