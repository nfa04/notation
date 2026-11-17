import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/text_crdt.dart';

import 'text_crdt_test.dart' show wire;

/// Takes everything each of [cs] has to every other, until nobody has anything left to say (a link with nothing lost).
void settle(List<TextCrdt> cs) {
  for (var round = 0; round < 10; round++) {
    var any = false;
    for (final c in cs) {
      final d = wire(c.takeChanges());
      if (d == null) continue;
      any = true;
      for (final o in cs) {
        if (!identical(o, c)) o.merge(d);
      }
    }
    if (!any) return;
  }
  fail('the devices never stop sending');
}

/// The tags typed by [typeTag], each exactly once in [text] (none lost, none doubled).
void expectTagsOnce(String text, Iterable<String> tags, {String reason = ''}) {
  for (final t in tags) {
    final n = t.allMatches(text).length;
    expect(n, 1, reason: '$reason: $t is there $n times in "$text"');
  }
}

/// Whether [at] is between two tags (and not in one).
bool _outsideTags(String text, int at) {
  var depth = 0;
  for (var k = 0; k < at; k++) {
    final c = text[k];
    if (c == '[') depth++;
    if (c == ']') depth--;
  }
  return depth == 0;
}

/// A random change that never touches a tag (`[...]`): the tags must all live to the end.
void editAroundTags(TextCrdt c, Random r, Set<String> tags, String name) {
  final text = c.text;
  final kind = r.nextInt(12);
  if (kind < 2) {
    var at = r.nextInt(text.length + 1);
    while (!_outsideTags(text, at)) {
      at--;
    }
    final tag = '[$name${tags.length}]';
    tags.add(tag);
    c.replace(at, 0, tag);
  } else if (kind < 7 || text.isEmpty) {
    var at = r.nextInt(text.length + 1);
    while (!_outsideTags(text, at)) {
      at--;
    }
    c.replace(at, 0, String.fromCharCodes([for (var k = 0; k <= r.nextInt(4); k++) 0x61 + r.nextInt(8)]));
  } else if (kind < 10) {
    final at = r.nextInt(text.length);
    final len = min(1 + r.nextInt(4), text.length - at);
    final cut = text.substring(at, at + len);
    if (RegExp(r'[\[\]A-Z0-9]').hasMatch(cut)) return;
    c.replace(at, len, '');
  } else {
    // formatting: bold on some words, or a colour, or taken away
    final n = c.length;
    if (n < 2) return;
    final a = r.nextInt(n - 1), b = a + 1 + r.nextInt(min(8, n - a - 1));
    final spans = c.spans;
    switch (r.nextInt(3)) {
      case 0:
        c.setSpans([...spans, MarkSpan(a, b, 'bold')]);
      case 1:
        c.setSpans([...spans, MarkSpan(a, b, 'color', ['red', 'blue', 'green'][r.nextInt(3)])]);
      default:
        c.setSpans([for (final s in spans) if (s.end <= a || s.start >= b) s]);
    }
  }
}

void main() {
  final collectAfter = TextCrdt.collectAfter;
  tearDown(() => TextCrdt.collectAfter = collectAfter);

  group('formatting at the same time', () {
    late TextCrdt a, b;
    setUp(() {
      a = TextCrdt('a')..replace(0, 0, 'one two three four');
      b = TextCrdt('b')..merge(wire(a.encode()));
      a.takeChanges();
    });

    test('two people make different words bold: both are bold', () {
      a.setSpans([const MarkSpan(0, 3, 'bold')]);
      b.setSpans([const MarkSpan(8, 13, 'bold')]);
      settle([a, b]);
      expect(a.spans, [const MarkSpan(0, 3, 'bold'), const MarkSpan(8, 13, 'bold')]);
      expect(b.spans, a.spans);
    });

    test('two people make overlapping words bold: one bold stretch, no gap, nothing doubled', () {
      a.setSpans([const MarkSpan(0, 7, 'bold')]);
      b.setSpans([const MarkSpan(4, 13, 'bold')]);
      settle([a, b]);
      expect(a.spans, [const MarkSpan(0, 13, 'bold')]);
      expect(b.spans, a.spans);
    });

    test('taking bold away does not take away bold another person added at the same time (and had not been seen)', () {
      a.setSpans([const MarkSpan(0, 3, 'bold')]);
      settle([a, b]);
      b.setSpans(const []); // b takes the bold of "one" away
      a.setSpans([const MarkSpan(0, 3, 'bold'), const MarkSpan(14, 18, 'bold')]); // while a makes "four" bold
      settle([a, b]);
      expect(a.spans, [const MarkSpan(14, 18, 'bold')]);
      expect(b.spans, a.spans);
    });

    test('taking bold away from part of a word keeps the rest bold', () {
      a.setSpans([const MarkSpan(0, 13, 'bold')]);
      settle([a, b]);
      b.setSpans([const MarkSpan(0, 3, 'bold'), const MarkSpan(8, 13, 'bold')]);
      settle([a, b]);
      expect(a.spans, [const MarkSpan(0, 3, 'bold'), const MarkSpan(8, 13, 'bold')]);
    });

    test('two colours on one word at once: the same colour on both devices, whichever order the changes come in', () {
      final colours = <String?>{};
      for (final aFirst in [true, false]) {
        final x = TextCrdt('x')..replace(0, 0, 'one two');
        final y = TextCrdt('y')..merge(wire(x.encode()));
        x.takeChanges();
        x.setSpans([const MarkSpan(0, 3, 'color', 'red')]);
        y.setSpans([const MarkSpan(0, 3, 'color', 'blue')]);
        final dx = wire(x.takeChanges()), dy = wire(y.takeChanges());
        if (aFirst) {
          y.merge(dx);
          x.merge(dy);
        } else {
          x.merge(dy);
          y.merge(dx);
        }
        expect(x.spans, y.spans);
        expect(x.spans.single.start, 0);
        expect(x.spans.single.end, 3);
        colours.add(x.spans.single.value);
      }
      expect(colours.length, 1);
    });

    test('a colour put on part of a word another person coloured shows both colours, each where it was put', () {
      a.setSpans([const MarkSpan(0, 13, 'color', 'red')]);
      settle([a, b]);
      b.setSpans([const MarkSpan(0, 4, 'color', 'red'), const MarkSpan(4, 7, 'color', 'blue'), const MarkSpan(7, 13, 'color', 'red')]);
      settle([a, b]);
      expect(a.spans, [const MarkSpan(0, 4, 'color', 'red'), const MarkSpan(4, 7, 'color', 'blue'), const MarkSpan(7, 13, 'color', 'red')]);
    });

    test('typing inside or at the end of a bold word makes the new letters bold, before it does not', () {
      a.setSpans([const MarkSpan(4, 7, 'bold')]);
      settle([a, b]);
      b.replace(7, 0, 's'); // "twos"
      b.replace(5, 0, 'X'); // "tXwos"
      b.replace(4, 0, '_'); // before the word
      settle([a, b]);
      expect(a.text, 'one _tXwos three four');
      expect(a.spans, [const MarkSpan(5, 10, 'bold')]);
    });

    test('formatting at the end of the text grows with what is typed at the end', () {
      a.setSpans([const MarkSpan(14, 18, 'italic')]);
      settle([a, b]);
      b.replace(18, 0, '!!');
      settle([a, b]);
      expect(a.spans, [const MarkSpan(14, 20, 'italic')]);
    });

    test('a word is deleted while another makes it bold: nothing is bold, and nothing breaks', () {
      a.replace(4, 4, '');
      b.setSpans([const MarkSpan(4, 7, 'bold')]);
      settle([a, b]);
      expect(a.text, 'one three four');
      expect(a.spans, isEmpty);
      expect(b.spans, isEmpty);
    });

    test('kinds of formatting a device does not know are kept by it and passed on', () {
      a.setSpans([const MarkSpan(0, 3, 'sparkle', 'gold')]); // (made by a newer version of the app)
      settle([a, b]);
      b.replace(0, 0, '> ');
      settle([a, b]);
      expect(a.spans, [const MarkSpan(2, 5, 'sparkle', 'gold')]);
    });

    test('random formatting and typing on 4 devices, changes lost, doubled, reordered: the same formatting everywhere', () {
      for (var seed = 0; seed < 30; seed++) {
        final r = Random(seed);
        final cs = [for (var i = 0; i < 4; i++) TextCrdt('d$i')];
        cs[0].replace(0, 0, 'the quick brown fox jumps over the lazy dog');
        for (var i = 1; i < 4; i++) {
          cs[i].merge(wire(cs[0].encode()));
        }
        cs[0].takeChanges();
        final inbox = [for (var i = 0; i < 4; i++) <Object?>[]];
        final tags = <String>{};
        for (var round = 0; round < 40; round++) {
          for (var i = 0; i < 4; i++) {
            if (r.nextInt(2) == 0) editAroundTags(cs[i], r, tags, 'D$i');
            final d = wire(cs[i].takeChanges());
            if (d == null) continue;
            for (var j = 0; j < 4; j++) {
              if (j == i || r.nextDouble() < 0.3) continue;
              inbox[j].add(d);
              if (r.nextDouble() < 0.2) inbox[j].add(d);
            }
          }
          for (var j = 0; j < 4; j++) {
            inbox[j].shuffle(r);
            for (var k = r.nextInt(inbox[j].length + 1); k > 0; k--) {
              cs[j].merge(inbox[j].removeLast());
            }
          }
        }
        for (var j = 0; j < 4; j++) {
          inbox[j].forEach(cs[j].merge);
        }
        final states = [for (final c in cs) wire(c.encode())];
        for (var j = 0; j < 4; j++) {
          for (var i = 0; i < 4; i++) {
            if (i != j) cs[j].merge(states[i]);
          }
        }
        for (var j = 1; j < 4; j++) {
          expect(cs[j].text, cs[0].text, reason: 'seed $seed');
          expect(cs[j].spans, cs[0].spans, reason: 'seed $seed');
        }
        for (final s in cs[0].spans) {
          expect(s.start < s.end && s.end <= cs[0].length, isTrue, reason: 'seed $seed: $s');
        }
      }
    });
  });

  group('collecting what was deleted', () {
    /// A host and guests, all with the same text, many characters deleted.
    (TextCrdt, List<TextCrdt>) withTombstones({int guests = 2}) {
      TextCrdt.collectAfter = 20;
      final host = TextCrdt('host')..replace(0, 0, 'aaaa bbbb cccc dddd eeee ffff gggg hhhh');
      final gs = [for (var i = 0; i < guests; i++) TextCrdt('g$i')..merge(wire(host.encode()))];
      host.takeChanges();
      host.setSpans([const MarkSpan(0, 4, 'bold'), const MarkSpan(30, 34, 'italic')]);
      settle([host, ...gs]);
      gs[0].replace(5, 10, ''); // bbbb cccc_
      host.replace(25, 5, 'X'); // ffff_
      gs[1 % guests].setSpans(const [MarkSpan(0, 4, 'bold')]); // the italic taken away
      settle([host, ...gs]);
      for (var k = 0; k < 6; k++) {
        gs[0].replace(0, 0, 'zz');
        settle([host, ...gs]);
        gs[0].replace(0, 2, '');
        settle([host, ...gs]);
      }
      return (host, gs);
    }

    test('when everybody is at the same point the host collects, and everybody does the same: no deleted characters are left', () {
      final (host, gs) = withTombstones();
      final text = host.text, spans = host.spans;
      expect(host.deletedCount, greaterThanOrEqualTo(20));
      final reports = [for (final g in gs) g.report()];
      expect(reports, everyElement(isNotNull));
      expect(host.collect(reports), isTrue);
      expect(host.deletedCount, 0);
      expect(host.unmarkedCount, 0);
      settle([host, ...gs]);
      for (final c in [host, ...gs]) {
        expect(c.text, text);
        expect(c.spans, spans);
        expect(c.deletedCount, 0);
        expect(c.epoch, 1);
      }
      // and they go on as before
      gs[0].replace(3, 0, 'Q');
      gs[1].replace(3, 0, 'R');
      host.replace(text.length, 0, '!');
      settle([host, ...gs]);
      expect(gs[0].text, host.text);
      expect(gs[1].text, host.text);
      expect(host.text, contains('!'));
    });

    test('the host does not collect while one guest is not where the others are', () {
      final (host, gs) = withTombstones();
      final reports = [gs[0].report(), null];
      expect(host.collect(reports), isFalse);
      gs[1].replace(0, 0, 'x'); // not sent yet: it cannot say where it is
      expect(gs[1].report(), isNull);
      expect(host.collect([gs[0].report(), gs[1].digest()]), isFalse);
      expect(host.deletedCount, greaterThan(0));
    });

    test('what a guest typed after it said where it was, and sent while the host collected, is not lost', () {
      final (host, gs) = withTombstones();
      final reports = [for (final g in gs) g.report()];
      gs[0].replace(2, 0, '[A]'); // after an edit that left deleted characters around it
      gs[1].replace(gs[1].length, 0, '[B]');
      final fromA = wire(gs[0].takeChanges()), fromB = wire(gs[1].takeChanges());
      expect(host.collect(reports), isTrue);
      final collection = wire(host.takeChanges());
      host
        ..merge(fromA)
        ..merge(fromB);
      gs[1]
        ..merge(fromA)
        ..merge(collection);
      gs[0]
        ..merge(collection)
        ..merge(fromB);
      settle([host, ...gs]);
      for (final c in [host, ...gs]) {
        expect(c.text, host.text);
        expect(c.deletedCount, 0);
        expectTagsOnce(c.text, ['[A]', '[B]']);
      }
    });

    test('a device that was away while the others collected, and typed while away, keeps what it typed', () {
      final (host, gs) = withTombstones(guests: 3);
      final away = gs.removeLast();
      away.replace(7, 0, '[OFF1]');
      away.replace(away.length, 0, '[OFF2]');
      away.replace(0, 3, ''); // a deletion made while away, of characters the others still have
      away.setSpans([...away.spans, const MarkSpan(10, 14, 'underline')]);
      expect(host.collect([for (final g in gs) g.report()]), isTrue);
      settle([host, ...gs]);
      host.replace(0, 0, '[HOST]');
      settle([host, ...gs]);

      // it comes back: it is given the text as it is, and gives its own
      final r = away.merge(wire(host.encode()));
      expect(r.rebased, isTrue);
      host.merge(wire(away.encode()));
      settle([host, away, ...gs]);
      for (final c in [host, away, ...gs]) {
        expect(c.text, host.text);
        expect(c.spans, host.spans);
        expectTagsOnce(c.text, ['[OFF1]', '[OFF2]', '[HOST]']);
        expect(c.epoch, 1);
      }
      expect(host.text, isNot(startsWith('aaa')), reason: 'the deletion made while away is kept');
      expect(host.spans.any((s) => s.type == 'underline'), isTrue);
    });

    test('the same when the device that comes back gives its text first, and then gets the host\'s', () {
      final (host, gs) = withTombstones(guests: 3);
      final away = gs.removeLast();
      away.replace(7, 0, '[OFF1]');
      away.replace(away.length, 0, '[OFF2]');
      expect(host.collect([for (final g in gs) g.report()]), isTrue);
      settle([host, ...gs]);

      final mine = wire(away.encode());
      for (final c in [host, ...gs]) {
        c.merge(mine); // (relayed to all, as the host does)
      }
      away.merge(wire(host.encode()));
      settle([host, away, ...gs]);
      for (final c in [host, away, ...gs]) {
        expect(c.text, host.text);
        expectTagsOnce(c.text, ['[OFF1]', '[OFF2]'], reason: c.site);
      }
    });

    test('a device that comes back twice, or whose text arrives twice, does not double what it typed', () {
      final (host, gs) = withTombstones(guests: 3);
      final away = gs.removeLast();
      away.replace(4, 0, '[OFF]');
      expect(host.collect([for (final g in gs) g.report()]), isTrue);
      settle([host, ...gs]);
      final mine = wire(away.encode());
      for (final c in [host, ...gs]) {
        c.merge(mine); // (relayed to all, as the host does)
      }
      away.merge(wire(host.encode()));
      settle([host, away, ...gs]);
      host.merge(mine); // the old text again, late
      away.merge(wire(host.encode()));
      host.merge(wire(away.encode()));
      settle([host, away, ...gs]);
      for (final c in [host, away, ...gs]) {
        expect(c.text, host.text);
        expectTagsOnce(c.text, ['[OFF]']);
      }
    });

    test('two hosts that each collected apart from the other (the link was cut): both end with one text, nothing doubled', () {
      final (host, gs) = withTombstones(guests: 3);
      // the link is cut: gs[2] becomes the host of the ones on its side
      final other = gs[2];
      host.replace(0, 0, '[H1]');
      other.replace(other.length, 0, '[O1]');
      for (var k = 0; k < 15; k++) {
        host.replace(5, 1, '');
        other.replace(9, 1, '');
      }
      settle([host, gs[0]]);
      settle([other, gs[1]]);
      expect(host.collect([gs[0].report()]), isTrue);
      expect(other.collect([gs[1].report()]), isTrue);
      settle([host, gs[0]]);
      settle([other, gs[1]]);
      host.replace(0, 0, '[H2]');
      other.replace(0, 0, '[O2]');
      settle([host, gs[0]]);
      settle([other, gs[1]]);
      expect(host.epoch, other.epoch);

      // the link is back: each side gives all of its text to the other, in both orders
      final h = wire(host.encode()), o = wire(other.encode());
      for (final c in [other, gs[1]]) {
        c.merge(h);
      }
      for (final c in [host, gs[0]]) {
        c.merge(o);
      }
      settle([host, ...gs]);
      final hs = wire(host.encode());
      for (final c in gs) {
        c.merge(hs);
      }
      for (final c in gs) {
        host.merge(wire(c.encode()));
      }
      settle([host, ...gs]);
      for (final c in [host, ...gs]) {
        expect(c.text, host.text, reason: c.site);
        expectTagsOnce(c.text, ['[H1]', '[H2]', '[O1]', '[O2]'], reason: c.site);
      }
    });

    test('after two hosts collected apart, somebody deletes words of which both devices of one side made a copy: gone everywhere', () {
      for (final deleter in [0, 1]) {
        final (host, gs) = withTombstones(guests: 3);
        final other = gs[2];
        host.replace(0, 0, '[H1]');
        other.replace(other.length, 0, '[O1]');
        for (var k = 0; k < 15; k++) {
          host.replace(5, 1, '');
          other.replace(9, 1, '');
        }
        settle([host, gs[0]]);
        settle([other, gs[1]]);
        expect(host.collect([gs[0].report()]), isTrue);
        expect(other.collect([gs[1].report()]), isTrue);
        settle([host, gs[0]]);
        settle([other, gs[1]]);

        final h = wire(host.encode()), o = wire(other.encode());
        final otherSide = [for (final c in [other, gs[1]]) c.merge(h).rebased];
        final hostSide = [for (final c in [host, gs[0]]) c.merge(o).rebased];
        // one side made the text again from the other's, both of its devices: each has its own copy of the words of its side
        final losers = otherSide.every((x) => x) ? [other, gs[1]] : [host, gs[0]];
        expect(otherSide.every((x) => x) != hostSide.every((x) => x), isTrue);
        final tag = identical(losers[0], other) ? '[O1]' : '[H1]';
        final who = losers[deleter];
        final at = who.text.indexOf(tag);
        who.replace(at, tag.length, ''); // a person deletes the words, in the copy they see

        settle([host, ...gs]);
        final hs = wire(host.encode());
        for (final c in gs) {
          c.merge(hs);
        }
        for (final c in gs) {
          host.merge(wire(c.encode()));
        }
        settle([host, ...gs]);
        for (final c in [host, ...gs]) {
          expect(c.text, host.text, reason: c.site);
          expect(c.text, isNot(contains(tag)), reason: '${c.site}: the words were deleted');
          expectTagsOnce(c.text, [if (tag != '[H1]') '[H1]', if (tag != '[O1]') '[O1]'], reason: c.site);
        }
      }
    });

    test('a host started again from an older saved text, two guests that both have what was written since: nothing doubled or lost', () {
      final old = TextCrdt('old')..replace(0, 0, 'one two');
      final a = TextCrdt('a')..merge(wire(old.encode()));
      final b = TextCrdt('b')..merge(wire(old.encode()));
      old.takeChanges();
      a.replace(7, 0, ' three'); // written after the host saved the note last
      a.setSpans([const MarkSpan(4, 7, 'bold')]);
      settle([old, a, b]);
      // the host app is gone; meanwhile each guest writes
      a.replace(0, 0, '[A]');
      b.replace(b.length, 0, '[B]');
      settle([a, b]); // (both have all of it: both type all of it into the new text below, and it must be there once)
      final host = TextCrdt('new')..replace(0, 0, 'one two'); // started again, from the saved note
      host.takeChanges();
      final h = wire(host.encode());
      expect(a.adoptUnrelated(h).rebased, isTrue);
      expect(b.adoptUnrelated(h).rebased, isTrue);
      settle([host, a, b]);
      for (final c in [host, a, b]) {
        expect(c.text, '[A]one two three[B]', reason: c.site);
        expect(c.spans, [const MarkSpan(7, 10, 'bold')], reason: c.site);
      }
      // and it goes on as one text
      host.replace(3, 0, '>');
      b.replace(b.length, 0, '!');
      settle([host, a, b]);
      expect(a.text, '[A]>one two three[B]!');
      expect(b.text, a.text);
    });

    test('words typed after a character that the others deleted and collected: nothing waits for it forever, the host collects again', () {
      final (host, gs) = withTombstones(guests: 3);
      final away = gs.removeLast();
      final at = host.text.indexOf('eeee');
      away.replace(at + 2, 0, '[OFF]'); // after an "e" ...
      host.replace(at, 4, ''); // ... that the others delete
      settle([host, ...gs]);
      expect(host.collect([for (final g in gs) g.report()]), isTrue);
      settle([host, ...gs]);

      final r = host.merge(wire(away.encode())); // its old text comes first
      expect(r.lost, greaterThanOrEqualTo(5));
      expect(host.waiting, 0, reason: 'what comes after a lost character is lost too, not waiting');
      away.merge(wire(host.encode()));
      settle([host, away, ...gs]);
      for (final c in [host, away, ...gs]) {
        expect(c.text, host.text);
        expectTagsOnce(c.text, ['[OFF]']);
      }
      // the host can say again that it is settled, and collect
      host.replace(0, 3, '');
      settle([host, away, ...gs]);
      TextCrdt.collectAfter = 1;
      expect(host.collect([for (final g in [away, ...gs]) g.report()]), isTrue);
      settle([host, away, ...gs]);
      expect(away.text, host.text);
      expect(away.deletedCount, 0);
    });

    test('a change that comes after the collection and refers to a collected character is told as lost, not taken wrongly', () {
      final (host, gs) = withTombstones();
      final stale = wire(gs[0].encode()); // the text from before the collection, as a device that was away has it
      expect(host.collect([for (final g in gs) g.report()]), isTrue);
      final before = host.text;
      final r = host.merge(stale);
      expect(host.text, before);
      expect(r.malformed, isFalse);
    });

    test('deleted formatting and characters are counted, and after a collection they are gone', () {
      final (host, gs) = withTombstones();
      expect(host.unmarkedCount, greaterThan(0));
      final marks = host.markCount;
      host.collect([for (final g in gs) g.report()]);
      expect(host.unmarkedCount, 0);
      expect(host.markCount, lessThanOrEqualTo(marks));
      expect(host.encode().toString().length, lessThan(wire(gs[0].encode()).toString().length));
    });

    /// A host and guests over links that lose, double and reorder what they carry; guests go away for a while (typing all along) and
    /// come back; the host collects whenever every guest that is there says it is where the host is. Every tag typed is there exactly
    /// once in the end, on every device, and the deleted characters are collected.
    ///
    /// A link that loses something is a link that dropped (what a data channel does): the guest is away until it comes back, and then
    /// both sides give each other all of their text. [loss]: how often a message is lost so; [twice]: doubled (as after a resume).
    void chaos(int seed, {int guests = 4, int rounds = 200, double loss = 0.02, double twice = 0.15, double awayChance = 0.02}) {
      TextCrdt.collectAfter = 25;
      final r = Random(seed);
      final host = TextCrdt('host')..replace(0, 0, 'a shared text to start from');
      final gs = [for (var i = 0; i < guests; i++) TextCrdt('g$i')..merge(wire(host.encode()))];
      host.takeChanges();
      final all = [host, ...gs];
      final tags = <String>{};
      final away = List.filled(guests, false);
      final toHost = [for (var i = 0; i < guests; i++) <Map<String, Object?>>[]];
      final toGuest = [for (var i = 0; i < guests; i++) <Object?>[]];
      final reports = <int, int>{};
      var collections = 0;

      void drop(int i) {
        // (what was on the way over the link is lost with it, both ways: a closed channel delivers nothing after)
        away[i] = true;
        reports.remove(i);
        toHost[i].clear();
        toGuest[i].clear();
      }

      void send(int guest, List<Object?> box, Object? m) {
        if (r.nextDouble() < loss) return drop(guest);
        box.add(m);
        if (r.nextDouble() < twice) box.add(m);
      }

      void comeBack(int i) {
        away[i] = false;
        toGuest[i].clear();
        // (the resume: one side gives all of its text, then the other, in either order)
        if (r.nextBool()) {
          gs[i].merge(wire(host.encode()));
          toHost[i].add({'tc': wire(gs[i].encode())});
        } else {
          toHost[i].add({'tc': wire(gs[i].encode())});
          gs[i].merge(wire(host.encode()));
        }
      }

      for (var round = 0; round < rounds; round++) {
        // people stop typing now and then: what is on the way arrives
        final quiet = round % 25 >= 18;
        int some(int n) => quiet ? n : r.nextInt(n + 1);
        for (var k = 0; k < all.length; k++) {
          if (!quiet && r.nextInt(3) == 0) editAroundTags(all[k], r, tags, k == 0 ? 'H' : 'G$k');
        }
        for (var i = 0; i < guests; i++) {
          if (away[i]) {
            if (r.nextDouble() < 0.15) comeBack(i);
            continue;
          }
          if (r.nextDouble() < awayChance) {
            drop(i);
            continue;
          }
          final d = wire(gs[i].takeChanges());
          if (d != null) send(i, toHost[i], {'tc': d});
          final h = gs[i].report();
          if (h != null && !away[i]) send(i, toHost[i], {'seen': h});
        }
        // the host takes what came - from each guest in the order it was sent (a data channel keeps it), from the guests in any order -
        // and passes the changes on
        for (var k = some(toHost.fold(0, (n, q) => n + q.length)); k > 0; k--) {
          final senders = [for (var i = 0; i < guests; i++) if (toHost[i].isNotEmpty) i];
          if (senders.isEmpty) break;
          final from = senders[r.nextInt(senders.length)];
          final m = toHost[from].removeAt(0);
          if (m['seen'] case final int h) {
            reports[from] = h;
            continue;
          }
          host.merge(m['tc']);
          for (var j = 0; j < guests; j++) {
            if (j != from && !away[j]) send(j, toGuest[j], m['tc']);
          }
        }
        final present = [for (var i = 0; i < guests; i++) if (!away[i]) i];
        if (host.collect([for (final i in present) reports[i]])) {
          collections++;
          reports.clear();
        }
        final own = wire(host.takeChanges()) as Map?;
        if (own != null) {
          for (final i in present) {
            send(i, toGuest[i], own);
          }
        }
        for (final i in present) {
          if (away[i]) continue;
          for (var k = some(toGuest[i].length); k > 0; k--) {
            gs[i].merge(toGuest[i].removeAt(0));
          }
        }
      }

      // everybody comes back, and the links lose nothing any more
      for (var i = 0; i < guests; i++) {
        if (away[i]) comeBack(i);
      }
      for (final q in toHost) {
        for (final m in q) {
          if (m['tc'] != null) host.merge(m['tc']);
        }
      }
      for (var i = 0; i < guests; i++) {
        toGuest[i].forEach(gs[i].merge);
      }
      for (var pass = 0; pass < 2; pass++) {
        for (final g in gs) {
          host.merge(wire(g.encode()));
        }
        final s = wire(host.encode());
        for (final g in gs) {
          g.merge(s);
        }
        settle(all);
      }
      for (final c in all) {
        expect(c.text, host.text, reason: 'seed $seed: ${c.site}');
        expect(c.spans, host.spans, reason: 'seed $seed: ${c.site}');
        expect(c.waiting, 0, reason: 'seed $seed: ${c.site}');
        expectTagsOnce(c.text, tags, reason: 'seed $seed: ${c.site}');
      }
      // a last collection, now that everybody is there (whatever is left)
      TextCrdt.collectAfter = 1;
      if (host.worthCollecting) {
        expect(host.collect([for (final g in gs) g.report()]), isTrue, reason: 'seed $seed');
        settle(all);
      }
      for (final c in all) {
        expect(c.text, host.text, reason: 'seed $seed: ${c.site}');
        if (c.deletedCount != 0) {
          // ignore: avoid_print
          print('DBG seed $seed ${c.site} dead ${c.deletedCount} epoch ${c.epoch} host epoch ${host.epoch} hostdead ${host.deletedCount} waiting ${c.waiting} hasChanges ${c.hasChanges}');
        }
        expect(c.deletedCount, 0, reason: 'seed $seed: ${c.site}');
        expect(c.epoch, host.epoch, reason: 'seed $seed: ${c.site}');
      }
      if (loss < 0.08) expect(collections, greaterThan(0), reason: 'seed $seed: the host never collected while they typed');
    }

    for (var seed = 0; seed < 30; seed++) {
      test('host and 4 guests, links that lose, double and reorder, guests away and back (seed $seed)', () => chaos(seed));
    }
    test('8 guests, links that drop all the time', () => chaos(1000, guests: 8, rounds: 300, loss: 0.1, awayChance: 0.08));
    for (var seed = 3000; seed < 3005; seed++) {
      test('2 guests, long, links that drop often (seed $seed)', () => chaos(seed, guests: 2, rounds: 600, loss: 0.05, awayChance: 0.05));
    }
    test('nothing lost, nobody away: the host collects many times', () {
      chaos(2000, rounds: 300, loss: 0, twice: 0, awayChance: 0);
    });
  });
}
