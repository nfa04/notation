import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/audio/wav.dart';
import 'package:notes/collab/compression.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/audio_repository.dart';
import 'package:notes/data/note_file.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/safe_names.dart';
import 'package:notes/data/safe_zip.dart';
import 'package:notes/extensions/extension_manifest.dart';
import 'package:notes/extensions/extension_service.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/models/pdf_models.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Files and messages of other people name things (a sound, a picture) and say how big they are. None of that may decide where on
/// the disk something is written, or how much memory is taken.
void main() {
  setUpAll(AppDatabase.initFfi);

  group('names', () {
    test('only plain names are ids', () {
      for (final ok in ['abc', 'lq3k9-0a1b2c3d4e5f6a7b', 'A_b-9', 'x' * 128]) {
        expect(isSafeId(ok), isTrue, reason: ok);
      }
      for (final bad in ['', '.', '..', '../x', 'a/b', r'a\b', 'a.b', '-x', ' a', 'a b', 'a\x00b', 'x' * 129, 'é']) {
        expect(isSafeId(bad), isFalse, reason: bad);
      }
      expect(isSafeId(null), isFalse);
    });

    test('an extension is five letters or digits or nothing', () {
      expect(safeExtension('PNG'), 'png');
      expect(safeExtension('jpeg'), 'jpeg');
      expect(safeExtension('a/../../x'), 'png');
      expect(safeExtension(r'png\..\x'), 'png');
      expect(safeExtension('toolong'), 'png');
      expect(safeExtension('', fallback: 'bin'), 'bin');
    });

    test('the extension of an entry of an archive is the one of its last part', () {
      expect(extensionOfEntry('media/images/ab.PNG'), 'png');
      expect(extensionOfEntry('media/images/ab'), 'png');
      expect(extensionOfEntry('media.x/ab'), 'png');
      expect(extensionOfEntry('a.b/../../../Startup/x.bat'), 'bat');
      expect(extensionOfEntry(r'a.b\..\..\x'), 'png');
      expect(extensionOfEntry('x./../../y'), 'png');
      expect(extensionOfEntry(null), 'png');
    });

    test('a folder id becomes a file name', () {
      expect(safeFileId('lq3k9-ab12'), 'lq3k9-ab12');
      expect(safeFileId('../../x'), '______x');
      expect(safeFileId(''), '_');
      expect(safeFileId('a' * 500).length, 128);
    });

    test('a path is inside a folder only if it stays there', () {
      expect(isInside('/a/audio', '/a/audio/n/x.wav'), isTrue);
      expect(isInside('/a/audio', '/a/audio/n/../../x.wav'), isFalse);
      expect(isInside('/a/audio', '/a/audio'), isFalse);
    });
  });

  group('zip files', () {
    Uint8List zip(Map<String, List<int>> files) {
      final archive = Archive();
      files.forEach((name, data) => archive.add(ArchiveFile(name, data.length, data)));
      return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
    }

    test('too many files, a file that is too big and a total that is too big are turned away before anything is unpacked', () {
      final many = zip({for (var i = 0; i < 20; i++) 'f$i': [1]});
      expect(() => decodeZipLimited(many, maxEntries: 10), throwsA(isA<ArchiveTooBigException>()));
      expect(decodeZipLimited(many, maxEntries: 20).files, hasLength(20));

      final bomb = zip({'zeros': List.filled(100000, 0)});
      expect(bomb.length, lessThan(2000), reason: 'a small file that unpacks to a lot');
      expect(() => decodeZipLimited(bomb, maxEntryBytes: 50000), throwsA(isA<ArchiveTooBigException>()));

      final two = zip({'a': List.filled(600, 0), 'b': List.filled(600, 0)});
      expect(() => decodeZipLimited(two, maxEntryBytes: 1000, maxTotalBytes: 1000), throwsA(isA<ArchiveTooBigException>()));
      expect(decodeZipLimited(two, maxEntryBytes: 1000, maxTotalBytes: 1200).files, hasLength(2));
    });

    test('an extension zip with a file too big for an extension is refused', () {
      final service = ExtensionService((_) async => null, (_, _) async {});
      final big = zip({'manifest.json': utf8.encode('{}'), 'main.js': List.filled(2 << 20, 0x20)});
      expect(() => service.inspectZip(big), throwsA(isA<ManifestException>().having((e) => e.toString(), 'message', contains('too big'))));
    });
  });

  group('messages', () {
    test('a message that unpacks to more than the limit is refused, one that fits is not', () {
      final huge = Uint8List(50000); // zeros: a few dozen bytes packed
      final packed = packMessageSync(huge);
      expect(packed.length, lessThan(200));
      expect(() => unpackMessageSync(packed, limit: 1000), throwsFormatException);
      expect(unpackMessageSync(packed, limit: 50000), huge);
    });

    test('a damaged packed message is a format error', () {
      final packed = packMessageSync(Uint8List.fromList(List.generate(2000, (i) => i % 7)));
      packed[packed.length ~/ 2] ^= 0xFF;
      expect(() => unpackMessageSync(packed), throwsFormatException);
    });
  });

  group('a note file of the wrong form', () {
    late Directory root;
    late Database db;
    late NoteRepository repo;
    late NoteFileService service;
    late Archive entries;
    late Map<String, Object?> manifest;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('malformed_');
      db = await AppDatabase.open(path: '${root.path}/n.db');
      repo = NoteRepository(db);
      service = NoteFileService(repo, supportDirectory: () async => root);
      final audio = AudioRepository(db, root: () async => Directory('${root.path}/audio'));
      service.audio = audio;
      final pdf = File('${root.path}/doc.pdf')..writeAsBytesSync(utf8.encode('%PDF-1.4 fake'));
      final pic = File('${root.path}/pic.png')..writeAsBytesSync([9, 8, 7, 6]);
      final id = await repo.createNote(title: 'Rich');
      final n = (await repo.loadNote(id))!
        ..pdfName = 'doc.pdf'
        ..pdfPath = pdf.path
        ..pdfSha256 = sha256.convert(pdf.readAsBytesSync()).toString()
        ..pdfPageCount = 3
        ..documentText = 'words';
      n.strokes[0] = [DrawingStroke(color: Colors.black, width: 2, points: const [Offset(1, 2), Offset(5, 9)])];
      n.textBoxes[0] = [TextBoxWidgetModel(id: 'b1', position: const Offset(4, 5), size: const Size(100, 40), initialText: 'hi')];
      n.images[1] = [ImageItem(id: 'p', path: pic.path, position: const Offset(1, 2), size: const Size(30, 40))];
      n.highlights[0] = [PdfHighlight(rect: const Rect.fromLTWH(5, 5, 50, 10), color: Colors.yellow)];
      await repo.saveNote(n);
      await repo.ai.put(NoteAiRow(noteId: id, kind: 'summary', key: '', content: 'c', sourceHash: 1, model: 'm', createdAt: DateTime(2026)));
      await audio.add(id, wavFromMuLaw(Uint8List.fromList([1, 2, 3]), 8000), title: 'x', id: 'snd1');
      entries = ZipDecoder().decodeBytes((await service.exportBytes(id))!);
      manifest = (jsonDecode(utf8.decode(entries.find('manifest.json')!.content)) as Map).cast<String, Object?>();
    });
    tearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });

    Uint8List pack(Object? manifestJson, {Uint8List? strokes}) {
      final out = Archive();
      for (final f in entries.files) {
        if (f.name == 'manifest.json') continue;
        final data = f.name == (manifest['strokes'] as Map)['file'] && strokes != null ? strokes : f.content;
        out.add(ArchiveFile(f.name, data.length, data));
      }
      final text = utf8.encode(jsonEncode(manifestJson));
      out.add(ArchiveFile('manifest.json', text.length, text));
      return Uint8List.fromList(ZipEncoder().encodeBytes(out));
    }

    Object? copyOf(Object? v) => jsonDecode(jsonEncode(v));

    test('the unchanged file reads without a warning', () {
      final parsed = decodeNoteFile(pack(manifest));
      expect(parsed.warnings, isEmpty);
      expect(parsed.note.textBoxes[0], hasLength(1));
      expect(parsed.audio, hasLength(1));
    });

    test('whatever one value of the manifest is replaced with, the file opens or is refused as a note file, nothing else', () {
      // every value in the manifest, one at a time, becomes something of another kind
      final paths = <List<Object>>[];
      void walk(Object? v, List<Object> path) {
        paths.add(path);
        if (v is Map) {
          v.forEach((k, x) => walk(x, [...path, k as String]));
        } else if (v is List) {
          for (var i = 0; i < v.length; i++) {
            walk(v[i], [...path, i]);
          }
        }
      }

      walk(manifest, []);
      expect(paths.length, greaterThan(60));
      final wrong = <Object?>[null, 'x', '', -1, 1.5, 1e30, true, <Object?>[], <String, Object?>{}, 4294967296];
      var opened = 0, refused = 0;
      for (final path in paths.where((p) => p.isNotEmpty)) {
        for (final w in wrong) {
          final copy = copyOf(manifest);
          Object? parent = copy;
          for (final key in path.take(path.length - 1)) {
            parent = parent is Map ? parent[key] : (parent as List)[key as int];
          }
          final last = path.last;
          if (parent is Map) {
            parent[last] = w;
          } else {
            (parent as List)[last as int] = w;
          }
          try {
            decodeNoteFile(pack(copy));
            opened++;
          } on NoteFileException {
            refused++;
          } catch (e, st) {
            fail('$path = $w: $e\n$st');
          }
        }
      }
      expect(opened, greaterThan(refused));
    });

    test('a text box, picture or highlight in the wrong form is left out and named; the rest of the note is kept', () {
      final m = copyOf(manifest) as Map<String, Object?>;
      (m['textBoxes'] as List).first['id'] = 7;
      (m['images'] as List).first['page'] = 'one';
      (m['highlights'] as List).first['color'] = 'yellow';
      final parsed = decodeNoteFile(pack(m));
      expect(parsed.warnings, containsAll([contains('text box'), contains('picture'), contains('highlight')]));
      expect(parsed.note.textBoxes, isEmpty);
      expect(parsed.note.images, isEmpty);
      expect(parsed.note.highlights, isEmpty);
      expect(parsed.note.strokes[0], hasLength(1));
      expect(parsed.audio, hasLength(1));
    });

    test('a page far beyond any note is not accepted, so no editor is asked to build millions of pages', () {
      final m = copyOf(manifest) as Map<String, Object?>;
      (m['textBoxes'] as List).first['page'] = 2000000000;
      final parsed = decodeNoteFile(pack(m));
      expect(parsed.note.textBoxes, isEmpty);
      expect(parsed.warnings, contains(contains('text box')));
    });

    test('strokes that are cut off anywhere are refused, and a damaged byte anywhere in them gives a note file error at worst', () {
      final name = (manifest['strokes'] as Map)['file'] as String;
      final good = Uint8List.fromList(entries.find(name)!.content);
      for (var cut = 0; cut < good.length; cut++) {
        try {
          decodeNoteFile(pack(manifest, strokes: Uint8List.sublistView(good, 0, cut)));
          fail('cut at $cut was accepted');
        } on NoteFileException {
          // as it should
        }
      }
      for (final at in List.generate(good.length, (i) => i)) {
        final damaged = Uint8List.fromList(good)..[at] ^= 0xFF;
        try {
          decodeNoteFile(pack(manifest, strokes: damaged));
        } on NoteFileException {
          // refused: fine
        }
      }
    });

    test('a stroke with no points that says it has pressures does not keep the page from being drawn', () {
      final one = encodeStrokes({
        0: [DrawingStroke(id: 'a', color: Colors.black, width: 2, points: const [Offset(1, 2), Offset(3, 4)], pressures: [10, 20])],
      });
      // the same stroke with no points: the header, the id, page, colour, width, dash and fill, then 0 points, "pressures", the pen, the base layer
      final bytes = (BytesBuilder()
            ..add(one.sublist(0, 12 + 2 + 4 + 4 + 4 + 2 + 4))
            ..add([0, 0, 0, 0, 1, 0, 0]))
          .toBytes();
      final stroke = decodeStrokes(bytes)[0]!.single;
      expect(stroke.points, isEmpty);
      expect(() => stroke.stamp, returnsNormally);
      expect(() => InkLayerPainter(strokes: [stroke]), returnsNormally);
    });
  });

  group('a note file of somebody else', () {
    late Directory root, support;
    late Database db;
    late NoteRepository repo;
    late NoteFileService service;
    late AudioRepository audio;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('hostile_');
      support = await Directory('${root.path}/support').create();
      db = await AppDatabase.open(path: '${root.path}/n.db');
      repo = NoteRepository(db);
      service = NoteFileService(repo, supportDirectory: () async => support);
      audio = AudioRepository(db, root: () async => Directory('${support.path}/audio'));
      service.audio = audio;
    });
    tearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });

    /// A real file of a note with one sound and one picture, then [change] applied to its manifest and entries.
    Future<Uint8List> forged(void Function(Map<String, Object?> manifest, Archive entries) change) async {
      final id = await repo.createNote(title: 'Victim');
      await audio.add(id, wavFromMuLaw(Uint8List.fromList([1, 2, 3]), 8000), title: 'x', id: 'snd1');
      final archive = ZipDecoder().decodeBytes((await service.exportBytes(id))!);
      final manifestFile = archive.find('manifest.json')!;
      final manifest = (jsonDecode(utf8.decode(manifestFile.content)) as Map).cast<String, Object?>();
      change(manifest, archive);
      final out = Archive();
      for (final f in archive.files) {
        if (f.name == 'manifest.json') continue;
        out.add(ArchiveFile(f.name, f.size, f.content));
      }
      final text = utf8.encode(jsonEncode(manifest));
      out.add(ArchiveFile('manifest.json', text.length, text));
      return Uint8List.fromList(ZipEncoder().encodeBytes(out));
    }

    /// Every file under [root] but the database and what the app itself keeps in the support folder.
    List<String> strays() => [
          for (final e in root.listSync(recursive: true))
            if (e is File && !e.path.startsWith(support.path) && !e.path.contains('n.db')) e.path,
        ];

    test('a sound whose id climbs out of the folder is left out, and nothing is written outside', () async {
      for (final evil in ['../../escape', '../escape', 'a/../../../escape', r'..\..\escape']) {
        final bytes = await forged((m, _) {
          final list = (m['audio'] as List).cast<Map>();
          list.first['id'] = evil;
        });
        final result = await service.importBytes(bytes);
        expect(result.warnings, contains('A sound with an unusable name was left out'), reason: evil);
        expect(await audio.list(result.noteId), isEmpty, reason: evil);
      }
      expect(strays(), isEmpty);
      expect(File('${root.path}/escape.wav').existsSync(), isFalse);
      expect(File('${support.path}/escape.wav').existsSync(), isFalse);
    });

    test('the audio repository itself refuses a name that is not plain', () async {
      final id = await repo.createNote(title: 'n');
      final wav = wavFromMuLaw(Uint8List.fromList([1, 2, 3]), 8000);
      await expectLater(audio.add(id, wav, id: '../../x'), throwsArgumentError);
      await expectLater(audio.add('../other', wav), throwsArgumentError);
      expect(strays(), isEmpty);
      expect(File('${support.path}/x.wav').existsSync(), isFalse);
    });

    test('a picture whose name ends in something that is no extension is written with a plain one', () async {
      final bytes = await forged((m, entries) {
        final pic = [9, 8, 7, 6];
        const name = r'media/images/p.a/../../../../evil';
        entries.add(ArchiveFile(name, pic.length, pic));
        m['images'] = [
          {'id': 'p', 'page': 0, 'file': name, 'x': 1, 'y': 2, 'w': 30, 'h': 40},
        ];
      });
      final result = await service.importBytes(bytes);
      expect(result.warnings, isEmpty);
      final note = (await repo.loadNote(result.noteId))!;
      final path = note.images[0]!.single.path;
      expect(File(path).existsSync(), isTrue);
      expect(isInside('${support.path}/images', path), isTrue);
      expect(path, endsWith('.png'));
      expect(strays(), isEmpty);
    });

    test('a file that unpacks to too much is refused with a message about its size', () {
      final archive = Archive()..add(ArchiveFile('manifest.json', 2, utf8.encode('{}')));
      final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
      // (the real limit is half a gigabyte a file; a forged directory entry says more than that)
      final text = latin1.decode(bytes);
      expect(text, contains('manifest.json'));
      final forgedSize = Uint8List.fromList(bytes);
      final data = ByteData.sublistView(forgedSize);
      // the central directory header says (offset 24 from its signature) how big the file is
      final at = _find(forgedSize, [0x50, 0x4b, 0x01, 0x02]);
      data.setUint32(at + 24, 0x7FFFFFFF, Endian.little);
      expect(() => decodeNoteFile(forgedSize), throwsA(isA<NoteFileException>().having((e) => e.toString(), 'message', contains('too big'))));
    });
  });
}

int _find(Uint8List bytes, List<int> signature) {
  for (var i = 0; i + signature.length <= bytes.length; i++) {
    var same = true;
    for (var j = 0; j < signature.length; j++) {
      if (bytes[i + j] != signature[j]) {
        same = false;
        break;
      }
    }
    if (same) return i;
  }
  throw StateError('no such signature');
}
