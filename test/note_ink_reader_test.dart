import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/note_text_repository.dart' show InkRead;
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/ink/note_ink_reader.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/search/search_query.dart';

import 'ink_prefetch_test.dart' show FakeReader, scribble, until, word;

void main() {
  late FakeReader text;
  late Map<int, List<DrawingStroke>> strokes;
  late List<(String, List<InkText>, Set<String>)> saved;
  late List<List<InkRead>> savedReads;
  late int progressed;
  var kept = <String, String>{};
  var keptReads = <InkRead>[];
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
        saveReads: (id, reads) async => savedReads.add(reads),
        loadSaved: (id) async => (texts: kept, reads: keptReads),
        onProgress: () => progressed++,
      );

  setUp(() {
    text = FakeReader((s) => 'hello');
    strokes = {0: word('a', 100, 100)};
    saved = [];
    savedReads = [];
    progressed = 0;
    kept = {};
    keptReads = [];
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

  group('readings kept from before', () {
    test('are there again at once, without a reader, and are not read twice', () async {
      final key = clusterStrokes(0, strokes[0]!).single.key;
      kept = {key: 'kept words'};
      final r = reader(handwriting: text);
      await r.restore();
      expect(r.prefetcher!.lookupText(strokes[0]!), 'kept words');
      await r.startIndex();
      r.prefetcher!.changed();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(text.calls, isEmpty);
      r.dispose();
    });

    test('a conversion that was asked for is kept, also when the search index is off', () async {
      wanted = false;
      final r = reader(handwriting: text);
      await r.restore();
      r.prefetcher!.remember(strokes[0]!, 'asked for');
      await r.saveReadings();
      expect(saved.single.$2.single.text, 'asked for');
      await r.saveReadings();
      expect(saved, hasLength(1)); // (nothing new: not written again)
      r.dispose();
    });
  });

  group('the maths check, which reads by rows', () {
    // one block of two rows of writing: "a" on top, "b" under it
    String row(List<DrawingStroke> s) => s.first.id.startsWith('a') ? 'x = 1' : 'y = 2';
    late FakeReader rows, formulas;
    setUp(() {
      strokes = {0: [...word('a', 100, 100, n: 5), ...word('b', 100, 140, n: 3)]};
      rows = FakeReader(row);
      formulas = FakeReader((s) => row(s).replaceAll(' ', ''));
    });

    Future<NoteInkReader> checking() async {
      final r = reader(handwriting: rows, math: formulas)..checkOn = true;
      await r.restore();
      await r.start();
      return r;
    }

    test('keeps its readings: the text by block for the search, the formulas beside it', () async {
      final block = clusterStrokes(0, strokes[0]!).single;
      final r = await checking();
      r.prefetcher!.changed();
      await until(() => formulas.calls.length == 2);
      await r.saveReadings();
      final (_, read, alive) = saved.single;
      expect(read.single.key, block.key, reason: 'by block, as the search and the PDF text have it');
      expect(read.single.text, 'x = 1\ny = 2', reason: 'a line to a row');
      expect(alive, {block.key});
      expect({for (final f in savedReads.single) f.latex}, {'x=1', 'y=2'});
      r.dispose();
    });

    test('opened again, nothing is read: not the text, not the formulas', () async {
      var r = await checking();
      r.prefetcher!.changed();
      await until(() => formulas.calls.length == 2);
      await r.saveReadings();
      r.dispose();
      kept = {for (final t in saved.last.$2) t.key: t.text};
      keptReads = savedReads.last;
      rows.calls.clear();
      formulas.calls.clear();

      r = await checking();
      r.prefetcher!.changed();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(rows.calls, isEmpty);
      expect(formulas.calls, isEmpty);
      expect({for (final x in r.prefetcher!.readings()) x.latex}, {'x=1', 'y=2'});
      r.dispose();
    });

    test('a block read for the search before gives its rows their text: only the formulas are read', () async {
      kept = {clusterStrokes(0, strokes[0]!).single.key: 'x = 1\ny = 2'};
      final r = await checking();
      r.prefetcher!.changed();
      await until(() => formulas.calls.length == 2);
      expect(rows.calls, isEmpty);
      r.dispose();
    });
  });

  group('conversions of a selection that is not a whole block', () {
    test('are remembered, kept, there again when the note is opened again, and dropped when the writing changes', () async {
      strokes = {0: [...word('a', 100, 100, n: 5), ...word('b', 100, 140, n: 3)]};
      final part = strokes[0]!.where((s) => s.id.startsWith('b')).toList();
      var r = reader(handwriting: text);
      await r.restore();
      expect(r.prefetcher!.lookupText(part), isNull, reason: 'it cuts the block');
      r.prefetcher!.remember(part, 'second line');
      expect(r.prefetcher!.lookupText(part), 'second line', reason: 'not read again while the note is open');
      await r.saveReadings();
      r.dispose();
      expect(savedReads.single.single.text, 'second line');

      keptReads = savedReads.single;
      r = reader(handwriting: text);
      await r.restore();
      expect(r.prefetcher!.lookupText(part), 'second line', reason: 'nor after it was opened again');

      // the writing changes: what was read of it is not what it says any more
      strokes = {0: [...strokes[0]!.where((s) => s.id != 'b0'), scribble('b0', 300, 140)]};
      r.prefetcher!.changed();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await r.saveReadings();
      expect(savedReads.last, isEmpty);
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

    test('a locked note keeps nothing', () async {
      final r = reader(handwriting: text);
      await r.startIndex();
      r.prefetcher!.changed();
      await until(() => r.prefetcher!.reads > 0);

      locked = true;
      await r.saveReadings();
      expect(saved, isEmpty);
      expect(savedReads, isEmpty);
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
