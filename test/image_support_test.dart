import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'support/fake_file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/image_item_widget.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 40, 20), Paint()..color = Colors.red);
  final image = await recorder.endRecording().toImage(40, 20);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

void main() {
  setUpAll(AppDatabase.initFfi);

  test('pictures are saved with the note', () async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    addTearDown(db.close);
    final repo = NoteRepository(db);
    final id = await repo.createNote();
    final note = (await repo.loadNote(id))!;
    note.images[2] = [
      ImageItem(id: 'a', path: '/x/a.png', position: const Offset(10, 20), size: const Size(100, 50)),
      ImageItem(id: 'b', path: '/x/b.jpg', position: const Offset(1, 2), size: const Size(30, 40)),
    ];
    await repo.saveNote(note);

    final back = (await repo.loadNote(id))!;
    expect(back.images.keys, [2]);
    expect(back.images[2]!.map((m) => m.id), ['a', 'b']); // stacking order kept
    expect(back.images[2]!.first.position, const Offset(10, 20));
    expect(back.images[2]!.first.size, const Size(100, 50));
    expect(back.images[2]!.last.path, '/x/b.jpg');
  });

  testWidgets('a picture ends up in the exported PDF', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('image_export_');
      final imagePath = '${dir.path}/pic.png';
      await File(imagePath).writeAsBytes(await _png());
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote(title: 'With picture');
      final note = (await repo.loadNote(id))!;
      note.images[0] = [ImageItem(id: 'p', path: imagePath, position: const Offset(50, 60), size: const Size(200, 100))];
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));

    final out = '${dir.path}/out.pdf';
    FilePickerPlatform.instance = FakeFilePicker(savePath: out);

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    // select mode: the picture plus the control layer above the page
    expect(find.byType(ImageItemWidget), findsNWidgets(2));

    // the picture can be picked, moved and resized through the real page
    final controls = find.byKey(const ValueKey('image-ctl-p'));
    final before = tester.getTopLeft(controls);
    await tester.drag(controls, const Offset(60, 40));
    await tester.pump();
    final moved = tester.getTopLeft(controls) - before; // the first few pixels are drag slop
    expect(moved.dx, greaterThan(20));
    expect(moved.dy, greaterThan(10));
    final sizeBefore = tester.getSize(controls);
    final grip = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('image-resize'))));
    for (var i = 0; i < 5; i++) {
      await grip.moveBy(const Offset(15, 0)); // several moves: the first ones are drag slop
      await tester.pump();
    }
    await grip.up();
    await tester.pump();
    expect(tester.getSize(controls).width, greaterThan(sizeBefore.width));

    await tester.ensureVisible(find.text('Export PDF')); // the toolbar scrolls sideways
    await tester.tap(find.text('Export PDF'));
    // the export uses timers of the test clock and real file work: alternate
    for (var i = 0; i < 100 && !File(out).existsSync(); i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }

    final pdf = String.fromCharCodes(await tester.runAsync(() => File(out).readAsBytes()) as List<int>);
    expect(pdf, startsWith('%PDF'));
    expect(pdf, contains('/Subtype/Image'));
  });

  testWidgets('a tapped picture can be resized and deleted', (tester) async {
    final item = ImageItem(id: 'p', path: '/nope.png', position: const Offset(60, 100), size: const Size(200, 100));
    var selected = false;
    var deleted = false;
    Offset resized = Offset.zero;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) => Stack(children: [
          ImageItemWidget(
            item: item,
            interactive: true,
            selected: selected,
            onSelect: () => setState(() => selected = true),
            onMoveStart: (_) {},
            onResize: (d) => resized += d,
            onDelete: () => deleted = true,
            onChangeEnd: () {},
          ),
        ]),
      ),
    ));
    expect(find.byKey(const ValueKey('image-delete')), findsNothing);
    await tester.tapAt(const Offset(100, 140));
    await tester.pump();
    await tester.drag(find.byKey(const ValueKey('image-resize')), const Offset(30, 10));
    expect(resized.dx, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('image-delete')));
    expect(deleted, isTrue);
  });

  testWidgets("the folder's banner shows above the pages and scrolls away", (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    late String banner;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('banner_');
      banner = '${dir.path}/banner.png';
      await File(banner).writeAsBytes(await _png());
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      final folder = await repo.createFolder('Trip');
      await repo.setFolderThemeImage(folder, banner);
      id = await repo.createNote(folderId: folder);
    });
    addTearDown(() => dir.delete(recursive: true));

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final image = find.byKey(ValueKey(banner));
    expect(image, findsOneWidget);
    expect(find.byTooltip('Remove theme image'), findsNothing); // the folder's, not the note's
    expect(tester.getSize(image).width, 1200); // all the width there is, not just the page's
    final top = tester.getTopLeft(image).dy;

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    // it went up with the pages, out of sight
    expect(image.evaluate().isEmpty || tester.getTopLeft(image).dy < top - 100, isTrue);
  });
}
