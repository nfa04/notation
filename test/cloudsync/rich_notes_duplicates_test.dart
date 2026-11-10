import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/folder_sync.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_keys.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/models/pdf_models.dart';

import '../devicesync/harness.dart';
import 'memory_cloud_folder.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late Device a, b;
  late MemoryCloudFolder cloud;
  late SyncSecret secret;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rich_');
    secret = SyncSecret.create(Random(5));
    cloud = MemoryCloudFolder();
    a = await Device.create('Laptop', root, profileId: 'aaaaaaaaaaaaaaaa');
    b = await Device.create('Tablet', root, profileId: 'aaaaaaaaaaaaaaaa');
    for (final d in [a, b]) {
      for (final other in [a, b]) {
        await d.book.add(PairedDevice(id: other.identity.id, name: other.name, publicKey: other.identity.publicKey, addedAt: 1));
      }
    }
  });
  tearDown(() async {
    for (final d in [a, b]) {
      await d.db.close();
    }
    await root.delete(recursive: true);
  });

  Future<void> run(Device d) async {
    final r = await FolderSync(
      folder: cloud, library: d.library, book: d.book, settings: d.settings, deviceId: d.identity.id, deviceName: d.name, key: secret.cloudKey, encrypted: true,
    ).run();
    expect(r.problems, isEmpty);
  }

  Future<int> copies(Device d) async => (await d.repo.listNotes()).where((n) => n.title.contains('from before the sync')).length;

  Future<String> richNote() async {
    final id = await a.note('Rich', '# Title\n\n![x](image:pic.png)');
    final png = File('${a.dir.path}/p.png')..writeAsBytesSync(List.generate(80, (i) => i));
    Directory('${a.dir.path}/images').createSync();
    File('${a.dir.path}/images/pic.png').writeAsBytesSync(List.generate(50, (i) => i * 2));
    final pdf = File('${a.dir.path}/doc.pdf')..writeAsBytesSync(utf8.encode('%PDF-1.4 fake'));
    final n = (await a.repo.loadNote(id))!;
    n.strokes = {0: [DrawingStroke(color: Colors.black, width: 2, points: [for (var i = 0; i < 6; i++) Offset(i * 4.0, i * 2.0)])]};
    n.images[0] = [
      ImageItem(id: 'i1', path: png.path, position: const Offset(5, 6), size: const Size(70, 80)),
      ImageItem(id: 'i2', path: png.path, position: const Offset(9, 6), size: const Size(70, 80)),
    ];
    n.highlights[0] = [PdfHighlight(rect: const Rect.fromLTRB(1, 2, 30, 40), color: const Color(0x66FFEB3B))];
    n
      ..pdfName = 'doc.pdf'
      ..pdfPath = pdf.path
      ..pdfSha256 = sha256.convert(pdf.readAsBytesSync()).toString()
      ..pdfPageCount = 3;
    await a.repo.saveNote(n);
    return id;
  }

  test('a rich note is the same file after it was taken in', () async {
    final id = await richNote();
    await run(a);
    await run(b);
    final x = (await a.files.exportBytes(id))!, y = (await b.files.exportBytes(id))!;
    expect(sameNoteContent(x, y), isTrue, reason: 'the note differs after the round trip');
  });

  test('opened (saved unchanged) on the tablet, changed on the laptop: not a conflict', () async {
    final id = await richNote();
    await run(a);
    await run(b);
    await Future<void>.delayed(const Duration(milliseconds: 3));
    await b.repo.saveNote((await b.repo.loadNote(id))!); // opened and saved, nothing changed
    await Future<void>.delayed(const Duration(milliseconds: 3));
    await a.edit(id, 'changed on the laptop');
    for (var i = 0; i < 3; i++) {
      await run(b);
      await run(a);
    }
    expect(await copies(a), 0);
    expect(await copies(b), 0);
  });
}
