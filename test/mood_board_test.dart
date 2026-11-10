import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'support/fake_file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/images/picture_edit.dart';
import 'package:notes/models/collage.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String dir;
  _Paths(this.dir);

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('the layout of a mood board', () {
    test('every row fills the width exactly, the pictures of a row are as tall as each other, and they keep their proportions', () {
      final aspects = [1.5, 0.75, 1.0, 2.0, 1.0, 0.5, 1.2, 1.0];
      final rects = collageRects(aspects, width: 700);
      expect(rects.length, aspects.length);
      final rows = <double, List<int>>{};
      for (var i = 0; i < rects.length; i++) {
        rows.putIfAbsent(rects[i].top, () => []).add(i);
        expect(rects[i].width / rects[i].height, closeTo(aspects[i], 1e-9));
      }
      var filled = 0;
      for (final row in rows.values) {
        expect({for (final i in row) rects[i].height.toStringAsFixed(6)}.length, 1, reason: 'one height in a row');
        final end = row.map((i) => rects[i].right).reduce((a, b) => a > b ? a : b);
        if (row.last != aspects.length - 1) {
          expect(end, closeTo(700, 1e-6), reason: 'a full row reaches the other side');
          filled++;
        }
      }
      expect(filled, greaterThan(0));
      // nothing lies over anything else
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          expect(rects[i].deflate(0.01).overlaps(rects[j]), isFalse, reason: '$i and $j');
        }
      }
    });

    test('a last row that comes short keeps the usual height instead of being stretched, and a single picture is just that', () {
      final rects = collageRects([1.0], width: 700, rowHeight: 170);
      expect(rects.single, const Rect.fromLTWH(0, 0, 170, 170));
      expect(collageRects(const [], width: 700), isEmpty);
      expect(collageRects([0, -1], width: 700).length, 2, reason: 'a nonsense proportion is a square');
    });
  });

  testWidgets('several pictures are put on the page as rows of a mood board', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    late Directory dir;
    final paths = <String>[];
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('moodboard');
      for (final (i, size) in [(0, (40, 30)), (1, (30, 40)), (2, (40, 40)), (3, (60, 30))]) {
        final f = File('${dir.path}/in$i.png')..writeAsBytesSync(encodePicture(RgbaPicture.filled(size.$1, size.$2, 20 * i, 90, 200)));
        paths.add(f.path);
      }
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
    });
    addTearDown(() => dir.delete(recursive: true));
    PathProviderPlatform.instance = _Paths(dir.path);
    FilePickerPlatform.instance = FakeFilePicker(pick: paths);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-collage')));
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pumpAndSettle();
    final note = (await tester.runAsync(() => repo.loadNote(id)))!;
    final pictures = note.images[0]!;
    expect(pictures.length, 4);
    // inside the page, with a margin, none over another
    for (final m in pictures) {
      expect(m.position.dx, greaterThanOrEqualTo(23.9));
      expect(m.position.dx + m.size.width, lessThanOrEqualTo(776.1));
    }
    for (var i = 0; i < pictures.length; i++) {
      for (var j = i + 1; j < pictures.length; j++) {
        expect((pictures[i].position & pictures[i].size).deflate(0.01).overlaps(pictures[j].position & pictures[j].size), isFalse);
      }
    }
    // the proportions are those of the files
    expect(pictures[1].size.width / pictures[1].size.height, closeTo(0.75, 0.01));
    expect(pictures[3].size.width / pictures[3].size.height, closeTo(2.0, 0.01));
  });
}
