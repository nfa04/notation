import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/block_editor.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/markdown/document_images.dart';
import 'package:notes/markdown/live_markdown.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// What the system adds to a keyboard: the floating cursor of iOS, the pen of an iPad and of Android, and pictures a keyboard puts in.
final _ios = TargetPlatformVariant.only(TargetPlatform.iOS);
final _android = TargetPlatformVariant.only(TargetPlatform.android);

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String dir;
  _Paths(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// A red pixel.
final Uint8List _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

/// A picture of a kind the exports do not know (a bitmap stands in for WebP, which a test cannot make): one pixel.
Uint8List _bitmap() {
  final b = ByteData(58);
  b.setUint8(0, 0x42);
  b.setUint8(1, 0x4D);
  b.setUint32(2, 58, Endian.little);
  b.setUint32(10, 54, Endian.little);
  b.setUint32(14, 40, Endian.little);
  b.setInt32(18, 1, Endian.little);
  b.setInt32(22, 1, Endian.little);
  b.setUint16(26, 1, Endian.little);
  b.setUint16(28, 24, Endian.little);
  b.setUint32(34, 4, Endian.little);
  b.setUint8(56, 0xFF);
  return b.buffer.asUint8List();
}

LiveMarkdownController _doc(String text, [int at = 0]) => LiveMarkdownController()..value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: at));

Future<BlockEditorState> _open(WidgetTester tester, LiveMarkdownController c, FocusNode focus, {Future<void> Function(KeyboardInsertedContent)? onContent}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: CustomScrollView(slivers: [
        SliverToBoxAdapter(child: BlockEditor(controller: c, focusNode: focus, style: documentTextStyle(16), width: 700, onContent: onContent)),
      ]),
    ),
  ));
  await tester.pump();
  await tester.pump();
  return tester.state<BlockEditorState>(find.byType(BlockEditor));
}

/// What the keyboard says to the app: [method] with [rest] after the number of the connection.
Future<void> _keyboardSays(WidgetTester tester, String method, List<Object?> rest) async {
  final id = tester.testTextInput.log.lastWhere((c) => c.method == 'TextInput.setClient').arguments[0];
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(MethodCall(method, [id, ...rest])),
    (_) {},
  );
  await tester.pump();
}

Offset _at(BlockEditorState state, int offset) => state.screenRectOf(TextRange(start: offset, end: offset + 1))!.center;

void main() {
  setUpAll(AppDatabase.initFfi);

  late FocusNode focus;
  setUp(() => focus = FocusNode());
  tearDown(() => focus.dispose());

  group('the floating cursor of iOS', () {
    const text = 'first line of it\nsecond line of it\nthird line of it';

    Future<BlockEditorState> opened(WidgetTester tester, LiveMarkdownController c) async {
      final state = await _open(tester, c, focus);
      focus.requestFocus();
      await tester.pump();
      return state;
    }

    Future<void> floatTo(WidgetTester tester, Offset by) async {
      // (the framework drops the place of the start, and counts what the update says from nothing: the keyboard says how far)
      await _keyboardSays(tester, 'TextInputClient.updateFloatingCursor', ['FloatingCursorDragState.start', {'X': 100.0, 'Y': 100.0}]);
      await _keyboardSays(tester, 'TextInputClient.updateFloatingCursor', ['FloatingCursorDragState.update', {'X': by.dx, 'Y': by.dy}]);
    }

    testWidgets('the caret stays until the finger lets go, then goes to the place the cursor was moved to', (tester) async {
      final c = _doc(text, 3);
      final state = await opened(tester, c);
      final line = state.screenCaret!.height;

      await floatTo(tester, Offset(0, 2 * line));
      expect(c.selection, const TextSelection.collapsed(offset: 3), reason: 'the cursor floats; nothing is selected yet');

      await _keyboardSays(tester, 'TextInputClient.updateFloatingCursor', ['FloatingCursorDragState.end', {'X': 0.0, 'Y': 0.0}]);
      // two lines further down, the same distance from the left
      expect(c.selection.isCollapsed, isTrue);
      expect(c.selection.baseOffset, greaterThanOrEqualTo(text.indexOf('third')));
      expect(c.selection.baseOffset, lessThan(text.indexOf('third') + 8));
    }, variant: _ios);

    testWidgets('moved to the right it goes along the line, and back it goes before where it began', (tester) async {
      final c = _doc(text, 8);
      final state = await opened(tester, c);
      final start = state.screenCaret!;
      await floatTo(tester, const Offset(60, 0));
      await _keyboardSays(tester, 'TextInputClient.updateFloatingCursor', ['FloatingCursorDragState.end', {'X': 0.0, 'Y': 0.0}]);
      expect(c.selection.baseOffset, greaterThan(8));
      expect(c.selection.baseOffset, lessThan(text.indexOf('\n')));
      expect(state.screenCaret!.left, greaterThan(start.left + 30));

      await floatTo(tester, const Offset(-400, 0));
      await _keyboardSays(tester, 'TextInputClient.updateFloatingCursor', ['FloatingCursorDragState.end', {'X': 0.0, 'Y': 0.0}]);
      expect(c.selection, const TextSelection.collapsed(offset: 0), reason: 'past the left edge it stops at the start of the line');
    }, variant: _ios);

    testWidgets('a selection the keyboard made with two fingers is kept when the fingers let go', (tester) async {
      final c = _doc(text, 3);
      await opened(tester, c);
      await _keyboardSays(tester, 'TextInputClient.updateFloatingCursor', ['FloatingCursorDragState.start', {'X': 100.0, 'Y': 100.0}]);
      c.selection = const TextSelection(baseOffset: 3, extentOffset: 11);
      await tester.pump();
      await _keyboardSays(tester, 'TextInputClient.updateFloatingCursor', ['FloatingCursorDragState.end', {'X': 0.0, 'Y': 0.0}]);
      expect(c.selection, const TextSelection(baseOffset: 3, extentOffset: 11));
    }, variant: _ios);

    testWidgets('a document that is only read is not touched', (tester) async {
      final c = _doc(text, 3)..readingView = true;
      await _open(tester, c, focus);
      final state = tester.state<BlockEditorState>(find.byType(BlockEditor));
      state.updateFloatingCursor(RawFloatingCursorPoint(state: FloatingCursorDragState.Start, offset: const Offset(100, 100)));
      state.updateFloatingCursor(RawFloatingCursorPoint(state: FloatingCursorDragState.Update, offset: const Offset(100, 300)));
      state.updateFloatingCursor(RawFloatingCursorPoint(state: FloatingCursorDragState.End));
      expect(c.selection, const TextSelection.collapsed(offset: 3));
    }, variant: _ios);
  });

  group('handwriting on iPadOS', () {
    testWidgets('the editor is a place a pen may write, while the document is written', (tester) async {
      final c = _doc('one two\nthree four', 0);
      final state = await _open(tester, c, focus);
      expect(TextInput.scribbleClients, hasLength(1));
      final client = TextInput.scribbleClients.values.single;
      final inside = Rect.fromCenter(center: _at(state, 2), width: 30, height: 10);
      expect(client.bounds, isNot(Rect.zero));
      expect(client.isInScribbleRect(inside), isTrue);
      expect(client.isInScribbleRect(const Rect.fromLTWH(-500, -500, 10, 10)), isFalse, reason: 'away from the text');

      c.readingView = true;
      await tester.pump();
      expect(client.isInScribbleRect(inside), isFalse, reason: 'not while it is only read');
    }, variant: _ios);

    testWidgets('where the pen begins to write, the document takes the focus and the caret', (tester) async {
      final c = _doc('one two\nthree four', 0);
      final state = await _open(tester, c, focus);
      expect(focus.hasFocus, isFalse);
      TextInput.scribbleClients.values.single.onScribbleFocus(_at(state, 11));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(c.selection.baseOffset, anyOf(11, 12));
    }, variant: _ios);

    testWidgets('the system is told where every letter is that the keyboard knows of, and the editor is let go when it is gone', (tester) async {
      final c = _doc('ab cd\nef', 0);
      final state = await _open(tester, c, focus);
      focus.requestFocus();
      await tester.pump(const Duration(milliseconds: 400));
      final sent = tester.testTextInput.log.where((m) => m.method == 'TextInput.setSelectionRects');
      expect(sent, isNotEmpty);
      final rects = (sent.last.arguments as List).cast<List<dynamic>>();
      // (a letter is [left, top, width, height, place in the text, direction])
      expect(rects, hasLength(7), reason: 'seven letters, the line break is none');
      expect([for (final r in rects) (r[4] as num).toInt()], [0, 1, 2, 3, 4, 6, 7]);
      expect(rects[1][0], greaterThan(rects[0][0] as num));
      expect(rects[5][1], greaterThan(rects[0][1] as num), reason: 'the second line is lower');
      final first = state.screenRectOf(const TextRange(start: 0, end: 1))!;
      expect((rects[0][0] as num).toDouble(), closeTo(0, 1), reason: 'in the box of the text, not on the screen');
      expect((rects[0][2] as num).toDouble(), closeTo(first.width, 1));

      await tester.pumpWidget(const SizedBox());
      expect(TextInput.scribbleClients, isEmpty);
    }, variant: _ios);

    testWidgets('typing tells the system the new letters, once the typing rests', (tester) async {
      final c = _doc('ab', 2);
      await _open(tester, c, focus);
      focus.requestFocus();
      await tester.pump(const Duration(milliseconds: 400));
      int count() => (tester.testTextInput.log.where((m) => m.method == 'TextInput.setSelectionRects').last.arguments as List).length;
      expect(count(), 2);
      c.value = const TextEditingValue(text: 'abcd', selection: TextSelection.collapsed(offset: 4));
      await tester.pump(const Duration(milliseconds: 400));
      expect(count(), 4);
    }, variant: _ios);

    testWidgets('on other systems nothing is sent', (tester) async {
      final c = _doc('ab cd', 0);
      await _open(tester, c, focus);
      focus.requestFocus();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.testTextInput.log.where((m) => m.method == 'TextInput.setSelectionRects'), isEmpty);
    }, variant: _android);
  });

  group('handwriting on Android', () {
    late List<String> asked;

    setUp(() => asked = []);

    void keyboardWithHandwriting(WidgetTester tester, {bool available = true}) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.scribe, (call) async {
        asked.add(call.method);
        return call.method == 'Scribe.isFeatureAvailable' ? available : null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.scribe, null));
    }

    testWidgets('a pen on the text puts the caret there and asks the keyboard to take the handwriting', (tester) async {
      keyboardWithHandwriting(tester);
      final c = _doc('one two\nthree four', 0);
      final state = await _open(tester, c, focus);
      final pen = await tester.startGesture(_at(state, 11), kind: PointerDeviceKind.stylus);
      await tester.pump();
      await tester.pump();
      await pen.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(asked, ['Scribe.isFeatureAvailable', 'Scribe.startStylusHandwriting']);
      expect(focus.hasFocus, isTrue);
      expect(c.selection.baseOffset, anyOf(11, 12));
    }, variant: _android);

    testWidgets('a finger does not start it, nor a keyboard that cannot', (tester) async {
      keyboardWithHandwriting(tester);
      final c = _doc('one two\nthree four', 0);
      final state = await _open(tester, c, focus);
      final finger = await tester.startGesture(_at(state, 11), kind: PointerDeviceKind.touch);
      await tester.pump();
      await finger.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(asked, isEmpty);

      keyboardWithHandwriting(tester, available: false);
      final pen = await tester.startGesture(_at(state, 3), kind: PointerDeviceKind.stylus);
      await tester.pump();
      await tester.pump();
      await pen.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(asked, ['Scribe.isFeatureAvailable']);
    }, variant: _android);

    testWidgets('a document that is only read takes no handwriting', (tester) async {
      keyboardWithHandwriting(tester);
      final c = _doc('one two', 0)..readingView = true;
      final state = await _open(tester, c, focus);
      final pen = await tester.startGesture(_at(state, 3), kind: PointerDeviceKind.stylus);
      await tester.pump();
      await pen.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(asked, isEmpty);
    }, variant: _android);
  });

  group('gestures of a pen on the text', () {
    const text = 'one two three four';

    /// Draws [path] with a pen (or [kind]) and lets the editor see it end.
    Future<void> draw(WidgetTester tester, List<Offset> path, {PointerDeviceKind kind = PointerDeviceKind.stylus}) async {
      final pen = await tester.startGesture(path.first, kind: kind);
      for (final p in path.skip(1)) {
        await pen.moveTo(p);
      }
      await pen.up();
      await tester.pump(const Duration(milliseconds: 400));
    }

    List<Offset> sweep(Rect over, {int passes = 5}) {
      final out = <Offset>[];
      for (var i = 0; i < passes; i++) {
        final from = i.isEven ? over.left : over.right, to = i.isEven ? over.right : over.left;
        for (var k = 0; k < 6; k++) {
          out.add(Offset.lerp(Offset(from, over.center.dy + (i.isEven ? -3 : 3)), Offset(to, over.center.dy + (i.isEven ? 3 : -3)), k / 6)!);
        }
      }
      return out;
    }

    List<Offset> loop(Rect around) => [
          for (var i = 0; i <= 40; i++)
            around.center + Offset(math.cos(2 * math.pi * 1.05 * i / 40) * (around.width / 2 + 6), math.sin(2 * math.pi * 1.05 * i / 40) * (around.height / 2 + 4)),
        ];

    Rect rangeOf(BlockEditorState state, String word) {
      final at = text.indexOf(word);
      return state.screenRectOf(TextRange(start: at, end: at + word.length))!;
    }

    testWidgets('a zigzag over a word deletes it, and a space with it', (tester) async {
      final c = _doc(text, 0);
      final state = await _open(tester, c, focus);
      await draw(tester, sweep(rangeOf(state, 'two').inflate(2)));
      expect(c.text, 'one three four');
      expect(c.selection, const TextSelection.collapsed(offset: 4));
    });

    testWidgets('over the last word it takes the space before it; over a part of a word it takes the whole word', (tester) async {
      final c = _doc(text, 0);
      final state = await _open(tester, c, focus);
      await draw(tester, sweep(rangeOf(state, 'four').inflate(2)));
      expect(c.text, 'one two three');

      final part = state.screenRectOf(const TextRange(start: 5, end: 6))!; // the "w" of "two"
      await draw(tester, sweep(part.inflate(8)));
      expect(c.text, 'one three');
    });

    testWidgets('a zigzag where there is no text does nothing', (tester) async {
      final c = _doc(text, 0);
      final state = await _open(tester, c, focus);
      final far = rangeOf(state, 'two').shift(const Offset(0, 120));
      await draw(tester, sweep(far.inflate(2)));
      expect(c.text, text);
    });

    testWidgets('a finger, or a mouse, does not make the gestures', (tester) async {
      final c = _doc(text, 0);
      final state = await _open(tester, c, focus);
      await draw(tester, sweep(rangeOf(state, 'two').inflate(2)), kind: PointerDeviceKind.touch);
      expect(c.text, text);
      await draw(tester, sweep(rangeOf(state, 'two').inflate(2)), kind: PointerDeviceKind.mouse);
      expect(c.text, text);
    });

    testWidgets('a loop round words selects them', (tester) async {
      final c = _doc(text, 0);
      final state = await _open(tester, c, focus);
      final both = rangeOf(state, 'two').expandToInclude(rangeOf(state, 'three'));
      await draw(tester, loop(both));
      expect(c.text, text);
      expect(c.selection, TextSelection(baseOffset: text.indexOf('two'), extentOffset: text.indexOf('three') + 5));
    });

    testWidgets('a stroke down inside a word splits it', (tester) async {
      final c = _doc(text, 0);
      final state = await _open(tester, c, focus);
      final h = state.screenRectOf(const TextRange(start: 9, end: 10))!; // "h" of "three": between "t" and "h" is 8
      final x = h.left;
      await draw(tester, [for (var i = 0; i <= 8; i++) Offset(x, h.center.dy - 12 + i * 3)]);
      expect(c.text, 'one two t hree four');
      expect(c.selection, const TextSelection.collapsed(offset: 10));
    });

    testWidgets('a stroke down on a space joins the words', (tester) async {
      final c = _doc(text, 0);
      final state = await _open(tester, c, focus);
      final space = state.screenRectOf(const TextRange(start: 3, end: 4))!;
      await draw(tester, [for (var i = 0; i <= 8; i++) Offset(space.center.dx, space.center.dy - 12 + i * 3)]);
      expect(c.text, 'onetwo three four');
    });

    testWidgets('a stroke down away from the text does nothing', (tester) async {
      final c = _doc(text, 0);
      final state = await _open(tester, c, focus);
      final far = rangeOf(state, 'two').center + const Offset(0, 150);
      await draw(tester, [for (var i = 0; i <= 8; i++) Offset(far.dx, far.dy - 12 + i * 3)]);
      expect(c.text, text);
    });

    testWidgets('a pen dragged along the text still selects it', (tester) async {
      final c = _doc(text, 0);
      final state = await _open(tester, c, focus);
      final two = rangeOf(state, 'two');
      await draw(tester, [for (var i = 0; i <= 10; i++) Offset(two.left + two.width * i / 10, two.center.dy)]);
      expect(c.text, text);
      expect(c.selection.isCollapsed, isFalse);
    });

    testWidgets('a document that is only read is not changed', (tester) async {
      final c = _doc(text, 0)..readingView = true;
      final state = await _open(tester, c, focus);
      await draw(tester, sweep(rangeOf(state, 'two').inflate(2)));
      expect(c.text, text);
    });

    testWidgets('a deleted word comes back with undo', (tester) async {
      final c = _doc(text, 0);
      final state = await _open(tester, c, focus);
      await tester.pump(const Duration(milliseconds: 600)); // (the history has the text as it was)
      await draw(tester, sweep(rangeOf(state, 'two').inflate(2)));
      expect(c.text, 'one three four');
      await tester.pump(const Duration(milliseconds: 600)); // (the history keeps a change once it rests)
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(c.text, text);
    });
  });

  group('pictures from the keyboard', () {
    Map<String, dynamic> content(String type, List<int>? data) => {'mimeType': type, 'uri': 'content://keyboard/1', 'data': ?data};

    testWidgets('the keyboard is told which pictures are welcome, only when something takes them', (tester) async {
      await _open(tester, _doc('abc'), focus, onContent: (_) async {});
      focus.requestFocus();
      await tester.pump();
      final config = tester.testTextInput.log.lastWhere((m) => m.method == 'TextInput.setClient').arguments[1] as Map;
      expect(config['contentCommitMimeTypes'], ['image/png', 'image/jpeg', 'image/gif', 'image/webp']);

      await tester.pumpWidget(const SizedBox());
      final other = FocusNode();
      addTearDown(other.dispose);
      await _open(tester, _doc('abc'), other);
      other.requestFocus();
      await tester.pump();
      expect((tester.testTextInput.log.lastWhere((m) => m.method == 'TextInput.setClient').arguments[1] as Map)['contentCommitMimeTypes'], isEmpty);
    }, variant: _android);

    testWidgets('a sticker the keyboard commits reaches whoever takes pictures, with its bytes', (tester) async {
      final got = <KeyboardInsertedContent>[];
      await _open(tester, _doc('abc'), focus, onContent: (x) async => got.add(x));
      focus.requestFocus();
      await tester.pump();
      await _keyboardSays(tester, 'TextInputClient.performAction', ['TextInputAction.commitContent', content('image/gif', [1, 2, 3])]);
      expect(got, hasLength(1));
      expect(got.single.mimeType, 'image/gif');
      expect(got.single.data, [1, 2, 3]);
    }, variant: _android);

    testWidgets('a document that is only read takes none', (tester) async {
      final got = <KeyboardInsertedContent>[];
      final c = _doc('abc');
      await _open(tester, c, focus, onContent: (x) async => got.add(x));
      focus.requestFocus();
      await tester.pump();
      c.readingView = true;
      await tester.pump();
      await _keyboardSays(tester, 'TextInputClient.performAction', ['TextInputAction.commitContent', content('image/png', [1])]);
      expect(got, isEmpty);
    }, variant: _android);

    testWidgets('PNG, JPEG and GIF are kept as they come, any other kind as a PNG', (tester) async {
      await tester.runAsync(() async {
        expect((await DocumentImages.forKeeping(_png)).ext, 'png');
        expect((await DocumentImages.forKeeping(_png)).bytes, _png);
        expect((await DocumentImages.forKeeping(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]))).ext, 'jpeg');
        expect((await DocumentImages.forKeeping(Uint8List.fromList('GIF89a....'.codeUnits))).ext, 'gif');
        final other = await DocumentImages.forKeeping(_bitmap());
        expect(other.ext, 'png');
        expect(other.bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
        await expectLater(DocumentImages.forKeeping(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9])), throwsA(anything));
      });
    });

    testWidgets('in a note, a sticker becomes a picture of the document at the caret, kept with the note', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late NoteRepository repo;
      late String id;
      late Directory dir;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('keyboard_picture_');
        PathProviderPlatform.instance = _Paths(dir.path);
        DocumentImages.dir = null;
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        repo = NoteRepository(db);
        id = await repo.createNote();
        final note = (await repo.loadNote(id))!;
        note.documentText = 'Before after';
        await repo.saveNote(note);
      });
      addTearDown(() => dir.delete(recursive: true));
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Document'));
      await tester.pumpAndSettle();
      final controller = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
      controller.selection = const TextSelection.collapsed(offset: 7);
      tester.widget<BlockEditor>(find.byType(BlockEditor)).focusNode.requestFocus();
      await tester.pump();

      await _keyboardSays(tester, 'TextInputClient.performAction', ['TextInputAction.commitContent', content('image/png', _png)]);
      for (var i = 0; i < 20 && !controller.text.contains('image:'); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(controller.text, matches(RegExp(r'^Before ?!\[Picture\]\(image:[^)]+\.png\) ?after$')));
      final target = RegExp(r'image:[^)]+').firstMatch(controller.text)!.group(0)!;
      await tester.runAsync(() async => expect(await DocumentImages.read(target), _png));

      // not a picture: the user is told, and the text is as it was
      final before = controller.text;
      await _keyboardSays(tester, 'TextInputClient.performAction', ['TextInputAction.commitContent', content('image/png', null)]);
      await tester.pump();
      await tester.pump();
      expect(controller.text, before);
      expect(find.textContaining('the keyboard sent no picture'), findsOneWidget);
    }, variant: _android);
  });
}
