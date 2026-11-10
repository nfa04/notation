import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/note_file.dart';
import 'package:notes/data/safe_zip.dart';

Uint8List _bytes(int n, int seed) => Uint8List.fromList(List.generate(n, (i) => (i * 31 + seed + i ~/ 7) & 255));

void main() {
  final manifest = Uint8List.fromList('{"format":"uninote"}'.codeUnits);
  final strokes = _bytes(2000, 1);
  final pdf = _bytes(300 * 1024, 2);
  final picture = _bytes(100 * 1024, 3);
  final small = _bytes(1000, 4);
  final whole = zipNoteFile([
    ('manifest.json', manifest, true),
    ('strokes.bin', strokes, true),
    ('source.pdf', pdf, false),
    ('media/1.png', picture, false),
    ('media/2.png', small, false),
  ]);

  Map<String, List<int>> files(Uint8List zip) => {for (final f in decodeZipLimited(zip).files) if (f.isFile) f.name: f.content};

  test('the big files come out of a note file, and the rest stays a note file', () {
    final split = splitNoteFile(whole)!;
    expect({for (final b in split.blobs) b.name}, {'source.pdf', 'media/1.png'});
    expect(split.blobs.firstWhere((b) => b.name == 'source.pdf').hash, sha256.convert(pdf).toString());
    expect(files(split.slim).keys.toSet(), {'manifest.json', 'strokes.bin', 'media/2.png'}, reason: 'a small picture stays');
    expect(split.slim.length, lessThan(20 * 1024));
  });

  test('joined again it holds the same files', () {
    final split = splitNoteFile(whole)!;
    final back = joinNoteFile(split.slim, {for (final b in split.blobs) b.name: b.bytes});
    expect(files(back), files(whole));
  });

  test('nothing to take out of a note without big files', () {
    expect(splitNoteFile(zipNoteFile([('manifest.json', manifest, true), ('strokes.bin', strokes, true)])), isNull);
  });

  test('a device that has the files finds them by their hash', () {
    final found = noteAttachmentsByHash(whole, {pdf.length, picture.length});
    expect(found.keys.toSet(), {sha256.convert(pdf).toString(), sha256.convert(picture).toString()});
    expect(noteAttachmentsByHash(whole, {1}), isEmpty);
    expect(noteAttachmentsByHash(Uint8List.fromList([1, 2, 3]), {3}), isEmpty, reason: 'not a note file');
  });
}
