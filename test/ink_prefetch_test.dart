
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/ink/ink_prefetcher.dart';
import 'package:notes/ink/ink_recognizer.dart';
import 'package:notes/models/canvas_models.dart';

/// A scribble about [w] wide and [h] tall with its left edge at [x] and its top at [y].
DrawingStroke scribble(String id, double x, double y, {double w = 14, double h = 22, Color color = Colors.black}) => DrawingStroke(
      id: id,
      color: color,
      width: 3,
      points: [for (var i = 0; i < 8; i++) Offset(x + w * (i / 7), y + (i.isEven ? 0 : h))],
    );

/// A "word" of [n] letters side by side with a small gap, starting at ([x], [y]).
List<DrawingStroke> word(String name, double x, double y, {int n = 4}) => [for (var i = 0; i < n; i++) scribble('$name$i', x + i * 20, y)];

/// A reader that says what it was given and what it read.
class FakeReader extends InkRecognizer {
  FakeReader(this.say, {this.delay = Duration.zero, this.installed = true, this.sayAgain});
  final String Function(List<DrawingStroke> strokes) say;

  /// The other readings (see [InkRecognizer.recognizeAgain]); none when null.
  final List<String> Function(List<DrawingStroke> strokes)? sayAgain;
  int lookedAgain = 0;
  final Duration delay;
  final bool installed;
  final calls = <List<String>>[];
  int running = 0;
  int mostAtOnce = 0;
  bool fail = false;

  @override
  HandwritingStatus get status => installed ? HandwritingStatus.installed : HandwritingStatus.notInstalled;
  @override
  double get progress => 0;
  @override
  String? get error => null;
  @override
  int get sizeMb => 1;
  @override
  Future<void> load() async {}
  @override
  Future<void> install() async {}
  @override
  Future<void> remove() async {}

  @override
  Future<List<String>> recognizeAgain(List<DrawingStroke> strokes) async {
    lookedAgain++;
    await Future<void>.delayed(delay);
    return sayAgain?.call(strokes) ?? const [];
  }

  @override
  Future<String> recognize(List<DrawingStroke> strokes) async {
    calls.add([for (final s in strokes) s.id]..sort());
    running++;
    if (running > mostAtOnce) mostAtOnce = running;
    await Future<void>.delayed(delay);
    running--;
    if (fail) throw StateError('cannot read this');
    return say(strokes);
  }
}

Future<void> until(bool Function() done, {int ms = 3000}) async {
  for (var i = 0; i < ms ~/ 10 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('grouping strokes that lie close together', () {
    test('the letters of a word, and the words of a line, are one block; a block further away is another', () {
      final strokes = [...word('a', 100, 100), ...word('b', 192, 100), ...word('far', 100, 500)];
      final clusters = clusterStrokes(0, strokes);
      expect(clusters.length, 2);
      expect(clusters.first.strokes.length, 8);
      expect(clusters.last.strokes.length, 4);
      expect(clusters.first.bounds.top, lessThan(clusters.last.bounds.top), reason: 'top to bottom');
    });

    test('lines under each other (a paragraph, or the two sides of a fraction) are one block when they are close', () {
      final strokes = [...word('l1', 100, 100), ...word('l2', 100, 130), ...word('l3', 100, 160)];
      expect(clusterStrokes(0, strokes), hasLength(1));
    });

    test('what is not handwriting is left out: the highlighter, a long line, a frame, a lone dot', () {
      final strokes = [
        ...word('w', 100, 100),
        scribble('marker', 100, 100, w: 100, h: 20, color: Colors.yellow.withValues(alpha: 0.35)),
        scribble('underline', 100, 125, w: 400, h: 2),
        scribble('frame', 90, 90, w: 300, h: 300),
        scribble('dot', 100, 300, w: 3, h: 3),
      ];
      final clusters = clusterStrokes(0, strokes);
      expect(clusters, hasLength(1));
      expect(clusters.single.strokes.map((s) => s.id).toSet(), {'w0', 'w1', 'w2', 'w3'});
      expect(isInkStroke(strokes.firstWhere((s) => s.id == 'underline')), isFalse);
      expect(isInkStroke(strokes.firstWhere((s) => s.id == 'marker')), isFalse);
    });

    test('a block is named by its strokes as they are: another stroke or a moved one is another name, the same ink is the same', () {
      final a = word('a', 100, 100);
      final key = clusterStrokes(0, a).single.key;
      expect(clusterStrokes(0, [...a]).single.key, key);
      expect(clusterStrokes(0, [...a, scribble('more', 170, 100)]).single.key, isNot(key));
      a.first.points[1] = const Offset(150, 150); // a stroke that was changed
      expect(clusterStrokes(0, a).single.key, isNot(key));
    });

    test('a page of writing is cut into its lines instead of being read in one go', () {
      final page = [for (var line = 0; line < 14; line++) ...word('l$line-', 60, 60 + line * 40, n: 12)]; // 168 strokes, 560 tall
      final clusters = clusterStrokes(0, page);
      expect(clusters.length, greaterThan(5));
      expect(clusters.every((c) => c.strokes.length <= largestCluster), isTrue);
      expect({for (final c in clusters) ...c.ids}.length, 168, reason: 'every stroke is in one');
    });

    test('maths is told from text by what is stacked, and by the signs in what was read', () {
      final fraction = [...word('top', 100, 100, n: 3), ...word('bottom', 100, 130, n: 3)];
      final c = clusterStrokes(0, fraction).single;
      expect(looksLikeMaths(c), isTrue, reason: 'one over the other');
      final line = clusterStrokes(0, word('plain', 100, 100)).single;
      expect(looksLikeMaths(line), isFalse);
      expect(looksLikeMaths(line, text: 'x^2 + 3 = 7'), isTrue);
      expect(looksLikeMaths(line, text: 'hello world'), isFalse);
      expect(looksLikeMaths(line, text: '3x'), isTrue);
    });
  });

  group('reading ahead of time', () {
    late Map<int, List<DrawingStroke>> page;
    late FakeReader text, maths;
    late InkPrefetcher prefetch;
    var quiet = true;

    InkPrefetcher make({FakeReader? t, FakeReader? m, bool Function()? canRun}) {
      prefetch = InkPrefetcher(strokes: () => page, canRun: canRun ?? () => quiet, idle: const Duration(milliseconds: 40))..configure(text: t, math: m);
      addTearDown(prefetch.dispose);
      return prefetch;
    }

    setUp(() {
      quiet = true;
      text = FakeReader((s) => 'text of ${s.length}');
      maths = FakeReader((s) => r'\frac{a}{b}');
      page = {
        0: [...word('a', 100, 100), ...word('b', 100, 500)],
      };
    });

    test('after things have been quiet each block is read once, and then there is nothing more to read', () async {
      final p = make(t: text);
      await until(() => text.calls.length >= 2);
      expect(text.calls, hasLength(2));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(text.calls, hasLength(2), reason: 'not again');
      p.changed();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(text.calls, hasLength(2), reason: 'nothing changed');
      expect(p.waiting, 0);
      expect(p.reads, 2);
    });

    test('the blocks that come first by [order] are read first, and a lone bar is taken as read without the reader', () async {
      page = {
        0: [...word('a', 100, 100)],
        3: [...word('b', 100, 100), DrawingStroke(id: 'bar', color: Colors.black, width: 3, points: [const Offset(100, 600), const Offset(160, 601)])],
      };
      prefetch = InkPrefetcher(strokes: () => page, canRun: () => quiet, idle: const Duration(milliseconds: 40), order: (c) => (c.page - 3).abs())
        ..configure(text: text);
      addTearDown(prefetch.dispose);
      await until(() => text.calls.length >= 2);
      expect(text.calls.first, everyElement(startsWith('b')), reason: 'the page in view (3) first');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(text.calls, hasLength(2), reason: 'the bar is not read');
      expect(prefetch.waiting, 0);
      expect(prefetch.readings().where((r) => r.block.ids.contains('bar')).single.text, '');
    });

    test('only what changed is read again', () async {
      final p = make(t: text);
      await until(() => text.calls.length >= 2);
      page[0]!.add(scribble('new', 220, 100)); // joins the first block
      p.changed();
      await until(() => text.calls.length >= 3);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(text.calls, hasLength(3));
      expect(text.calls.last, contains('new'));
    });

    test('nothing is read while the person is drawing, and it is read once they stop', () async {
      quiet = false;
      final p = make(t: text);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(text.calls, isEmpty);
      quiet = true;
      await until(() => text.calls.isNotEmpty, ms: 4000);
      expect(text.calls, isNotEmpty, reason: 'it looks again a moment later');
      expect(p.active, isTrue);
    });

    test('a change while reading stops the round: the new ink is read after another quiet moment', () async {
      final slow = FakeReader((s) => 'slow', delay: const Duration(milliseconds: 120));
      final p = make(t: slow);
      await until(() => slow.calls.length == 1);
      page[0]!.add(scribble('late', 220, 100));
      p.changed();
      await until(() => slow.calls.length >= 3, ms: 4000);
      expect(slow.mostAtOnce, 1, reason: 'one at a time');
      expect(slow.calls.any((c) => c.contains('late')), isTrue);
    });

    test('the formula reader is asked only for what looks like a formula (once the text is read), and only once', () async {
      page = {
        0: [...word('eq', 100, 100), ...word('hello', 100, 500)],
      };
      text = FakeReader((s) => s.any((x) => x.id.startsWith('eq')) ? 'x^2 + 1 = 2' : 'hello');
      make(t: text, m: maths);
      await until(() => text.calls.length >= 2 && maths.calls.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(maths.calls, hasLength(1));
      expect(maths.calls.single.every((id) => id.startsWith('eq')), isTrue);
    });

    test('without a handwriting reader the formula reader reads every block; neither installed: nothing happens', () async {
      make(m: maths);
      await until(() => maths.calls.length >= 2);
      expect(maths.calls, hasLength(2));
      final none = FakeReader((s) => '', installed: false);
      final p2 = InkPrefetcher(strokes: () => page, idle: const Duration(milliseconds: 20))..configure(text: none, math: none);
      addTearDown(p2.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(none.calls, isEmpty);
      expect(p2.active, isFalse);
    });

    test('a block that cannot be read is not tried again until its ink changes, and the others still are', () async {
      text.fail = true;
      final p = make(t: text);
      await until(() => text.calls.length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(text.calls, hasLength(2), reason: 'each once');
      text.fail = false;
      page[0]!.add(scribble('fix', 220, 100));
      p.changed();
      await until(() => text.calls.length >= 3);
      expect(text.calls, hasLength(3));
    });

    test('what is selected is there at once when it is exactly some blocks: one, or several in reading order', () async {
      page = {
        0: [...word('a', 100, 100), ...word('b', 330, 105), ...word('c', 100, 160)],
      };
      text = FakeReader((s) => s.first.id.startsWith('a') ? 'first' : s.first.id.startsWith('b') ? 'second' : 'third');
      final p = make(t: text);
      // (a and b are on one line, 130 apart: a gap of a word; c is the line under them, close enough to be one block with a)
      await until(() => p.waiting == 0 && text.calls.isNotEmpty);
      final all = page[0]!;
      final blocks = clusterStrokes(0, all);
      final firstBlock = blocks.first.strokes;
      expect(p.lookupText(firstBlock), isNotNull);
      expect(p.lookupText(firstBlock.take(2)), isNull, reason: 'part of a block was not what was read');
      expect(p.lookupText(const []), isNull);
      expect(p.lookupMath(firstBlock), isNull, reason: 'no formula was read');
      expect(p.isReady(firstBlock), isTrue);
      expect(p.isReady(firstBlock, math: true), isFalse);
    });

    test('several blocks are put together as lines: left to right on a line, top to bottom', () async {
      page = {
        0: [...word('a', 100, 100), ...word('b', 330, 105), ...word('c', 100, 400)],
      };
      text = FakeReader((s) => s.first.id.startsWith('a') ? 'one' : s.first.id.startsWith('b') ? 'two' : 'three');
      final p = make(t: text);
      await until(() => text.calls.length >= 3);
      expect(p.lookupText(page[0]!.reversed), 'one two\nthree');
      expect(p.lookupText([...word('a', 100, 100), ...word('b', 330, 105)].take(7)), isNull, reason: 'a block with a stroke missing: not what was read');
    });

    test('a formula is read for one block only', () async {
      page = {
        0: [...word('top', 100, 100, n: 3), ...word('bottom', 100, 130, n: 3), ...word('other', 100, 500)],
      };
      text = FakeReader((s) => 'plain');
      final p = make(t: text, m: maths);
      await until(() => maths.calls.isNotEmpty && text.calls.length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final fraction = page[0]!.where((s) => !s.id.startsWith('other')).toList();
      expect(p.lookupMath(fraction), r'\frac{a}{b}');
      expect(p.lookupMath(page[0]!), isNull, reason: 'two blocks: not one formula');
    });

    test('a conversion that is asked for waits for the piece being read, then goes before the next; what it read is kept', () async {
      final slow = FakeReader((s) => 'slow', delay: const Duration(milliseconds: 150));
      page = {
        0: [...word('a', 100, 100), ...word('b', 100, 400), ...word('c', 100, 700)],
      };
      final p = make(t: slow);
      await until(() => slow.calls.length == 1);
      final order = <String>[];
      var readingWhenMine = -1;
      final job = p.exclusive(() async {
        order.add('mine');
        readingWhenMine = slow.running;
        return 'read';
      });
      expect(await job, 'read');
      expect(readingWhenMine, 0, reason: 'it ran between two pieces, not in the middle of one');
      expect(order, ['mine']);
      expect(slow.mostAtOnce, 1);

      final block = clusterStrokes(0, page[0]!).first.strokes;
      p.remember(block, 'what the person asked for');
      expect(p.lookupText(block), 'what the person asked for');
      p.remember(block.take(1), 'not a block'); // not remembered
      expect(p.lookupText(block), 'what the person asked for');
    });

    test('blocks that are not on the page any more are forgotten', () async {
      final p = make(t: text);
      await until(() => text.calls.length >= 2);
      final gone = page[0]!.where((s) => s.id.startsWith('b')).toList();
      page[0]!.removeWhere(gone.contains);
      p.changed();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(p.lookupText(gone), isNull);
      page[0]!.addAll(gone); // undone: read again
      p.changed();
      await until(() => text.calls.length >= 3);
      expect(text.calls, hasLength(3));
    });
  });
}
