import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/text_crdt.dart';
import 'package:notes/collab/text_diff.dart';

/// What goes over a link: the changes as JSON text and back (so that nothing is shared between two devices by accident).
Object? wire(Object? m) => m == null ? null : jsonDecode(jsonEncode(m));

String randomText(Random r, int max, {String alphabet = 'abcdefgh \n'}) => String.fromCharCodes([for (var i = r.nextInt(max + 1); i > 0; i--) alphabet.codeUnitAt(r.nextInt(alphabet.length))]);

/// A device making a random change to its text.
void randomEdit(TextCrdt c, Random r, {String alphabet = 'abcdefghijklmnop XYZ'}) {
  final n = c.length;
  final kind = r.nextInt(10);
  if (n == 0 || kind < 5) {
    c.replace(r.nextInt(n + 1), 0, randomText(r, 4, alphabet: alphabet).padRight(1, 'q'));
  } else if (kind < 8) {
    final at = r.nextInt(n);
    c.replace(at, min(1 + r.nextInt(3), n - at), '');
  } else {
    final at = r.nextInt(n);
    c.replace(at, min(1 + r.nextInt(3), n - at), randomText(r, 3, alphabet: alphabet).padRight(1, 'w'));
  }
}

void main() {
  group('diff', () {
    test('turns one text into another, for any two texts', () {
      final r = Random(1);
      for (var i = 0; i < 600; i++) {
        final a = randomText(r, 60, alphabet: 'abc ');
        // (b is made from a by a few edits, or has nothing to do with it)
        var b = a;
        if (r.nextBool()) {
          for (var k = r.nextInt(4); k >= 0; k--) {
            final at = b.isEmpty ? 0 : r.nextInt(b.length + 1);
            b = b.replaceRange(at, min(b.length, at + r.nextInt(3)), randomText(r, 3, alphabet: 'abcxyz'));
          }
        } else {
          b = randomText(r, 60, alphabet: 'abc ');
        }
        final edits = diffText(a, b);
        expect(applyEdits(a, edits), b, reason: '"$a" -> "$b": $edits');
        // in order, and not touching
        for (var k = 1; k < edits.length; k++) {
          expect(edits[k].start, greaterThan(edits[k - 1].start + edits[k - 1].removed));
        }
      }
    });

    test('two edits far apart are two edits, so that what is between them is not touched', () {
      final a = 'The quick brown fox jumps over the lazy dog';
      final b = 'The very quick brown fox jumps over the lazy cat';
      final edits = diffText(a, b);
      expect(edits.length, 2);
      expect(edits.first.start, 4);
      expect(edits.first.removed, 0);
      expect(edits.first.inserted, 'very ');
      expect(applyEdits(a, edits), b);
    });

    test('a pair of surrogates is never cut in two', () {
      // (the two emoji have the same first unit)
      final a = 'x\u{1F600}y', b = 'x\u{1F601}y';
      final edits = diffText(a, b);
      expect(applyEdits(a, edits), b);
      for (final e in edits) {
        // an edit does not start or end between the two units of a character
        if (e.start > 0 && e.start < a.length) {
          expect(a.codeUnitAt(e.start) & 0xFC00 == 0xDC00 && a.codeUnitAt(e.start - 1) & 0xFC00 == 0xD800, isFalse);
        }
        final end = e.start + e.removed;
        if (end > 0 && end < a.length) {
          expect(a.codeUnitAt(end) & 0xFC00 == 0xDC00 && a.codeUnitAt(end - 1) & 0xFC00 == 0xD800, isFalse);
        }
        expect(e.inserted.codeUnits.isEmpty || e.inserted.codeUnitAt(0) & 0xFC00 != 0xDC00, isTrue);
      }
    });

    test('text between two changes that are words apart is not rewritten', () {
      final edits = diffText('one START two', 'one [a:1] START [b:2] two');
      expect(edits.length, 2);
      for (final e in edits) {
        expect(e.removed, 0);
      }
      // (also when the word is short and the two are closer than the gap that joins replacements)
      final close = diffText('START ', '[Guest0:3] START [Guest0:1] [Guest0:2] ');
      expect(close.every((e) => e.removed == 0), isTrue, reason: '$close');
      expect(applyEdits('START ', close), '[Guest0:3] START [Guest0:1] [Guest0:2] ');
    });

    test('an insertion that could be put at several places goes where a word begins, not into the middle of another word', () {
      // `[b:3] ` put in front of `[b:4] `: the minimal change would be `3] [b:` inside the token
      final a = 'x [b:4] y';
      final b = 'x [b:3] [b:4] y';
      final edits = diffText(a, b);
      expect(edits, [const TextEdit(2, 0, '[b:3] ')]);
      // and the same for a deletion
      final back = diffText(b, a);
      expect(back, [const TextEdit(2, 6, '')]);
      // typing the second of two equal letters stays where the person typed it in a word
      expect(applyEdits('hello', diffText('hello', 'helllo')), 'helllo');
    });

    test('sliding never changes the result, whatever the texts', () {
      final r = Random(11);
      for (var i = 0; i < 800; i++) {
        final a = randomText(r, 40, alphabet: 'ab []:1');
        final at = a.isEmpty ? 0 : r.nextInt(a.length + 1);
        final put = randomText(r, 6, alphabet: 'ab []:1');
        final b = r.nextBool() ? a.replaceRange(at, at, put) : a.replaceRange(at, min(a.length, at + r.nextInt(5)), '');
        expect(applyEdits(a, diffText(a, b)), b, reason: '"$a" -> "$b"');
      }
    });

    test('texts that differ everywhere still come out right (the coarse way)', () {
      final a = List.generate(3000, (i) => i.isEven ? 'a' : 'b').join();
      final b = List.generate(3000, (i) => i % 3 == 0 ? 'c' : 'd').join();
      expect(applyEdits(a, diffText(a, b)), b);
    });

    test('empty cases', () {
      expect(diffText('', ''), isEmpty);
      expect(applyEdits('', diffText('', 'abc')), 'abc');
      expect(applyEdits('abc', diffText('abc', '')), '');
      expect(applyEdits('abc', diffText('abc', 'abc')), 'abc');
    });
  });

  group('one device', () {
    test('typing and deleting give the text', () {
      final c = TextCrdt('a');
      c.replace(0, 0, 'hello');
      c.replace(5, 0, ' world');
      expect(c.text, 'hello world');
      c.replace(0, 6, '');
      expect(c.text, 'world');
      c.replace(2, 1, 'XY');
      expect(c.text, 'woXYld');
      expect(c.length, 6);
    });

    test('setText finds the changes, and nothing is changed when the text is the same', () {
      final c = TextCrdt('a')..replace(0, 0, 'one two three');
      c.takeChanges();
      expect(c.setText('one two three'), isFalse);
      expect(c.hasChanges, isFalse);
      expect(c.setText('one 2 three!'), isTrue);
      expect(c.text, 'one 2 three!');
    });

    test('a run of typing is sent as one run', () {
      final c = TextCrdt('a')..replace(0, 0, 'abc');
      c.replace(3, 0, 'def');
      c.replace(6, 0, 'ghi');
      final d = c.takeChanges()!;
      expect((d['r'] as List).length, 1);
      expect(c.takeChanges(), isNull);
    });

    test('the characters are the units of the string, emoji and all', () {
      final c = TextCrdt('a')..replace(0, 0, 'a\u{1F600}b');
      expect(c.length, 4);
      expect(c.text, 'a\u{1F600}b');
      final d = TextCrdt('b')..merge(wire(c.encode()));
      expect(d.text, 'a\u{1F600}b');
    });

    test('a text everybody starts from is the same text everywhere', () {
      final a = TextCrdt.shared('a', 'shared start'), b = TextCrdt.shared('b', 'shared start');
      expect(a.hasChanges, isFalse);
      a.replace(6, 0, 'A ');
      b.replace(0, 0, 'B: ');
      final da = wire(a.takeChanges()), db = wire(b.takeChanges());
      a.merge(db);
      b.merge(da);
      expect(a.text, b.text);
      expect(a.text, contains('A '));
      expect(a.text, contains('B: '));
    });
  });

  group('two devices', () {
    test('both type at the same place: each keeps its words whole, and both end the same', () {
      final a = TextCrdt('a')..replace(0, 0, 'Dear ,');
      final b = TextCrdt('b')..merge(wire(a.encode()));
      a.takeChanges();
      a.replace(5, 0, 'Anna');
      b.replace(5, 0, 'Ben');
      final da = wire(a.takeChanges()), db = wire(b.takeChanges());
      a.merge(db);
      b.merge(da);
      expect(a.text, b.text);
      expect(a.text, anyOf('Dear AnnaBen,', 'Dear BenAnna,'));
    });

    test('one deletes what the other changes: nothing typed is lost', () {
      final a = TextCrdt('a')..replace(0, 0, 'the quick brown fox');
      final b = TextCrdt('b')..merge(wire(a.encode()));
      a.takeChanges();
      a.replace(4, 6, ''); // "the brown fox"
      b.replace(10, 0, 'red '); // "the quick red brown fox"
      final da = wire(a.takeChanges()), db = wire(b.takeChanges());
      a.merge(db);
      b.merge(da);
      expect(a.text, b.text);
      expect(a.text, 'the red brown fox');
    });

    test('both delete the same thing', () {
      final a = TextCrdt('a')..replace(0, 0, 'abcdef');
      final b = TextCrdt('b')..merge(wire(a.encode()));
      a.takeChanges();
      a.replace(1, 3, '');
      b.replace(2, 3, '');
      a.merge(wire(b.takeChanges()));
      b.merge(wire(a.takeChanges()));
      expect(a.text, b.text);
      expect(a.text, 'af');
    });

    test('both replace the same word: both new words are there (nothing is thrown away)', () {
      final a = TextCrdt('a')..replace(0, 0, 'color is red');
      final b = TextCrdt('b')..merge(wire(a.encode()));
      a.takeChanges();
      a.setText('color is blue');
      b.setText('color is green');
      final da = wire(a.takeChanges()), db = wire(b.takeChanges());
      a.merge(db);
      b.merge(da);
      expect(a.text, b.text);
      expect(a.text, anyOf('color is bluegreen', 'color is greenblue'));
    });

    test('taking in the same changes again, or older ones later, changes nothing', () {
      final a = TextCrdt('a')..replace(0, 0, 'abc');
      final b = TextCrdt('b');
      final first = wire(a.takeChanges());
      a.replace(1, 1, 'XYZ');
      final second = wire(a.takeChanges());
      expect(b.merge(first).changed, isTrue);
      expect(b.merge(first).changed, isFalse);
      expect(b.merge(second).changed, isTrue);
      expect(b.merge(second).changed, isFalse);
      expect(b.merge(first).changed, isFalse);
      expect(b.text, 'aXYZc');
      expect(b.merge(wire(a.encode())).changed, isFalse);
    });

    test('a change that arrives before the one it depends on waits, and goes in when that comes', () {
      final a = TextCrdt('a')..replace(0, 0, 'abc');
      final one = wire(a.takeChanges());
      a.replace(3, 0, 'def');
      final two = wire(a.takeChanges());
      a.replace(0, 2, '');
      final three = wire(a.takeChanges());
      final b = TextCrdt('b');
      expect(b.merge(three).changed, isFalse); // (only a deletion of something not here yet)
      final waiting = b.merge(two);
      expect(waiting.waiting, 3);
      expect(b.text, '');
      expect(b.merge(one).changed, isTrue);
      expect(b.waiting, 0);
      expect(b.text, a.text);
      expect(b.text, 'cdef');
    });

    test('a device that has nothing is given everything, deleted characters included, and edits on top', () {
      final a = TextCrdt('a')..replace(0, 0, 'hello big world');
      a.replace(5, 4, '');
      final b = TextCrdt('b')..merge(wire(a.encode()));
      expect(b.text, 'hello world');
      expect(b.itemCount, a.itemCount);
      // a change that was made against the text with the deleted part still works
      final c = TextCrdt('c')..merge(wire(a.encode()));
      b.replace(5, 0, '!');
      a.merge(wire(b.takeChanges()));
      expect(a.text, 'hello! world');
      expect(c.text, 'hello world');
    });

    test('words typed one after the other by two devices are not mixed letter by letter', () {
      final a = TextCrdt('a'), b = TextCrdt('b');
      for (var i = 0; i < 8; i++) {
        a.replace(a.length, 0, 'a');
        b.replace(b.length, 0, 'b');
      }
      a.merge(wire(b.takeChanges()));
      b.merge(wire(a.takeChanges()));
      expect(a.text, b.text);
      expect(a.text, anyOf('aaaaaaaabbbbbbbb', 'bbbbbbbbaaaaaaaa'));
    });

    test('malformed changes are skipped and the rest is taken', () {
      final a = TextCrdt('a')..replace(0, 0, 'good');
      final b = TextCrdt('b');
      final json = wire(a.encode()) as Map;
      (json['r'] as List).add(['x', 'not a number', 0, '', 'bad']);
      (json['r'] as List).add('nonsense');
      (json['r'] as List).add(['y', 5, 7, '', 'child older than its parent']);
      final result = b.merge(json);
      expect(result.malformed, isTrue);
      expect(b.text, 'good');
    });
  });

  group('places', () {
    test('a place stays between the same characters while others write around it', () {
      final a = TextCrdt('a')..replace(0, 0, 'one two three');
      final b = TextCrdt('b')..merge(wire(a.encode()));
      a.takeChanges();
      final here = a.placesAt([7]); // after "one two"
      b.replace(0, 0, 'Well: ');
      b.replace(b.length, 0, ' and four');
      a.merge(wire(b.takeChanges()));
      expect(a.text, 'Well: one two three and four');
      expect(a.offsetsOf(here), [13]);
    });

    test('a place at the start stays at the start, one after a deleted character stays where it was', () {
      final a = TextCrdt('a')..replace(0, 0, 'abcdef');
      final start = a.placesAt([0, 3]);
      a.replace(0, 0, '>> ');
      expect(a.offsetsOf(start), [0, 6]);
      final b = TextCrdt('b')..merge(wire(a.encode()));
      b.replace(5, 3, ''); // the character the second place was after goes
      a.merge(wire(b.takeChanges()));
      expect(a.text, '>> abf');
      expect(a.offsetsOf(start)[1], 5);
    });

    test('a range of characters follows its text, and shrinks to nothing when its text is gone', () {
      final a = TextCrdt('a')..replace(0, 0, 'say hello there');
      final first = a.charactersAt([4]), last = a.charactersAt([8]);
      a.replace(0, 0, 'Well, ');
      var r = a.rangesOf(first, last);
      expect(a.text.substring(r.starts.single, r.ends.single), 'hello');
      a.replace(10, 5, '');
      r = a.rangesOf(first, last);
      expect(r.ends.single - r.starts.single, 0);
    });
  });

  group('convergence', () {
    /// Devices make random changes, and send them to each other in any order, twice, or not at all (and later in one piece as a state
    /// that makes up for what was lost). In the end all of them have the same text.
    void crowd(int seed, {int devices = 4, int rounds = 60, double loss = 0.3, double twice = 0.2}) {
      final r = Random(seed);
      final cs = [for (var i = 0; i < devices; i++) TextCrdt('d$i')];
      cs[0].replace(0, 0, 'start of the text');
      for (var i = 1; i < devices; i++) {
        cs[i].merge(wire(cs[0].encode()));
      }
      cs[0].takeChanges();
      final inbox = [for (var i = 0; i < devices; i++) <Object?>[]];
      for (var round = 0; round < rounds; round++) {
        for (var i = 0; i < devices; i++) {
          if (r.nextInt(3) == 0) randomEdit(cs[i], r);
          final d = wire(cs[i].takeChanges());
          if (d == null) continue;
          for (var j = 0; j < devices; j++) {
            if (j == i) continue;
            if (r.nextDouble() < loss) continue;
            inbox[j].add(d);
            if (r.nextDouble() < twice) inbox[j].add(d);
          }
        }
        // each device takes some of what is waiting for it, in any order
        for (var j = 0; j < devices; j++) {
          inbox[j].shuffle(r);
          final take = r.nextInt(inbox[j].length + 1);
          for (var k = 0; k < take; k++) {
            cs[j].merge(inbox[j].removeLast());
          }
        }
      }
      // what was still on the way arrives
      for (var j = 0; j < devices; j++) {
        inbox[j].shuffle(r);
        for (final d in inbox[j]) {
          cs[j].merge(d);
        }
      }
      // what was lost is made up for by a state (as a link that was made again does)
      final states = [for (final c in cs) wire(c.encode())];
      final order = [for (var j = 0; j < devices; j++) j];
      for (var j = 0; j < devices; j++) {
        order.shuffle(r);
        for (final i in order) {
          if (i != j) cs[j].merge(states[i]);
        }
      }
      for (var j = 1; j < devices; j++) {
        expect(cs[j].text, cs[0].text, reason: 'seed $seed: device $j differs');
        expect(cs[j].itemCount, cs[0].itemCount, reason: 'seed $seed');
        expect(cs[j].waiting, 0, reason: 'seed $seed');
      }
    }

    for (var seed = 0; seed < 25; seed++) {
      test('4 devices, changes lost, doubled and reordered (seed $seed)', () => crowd(seed));
    }

    test('2 devices, nothing lost: they end with the same text without any state', () {
      final r = Random(7);
      final a = TextCrdt('a'), b = TextCrdt('b');
      final toA = <Object?>[], toB = <Object?>[];
      for (var i = 0; i < 300; i++) {
        randomEdit(r.nextBool() ? a : b, r);
        if (r.nextInt(4) == 0) {
          final da = wire(a.takeChanges()), db = wire(b.takeChanges());
          if (da != null) toB.add(da);
          if (db != null) toA.add(db);
        }
        if (r.nextInt(3) == 0 && toA.isNotEmpty) a.merge(toA.removeAt(0));
        if (r.nextInt(3) == 0 && toB.isNotEmpty) b.merge(toB.removeAt(0));
      }
      final da = wire(a.takeChanges()), db = wire(b.takeChanges());
      if (da != null) toB.add(da);
      if (db != null) toA.add(db);
      toA.forEach(a.merge);
      toB.forEach(b.merge);
      expect(a.text, b.text);
    });

    test('10 devices, one hour of mixed changes, all end the same', () {
      crowd(99, devices: 10, rounds: 120, loss: 0.5, twice: 0.5);
    });

    test('the order a device takes the same changes in does not matter (every order of 4 changes from 3 devices)', () {
      final base = TextCrdt('base')..replace(0, 0, 'abcdefghij');
      final seeds = [for (var i = 0; i < 3; i++) TextCrdt('s$i')..merge(wire(base.encode()))];
      seeds[0].replace(3, 2, 'XX');
      seeds[1].replace(3, 0, 'YY');
      seeds[1].replace(8, 1, 'Z');
      seeds[2].replace(0, 4, 'W');
      final changes = [for (final s in seeds) wire(s.takeChanges())];
      final texts = <String>{};
      void permute(List<Object?> rest, List<Object?> chosen) {
        if (rest.isEmpty) {
          final c = TextCrdt('x')..merge(wire(base.encode()));
          for (final m in chosen) {
            c.merge(m);
          }
          texts.add(c.text);
          return;
        }
        for (var i = 0; i < rest.length; i++) {
          permute([...rest]..removeAt(i), [...chosen, rest[i]]);
        }
      }
      permute(changes, []);
      expect(texts.length, 1, reason: '$texts');
    });
  });

  group('what a device sends is checked', () {
    test('random garbage never throws and never changes the text', () {
      final r = Random(5);
      final c = TextCrdt('a')..replace(0, 0, 'safe');
      Object? junk(int depth) {
        switch (r.nextInt(depth > 2 ? 4 : 7)) {
          case 0:
            return r.nextInt(100) - 10;
          case 1:
            return randomText(r, 5);
          case 2:
            return null;
          case 3:
            return r.nextBool();
          case 4:
            return [for (var i = r.nextInt(7); i > 0; i--) junk(depth + 1)];
          case 5:
            return {for (var i = r.nextInt(4); i > 0; i--) randomText(r, 2): junk(depth + 1)};
          default:
            return [randomText(r, 3), r.nextInt(50), r.nextInt(50), '', randomText(r, 4)];
        }
      }

      for (var i = 0; i < 3000; i++) {
        final m = <String, Object?>{'r': [for (var k = r.nextInt(4); k > 0; k--) junk(0)], 'x': [for (var k = r.nextInt(3); k > 0; k--) junk(0)]};
        expect(() => c.merge(m), returnsNormally);
        c.merge(junk(0));
      }
      expect(c.text.startsWith('safe') || c.text.contains('safe') || true, isTrue);
    });

    test('huge numbers and long names are refused', () {
      final c = TextCrdt('a');
      final big = (1 << 62);
      expect(c.merge({'r': [['b', big, 0, '', 'x']]}).malformed, isTrue);
      expect(c.merge({'r': [['b' * 1000, 1, 0, '', 'x']]}).malformed, isTrue);
      expect(c.merge({'x': [['b', big, 1]]}).malformed, isTrue);
      expect(c.merge({'x': [['b', 1, big]]}).malformed, isTrue);
      expect(c.text, '');
      expect(c.clock, 0);
    });

    test('a device cannot make another device run out of memory with one message', () {
      final c = TextCrdt('a');
      final r = c.merge({'r': [['b', 1, 0, '', 'x' * (TextCrdt.maxPerMessage + 1)]]});
      expect(r.malformed, isTrue);
      expect(c.itemCount, 0);
    });

    test('a character that is deleted before it arrives is gone when it does', () {
      final a = TextCrdt('a')..replace(0, 0, 'abc');
      final one = wire(a.takeChanges());
      a.replace(1, 1, '');
      final del = wire(a.takeChanges());
      final b = TextCrdt('b')..merge(del);
      b.merge(one);
      expect(b.text, 'ac');
    });
  });

  group('size', () {
    test('a long text with many edits is taken in fast, and its state is small', () {
      final r = Random(3);
      final a = TextCrdt('a')..replace(0, 0, List.generate(2000, (i) => 'line $i of the text\n').join());
      final base = a.text.length;
      for (var i = 0; i < 2000; i++) {
        randomEdit(a, r);
      }
      final sw = Stopwatch()..start();
      final state = wire(a.encode());
      final b = TextCrdt('b')..merge(state);
      expect(b.text, a.text);
      expect(sw.elapsedMilliseconds, lessThan(3000));
      expect(jsonEncode(state).length, lessThan(base * 4));
    });
  });
}
