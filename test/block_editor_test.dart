import 'dart:io';
import 'dart:ui' show CheckedState;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/block_editor.dart';
import 'package:notes/block_editor/block_column.dart';
import 'package:notes/markdown/live_markdown.dart';
import 'package:notes/models/rich_text.dart';
import 'package:notes/screens/document_sheet.dart';

/// The editor in a scroll view, as it is in a note.
class Host extends StatelessWidget {
  final LiveMarkdownController controller;
  final FocusNode focus;
  final ScrollController? scroll;
  const Host(this.controller, this.focus, {super.key, this.scroll});

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: CustomScrollView(controller: scroll, slivers: [
            SliverToBoxAdapter(
              child: BlockEditor(controller: controller, focusNode: focus, style: documentTextStyle(16), width: 700, autofocus: true),
            ),
          ]),
        ),
      );
}

Future<void> typeText(WidgetTester tester, String text) async {
  // what the keyboard does: says what is before the caret changes
  for (final ch in text.split('')) {
    final v = tester.state<BlockEditorState>(find.byType(BlockEditor)).currentTextEditingValue!;
    final at = v.selection.start, end = v.selection.end, old = v.text;
    final delta = {
      'oldText': old,
      'deltaText': ch,
      'deltaStart': at,
      'deltaEnd': end,
      'selectionBase': at + 1,
      'selectionExtent': at + 1,
      'selectionAffinity': 'TextAffinity.downstream',
      'selectionIsDirectional': false,
      'composingBase': -1,
      'composingExtent': -1,
    };
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(MethodCall('TextInputClient.updateEditingStateWithDeltas', [tester.testTextInput.log.lastWhere((c) => c.method == 'TextInput.setClient').arguments[0], {'deltas': [delta]}])),
      (_) {},
    );
    await tester.pump();
  }
}

LiveMarkdownController doc(String text, int at, [int? end]) =>
    LiveMarkdownController()..value = TextEditingValue(text: text, selection: TextSelection(baseOffset: at, extentOffset: end ?? at));

Future<BlockEditorState> open(WidgetTester tester, LiveMarkdownController c, {ScrollController? scroll}) async {
  final focus = FocusNode();
  addTearDown(focus.dispose);
  await tester.pumpWidget(Host(c, focus, scroll: scroll));
  await tester.pump();
  await tester.pump();
  return tester.state<BlockEditorState>(find.byType(BlockEditor));
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {bool shift = false, bool control = false}) async {
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump();
}

/// Where the place [offset] of the text is on the screen.
Offset placeOf(WidgetTester tester, BlockEditorState state, int offset) => state.screenRectOf(TextRange(start: offset, end: offset + 1))!.center;

void main() {
  group('the block editor', () {
    testWidgets('builds only what is around the screen', (tester) async {
      final text = List.generate(3000, (i) => 'Line number $i of the text').join('\n');
      await open(tester, doc(text, 0));
      expect(find.byType(BlockLine).evaluate().length, lessThan(120));
    });

    testWidgets('what is typed goes into the document, at the caret', (tester) async {
      final c = doc('one\n\nthree', 3);
      await open(tester, c);
      expect(tester.testTextInput.isVisible, isTrue);
      await typeText(tester, ' two');
      expect(c.text, 'One two\n\nthree');
      expect(c.selection.baseOffset, 7);
    });

    testWidgets('the keyboard is told only of the lines around the caret, however long the document is', (tester) async {
      final text = List.generate(3000, (i) => 'Line number $i of the text').join('\n');
      final at = text.indexOf('Line number 1500');
      final c = doc(text, at);
      final state = await open(tester, c);
      await tester.pumpAndSettle();
      expect(state.currentTextEditingValue!.text.length, lessThan(100));
      expect(state.currentTextEditingValue!.text, contains('Line number 1500'));
      await typeText(tester, 'x');
      expect(c.text.substring(at, at + 2), 'xL');
      expect(c.text.length, text.length + 1);
      expect(c.text.endsWith('Line number 2999 of the text'), isTrue);
    });

    testWidgets('a list goes on and the caret leaves the marker, as in the text field', (tester) async {
      final c = doc('- one', 5);
      await open(tester, c);
      await typeText(tester, '\n');
      expect(c.text, '- one\n- ');
      expect(c.selection.baseOffset, 8);
      await typeText(tester, 'two');
      expect(c.text, '- one\n- two');
    });

    testWidgets('a key the keyboard does not know of changes what it is told', (tester) async {
      final c = doc('one', 3);
      final state = await open(tester, c);
      c.value = const TextEditingValue(text: 'one two', selection: TextSelection.collapsed(offset: 7));
      await tester.pump();
      expect(state.currentTextEditingValue!.text, 'one two');
      expect(state.currentTextEditingValue!.selection.baseOffset, 7);
    });

    testWidgets('a character can be replaced, and a selection typed over', (tester) async {
      final c = doc('one two three', 4, 7);
      await open(tester, c);
      await typeText(tester, 'x');
      expect(c.text, 'one x three');
    });

    group('keys', () {
      testWidgets('arrows go through lines and stop at the ends', (tester) async {
        final c = doc('ab\ncd', 2);
        await open(tester, c);
        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(c.selection.baseOffset, 3);
        await press(tester, LogicalKeyboardKey.arrowLeft);
        await press(tester, LogicalKeyboardKey.arrowLeft);
        expect(c.selection.baseOffset, 1);
        c.selection = const TextSelection.collapsed(offset: 5);
        await tester.pump();
        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(c.selection.baseOffset, 5);
      });

      testWidgets('up and down go to the line above and below and keep to their place', (tester) async {
        final c = doc('abcdef\nxy\nghijkl', 4);
        await open(tester, c);
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(c.selection.baseOffset, 9, reason: 'the end of the short line');
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(c.selection.baseOffset, 14, reason: 'back where it started, on the next line');
        await press(tester, LogicalKeyboardKey.arrowUp);
        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(c.selection.baseOffset, 4);
      });

      testWidgets('shift keeps a selection, and an arrow goes to its end', (tester) async {
        final c = doc('hello world', 2);
        await open(tester, c);
        await press(tester, LogicalKeyboardKey.arrowRight, shift: true);
        await press(tester, LogicalKeyboardKey.arrowRight, shift: true);
        expect(c.selection, const TextSelection(baseOffset: 2, extentOffset: 4));
        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(c.selection, const TextSelection.collapsed(offset: 4));
      });

      testWidgets('a selection can go over lines, and is taken away with Backspace', (tester) async {
        final c = doc('one\ntwo\nthree', 2);
        await open(tester, c);
        await press(tester, LogicalKeyboardKey.arrowDown, shift: true);
        await press(tester, LogicalKeyboardKey.arrowDown, shift: true);
        expect(c.selection.isCollapsed, isFalse);
        await press(tester, LogicalKeyboardKey.backspace);
        expect(c.text, 'onree');
        expect(c.selection, const TextSelection.collapsed(offset: 2));
      });

      testWidgets('Backspace and Delete take a character, and join lines', (tester) async {
        final c = doc('ab\ncd', 3);
        await open(tester, c);
        await press(tester, LogicalKeyboardKey.backspace);
        expect(c.text, 'abcd');
        expect(c.selection.baseOffset, 2);
        await press(tester, LogicalKeyboardKey.delete);
        expect(c.text, 'abd');
      });

      testWidgets('an emoji goes as one', (tester) async {
        final c = doc('a😀b', 3);
        await open(tester, c);
        await press(tester, LogicalKeyboardKey.arrowLeft);
        expect(c.selection.baseOffset, 1);
        await press(tester, LogicalKeyboardKey.delete);
        expect(c.text, 'ab');
      });

      testWidgets('Control goes by words', (tester) async {
        final c = doc('one two three', 0);
        await open(tester, c);
        await press(tester, LogicalKeyboardKey.arrowRight, control: true);
        expect(c.selection.baseOffset, 3);
        await press(tester, LogicalKeyboardKey.arrowRight, control: true);
        expect(c.selection.baseOffset, 7);
        await press(tester, LogicalKeyboardKey.arrowLeft, control: true);
        expect(c.selection.baseOffset, 4);
        await press(tester, LogicalKeyboardKey.backspace, control: true);
        expect(c.text, 'two three');
      });

      testWidgets('Home and End go to the ends of the line', (tester) async {
        final c = doc('one\ntwo words\nthree', 6);
        await open(tester, c);
        await press(tester, LogicalKeyboardKey.home);
        expect(c.selection.baseOffset, 4);
        await press(tester, LogicalKeyboardKey.end);
        expect(c.selection.baseOffset, 13);
      });

      testWidgets('Control and Home or End go to the ends of the document, a long way off', (tester) async {
        final text = List.generate(3000, (i) => 'Line number $i').join('\n');
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final c = doc(text, 0);
        await open(tester, c, scroll: scroll);
        await press(tester, LogicalKeyboardKey.end, control: true);
        await tester.pump();
        await tester.pump();
        expect(c.selection.baseOffset, text.length);
        expect(scroll.offset, greaterThan(1000), reason: 'the caret stays on screen');
        await tester.pump();
        expect(find.textContaining('Line number 2999', findRichText: true), findsOneWidget);
        await press(tester, LogicalKeyboardKey.home, control: true);
        await tester.pump();
        await tester.pump();
        expect(c.selection.baseOffset, 0);
        expect(scroll.offset, 0);
      });

      testWidgets('Control and A selects it all', (tester) async {
        final c = doc('one\ntwo', 1);
        await open(tester, c);
        await press(tester, LogicalKeyboardKey.keyA, control: true);
        expect(c.selection, const TextSelection(baseOffset: 0, extentOffset: 7));
      });

      testWidgets('copy and cut', (tester) async {
        final copied = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
          return null;
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
        final c = doc('one two', 4, 7);
        await open(tester, c);
        await press(tester, LogicalKeyboardKey.keyC, control: true);
        expect(copied, ['two']);
        await press(tester, LogicalKeyboardKey.keyX, control: true);
        expect(copied, ['two', 'two']);
        expect(c.text, 'one ');
      });

      testWidgets('undo takes back what was typed, redo brings it back', (tester) async {
        final c = doc('one', 3);
        await open(tester, c);
        await tester.pump(const Duration(milliseconds: 600));
        await typeText(tester, 'x');
        await tester.pump(const Duration(milliseconds: 600));
        await press(tester, LogicalKeyboardKey.keyZ, control: true);
        expect(c.text, 'one');
        await press(tester, LogicalKeyboardKey.keyZ, control: true, shift: true);
        expect(c.text, 'onex');
      });

      testWidgets('nothing changes while the document is only read', (tester) async {
        final c = doc('one', 3)..readingView = true;
        await open(tester, c);
        await press(tester, LogicalKeyboardKey.backspace);
        expect(c.text, 'one');
      });
    });

    group('pointers', () {
      testWidgets('a click puts the caret there, and takes the focus', (tester) async {
        final c = doc('one two three\nsecond line', 0);
        final state = await open(tester, c);
        await tester.tapAt(placeOf(tester, state, 18), kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 500));
        expect((c.selection.baseOffset - 18).abs(), lessThanOrEqualTo(1));
      });

      testWidgets('a drag selects, over lines too', (tester) async {
        final c = doc('one two three\nsecond line', 0);
        final state = await open(tester, c);
        final gesture = await tester.startGesture(placeOf(tester, state, 2), kind: PointerDeviceKind.mouse);
        await tester.pump();
        await gesture.moveTo(placeOf(tester, state, 20));
        await tester.pump();
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 500));
        expect(c.selection.start, inInclusiveRange(1, 3));
        expect(c.selection.end, inInclusiveRange(19, 21));
      });

      testWidgets('a double click selects a word, three the line', (tester) async {
        final c = doc('one two three\nsecond line', 0);
        final state = await open(tester, c);
        final at = placeOf(tester, state, 5);
        await tester.tapAt(at, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(at, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 50));
        expect(c.selection, const TextSelection(baseOffset: 4, extentOffset: 7));
        await tester.tapAt(at, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 500));
        expect(c.selection, const TextSelection(baseOffset: 0, extentOffset: 13));
      });

      testWidgets('a tick box is ticked where it is, wherever the text before it went', (tester) async {
        final c = doc('First\n- [ ] task', 0);
        await open(tester, c);
        c.value = TextEditingValue(text: 'A longer first line\n- [ ] task', selection: const TextSelection.collapsed(offset: 0));
        await tester.pump();
        await tester.tap(find.byIcon(Icons.check_box_outline_blank));
        await tester.pump(const Duration(milliseconds: 500));
        expect(c.text, 'A longer first line\n- [x] task');
      });
    });

    group('the caret', () {
      testWidgets('is as tall as its line and in the same place, wherever on the line it is', (tester) async {
        for (final text in const ['Some plain words', 'Ends in **bold**', 'Ends with a space ', 'Ends in *italic* and `code`', '']) {
          final c = doc(text, text.length);
          await open(tester, c);
          await tester.pump();
          final line = tester.renderObject<RenderBlockLine>(find.byType(BlockLine).first);
          final end = line.caretRect(TextPosition(offset: text.length));
          for (final at in [0, text.length ~/ 2, text.length]) {
            final caret = line.caretRect(TextPosition(offset: at));
            expect(caret.top, end.top, reason: 'at $at of "$text"');
            expect(caret.height, line.size.height, reason: 'at $at of "$text"');
          }
          await tester.pumpWidget(const SizedBox());
        }
      });

      testWidgets('in the font of the document too, on wrapped lines and at their ends', (tester) async {
        await tester.runAsync(() async {
          final bytes = File('assets/fonts/LiberationSans-Regular.ttf').readAsBytesSync();
          await (FontLoader('LiberationSans')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        });
        final text = 'Some words that go on ' * 12;
        final c = doc(text, text.length);
        await open(tester, c);
        await tester.pump();
        final line = tester.renderObject<RenderBlockLine>(find.byType(BlockLine).first);
        final rows = <double>{};
        for (var at = 0; at <= text.length; at++) {
          for (final affinity in TextAffinity.values) {
            final caret = line.caretRect(TextPosition(offset: at, affinity: affinity));
            expect(caret.height, 24, reason: 'at $at');
            rows.add(caret.top);
          }
        }
        expect(rows.length, greaterThan(2));
        for (final a in rows) {
          for (final b in rows) {
            expect(a == b || (a - b).abs() >= 24, isTrue, reason: 'rows at $a and $b');
          }
        }
        final last = line.caretRect(TextPosition(offset: text.length));
        expect(last.bottom, line.size.height);
      });

      testWidgets('on a wrapped line it is on that line, and as tall', (tester) async {
        final text = 'word ' * 60;
        final c = doc(text, text.length);
        await open(tester, c);
        await tester.pump();
        final line = tester.renderObject<RenderBlockLine>(find.byType(BlockLine).first);
        final last = line.caretRect(TextPosition(offset: text.length));
        final first = line.caretRect(const TextPosition(offset: 2));
        expect(first.top, 0);
        expect(last.bottom, line.size.height);
        expect(last.height, first.height);
      });
    });

    group('for a screen reader', () {
      testWidgets('the line with the caret is a text field, the others are text', (tester) async {
        final handle = tester.ensureSemantics();
        final c = doc('First line\nSecond line', 3);
        await open(tester, c);
        await tester.pump();
        final field = tester.getSemantics(find.byType(BlockLine).first);
        expect(field.flagsCollection.isTextField, isTrue);
        expect(field.value, 'First line');
        expect(field.textSelection, const TextSelection.collapsed(offset: 3));
        expect(find.bySemanticsLabel('Second line'), findsOneWidget);
        handle.dispose();
      });

      testWidgets('the marks that are not drawn are not read out, and a heading is a heading', (tester) async {
        final handle = tester.ensureSemantics();
        final c = doc('# Big title\n\nSome **bold** words and a [link](https://example.org) here.\n\nlast', 'last'.length + 70);
        await open(tester, c);
        await tester.pump();
        final title = tester.getSemantics(find.bySemanticsLabel('Big title'));
        expect(title.label, 'Big title', reason: 'not "# Big title"');
        expect(title.flagsCollection.isHeader, isTrue);
        expect(title.headingLevel, 1);
        // (the link is a piece of its own for a screen reader)
        final line = tester.getSemantics(find.bySemanticsLabel(RegExp('^Some bold words')));
        expect(line.label.replaceAll('\n', ''), 'Some bold words and a link here.', reason: 'not the stars, the brackets and the address');
        handle.dispose();
      });

      testWidgets('the line with the caret is read as it is written, marks and all (it is the one being edited)', (tester) async {
        final handle = tester.ensureSemantics();
        final c = doc('Some **bold** words', 3);
        await open(tester, c);
        await tester.pump();
        expect(tester.getSemantics(find.byType(BlockLine).first).value, 'Some **bold** words');
        handle.dispose();
      });

      testWidgets('a task says whether it is ticked, and a screen reader ticks it', (tester) async {
        final handle = tester.ensureSemantics();
        final c = doc('- [ ] write it\n- [x] read it\n\nplain', 'plain'.length + 28);
        await open(tester, c);
        await tester.pump();
        final open_ = tester.getSemantics(find.bySemanticsLabel(RegExp('write it')));
        final done = tester.getSemantics(find.bySemanticsLabel(RegExp('read it')));
        expect(open_.flagsCollection.isChecked, CheckedState.isFalse);
        expect(done.flagsCollection.isChecked, CheckedState.isTrue);
        expect(open_.label.trim(), 'write it', reason: 'not "- [ ] write it"');
        open_.owner!.performAction(open_.id, SemanticsAction.tap);
        await tester.pump();
        expect(c.text, startsWith('- [x] write it'));
        handle.dispose();
      });

      testWidgets('it moves the caret and goes to another line', (tester) async {
        final handle = tester.ensureSemantics();
        final c = doc('First line\nSecond line', 3);
        await open(tester, c);
        await tester.pump();
        final field = tester.getSemantics(find.byType(BlockLine).first);
        final owner = field.owner!;
        owner.performAction(field.id, SemanticsAction.moveCursorForwardByCharacter, false);
        await tester.pump();
        expect(c.selection.baseOffset, 4);
        final other = tester.getSemantics(find.bySemanticsLabel('Second line'));
        owner.performAction(other.id, SemanticsAction.tap);
        await tester.pump();
        expect(c.selection.baseOffset, 'First line\nSecond line'.length);
        handle.dispose();
      });
    });

    group('what a careful look found', () {
      testWidgets('a caret at the end of a line that ends in hidden Markdown has a place', (tester) async {
        final c = doc('one **two**\nsecond', 11);
        final state = await open(tester, c);
        c.selection = const TextSelection.collapsed(offset: 16);
        await tester.pump();
        expect(state.screenCaret, isNotNull);
        expect(tester.takeException(), isNull);
        c.value = const TextEditingValue(text: 'one **two**', selection: TextSelection.collapsed(offset: 11));
        c.revealing = false;
        await tester.pump();
        expect(state.screenCaret!.left, greaterThan(0));
        expect(tester.takeException(), isNull);
      });

      testWidgets('a line break at the top of blank lines is made, and the keyboard agrees', (tester) async {
        final c = doc('a\n\n\n\nb', 2);
        await open(tester, c);
        await typeText(tester, '\n');
        expect(tester.takeException(), isNull);
        expect(c.text, 'a\n\n\n\n\nb');
        expect(c.selection.baseOffset, 3);
      });

      testWidgets('a selection going up over lines is one, and shows the Markdown of all of them', (tester) async {
        final text = List.generate(8, (i) => '**line $i** of it').join('\n');
        final c = doc(text, 60, 2)..revealing = true;
        final state = await open(tester, c);
        await tester.pump();
        expect(tester.takeException(), isNull);
        final down = doc(text, 2, 60)..revealing = true;
        final second = await open(tester, down);
        expect(state.documentHeight, second.documentHeight);
      });

      testWidgets('what comes up when many lines are taken away is built and drawn', (tester) async {
        final text = List.generate(300, (i) => 'line $i').join('\n');
        final c = doc(text, text.indexOf('line 2\n'), text.indexOf('line 72\n'));
        final state = await open(tester, c);
        c.value = TextEditingValue(text: text.replaceRange(c.selection.start, c.selection.end, ''), selection: TextSelection.collapsed(offset: c.selection.start));
        await tester.pump();
        await tester.pump();
        await tester.pump();
        final tops = [for (final (_, y) in state.linesOnScreen()) y]..sort();
        expect(tops.last, greaterThan(500), reason: 'the screen is 600 tall');
        expect(find.text('line 90', findRichText: true), findsOneWidget);
      });

      testWidgets('typing in a long paragraph does not move what the keyboard has, key by key', (tester) async {
        final c = doc('word ' * 800, 2000);
        await open(tester, c);
        int told() => tester.testTextInput.log.where((m) => m.method == 'TextInput.setEditingState').length;
        final was = told();
        await typeText(tester, 'abcdefghij');
        expect(c.text.substring(2000, 2010), 'abcdefghij');
        expect(told(), was);
      });

      testWidgets('a key made on what the keyboard was told before still counts, where the caret is', (tester) async {
        final c = doc('one two', 7);
        final state = await open(tester, c);
        final old = state.currentTextEditingValue!;
        await typeText(tester, 'q');
        // (made on the text before the q)
        state.updateEditingValueWithDeltas([TextEditingDeltaInsertion(oldText: old.text, textInserted: 'z', insertionOffset: 7, selection: const TextSelection.collapsed(offset: 8), composing: TextRange.empty)]);
        await tester.pump();
        expect(c.text, 'one twoqz');
        expect(c.selection.baseOffset, 9);
        expect(state.currentTextEditingValue!.text, 'one twoqz');
      });

      testWidgets('so does a Backspace', (tester) async {
        final c = doc('one two', 7);
        final state = await open(tester, c);
        final old = state.currentTextEditingValue!;
        await typeText(tester, 'q');
        state.updateEditingValueWithDeltas([TextEditingDeltaDeletion(oldText: old.text.replaceRange(7, 7, 'x'), deletedRange: const TextRange(start: 7, end: 8), selection: const TextSelection.collapsed(offset: 7), composing: TextRange.empty)]);
        await tester.pump();
        expect(c.text, 'one twoq', reason: 'what it would take away is not there: nothing goes');
        state.updateEditingValueWithDeltas([TextEditingDeltaDeletion(oldText: 'other', deletedRange: const TextRange(start: 0, end: 1), selection: const TextSelection.collapsed(offset: 0), composing: TextRange.empty)]);
        await tester.pump();
        expect(c.text, 'one twoq');
      });

      testWidgets('the hint goes with the first key, and comes back with the last', (tester) async {
        final c = doc('', 0);
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: CustomScrollView(slivers: [
              SliverToBoxAdapter(child: BlockEditor(controller: c, focusNode: focus, style: documentTextStyle(16), width: 700, autofocus: true, hint: 'Start writing')),
            ]),
          ),
        ));
        await tester.pump();
        await tester.pump();
        expect(find.text('Start writing', findRichText: true), findsOneWidget);
        await typeText(tester, 'H');
        expect(find.text('Start writing', findRichText: true), findsNothing);
        c.value = const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0));
        await tester.pump();
        expect(find.text('Start writing', findRichText: true), findsOneWidget);
      });

      testWidgets('a box ticked further down leaves the page where it is', (tester) async {
        final text = List.generate(300, (i) => '- [ ] task $i').join('\n');
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final c = doc(text, 0);
        await open(tester, c, scroll: scroll);
        scroll.jumpTo(5000);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
        final was = scroll.offset;
        c.toggleTask(text.lastIndexOf('[ ]'));
        await tester.pump();
        await tester.pump();
        expect(c.text.endsWith('- [x] task 299'), isTrue);
        expect(scroll.offset, was);
      });

      testWidgets('Delete brings back a caret that was scrolled away, though it stays where it is', (tester) async {
        final text = List.generate(300, (i) => 'line $i').join('\n');
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final c = doc(text, 3);
        await open(tester, c, scroll: scroll);
        scroll.jumpTo(5000);
        await tester.pump(const Duration(milliseconds: 500));
        await press(tester, LogicalKeyboardKey.delete);
        await tester.pump();
        await tester.pump();
        expect(scroll.offset, lessThan(100));
      });

      testWidgets('Up after typing goes from where the caret is, not from where it was', (tester) async {
        final c = doc('abcdefghijklmnopqrstuvwxyz abcdefgh\nab\n', 2);
        await open(tester, c);
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(c.selection.baseOffset, 38);
        await typeText(tester, 'cdefghijklmnop');
        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(c.selection.baseOffset, 16);
      });

      testWidgets('what shows attributes is told of a change of them alone', (tester) async {
        final c = doc('some bold words', 0);
        final state = await open(tester, c);
        final was = state.debugBuilds;
        c.attributes.add(TextSpanAttribute(start: 5, end: 9, type: AttributeType.underline));
        c.attributesChanged();
        await tester.pump();
        expect(state.debugBuilds, greaterThan(was));
      });

      testWidgets('the far end of a long selection keeps its line, and both handles have a place', (tester) async {
        final text = List.generate(300, (i) => 'line $i').join('\n');
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final c = doc(text, 0, text.length - 3);
        final state = await open(tester, c, scroll: scroll);
        await tester.pump();
        expect(state.screenRectOf(TextRange(start: 0, end: 1)), isNotNull);
        expect(state.screenRectOf(TextRange(start: text.length - 3, end: text.length - 2)), isNotNull);
        scroll.jumpTo(3000);
        await tester.pump();
        await tester.pump();
        expect(state.screenRectOf(TextRange(start: 0, end: 1)), isNotNull);
        expect(state.screenRectOf(TextRange(start: text.length - 3, end: text.length - 2)), isNotNull);
      });

      testWidgets('after Select all on a touch screen the menu and the handles are there', (tester) async {
        final c = doc(List.generate(300, (i) => 'line $i').join('\n'), 0);
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: CustomScrollView(slivers: [
              SliverToBoxAdapter(child: BlockEditor(controller: c, focusNode: focus, style: documentTextStyle(16), width: 700, selectionControls: materialTextSelectionHandleControls)),
            ]),
          ),
        ));
        await tester.pump();
        final state = tester.state<BlockEditorState>(find.byType(BlockEditor));
        await tester.longPressAt(placeOf(tester, state, 2));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('Select all'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(c.selection, TextSelection(baseOffset: 0, extentOffset: c.text.length));
        expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
        expect(find.text('Copy'), findsOneWidget);
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));

      testWidgets('Paste is offered only with something to paste', (tester) async {
        var has = false;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => call.method == 'Clipboard.hasStrings' ? {'value': has} : null);
        addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
        final c = doc('one two', 0);
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: CustomScrollView(slivers: [
              SliverToBoxAdapter(child: BlockEditor(controller: c, focusNode: focus, style: documentTextStyle(16), width: 700, selectionControls: materialTextSelectionHandleControls)),
            ]),
          ),
        ));
        await tester.pump();
        final state = tester.state<BlockEditorState>(find.byType(BlockEditor));
        await tester.longPressAt(placeOf(tester, state, 2));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Paste'), findsNothing);
        has = true;
        await tester.tapAt(placeOf(tester, state, 5));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.longPressAt(placeOf(tester, state, 2));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Paste'), findsOneWidget);
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    });

    group('with a finger', () {
      testWidgets('a tap puts the caret there and brings the keyboard; a long press selects a word, with handles and a menu', (tester) async {
        final c = doc('one two three\nsecond line', 0);
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: CustomScrollView(slivers: [
              SliverToBoxAdapter(
                child: BlockEditor(controller: c, focusNode: focus, style: documentTextStyle(16), width: 700, selectionControls: materialTextSelectionHandleControls),
              ),
            ]),
          ),
        ));
        await tester.pump();
        final state = tester.state<BlockEditorState>(find.byType(BlockEditor));
        await tester.tapAt(placeOf(tester, state, 5));
        await tester.pump(const Duration(milliseconds: 400));
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        expect((c.selection.baseOffset - 5).abs(), lessThanOrEqualTo(1));
        await tester.longPressAt(placeOf(tester, state, 9));
        await tester.pump(const Duration(milliseconds: 400));
        expect(c.selection, const TextSelection(baseOffset: 8, extentOffset: 13));
        expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
        await tester.tapAt(placeOf(tester, state, 18));
        await tester.pump(const Duration(milliseconds: 400));
        expect(c.selection.isCollapsed, isTrue);
        expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    });

    group('a long document', () {
      // (long lines that wrap, which an estimate gets wrong; some are short)
      String longText() => List.generate(600, (i) => i.isEven ? 'Line $i ${'word ' * 90}' : 'Short $i').join('\n');

      testWidgets('all of its lines are measured in time, while what is on screen stays where it is', (tester) async {
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final c = doc(longText(), 0);
        final state = await open(tester, c, scroll: scroll);
        expect(state.allMeasured, isFalse);
        final estimate = state.documentHeight;
        scroll.jumpTo(estimate / 2);
        await tester.pump();
        await tester.pump();
        // (the caret's lines are built too, far above the screen: those may go anywhere)
        Map<int, double> onScreen() => {
              for (final t in state.linesOnScreen())
                if (t.$2 >= 0 && t.$2 < 600) t.$1: t.$2,
            };
        final before = onScreen();
        expect(before, isNotEmpty);
        for (var i = 0; i < 400 && !state.allMeasured; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(state.allMeasured, isTrue);
        await tester.pump();
        final after = onScreen();
        final both = before.keys.where(after.containsKey).toList();
        expect(both, isNotEmpty, reason: 'what was on screen is still there');
        for (final k in both) {
          expect((after[k]! - before[k]!).abs(), lessThan(2), reason: 'line $k moved on the screen');
        }
      });

      testWidgets('typing above what was measured goes on working, and heights are kept', (tester) async {
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final c = doc(longText(), 0);
        final state = await open(tester, c, scroll: scroll);
        for (var i = 0; i < 400 && !state.allMeasured; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        final height = state.documentHeight;
        await typeText(tester, 'x');
        await tester.pump();
        expect(state.documentHeight, closeTo(height, 30));
        expect(c.text.startsWith('Xline 0') || c.text.startsWith('xLine 0'), isTrue);
      });

      testWidgets('a line break and a joined line build the lines they should, in order', (tester) async {
        final text = List.generate(100, (i) => 'Line $i').join('\n');
        final c = doc(text, text.indexOf('\n', 40));
        await open(tester, c);
        await typeText(tester, '\n');
        await tester.pump();
        await typeText(tester, 'new');
        await tester.pump();
        expect(find.textContaining('new', findRichText: true), findsOneWidget);
        expect(c.selection.isCollapsed, isTrue);
        await press(tester, LogicalKeyboardKey.backspace);
        await press(tester, LogicalKeyboardKey.backspace);
        await press(tester, LogicalKeyboardKey.backspace);
        await press(tester, LogicalKeyboardKey.backspace);
        await tester.pump();
        expect(c.text, text);
      });

      testWidgets('a change of all of the text is followed', (tester) async {
        final c = doc('one', 0);
        await open(tester, c);
        c.text = List.generate(500, (i) => 'Other $i').join('\n');
        await tester.pump();
        await tester.pump();
        expect(find.textContaining('Other 0', findRichText: true), findsOneWidget);
        c.text = '';
        await tester.pump();
        await tester.pump();
        expect(find.textContaining('Other 0', findRichText: true), findsNothing);
      });

      group('on sheets of paper', () {
        Future<(LiveMarkdownController, BlockEditorState)> sheets(WidgetTester tester, String text, {ScrollController? scroll, int at = 0}) async {
          final c = LiveMarkdownController()..value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: at));
          await tester.pumpWidget(MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                controller: scroll,
                child: DocumentSheet(controller: c, width: 800, minHeight: 1000, pageHeight: 1100, sheetGap: 24),
              ),
            ),
          ));
          final state = tester.state<BlockEditorState>(find.byType(BlockEditor));
          for (var i = 0; i < 200 && !state.allMeasured; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          await tester.pump();
          await tester.pump();
          return (c, state);
        }

        testWidgets('there is a gap between the sheets, and only those near the screen are built', (tester) async {
          final text = List.generate(2000, (i) => 'Line number $i').join('\n');
          final (_, state) = await sheets(tester, text);
          expect(state.sheetCount, greaterThan(40));
          final first = tester.getRect(find.byKey(const ValueKey('write-sheet-0')));
          final second = tester.getRect(find.byKey(const ValueKey('write-sheet-1')));
          expect(first.height, 1100);
          expect(second.top - first.bottom, 24);
          expect(find.byKey(ValueKey('write-sheet-${state.sheetCount - 1}')), findsNothing);
        });

        testWidgets('the text goes on at the top margin of the next sheet', (tester) async {
          final text = List.generate(60, (i) => 'Line number $i').join('\n');
          final (_, state) = await sheets(tester, text);
          final top = tester.getTopLeft(find.byKey(const ValueKey('write-sheet-1'))).dy;
          // 56 at the top and bottom of 1100: 41 lines of 24
          final next = state.screenRectOf(TextRange(start: text.indexOf('Line number 41'), end: text.indexOf('Line number 41') + 1));
          expect(next!.top, closeTo(top + 56, 8));
        });

        testWidgets('a paragraph goes over between two rows; a click below the gap finds its text', (tester) async {
          final text = '${List.generate(38, (i) => 'Line $i').join('\n')}\n${'word ' * 400}';
          final scroll = ScrollController();
          addTearDown(scroll.dispose);
          final (c, state) = await sheets(tester, text, scroll: scroll);
          scroll.jumpTo(800);
          await tester.pump();
          await tester.pump();
          final top = tester.getTopLeft(find.byKey(const ValueKey('write-sheet-1'))).dy;
          final at = text.indexOf('word') + 300;
          final rect = state.screenRectOf(TextRange(start: at, end: at + 1))!;
          expect(rect.top, greaterThan(top), reason: 'it is on the second sheet');
          await tester.tapAt(rect.center, kind: PointerDeviceKind.mouse);
          await tester.pump(const Duration(milliseconds: 500));
          expect((c.selection.baseOffset - at).abs(), lessThanOrEqualTo(1));
        });

        testWidgets('a page break starts a new sheet', (tester) async {
          final text = 'Before\n\\pagebreak\nAfter';
          final (_, state) = await sheets(tester, text);
          expect(state.sheetCount, 2);
          final after = state.screenRectOf(TextRange(start: text.indexOf('After'), end: text.indexOf('After') + 1))!;
          expect(after.top, closeTo(tester.getTopLeft(find.byKey(const ValueKey('write-sheet-1'))).dy + 56, 8));
        });

        testWidgets('typing to the end of a sheet makes the next one, and taking it away takes it away', (tester) async {
          final text = List.generate(41, (i) => 'Line $i').join('\n');
          final (c, state) = await sheets(tester, text, at: text.length);
          expect(state.sheetCount, 1);
          await typeText(tester, '\n');
          await tester.pump();
          await tester.pump();
          expect(state.sheetCount, 2);
          expect(find.byKey(const ValueKey('write-sheet-1')), findsOneWidget);
          await press(tester, LogicalKeyboardKey.backspace);
          await tester.pump();
          await tester.pump();
          expect(state.sheetCount, 1);
          expect(c.text, text);
        });
      });
    });

    group('a key changes only what it changes', () {
      testWidgets('typing builds one line, and moving the caret the lines it leaves and goes to', (tester) async {
        final text = List.generate(40, (i) => 'Line number $i').join('\n');
        final c = doc(text, 5);
        final state = await open(tester, c);
        final before = state.debugBuilds;
        await typeText(tester, 'x');
        expect(state.debugBuilds - before, 1);
        final moved = state.debugBuilds;
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(state.debugBuilds - moved, lessThanOrEqualTo(2));
      });

      testWidgets('a line that is built keeps a change made before it: its link goes on working', (tester) async {
        final c = doc('one\n[link](https://x.y) after', 0);
        String? opened;
        c.onLink = (t) => opened = t;
        await open(tester, c);
        await typeText(tester, 'more ');
        await tester.tap(find.textContaining('link', findRichText: true).last);
        await tester.pump(const Duration(milliseconds: 500));
        expect(opened, 'https://x.y');
      });
    });

    group('the table of contents', () {
      testWidgets('an entry takes the caret and the screen to its heading', (tester) async {
        final text = '[toc]\n\n${List.generate(30, (i) => '# Part $i\n\n${List.generate(8, (j) => 'Some words of part $i, line $j.').join('\n')}\n').join('\n')}';
        final c = doc(text, 0);
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final state = await open(tester, c, scroll: scroll);
        expect(scroll.offset, 0);
        await tester.tap(find.byKey(ValueKey('toc-${text.indexOf('# Part 20')}')));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(c.selection.baseOffset, text.indexOf('# Part 20'));
        expect(scroll.offset, greaterThan(1000));
        expect(state.screenCaret, isNotNull);
        final caret = state.screenCaret!;
        expect(caret.top, inInclusiveRange(0, 150));
      });

      for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch, PointerDeviceKind.stylus]) {
        testWidgets('it does so for a ${kind.name}, from where the document is being written', (tester) async {
          final text = '[toc]\n\n${List.generate(30, (i) => '# Part $i\n\n${List.generate(8, (j) => 'Some words of part $i, line $j.').join('\n')}\n').join('\n')}';
          final c = doc(text, text.length);
          final scroll = ScrollController();
          addTearDown(scroll.dispose);
          final focus = FocusNode();
          addTearDown(focus.dispose);
          await tester.pumpWidget(Host(c, focus, scroll: scroll));
          focus.requestFocus();
          await tester.pump();
          await tester.pump();
          scroll.jumpTo(0);
          await tester.pump();
          final entry = find.byKey(ValueKey('toc-${text.indexOf('# Part 20')}'));
          expect(entry, findsOneWidget);
          // (the screen is drawn between the press and the release)
          final press = await tester.startGesture(tester.getCenter(entry), kind: kind);
          await tester.pump(const Duration(milliseconds: 80));
          await press.up();
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(c.selection.baseOffset, text.indexOf('# Part 20'));
          expect(scroll.offset, greaterThan(1000));
        });
      }
    });
  });
}
