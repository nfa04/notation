import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/image_item_widget.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String dir;
  _Paths(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 40, 20), Paint()..color = Colors.red);
  final image = await recorder.endRecording().toImage(40, 20);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late String id;
  late Directory dir;
  ClipboardContent clipboard = (image: null, files: const [], text: null);

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('paste_');
      PathProviderPlatform.instance = _Paths(dir.path);
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
    });
    addTearDown(() => dir.delete(recursive: true));
    clipboard = (image: null, files: const [], text: null);
    await tester.pumpWidget(MaterialApp(
      home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, readClipboard: () async => clipboard),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  /// The pictures on the page (each has a second widget for its handles).
  int pictures() => find.byWidgetPredicate((w) => w is ImageItemWidget && (w.key.toString().contains('image-pic'))).evaluate().length;

  Future<void> paste(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('pasted text becomes a text box, in select mode and in draw mode', (tester) async {
    await open(tester);
    clipboard = (image: null, files: const [], text: '  Copied from a web page\nsecond line  ');
    await paste(tester);
    expect(find.byKey(const ValueKey('delete-text-box')), findsOneWidget); // a box, selected
    expect(find.text('Copied from a web page\nsecond line'), findsOneWidget);

    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getTopLeft(find.byKey(const ValueKey('page-0'))) + const Offset(600, 700)); // off the box
    await tester.pump(const Duration(milliseconds: 400)); // past the double-tap timer: the tap is a tap
    await tester.pumpAndSettle();
    clipboard = (image: null, files: const [], text: 'Pasted while drawing');
    await paste(tester);
    expect(find.text('Pasted while drawing'), findsOneWidget);
    expect(find.textContaining('Copied from a web page'), findsOneWidget); // the first box is still there

    await tester.tapAt(tester.getTopLeft(find.byKey(const ValueKey('page-0'))) + const Offset(600, 800));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    clipboard = (image: null, files: const [], text: '   ');
    await paste(tester);
    expect(find.byKey(const ValueKey('delete-text-box')), findsNothing); // nothing to paste: no new box
  });

  testWidgets('a pasted picture becomes a picture on the page, kept with the note', (tester) async {
    await open(tester);
    final bytes = (await tester.runAsync(_png))!;
    clipboard = (image: bytes, files: const [], text: 'text that comes along with the picture');
    await paste(tester);
    expect(pictures(), 1);
    expect(find.text('text that comes along with the picture'), findsNothing); // the picture wins
    await tester.pump(const Duration(seconds: 1)); // the autosave
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    final saved = (await tester.runAsync(() => repo.loadNote(id)))!;
    expect(saved.images.values.expand((l) => l).length, 1);
    final stored = saved.images.values.expand((l) => l).single;
    expect(File(stored.path).existsSync(), isTrue);
    expect(stored.path.startsWith(dir.path), isTrue); // a copy in the app's storage
  });

  testWidgets('a picture file copied in a file manager is pasted as a picture', (tester) async {
    await open(tester);
    final file = File('${dir.path}/copied.png');
    await tester.runAsync(() async => file.writeAsBytes(await _png()));
    clipboard = (image: null, files: ['/does/not/exist.png', '${dir.path}/notes.txt', file.path], text: null);
    await paste(tester);
    expect(pictures(), 1);
  });

  testWidgets('while a text is being edited, paste is left to that text', (tester) async {
    await open(tester);
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    clipboard = (image: null, files: const [], text: 'first');
    await paste(tester); // makes a box and focuses it
    expect(find.text('first'), findsOneWidget);
    await tester.tapAt(origin + const Offset(60, 70)); // into the box
    await tester.pumpAndSettle();
    clipboard = (image: null, files: const [], text: 'second');
    await paste(tester);
    // no second box: the field's own paste handles it (the test clipboard is not the system's)
    expect(find.byKey(const ValueKey('delete-text-box')), findsOneWidget);
    expect(find.text('second'), findsNothing);
  });

  testWidgets('a screenshot pasted while a text is being edited still goes onto the page', (tester) async {
    await open(tester);
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    clipboard = (image: null, files: const [], text: 'a box');
    await paste(tester); // a box, in editing
    expect(find.text('a box'), findsOneWidget);
    expect(pictures(), 0);

    final bytes = (await tester.runAsync(_png))!;
    clipboard = (image: bytes, files: const [], text: null); // a screenshot: a picture and no text
    await paste(tester);
    expect(pictures(), 1);
    expect(find.text('a box'), findsOneWidget); // the text is untouched

    // a picture together with text (copied from a web page): the text field takes the text, no picture
    await tester.tapAt(origin + const Offset(60, 70)); // into the box again
    await tester.pumpAndSettle();
    clipboard = (image: bytes, files: const [], text: 'text and picture');
    await paste(tester);
    expect(pictures(), 1);
  });

  testWidgets('a screenshot pasted into the written document is placed on the page', (tester) async {
    await open(tester);
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('page-0')), findsOneWidget);
    final bytes = (await tester.runAsync(_png))!;
    clipboard = (image: bytes, files: const [], text: null);
    await paste(tester);
    expect(pictures(), 1);
    // and it can be moved: the editor left the document for the mode that does that
    expect(find.text('Document'), findsOneWidget);
  });

  testWidgets('a clipboard that cannot be read is said so, not ignored', (tester) async {
    // (these tests have no clipboard plugin, which is what an app started before the plugin was added has)
    final problems = <String>[];
    final content = await tester.runAsync(() => readSystemClipboard(onProblem: problems.add));
    expect(content!.image, isNull);
    expect(problems, isNotEmpty);
    expect(problems.first, contains('stop it and start it again'));
  });
}
