import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/images/picture_edit.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/picture_edit_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// White paper, 24 by 12, with a black square in the middle.
Uint8List paperPng() {
  final p = RgbaPicture.filled(24, 12, 255, 255, 255);
  for (var y = 3; y <= 8; y++) {
    for (var x = 9; x <= 14; x++) {
      p.setPixel(x, y, 0, 0, 0);
    }
  }
  return encodePicture(p);
}

/// Lets real work (files, isolates) go on, and the app see what it did: each step of such work needs a turn of the real event loop
/// and then the fake one.
Future<void> work(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// Where the app keeps its files, in a folder of the test.
class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String dir;
  _Paths(this.dir);

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('the panel', () {
    PictureEditResult? result;
    var answered = false;

    // (the picture is made into an image by the engine, which takes a moment of real time)
    Future<void> shown(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 200)); // (the wait before an edit is shown)
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();
    }

    Future<void> open(WidgetTester tester, Uint8List bytes) async {
      result = null;
      answered = false;
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<PictureEditResult>(context: context, builder: (_) => PictureEditDialog(source: bytes, decoder: (b) async => decodePicture(b, maxSide: pictureEditPreviewSide), renderer: (s, e, m) async => applyPictureEdit(s, e, subject: m)));
              answered = true;
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 300)); // (not pumpAndSettle: the spinner turns until the picture is there)
      await shown(tester);
      await tester.pump();
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump();
      await shown(tester);
    }

    bool applyEnabled(WidgetTester tester) => tester.widget<FilledButton>(find.byKey(const ValueKey('pe-apply'))).onPressed != null;

    testWidgets('nothing is changed at first, so there is nothing to apply; a turn is something', (tester) async {
      await open(tester, paperPng());
      expect(find.byType(RawImage), findsOneWidget, reason: 'the picture is shown');
      expect(applyEnabled(tester), isFalse);
      await tapKey(tester, 'pe-rotate-right');
      expect(applyEnabled(tester), isTrue);
      await tapKey(tester, 'pe-rotate-right');
      await tapKey(tester, 'pe-flip-h');
      await tester.tap(find.byKey(const ValueKey('pe-apply')));
      await tester.pumpAndSettle();
      expect(answered, isTrue);
      expect(result!.edit.turns, 2);
      expect(result!.edit.flipHorizontal, isTrue);
    });

    testWidgets('left, right and reset', (tester) async {
      await open(tester, paperPng());
      await tapKey(tester, 'pe-rotate-left');
      expect(find.byKey(const ValueKey('pe-reset')), findsOneWidget);
      await tapKey(tester, 'pe-reset');
      expect(applyEnabled(tester), isFalse);
      await tapKey(tester, 'pe-rotate-left');
      await tester.tap(find.byKey(const ValueKey('pe-apply')));
      await tester.pumpAndSettle();
      expect(result!.edit.turns, 3, reason: 'one turn to the left is three to the right');
    });

    testWidgets('sliders and filters change the edit that is answered', (tester) async {
      await open(tester, paperPng());
      await tester.ensureVisible(find.byKey(const ValueKey('pe-brightness')));
      await tester.pumpAndSettle();
      await tester.drag(find.byKey(const ValueKey('pe-brightness')), const Offset(120, 0));
      await tester.pump();
      await shown(tester);
      await tapKey(tester, 'pe-filter-sepia');
      await tester.drag(find.byKey(const ValueKey('pe-crop-left')), const Offset(60, 0));
      await tester.pump();
      await shown(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('pe-apply')));
      await tester.tap(find.byKey(const ValueKey('pe-apply')));
      await tester.pumpAndSettle();
      expect(result!.edit.brightness, greaterThan(0));
      expect(result!.edit.filter, PictureFilter.sepia);
      expect(result!.edit.cropLeft, greaterThan(0));
      expect(result!.edit.contrast, 0);
    });

    testWidgets('the background: the options appear, the colour is picked by tapping the picture, and "edges" goes back to the automatic colour', (tester) async {
      await open(tester, paperPng());
      expect(find.byKey(const ValueKey('pe-tolerance')), findsNothing);
      await tapKey(tester, 'pe-bg-fromEdges');
      expect(find.byKey(const ValueKey('pe-tolerance')), findsOneWidget);
      expect(find.byKey(const ValueKey('pe-softness')), findsOneWidget);
      expect(find.byKey(const ValueKey('pe-colour-auto')), findsNothing);
      // a tap in the middle of the picture is on the black square
      await tester.ensureVisible(find.byKey(const ValueKey('pe-preview'))); // (the panel scrolled down to the options)
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('pe-preview'))));
      await tester.pump();
      await shown(tester);
      expect(find.byKey(const ValueKey('pe-colour-auto')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('pe-apply')));
      await tester.tap(find.byKey(const ValueKey('pe-apply')));
      await tester.pumpAndSettle();
      expect(result!.edit.background, BackgroundRemoval.fromEdges);
      expect(result!.edit.backgroundColor, 0xFF000000);
    });

    testWidgets('on the width of a phone it fits, and everything can still be reached', (tester) async {
      await open(tester, paperPng());
      tester.view.physicalSize = const Size(360, 700);
      await tester.pump(const Duration(milliseconds: 300));
      await shown(tester);
      expect(tester.takeException(), isNull, reason: 'nothing overflows');
      await tapKey(tester, 'pe-bg-everywhere');
      await tapKey(tester, 'pe-rotate-right');
      await tester.ensureVisible(find.byKey(const ValueKey('pe-apply')));
      await tester.tap(find.byKey(const ValueKey('pe-apply')));
      await tester.pumpAndSettle();
      expect(result!.edit.background, BackgroundRemoval.everywhere);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cancel answers nothing, and a file that is not a picture says so and cannot be applied', (tester) async {
      await open(tester, paperPng());
      await tapKey(tester, 'pe-rotate-right');
      await tester.ensureVisible(find.byKey(const ValueKey('pe-cancel')));
      await tester.tap(find.byKey(const ValueKey('pe-cancel')));
      await tester.pumpAndSettle();
      expect(answered, isTrue);
      expect(result, isNull);

      await open(tester, Uint8List.fromList([1, 2, 3]));
      expect(find.text('This picture cannot be opened.'), findsOneWidget);
      expect(applyEnabled(tester), isFalse);
    });
  });

  group('on a page', () {
    testWidgets('a picture is edited from its toolbar, its file is a new one with the result, and one step takes it back', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late NoteRepository repo;
      late String id;
      late Directory dir;
      late ImageItem original;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('picedit');
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote();
        final file = File('${dir.path}/paper.png')..writeAsBytesSync(paperPng());
        original = ImageItem(id: 'pic1', path: file.path, position: const Offset(100, 100), size: const Size(240, 120));
        final note = (await repo.loadNote(id))!;
        note.images[0] = [original];
        await repo.saveNote(note);
      });
      PathProviderPlatform.instance = _Paths(dir.path);
      addTearDown(() => dir.delete(recursive: true));
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('image-ctl-pic1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('image-edit')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('image-edit')));
      await work(tester); // (the file is read, then the preview is made in an isolate)
      expect(find.byKey(const ValueKey('pe-apply')), findsOneWidget);
      expect(find.byKey(const ValueKey('picture-edit-panel')), findsOneWidget, reason: 'beside the page, which stays in view');

      // turned a quarter and cut by half of the width: a 240 by 120 picture becomes 120 wide... see below
      await tester.tap(find.byKey(const ValueKey('pe-rotate-right')));
      await work(tester);
      await tester.tap(find.byKey(const ValueKey('pe-apply')));
      await work(tester); // (the picture is made in an isolate and its file written)
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('picture-edit-panel')), findsNothing, reason: 'put away when it is applied');
      await tester.pump(const Duration(seconds: 1));
      await work(tester); // (the note is saved)
      await tester.pumpAndSettle();

      final saved = (await tester.runAsync(() => repo.loadNote(id)))!;
      final now = saved.images[0]!.single;
      expect(now.id, isNot('pic1'), reason: 'a new picture, so that the others in a live session get its file');
      expect(now.path, isNot(original.path));
      expect(File(now.path).existsSync(), isTrue);
      expect(File(original.path).existsSync(), isTrue, reason: 'the old file is kept for taking it back');
      expect(now.position, original.position);
      // turned by a quarter, the 240 by 120 picture (24 by 12 pixels) is 120 by 240 on the page
      expect(now.size.width, closeTo(120, 0.5));
      expect(now.size.height, closeTo(240, 0.5));
      final fileSize = decodePicture(File(now.path).readAsBytesSync())!;
      expect((fileSize.width, fileSize.height), (12, 24), reason: 'turned');

      await tester.tap(find.byKey(const ValueKey('undo-any')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pumpAndSettle();
      final undone = (await tester.runAsync(() => repo.loadNote(id)))!;
      expect(undone.images[0]!.single.id, 'pic1');
      expect(undone.images[0]!.single.size, const Size(240, 120));
    });
  });
}
