import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/wet_ink.dart';
import 'package:notes/models/canvas_models.dart';

/// A message as it arrives: through JSON.
Map<String, Object?> wire(Map<String, Object?> m) => (jsonDecode(jsonEncode(m)) as Map).cast<String, Object?>();

DrawingStroke line(String id, {int points = 3}) =>
    DrawingStroke(id: id, color: Colors.red, width: 4, points: [for (var i = 0; i < points; i++) Offset(i * 2.0, i * 3.0)]);

void grow(DrawingStroke s, int more) {
  for (var i = 0; i < more; i++) {
    final n = s.points.length;
    s.points.add(Offset(n * 2.0, n * 3.0));
  }
}

void main() {
  late DateTime now;
  setUp(() => now = DateTime(2026, 11, 17, 12));

  WetBook book() => WetBook(now: () => now);

  /// Everything [lane] has to send now from [from] to [to].
  int deliver(WetLane lane, WetBook from, WetBook to, {String? except, String? only}) {
    var n = 0;
    while (true) {
      final m = lane.next(from, except: except, only: only, now: now);
      if (m == null) return n;
      to.take(wire(m));
      n++;
    }
  }

  group('a line being drawn', () {
    test('grows on the other device as the pen moves, with only the new points sent each time', () {
      final here = book(), there = book();
      final lane = WetLane();
      final s = line('s1');
      here.drawing('a', 2, s);
      final first = lane.next(here, now: now)!;
      expect(first['f'], 0);
      there.take(wire(first));
      expect(there.on(2).single.points, s.points);
      grow(s, 5);
      final second = lane.next(here, now: now)!;
      expect(second['f'], 3);
      there.take(wire(second));
      expect(there.on(2).single.points, s.points);
      expect(there.on(2).single.color.toARGB32(), Colors.red.toARGB32());
      expect(lane.next(here, now: now), isNull, reason: 'nothing new, nothing sent');
    });

    test('one point shows nothing and is not sent', () {
      final here = book();
      here.drawing('a', 0, line('s', points: 1));
      expect(WetLane().next(here, now: now), isNull);
    });

    test('on a slow link the points pile up and go as one message when the link is free again', () {
      final here = book(), there = book();
      final lane = WetLane();
      final s = line('s');
      here.drawing('a', 0, s);
      final first = lane.next(here, now: now)!;
      lane.busy = true; // (the link has not taken it yet)
      for (var i = 0; i < 20; i++) {
        grow(s, 1);
        expect(lane.next(here, now: now), isNull);
      }
      lane.busy = false;
      there.take(wire(first));
      final catchUp = lane.next(here, now: now)!;
      there.take(wire(catchUp));
      expect(there.on(0).single.points.length, 23);
      expect(lane.next(here, now: now), isNull);
    });

    test('a poor link is sent at most every so often', () {
      final here = book();
      final lane = WetLane(gap: const Duration(milliseconds: 300));
      final s = line('s');
      here.drawing('a', 0, s);
      expect(lane.next(here, now: now), isNotNull);
      grow(s, 2);
      now = now.add(const Duration(milliseconds: 100));
      expect(lane.next(here, now: now), isNull);
      now = now.add(const Duration(milliseconds: 250));
      expect(lane.next(here, now: now), isNotNull);
    });

    test('a message that was lost leaves a gap: what comes after waits until the whole line comes again', () {
      final here = book(), there = book();
      final lane = WetLane();
      final s = line('s');
      here.drawing('a', 0, s);
      there.take(wire(lane.next(here, now: now)!));
      grow(s, 4);
      lane.next(here, now: now); // (lost)
      grow(s, 4);
      there.take(wire(lane.next(here, now: now)!));
      expect(there.on(0).single.points.length, 3, reason: 'nothing after a gap is drawn in the wrong place');
      expect(there['s']!.broken, isTrue);
      // the link was made again: the lane starts over and sends it whole
      lane.reset();
      there.take(wire(lane.next(here, now: now)!));
      expect(there.on(0).single.points, s.points);
      expect(there['s']!.broken, isFalse);
    });

    test('a message that comes twice, or overlaps what is there, adds each point once', () {
      final here = book(), there = book();
      final lane = WetLane();
      final s = line('s');
      here.drawing('a', 0, s);
      final m1 = wire(lane.next(here, now: now)!);
      grow(s, 3);
      final m2 = wire(lane.next(here, now: now)!);
      there.take(m1);
      there.take(m2);
      there.take(m2);
      there.take(m1);
      expect(there.on(0).single.points, s.points);
    });

    test('a shape being drawn is made again as the pen moves: the other device always shows the shape as it is now', () {
      final here = book(), there = book();
      final lane = WetLane();
      final s = line('box', points: 5);
      here.drawing('a', 0, s);
      there.take(wire(lane.next(here, now: now)!));
      for (var k = 1; k < 6; k++) {
        s.points
          ..clear()
          ..addAll([for (var i = 0; i < 5; i++) Offset(i * 10.0 * k, k * 1.0)]);
        here.drawing('a', 0, s);
        final m = wire(lane.next(here, now: now)!);
        expect(m['f'], 0, reason: 'the whole shape goes');
        there.take(m);
        expect(there.on(0).single.points, s.points);
      }
    });

    test('an older shape that comes late does not replace a newer one', () {
      final here = book(), there = book();
      final lane = WetLane();
      final s = line('box', points: 5);
      here.drawing('a', 0, s);
      final old = wire(lane.next(here, now: now)!);
      s.points
        ..clear()
        ..addAll([for (var i = 0; i < 5; i++) Offset(i * 7.0, 1)]);
      here.drawing('a', 0, s);
      final newer = wire(lane.next(here, now: now)!);
      there.take(newer);
      there.take(old);
      expect(there.on(0).single.points, s.points);
    });

    test('pressure goes along, and stays as long as the line', () {
      final here = book(), there = book();
      final lane = WetLane();
      final s = line('s')..pressures = [10, 20, 30];
      here.drawing('a', 0, s);
      there.take(wire(lane.next(here, now: now)!));
      grow(s, 2);
      s.pressures!.addAll([40, 50]);
      there.take(wire(lane.next(here, now: now)!));
      expect(there.on(0).single.pressures, [10, 20, 30, 40, 50]);
    });

    test('a line goes when its finished form comes, and a late message about it does not bring it back', () {
      final here = book(), there = book();
      final lane = WetLane();
      final s = line('s');
      here.drawing('a', 0, s);
      final m = wire(lane.next(here, now: now)!);
      there.take(m);
      expect(there.finished('s'), isTrue);
      expect(there.on(0), isEmpty);
      there.take(m);
      expect(there.on(0), isEmpty);
    });

    test('a line that was not kept (a tap) goes on the other device as soon as it hears so', () {
      final here = book(), there = book();
      final lane = WetLane();
      final s = line('s');
      here.drawing('a', 0, s);
      there.take(wire(lane.next(here, now: now)!));
      here.ended('s', kept: false);
      final end = wire(lane.next(here, now: now)!);
      expect(end['x'], 2);
      there.take(end);
      expect(there.on(0), isEmpty);
    });

    test('a line whose pen was lifted stays until its finished form comes, or a little while', () {
      final here = book(), there = book();
      final lane = WetLane();
      final s = line('s');
      here.drawing('a', 0, s);
      there.take(wire(lane.next(here, now: now)!));
      here.ended('s', kept: true);
      final end = wire(lane.next(here, now: now)!);
      expect(end['x'], 1);
      there.take(end);
      expect(there.on(0), hasLength(1));
      now = now.add(WetBook.endedFor + const Duration(milliseconds: 1));
      there.expire('b');
      expect(there.on(0), isEmpty);
    });

    test('a line nothing more comes of (the link of who draws it is gone) goes after a while', () {
      final here = book(), there = book();
      here.drawing('a', 0, line('s'));
      there.take(wire(WetLane().next(here, now: now)!));
      now = now.add(WetBook.staleAfter - const Duration(seconds: 1));
      there.expire('b');
      expect(there.on(0), hasLength(1));
      now = now.add(const Duration(seconds: 2));
      there.expire('b');
      expect(there.on(0), isEmpty);
    });

    test('a line of this device the screen never ended is given up on, as kept, after a long while', () {
      final here = book();
      here.drawing('a', 0, line('s'));
      now = now.add(const Duration(seconds: 10));
      expect(here.expire('a'), isEmpty, reason: 'the pen may rest');
      now = now.add(WetBook.abandonedAfter);
      expect(here.expire('a'), ['s']);
      expect(here['s']!.ended, isTrue);
      expect(here.droppedOf('s'), isFalse);
    });

    test('the lines of the device itself are not shown by it as wet ink (its screen draws them)', () {
      final here = book();
      here.drawing('a', 0, line('mine'));
      expect(here.on(0, except: 'a'), isEmpty);
    });

    test('a guest sends only its own lines to the host; the host sends a guest everybody\'s but its own', () {
      final host = book();
      host.drawing('host', 0, line('h'));
      host.take(wire(WetLane().next(book()..drawing('g1', 0, line('g1')), now: now)!));
      host.take(wire(WetLane().next(book()..drawing('g2', 0, line('g2')), now: now)!));
      final toG1 = book();
      deliver(WetLane(), host, toG1, except: 'g1');
      expect({for (final w in toG1.all) w.id}, {'h', 'g2'});
      final guest = book()..drawing('g1', 0, line('mine'));
      guest.take(wire(WetLane().next(book()..drawing('g2', 0, line('other')), now: now)!));
      final toHost = book();
      deliver(WetLane(), guest, toHost, only: 'g1');
      expect({for (final w in toHost.all) w.id}, {'mine'});
    });

    test('lines drawn at the same time (a line and its mirror images) all grow in each message, however busy the link', () {
      final here = book(), there = book();
      final lane = WetLane(gap: const Duration(milliseconds: 300));
      final lines = [line('a'), line('a-mirror'), line('a-mirror-2')];
      for (final s in lines) {
        here.drawing('a', 0, s);
      }
      for (var round = 0; round < 6; round++) {
        final m = lane.batch(here, now: now);
        expect(m, isNotNull);
        expect(m!['all'], hasLength(3), reason: 'every line that has something new, in one message');
        expect(there.take(wire(m)), isTrue);
        for (final s in lines) {
          expect(there[s.id]!.stroke.points, s.points, reason: 'round $round: ${s.id}');
        }
        for (final s in lines) {
          grow(s, 2);
          here.drawing('a', 0, s);
        }
        expect(lane.batch(here, now: now), isNull, reason: 'the gap of a poor link holds for the batch as a whole');
        now = now.add(const Duration(milliseconds: 301));
      }
    });

    test('a batch of one line is the message of that line; a batch with nothing new is nothing', () {
      final here = book();
      final lane = WetLane();
      here.drawing('a', 0, line('s'));
      final m = lane.batch(here, now: now)!;
      expect(m['i'], 's');
      expect(m.containsKey('all'), isFalse);
      expect(lane.batch(here, now: now), isNull);
    });

    test('in a batch, a guest speaks only for its own lines, and the lines of this device are never taken from a message', () {
      final g1 = book()
        ..drawing('g1', 0, line('mine'))
        ..take(wire(WetLane().next(book()..drawing('g2', 0, line('theirs')), now: now)!));
      final batch = wire(WetLane().batch(g1, now: now)!);
      expect(batch['all'], hasLength(2));
      final host = book();
      expect(host.take(batch, from: 'g1'), isTrue);
      expect({for (final w in host.all) w.id}, {'mine'}, reason: 'g1 cannot say what g2 draws');

      final drawing = line('own', points: 5);
      final self = book()..drawing('me', 0, drawing);
      final echo = wire(WetLane().next(book()..drawing('me', 0, line('own', points: 2)), now: now)!);
      expect(self.take(echo, self: 'me'), isFalse);
      expect(drawing.points, hasLength(5), reason: 'the line the pen draws here is not touched');
    });

    test('a batch that is too long is taken only so far', () {
      final big = book();
      final senders = [for (var i = 0; i < WetBook.maxPerMessage + 40; i++) wire(WetLane().next(book()..drawing('x', 0, line('l$i')), now: now)!)];
      expect(big.take({'t': 'wet', 'all': senders}), isTrue);
      expect(big.all.length, lessThanOrEqualTo(WetBook.maxStrokes));
      expect(() => big.take({'t': 'wet', 'all': 'junk'}), returnsNormally);
      expect(() => big.take({'t': 'wet', 'all': [1, null, 'x', [], {}]}), returnsNormally);
    });

    test('a device cannot continue another device\'s line', () {
      final there = book();
      there.take(wire(WetLane().next(book()..drawing('a', 0, line('s')), now: now)!));
      final fake = wire(WetLane().next(book()..drawing('b', 0, line('s', points: 9)), now: now)!);
      expect(there.take(fake), isFalse);
      expect(there.on(0).single.points.length, 3);
    });
  });

  group('what another device sends is checked', () {
    test('garbage never throws and never makes a line', () {
      final r = Random(4);
      final there = book();
      Object? junk() => switch (r.nextInt(6)) {
            0 => r.nextInt(1 << 20) - 100,
            1 => 'x' * r.nextInt(30),
            2 => null,
            3 => [1, 'a'],
            4 => base64Encode(List.generate(r.nextInt(40), (_) => r.nextInt(256))),
            _ => -1.5,
          };
      for (var i = 0; i < 5000; i++) {
        final m = <String, Object?>{'t': 'wet', for (final k in ['i', 's', 'p', 'f', 'pts', 'pr', 'c', 'w', 'b', 'd', 'x', 'all']) if (r.nextInt(5) > 0) k: junk()};
        expect(() => there.take(m), returnsNormally);
      }
      for (final w in there.all) {
        expect(w.stroke.points.length, lessThanOrEqualTo(WetBook.maxPoints));
      }
      expect(there.all.length, lessThanOrEqualTo(WetBook.maxStrokes));
    });

    test('there is a limit to how many lines another device can have in the book', () {
      final there = book();
      for (var i = 0; i < 200; i++) {
        there.take(wire(WetLane().next(book()..drawing('a', 0, line('s$i')), now: now)!));
      }
      expect(there.all.length, WetBook.maxStrokes);
    });
  });
}
