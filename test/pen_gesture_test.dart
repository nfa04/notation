import 'dart:math' as math;


import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/pen_gesture.dart';

const _line = 24.0;

/// Points along [corners], [per] between each two.
List<Offset> _along(List<Offset> corners, {int per = 6}) => [
      for (var i = 0; i + 1 < corners.length; i++)
        for (var k = 0; k < per; k++) Offset.lerp(corners[i], corners[i + 1], k / per)!,
      corners.last,
    ];

List<Offset> _zigzag({double left = 100, double width = 60, double y = 200, int passes = 5, double wobble = 3}) => _along([
      for (var i = 0; i <= passes; i++) Offset(i.isEven ? left : left + width, y + (i.isEven ? -wobble : wobble)),
    ]);

List<Offset> _loop({Offset centre = const Offset(200, 200), double rx = 40, double ry = 16, double turns = 1.05, double sign = 1}) => [
      for (var i = 0; i <= 40; i++) centre + Offset(math.cos(sign * 2 * math.pi * turns * i / 40) * rx, math.sin(sign * 2 * math.pi * turns * i / 40) * ry),
    ];

void main() {
  group('a zigzag', () {
    test('over a word is a scratch out', () {
      final g = recognizePenGesture(_zigzag(), _line);
      expect(g?.kind, PenGestureKind.scratchOut);
      expect(g!.box.left, 100);
      expect(g.box.right, 160);
    });

    test('three passes are not enough, a wide scribble over a page is none, a straight drag along a line is none', () {
      expect(recognizePenGesture(_zigzag(passes: 2), _line), isNull);
      expect(recognizePenGesture(_zigzag(width: 400, passes: 6), _line)?.kind, isNot(PenGestureKind.scratchOut), reason: 'bigger than a gesture is');
      expect(recognizePenGesture(_along([const Offset(100, 200), const Offset(300, 201)]), _line), isNull);
    });

    test('a shake too small to mean it is none (the hand of someone writing)', () {
      expect(recognizePenGesture(_zigzag(width: 8, passes: 8), _line), isNull);
    });

    test('over several lines it is not a scratch out', () {
      final tall = _along([for (var i = 0; i <= 5; i++) Offset(i.isEven ? 100 : 160, 100 + i * 20.0)]);
      expect(recognizePenGesture(tall, _line)?.kind, isNot(PenGestureKind.scratchOut));
    });
  });

  group('a loop', () {
    test('round words is a circle, whichever way it goes', () {
      expect(recognizePenGesture(_loop(), _line)?.kind, PenGestureKind.circle);
      expect(recognizePenGesture(_loop(sign: -1), _line)?.kind, PenGestureKind.circle);
    });

    test('that does not come back to where it began is none, nor half a circle', () {
      expect(recognizePenGesture(_loop(turns: 0.5), _line), isNull);
      expect(recognizePenGesture(_loop(turns: 0.75), _line), isNull);
    });

    test('that is too small for a letter is none', () {
      expect(recognizePenGesture(_loop(rx: 4, ry: 4), _line), isNull);
    });
  });

  group('a stroke down', () {
    test('about a line tall is a split or join', () {
      final g = recognizePenGesture(_along([const Offset(150, 190), const Offset(151, 214)]), _line);
      expect(g?.kind, PenGestureKind.splitOrJoin);
      expect(g!.box.center.dx, closeTo(150.5, 0.01));
    });

    test('that is short, long or bent is none', () {
      expect(recognizePenGesture(_along([const Offset(150, 200), const Offset(150, 208)]), _line), isNull);
      expect(recognizePenGesture(_along([const Offset(150, 150), const Offset(150, 250)]), _line), isNull);
      expect(recognizePenGesture(_along([const Offset(150, 190), const Offset(165, 202), const Offset(150, 214)]), _line), isNull);
    });
  });

  test('a stroke of a few points, or a line of no height, is none', () {
    expect(recognizePenGesture([const Offset(1, 1), const Offset(2, 2)], _line), isNull);
    expect(recognizePenGesture(_zigzag(), 0), isNull);
  });

  test('the size of a gesture goes by the size of the text', () {
    // the same zigzag over text twice as tall is too small to mean it
    expect(recognizePenGesture(_zigzag(width: 30), _line)?.kind, PenGestureKind.scratchOut);
    expect(recognizePenGesture(_zigzag(width: 30), _line * 2), isNull);
  });
}
