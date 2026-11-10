import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/rich_text.dart';

/// A note file comes from anywhere (a download, a share, a sync folder): however it is damaged, reading it ends in a [NoteFileException]
/// (or a note), quickly, and never in another kind of error or a huge allocation.
void main() {
  setUpAll(AppDatabase.initFfi);

  NoteData sample() {
    final n = NoteData(id: 'n1', title: 'Fuzz', documentText: '# Title\n\nSome **text**', documentSpans: [TextSpanAttribute(start: 2, end: 7, type: AttributeType.italic)]);
    n.strokes = {
      0: [
        for (var i = 0; i < 6; i++) DrawingStroke(color: Colors.blue, width: 2, points: [for (var k = 0; k < 8; k++) Offset(k * 3.0, i * 5.0 + k)]),
      ],
      3: [DrawingStroke(color: Colors.red, width: 4, points: const [Offset(1, 1), Offset(9, 9)])],
    };
    n.textBoxes[1] = [TextBoxWidgetModel(id: 'b1', position: const Offset(4, 5), size: const Size(100, 50), initialText: 'hello', fontSize: 16)];
    return n;
  }

  /// Reads [bytes] and tells what came out, or null when it was read fine; fails the test for anything but a [NoteFileException].
  String? outcome(Uint8List bytes) {
    final sw = Stopwatch()..start();
    try {
      decodeNoteFile(bytes);
      return null;
    } on NoteFileException catch (e) {
      return e.message;
    } finally {
      expect(sw.elapsedMilliseconds, lessThan(3000), reason: 'reading damaged bytes must not take long');
    }
  }

  test('bytes flipped anywhere in the file end in a note or in words', () {
    final good = encodeNoteFile(NoteFileParts(sample()));
    expect(outcome(good), isNull);
    final rnd = Random(77);
    var damaged = 0;
    for (var round = 0; round < 400; round++) {
      final bytes = Uint8List.fromList(good);
      for (var k = 0; k < 1 + rnd.nextInt(6); k++) {
        bytes[rnd.nextInt(bytes.length)] = rnd.nextInt(256);
      }
      if (outcome(bytes) != null) damaged++;
    }
    expect(damaged, greaterThan(0), reason: 'a fuzz run in which nothing was ever refused tests nothing');
  });

  test('a file cut off anywhere is refused in words', () {
    final good = encodeNoteFile(NoteFileParts(sample()));
    final rnd = Random(5);
    for (var round = 0; round < 100; round++) {
      final cut = rnd.nextInt(good.length - 1);
      final message = outcome(Uint8List.sublistView(good, 0, cut));
      expect(message, isNotNull, reason: 'cut at $cut of ${good.length}');
    }
    expect(outcome(Uint8List(0)), isNotNull);
  });

  test('bytes that are no file at all are refused in words', () {
    final rnd = Random(9);
    for (var round = 0; round < 50; round++) {
      final junk = Uint8List.fromList([for (var i = 0; i < rnd.nextInt(2000); i++) rnd.nextInt(256)]);
      expect(outcome(junk), isNotNull);
    }
    expect(outcome(Uint8List.fromList(utf8.encode('{"format":"uninote"}'))), isNotNull);
  });

  group('a manifest and strokes with the wrong things in them', () {
    Uint8List zipWith(Map<String, Object?> manifest, {Uint8List? strokes}) {
      final a = Archive()..addFile(ArchiveFile.bytes('manifest.json', utf8.encode(jsonEncode(manifest))));
      if (strokes != null) a.addFile(ArchiveFile.bytes('strokes.bin', strokes));
      return Uint8List.fromList(ZipEncoder().encode(a));
    }

    test('a wrong format, a version of the wrong kind, a newer version', () {
      expect(outcome(zipWith({'format': 'other', 'version': 1})), contains('wrong format'));
      expect(outcome(zipWith({'format': 'uninote', 'version': 'one'})), contains('version'));
      expect(outcome(zipWith({'format': 'uninote', 'version': 0})), contains('version'));
      expect(outcome(zipWith({'format': 'uninote', 'version': noteFileVersion + 1})), contains('newer version'));
    });

    test('a manifest whose parts are of the wrong kind is read as far as it can be or refused, never another error', () {
      final kinds = <Object?>[null, 'text', 7, -3, 1e30, true, [], {}, [1, 2], {'a': 1}];
      final keys = ['title', 'background', 'landscape', 'pages', 'textBoxes', 'images', 'highlights', 'documentText', 'documentSpans', 'margins', 'pdf', 'created', 'updated'];
      final rnd = Random(3);
      for (var round = 0; round < 300; round++) {
        final m = <String, Object?>{'format': 'uninote', 'version': noteFileVersion};
        for (final k in keys) {
          if (rnd.nextBool()) m[k] = kinds[rnd.nextInt(kinds.length)];
        }
        outcome(zipWith(m));
      }
    });

    test('strokes: a count that promises more than the bytes hold, a page far out, a point that is not a number', () {
      Uint8List strokes(void Function(ByteData d) fill) {
        final d = ByteData(4096);
        fill(d);
        return Uint8List.fromList(d.buffer.asUint8List());
      }

      final huge = strokes((d) {
        d.setUint32(0, 0x54534E55, Endian.little);
        d.setUint32(4, 1, Endian.little);
        d.setUint32(8, 0xFFFFFFFF, Endian.little); // (four billion strokes)
      });
      expect(() => decodeStrokes(huge), throwsA(isA<NoteFileException>()));

      final far = strokes((d) {
        d.setUint32(0, 0x54534E55, Endian.little);
        d.setUint32(4, 1, Endian.little);
        d.setUint32(8, 1, Endian.little);
        d.setUint32(12, 0xFFFFFF, Endian.little); // (a page far out)
      });
      expect(() => decodeStrokes(far), throwsA(isA<NoteFileException>()));

      final nan = strokes((d) {
        d.setUint32(0, 0x54534E55, Endian.little);
        d.setUint32(4, 1, Endian.little);
        d.setUint32(8, 1, Endian.little);
        d.setUint32(12, 0, Endian.little);
        d.setUint32(16, 0xFF000000, Endian.little);
        d.setFloat32(20, double.nan, Endian.little);
      });
      expect(() => decodeStrokes(nan), throwsA(isA<NoteFileException>()));

      expect(() => decodeStrokes(Uint8List(5)), throwsA(isA<NoteFileException>()));
      expect(() => decodeStrokes(Uint8List(64)), throwsA(isA<NoteFileException>()), reason: 'zeros are no magic number');
    });

    test('strokes written by the app read back the same', () {
      final n = sample();
      final back = decodeStrokes(encodeStrokes(n.strokes));
      expect(back.keys, n.strokes.keys);
      expect(back[0]!.length, 6);
      expect(back[3]!.single.points, const [Offset(1, 1), Offset(9, 9)]);
    });

    test('strokes cut off at any byte are refused in words', () {
      final bytes = encodeStrokes(sample().strokes);
      for (var cut = 0; cut < bytes.length; cut++) {
        try {
          decodeStrokes(Uint8List.sublistView(bytes, 0, cut));
          fail('cut at $cut was read');
        } on NoteFileException {
          // expected
        }
      }
    });
  });
}
