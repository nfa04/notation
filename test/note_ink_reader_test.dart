import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ink/note_ink_reader.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/search/search_query.dart';

import 'ink_prefetch_test.dart' show FakeReader, until, word;

void main() {
  late FakeReader text;
  late Map<int, List<DrawingStroke>> strokes;
  late List<(String, List<InkText>, Set<String>)> saved;
  late int progressed;
  var open = true, locked = false, wanted = true;

  NoteInkReader reader({FakeReader? handwriting, FakeReader? math}) => NoteInkReader(
        noteId: 'n1',
        handwriting: handwriting,
        math: math,
        idle: const Duration(milliseconds: 20),
        strokes: () => strokes,
        visiblePage: () => 0,
        isQuiet: () => true,
        isOpen: () => open,
        isLocked: () => locked,
        ready: () async {},
        indexWanted: () async => wanted,
        saveIndex: (id, read, alive) async => saved.add((id, read, alive)),
        onProgress: () => progressed++,
      );

  setUp(() {
    text = FakeReader((s) => 'hello');
    strokes = {0: word('a', 100, 100)};
    saved = [];
    progressed = 0;
    open = true;
    locked = false;
    wanted = true;
  });

  group('starting', () {
    test('with no reader there is nothing to start, and it says why', () async {
      final r = reader();
      expect(await r.start(), contains('switched off'));
      expect(r.prefetcher, isNull);
      r.dispose();
    });

    test('readers whose models are not installed are not started', () async {
      final r = reader(handwriting: FakeReader((s) => 'x', installed: false));
      r.prepText = true;
      expect(await r.start(), contains('not installed'));
      expect(r.prefetcher, isNull);
      r.dispose();
    });

    test('a note that was closed meanwhile starts nothing', () async {
      final r = reader(handwriting: text)..prepText = true;
      open = false;
      expect(await r.start(), 'The note was not open');
      expect(r.prefetcher, isNull);
    });

    test('a reader is only used for what was asked: the formula reader waits until formulas are wanted', () async {
      final math = FakeReader((s) => r'\frac{1}{2}');
      final r = reader(handwriting: text, math: math);
      expect(await r.prepare(text: true, math: false), contains('ahead of time'));
      expect(r.prefetcher, isNotNull);
      expect(r.prepText, isTrue);
      expect(r.prepMath, isFalse);
      r.dispose();
    });
  });

  group('reading for the search', () {
    test('the writing is read, kept as the readings change, and reported to the editor', () async {
      final r = reader(handwriting: text);
      await r.startIndex();
      expect(r.indexInk, isTrue);
      r.prefetcher!.changed();
      await until(() => r.prefetcher!.reads > 0);
      expect(text.calls, isNotEmpty);
      await until(() => progressed > 0);
      expect(progressed, greaterThan(0));

      await r.saveReadings();
      expect(saved, hasLength(1));
      final (id, read, alive) = saved.single;
      expect(id, 'n1');
      expect(read.single.text, 'hello');
      expect(alive, {read.single.key});
      r.dispose();
    });

    test('switched off in the settings, nothing is read', () async {
      wanted = false;
      final r = reader(handwriting: text);
      await r.startIndex();
      expect(r.indexInk, isFalse);
      expect(r.prefetcher, isNull);
      await r.saveReadings();
      expect(saved, isEmpty);
    });

    test('a locked note keeps nothing, and nor does line by line checking of maths', () async {
      final r = reader(handwriting: text);
      await r.startIndex();
      r.prefetcher!.changed();
      await until(() => r.prefetcher!.reads > 0);

      locked = true;
      await r.saveReadings();
      expect(saved, isEmpty);
      locked = false;
      r.checkOn = true;
      await r.saveReadings();
      expect(saved, isEmpty);
      r.checkOn = false;
      r.dispose();
    });

    test('closing the note keeps what was read so far', () async {
      final r = reader(handwriting: text);
      await r.startIndex();
      r.prefetcher!.changed();
      await until(() => r.prefetcher!.reads > 0);
      r.dispose();
      await until(() => saved.isNotEmpty);
      expect(saved, hasLength(1));
    });
  });
}
